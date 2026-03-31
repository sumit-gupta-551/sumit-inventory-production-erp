import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Checks GitHub repo for a newer APK and installs it.
///
/// How it works:
///   1. Reads version.json from the repo (raw.githubusercontent.com).
///   2. Compares remote version with [currentVersion].
///   3. Downloads the APK directly from the repo.
///   4. Update version.json, build APK, push to git for each new version.
class AppUpdater {
  AppUpdater._();

  // ──────── CONFIGURE THESE ────────
  static const owner = 'sumit-gupta-551';
  static const repo = 'sumit-inventory-production-erp';
  static const branch = 'main';
  static const currentVersion = '1.0.2';
  // ──────────────────────────────────

  static String _rawUrl(String path) =>
      'https://raw.githubusercontent.com/$owner/$repo/$branch/$path';

  static String _repoFileUrl(String path) =>
      'https://github.com/$owner/$repo/raw/$branch/$path';

  /// Check GitHub repo version.json for a newer version. Returns info or null.
  static Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(
        Uri.parse(_rawUrl('version.json')),
      );
      final response = await request.close();
      if (response.statusCode != 200) return null;

      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final remoteVersion = (data['version'] ?? '').toString();
      final apkName = (data['apk'] ?? '').toString();
      final notes = (data['notes'] ?? '').toString();

      if (apkName.isEmpty) return null;

      if (_isNewer(remoteVersion, currentVersion)) {
        return {
          'version': remoteVersion,
          'downloadUrl': _repoFileUrl(apkName),
          'releaseNotes': notes,
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

    // Show progress dialog
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

      // Download
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(downloadUrl));
      final response = await request.close();

      if (response.statusCode == 200 ||
          response.statusCode == 301 ||
          response.statusCode == 302) {
        // Handle redirects
        HttpClientResponse finalResponse = response;
        if (response.isRedirect || response.statusCode == 302) {
          final redirectUrl = response.headers.value('location');
          if (redirectUrl != null) {
            final req2 = await client.getUrl(Uri.parse(redirectUrl));
            finalResponse = await req2.close();
          }
        }
        final bytes = await finalResponse.fold<List<int>>(
          [],
          (prev, chunk) => prev..addAll(chunk),
        );
        await file.writeAsBytes(bytes);
      } else {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      navigator.pop(); // close progress dialog

      // Open APK for installation
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
      navigator.pop(); // close progress dialog
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
