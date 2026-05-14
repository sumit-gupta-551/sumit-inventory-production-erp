import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' as sql;

import 'erp_database.dart';
import 'firebase_sync_service.dart';

/// Read-only pull-from-Firebase sync used on platforms where the native
/// firebase_database plugin isn't available (Windows / Linux desktop).
///
/// Mirrors the table set & write semantics of [FirebaseSyncService._pullTable]
/// but uses the Realtime Database REST API. The desktop app NEVER pushes —
/// it only mirrors what mobile devices have already written.
class RestPullSyncService {
  RestPullSyncService._();
  static final RestPullSyncService instance = RestPullSyncService._();

  static const _dbUrl =
      'https://mayur-synthetics-default-rtdb.asia-southeast1.firebasedatabase.app';

  /// All app data lives under /sync on the server (matches FirebaseSyncService).
  static const _rootPath = 'sync';

  /// Same list used by FirebaseSyncService so Windows mirrors all data.
  static const _tables = [
    'gst_categories',
    'products',
    'parties',
    'fabric_shades',
    'firms',
    'machines',
    'thread_shades',
    'delay_reasons',
    'stock_ledger',
    'order_master',
    'order_items',
    'purchase_master',
    'purchase_items',
    'challan_requirements',
    'units',
    'employees',
    'production_entries',
    'attendance',
    'employee_salary_history',
    'salary_advances',
    'salary_payments',
    'saved_payroll',
    'program_master',
    'program_fabrics',
    'program_thread_shades',
    'program_allotment',
    'program_logs',
    'program_cards',
    'dispatch_bills',
    'dispatch_items',
    'activity_log',
  ];

  static const _batchSize = 50;
  static const _httpTimeout = Duration(seconds: 30);
  static const _autoInterval = Duration(seconds: 60);

  Timer? _timer;
  bool _running = false;
  DateTime? _lockBackoffUntil;
  int _lockBackoffSec = 0;

  bool _isDbLockedError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('database is locked') ||
        msg.contains('sqlite_error: 5') ||
        msg.contains('(code 5)');
  }

  bool _isLockedMessage(String message) => _isDbLockedError(message);

  Future<T> _dbRetry<T>(
    Future<T> Function() action, {
    String op = 'db op',
    int maxAttempts = 8,
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } catch (e) {
        if (!_isDbLockedError(e) || attempt >= maxAttempts) rethrow;
        final waitMs = 120 * attempt * attempt;
        debugPrint(
            'REST pull retry ($op) locked [attempt $attempt/$maxAttempts], waiting ${waitMs}ms');
        await Future.delayed(Duration(milliseconds: waitMs));
      }
    }
    throw Exception('Unexpected retry flow exit ($op)');
  }

  /// Notifies UI when state changes (running flag, last sync time, last error).
  final ValueNotifier<DateTime?> lastSyncAt = ValueNotifier(null);
  final ValueNotifier<bool> isSyncing = ValueNotifier(false);
  final ValueNotifier<String?> lastError = ValueNotifier(null);

  /// Start the background pull loop. Safe to call multiple times.
  void start({
    Duration interval = _autoInterval,
    Duration initialDelay = Duration.zero,
  }) {
    _timer?.cancel();
    // Kick off an immediate pull, then schedule periodic ones.
    if (initialDelay <= Duration.zero) {
      unawaited(pullNow());
    } else {
      Timer(initialDelay, () => unawaited(pullNow()));
    }
    _timer = Timer.periodic(interval, (_) => unawaited(pullNow()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Manually trigger a full pull. UI can await this for a "Sync Now" button.
  Future<bool> pullNow() async {
    if (_running) return false;
    final now = DateTime.now();
    if (_lockBackoffUntil != null && now.isBefore(_lockBackoffUntil!)) {
      return false;
    }
    _running = true;
    isSyncing.value = true;
    lastError.value = null;
    var ok = true;
    final failures = <String>[];
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final db = await ErpDatabase.instance.database;
      var totalRows = 0;
      var lockedDetected = false;
      final sync = FirebaseSyncService.instance;
      await sync.retryPendingNow();
      for (final table in _tables) {
        final hasPendingLocal = await sync.hasPendingSyncForTable(table);
        if (hasPendingLocal) {
          debugPrint(
              'REST pull skipped $table: local pending sync exists (protect local edits)');
          continue;
        }
        final res = await _pullTable(client, db, table);
        if (res.error != null) {
          ok = false;
          failures.add('$table: ${res.error}');
          if (_isLockedMessage(res.error!)) {
            failures.add('Local database busy; remaining tables skipped.');
            lockedDetected = true;
            break;
          }
        } else {
          totalRows += res.rowsUpserted;
          debugPrint('✓ REST pull $table: ${res.rowsUpserted} rows');
        }
      }
      if (lockedDetected) {
        _lockBackoffSec = _lockBackoffSec == 0
            ? 30
            : math.min(_lockBackoffSec * 2, 300);
        _lockBackoffUntil =
            DateTime.now().add(Duration(seconds: _lockBackoffSec));
        debugPrint(
            'REST pull paused for ${_lockBackoffSec}s due to DB lock. Will retry automatically.');
      } else if (ok) {
        _lockBackoffSec = 0;
        _lockBackoffUntil = null;
      }
      debugPrint('REST pull complete. Total upserted: $totalRows');
      lastSyncAt.value = DateTime.now();
      if (!ok) {
        lastError.value = failures.take(3).join(' | ');
        debugPrint('⚠ REST pull had errors: ${failures.join(' | ')}');
      }
      // Notify pages that data changed so they refresh.
      ErpDatabase.instance.dataVersion.value++;
    } catch (e) {
      ok = false;
      lastError.value = e.toString();
      debugPrint('⚠ REST pull failed: $e');
    } finally {
      client?.close(force: true);
      isSyncing.value = false;
      _running = false;
    }
    return ok;
  }

  Future<_PullResult> _pullTable(
    HttpClient client,
    sql.Database db,
    String table,
  ) async {
    var upserted = 0;
    try {
      final uri = Uri.parse('$_dbUrl/$_rootPath/$table.json');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(_httpTimeout);
      if (resp.statusCode != 200) {
        final body = await resp.transform(utf8.decoder).join();
        final msg = 'HTTP ${resp.statusCode} ${body.isNotEmpty ? body : ''}'
            .trim();
        debugPrint('⚠ REST pull $table $msg');
        return _PullResult(error: msg);
      }
      final body = await resp.transform(utf8.decoder).join();
      if (body.isEmpty || body == 'null') {
        // Remote node missing — leave local data untouched.
        return _PullResult();
      }
      final decoded = jsonDecode(body);

      final map = <String, dynamic>{};
      if (decoded is Map) {
        decoded.forEach((k, v) => map['$k'] = v);
      } else if (decoded is List) {
        for (var i = 0; i < decoded.length; i++) {
          final v = decoded[i];
          if (v != null) map['$i'] = v;
        }
      } else {
        return _PullResult();
      }

      // --- Build local id set in pages of _batchSize ---
      final localIds = <int>{};
      var lastId = 0;
      while (true) {
        final rows = await _dbRetry(
          () => db.query(
            table,
            columns: ['id'],
            where: 'id > ?',
            whereArgs: [lastId],
            orderBy: 'id ASC',
            limit: _batchSize,
          ),
          op: 'query ids $table',
        );
        if (rows.isEmpty) break;
        for (final r in rows) {
          final id = r['id'] as int?;
          if (id != null) {
            localIds.add(id);
            lastId = id;
          }
        }
      }

      final remoteIds = <int>{};
      var batch = db.batch();
      var pending = 0;

      Future<void> flush() async {
        if (pending == 0) return;
        await _dbRetry(
          () => batch.commit(noResult: true, continueOnError: true),
          op: 'batch commit $table',
        );
        batch = db.batch();
        pending = 0;
      }

      for (final entry in map.entries) {
        final id = int.tryParse(entry.key.toString());
        if (id == null || entry.value is! Map) continue;

        final data = Map<String, dynamic>.from(entry.value as Map);

        // Mirror the soft-delete handling used by the mobile sync service.
        if (table == 'stock_ledger' && _isDeletedFlag(data['is_deleted'])) {
          continue;
        }

        remoteIds.add(id);
        data.remove('_ts');
        data['id'] = id;

        batch.insert(
          table,
          data,
          conflictAlgorithm: sql.ConflictAlgorithm.replace,
        );
        upserted++;
        pending++;
        if (pending >= _batchSize) await flush();
      }

      // Delete locals that no longer exist remotely (only if we successfully
      // received the table — we already returned early if body was 'null').
      for (final localId in localIds) {
        if (!remoteIds.contains(localId)) {
          batch.delete(table, where: 'id=?', whereArgs: [localId]);
          pending++;
          if (pending >= _batchSize) await flush();
        }
      }

      await flush();
      return _PullResult(rowsUpserted: upserted);
    } catch (e) {
      debugPrint('⚠ REST pull table $table failed: $e');
      return _PullResult(error: e.toString());
    }
  }

  bool _isDeletedFlag(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.toLowerCase();
      return s == 'true' || s == '1' || s == 'yes';
    }
    return false;
  }
}

class _PullResult {
  _PullResult({this.rowsUpserted = 0, this.error});
  final int rowsUpserted;
  final String? error;
}
