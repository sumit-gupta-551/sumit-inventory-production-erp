import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Checks GitHub Releases for a newer APK and installs it.
///
/// Setup:
///   1. Create a GitHub repo (public or private).
///   2. Go to Releases → "Create a new release".
///   3. Tag = version name, e.g. "1.0.1"
///   4. Attach the APK file (app-release.apk).
///   5. Set [owner] and [repo] below.
///   6. Update [version] in pubspec.yaml before each build.
class AppUpdater {
  AppUpdater._();

  // ──────── CONFIGURE THESE ────────
  /// GitHub username or organization
  static const owner = 'sumit-gupta-551';

  /// GitHub repository name
  static const repo = 'sumit-inventory-production-erp';

  /// Current app version (must match pubspec.yaml version)
  static const currentVersion = '1.0.0';
  // ──────────────────────────────────

  /// Check GitHub for a newer release. Returns release info or null.
  static Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(
        Uri.parse(
            'https://api.github.com/repos/$owner/$repo/releases/latest'),
      );
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      final response = await request.close();
      if (response.statusCode != 200) return null;

      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final tagName = (data['tag_name'] ?? '').toString().replaceAll('v', '');

      if (_isNewer(tagName, currentVersion)) {
        // Find the .apk asset
        final assets = data['assets'] as List<dynamic>? ?? [];
        final apkAsset = assets.cast<Map<String, dynamic>>().firstWhere(
              (a) =>
                  (a['name'] ?? '').toString().toLowerCase().endsWith('.apk'),
              orElse: () => <String, dynamic>{},
            );
        final downloadUrl =
            (apkAsset['browser_download_url'] ?? '').toString();
        if (downloadUrl.isEmpty) return null;

        return {
          'version': tagName,
          'downloadUrl': downloadUrl,
          'releaseNotes': (data['body'] ?? '').toString(),
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

      // Trigger APK install via Android intent
      final result = await Process.run('am', [
        'start',
        '-a',
        'android.intent.action.VIEW',
        '-t',
        'application/vnd.android.package-archive',
        '-d',
        'file://$filePath',
        '--grant-read-uri-permission',
      ]);

      // Fallback: use content:// URI with FileProvider
      if (result.exitCode != 0) {
        await Process.run('am', [
          'start',
          '-a',
          'android.intent.action.INSTALL_PACKAGE',
          '-d',
          Uri.file(filePath).toString(),
        ]);
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text('APK downloaded. Check notifications to install v$version.'),
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
