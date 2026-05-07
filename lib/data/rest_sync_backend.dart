import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// REST-based writes to Firebase Realtime Database for desktop (Windows /
/// Linux), where the native firebase_database plugin isn't available.
///
/// Mirrors what FirebaseSyncService does on mobile:
///   - getNextId(table)      -> atomic counter at /sync/_counters/<table>
///   - push(table, id, data) -> PUT /sync/<table>/<id> with _ts server stamp
///   - delete(table, id)     -> DELETE /sync/<table>/<id>
class RestSyncBackend {
  RestSyncBackend._();
  static final RestSyncBackend instance = RestSyncBackend._();

  static const _dbUrl =
      'https://mayur-synthetics-default-rtdb.asia-southeast1.firebasedatabase.app';
  static const _root = 'sync';
  static const _httpTimeout = Duration(seconds: 20);
  static const _maxCounterRetries = 8;

  HttpClient _newClient() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 15);

  /// Atomic counter via Firebase REST conditional update (ETag / If-Match).
  /// Retries on 412 (someone else incremented in parallel).
  Future<int> getNextId(String table) async {
    final client = _newClient();
    try {
      final uri = Uri.parse('$_dbUrl/$_root/_counters/$table.json');
      Object? lastError;
      for (var attempt = 0; attempt < _maxCounterRetries; attempt++) {
        try {
          // 1) GET current value with ETag.
          final getReq = await client.getUrl(uri);
          getReq.headers.set('X-Firebase-ETag', 'true');
          final getResp = await getReq.close().timeout(_httpTimeout);
          final getBody =
              await getResp.transform(utf8.decoder).join();
          if (getResp.statusCode != 200) {
            throw 'counter GET HTTP ${getResp.statusCode}: $getBody';
          }
          final etag = getResp.headers.value('ETag') ?? '';
          final current = (jsonDecode(getBody.isEmpty ? 'null' : getBody)
                  as Object?) ??
              0;
          final currentInt = current is int
              ? current
              : (current is num ? current.toInt() : 0);
          final next = currentInt + 1;

          // 2) Conditional PUT.
          final putReq = await client.putUrl(uri);
          putReq.headers.set('Content-Type', 'application/json');
          if (etag.isNotEmpty) {
            putReq.headers.set('if-match', etag);
          }
          putReq.write(jsonEncode(next));
          final putResp = await putReq.close().timeout(_httpTimeout);
          final putBody =
              await putResp.transform(utf8.decoder).join();
          if (putResp.statusCode == 200) {
            return next;
          }
          if (putResp.statusCode == 412) {
            // ETag mismatch -> someone else incremented; retry.
            continue;
          }
          throw 'counter PUT HTTP ${putResp.statusCode}: $putBody';
        } catch (e) {
          lastError = e;
        }
      }
      throw 'getNextId($table) failed after $_maxCounterRetries retries: '
          '${lastError ?? 'unknown'}';
    } finally {
      client.close(force: true);
    }
  }

  /// PUT /sync/<table>/<id> with `_ts` server-timestamp sentinel.
  Future<void> push(String table, int id, Map<String, dynamic> data) async {
    final client = _newClient();
    try {
      final uri = Uri.parse('$_dbUrl/$_root/$table/$id.json');
      final payload = Map<String, dynamic>.from(data);
      // Server-side timestamp sentinel — Firebase replaces with epoch ms.
      payload['_ts'] = {'.sv': 'timestamp'};

      final req = await client.putUrl(uri);
      req.headers.set('Content-Type', 'application/json');
      req.write(jsonEncode(payload));
      final resp = await req.close().timeout(_httpTimeout);
      if (resp.statusCode != 200) {
        final body = await resp.transform(utf8.decoder).join();
        throw 'push HTTP ${resp.statusCode}: $body';
      }
      // Drain body.
      await resp.drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  /// DELETE /sync/<table>/<id>
  Future<void> delete(String table, int id) async {
    final client = _newClient();
    try {
      final uri = Uri.parse('$_dbUrl/$_root/$table/$id.json');
      final req = await client.deleteUrl(uri);
      final resp = await req.close().timeout(_httpTimeout);
      if (resp.statusCode != 200) {
        final body = await resp.transform(utf8.decoder).join();
        // 404-ish responses can come back as 200 with body "null" — anything
        // non-200 we surface so the caller can queue for retry.
        debugPrint('⚠ REST delete $table/$id HTTP ${resp.statusCode}: $body');
        throw 'delete HTTP ${resp.statusCode}: $body';
      }
      await resp.drain<void>();
    } finally {
      client.close(force: true);
    }
  }
}
