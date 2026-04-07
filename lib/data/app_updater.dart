import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Checks GitHub Releases for a newer APK and installs it.
///
/// To release an update:
///   1. Bump [currentVersion] below and version in pubspec.yaml
///   2. Build APK: flutter build apk
///   3. Go to GitHub → Releases → Create new release
///   4. Tag: v1.0.1 (match the version)
///   5. Attach the app-release.apk file
///   6. Publish the release
class AppUpdater {
  AppUpdater._();

  static const _owner = 'sumit-gupta-551';
  static const _repo = 'sumit-inventory-production-erp';

  /// Current app version (must match pubspec.yaml version)
  static const currentVersion = '1.0.9';

  /// Check GitHub Releases for a newer release. Returns release info or null.
  static Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final request = await client.getUrl(Uri.parse(
          'https://api.github.com/repos/$_owner/$_repo/releases/latest'));
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      final response = await request.close();

      if (response.statusCode != 200) return null;

      final body = await response.transform(utf8.decoder).join();
      final data = json.decode(body) as Map<String, dynamic>;

      final tagName = (data['tag_name'] ?? '').toString().replaceFirst('v', '');
      final releaseNotes = (data['body'] ?? '').toString();
      final assets = data['assets'] as List<dynamic>? ?? [];

      String? downloadUrl;
      for (final asset in assets) {
        final name = (asset['name'] ?? '').toString().toLowerCase();
        if (name.endsWith('.apk')) {
          downloadUrl = asset['browser_download_url']?.toString();
          break;
        }
      }

      if (tagName.isEmpty || downloadUrl == null) return null;

      if (_isNewer(tagName, currentVersion)) {
        return {
          'version': tagName,
          'downloadUrl': downloadUrl,
          'releaseNotes': releaseNotes,
          'forceUpdate': false,
        };
      }
      return null;
    } catch (e) {
      debugPrint('⚠ Update check failed: $e');
      return null;
    }
  }

  /// Download APK and trigger install.
  static Future<void> downloadAndInstall(
    BuildContext context,
    String downloadUrl,
    String version,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Downloading v$version...'),
            ],
          ),
        ),
      ),
    );

    try {
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/app-update-$version.apk';
      final file = File(filePath);

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);
      final request = await client.getUrl(Uri.parse(downloadUrl));
      final response = await request.close();

      if (response.statusCode == 200) {
        final bytes = await response.fold<List<int>>(
          [],
          (prev, chunk) => prev..addAll(chunk),
        );
        await file.writeAsBytes(bytes);
      } else if (response.statusCode == 301 ||
          response.statusCode == 302 ||
          response.statusCode == 307) {
        final redirectUrl = response.headers.value('location');
        if (redirectUrl != null) {
          final req2 = await client.getUrl(Uri.parse(redirectUrl));
          final resp2 = await req2.close();
          final bytes = await resp2.fold<List<int>>(
            [],
            (prev, chunk) => prev..addAll(chunk),
          );
          await file.writeAsBytes(bytes);
        } else {
          throw Exception('Redirect without location header');
        }
      } else {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      navigator.pop();

      final result = await OpenFilex.open(filePath,
          type: 'application/vnd.android.package-archive');

      if (result.type != ResultType.done) {
        messenger.showSnackBar(
          SnackBar(
              content: Text('Could not open installer: ${result.message}')),
        );
        return;
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text('Installing v$version...'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text('Update failed: $e')),
      );
    }
  }

  /// Compare two version strings (e.g. "1.0.1" > "1.0.0").
  static bool _isNewer(String remote, String local) {
    final rParts = remote.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final lParts = local.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final len = rParts.length > lParts.length ? rParts.length : lParts.length;
    for (var i = 0; i < len; i++) {
      final r = i < rParts.length ? rParts[i] : 0;
      final l = i < lParts.length ? lParts[i] : 0;
      if (r > l) return true;
      if (r < l) return false;
    }
    return false;
  }
}
