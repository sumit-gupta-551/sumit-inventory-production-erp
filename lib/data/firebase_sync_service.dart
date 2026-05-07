import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' as sql;

import 'erp_database.dart';
import 'rest_sync_backend.dart';

/// Keeps all 10+ devices in sync via Firebase Realtime Database.
///
/// Flow:
///   - Every insert/update/delete goes to local SQLite AND Firebase.
///   - IDs are generated centrally via Firebase atomic counters,
///     so all devices share the same IDs (no foreign-key conflicts).
///   - On startup, [fullSync] pulls all Firebase data into local SQLite.
///   - Real-time listeners push remote changes into local SQLite immediately.
///   - Failed pushes/deletes are persisted to SQLite and retried automatically.
class FirebaseSyncService {
  static final FirebaseSyncService instance = FirebaseSyncService._();
  FirebaseSyncService._();

  /// SharedPreferences flag used to mark that a device has completed its
  /// initial full restore from Firebase.
  static const initialFullSyncDonePrefKey = 'initial_full_sync_done_v1';

  static const _dbUrl =
      'https://mayur-synthetics-default-rtdb.asia-southeast1.firebasedatabase.app';

  static const _syncTables = [
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
  static const _dbBatchSize = 50;
  static const _versionBumpDelay = Duration(milliseconds: 180);
  static const _initialAddSettleDelay = Duration(seconds: 2);
  static const _remoteMutationFlushDelay = Duration(milliseconds: 120);
  static const _remoteMutationMaxBatchSize = 250;
  static const _healthTables = <String>[
    'products',
    'parties',
    'employees',
    'stock_ledger',
  ];

  late final DatabaseReference _ref;
  bool _initialized = false;
  bool _syncing = false;
  bool _fastSyncInProgress = false;
  int _localDbWriteDepth = 0;
  Completer<void>? _localDbWriteCompleter;
  int _syncDbTaskDepth = 0;
  Completer<void>? _syncDbTaskCompleter;
  Future<void> _syncDbQueue = Future.value();
  final Map<String, _DeferredRemoteMutation> _deferredRemoteMutations = {};
  final Map<String, _DeferredRemoteMutation> _bufferedRemoteMutations = {};
  Timer? _remoteMutationFlushTimer;
  bool _remoteMutationFlushInProgress = false;
  Timer? _versionBumpTimer;
  bool _versionBumpQueued = false;
  Timer? _initialAddSettleTimer;
  bool _pendingDataVersionAfterInitial = false;
  final Map<String, int> _warningCounts = {};
  String? _lastSyncError;
  DateTime? _lastFullSyncStartedAt;
  DateTime? _lastFullSyncFinishedAt;
  bool? _lastFullSyncSucceeded;
  final Map<String, SyncTablePullStats> _lastPullStats = {};

  bool get isInitialized => _initialized;
  bool get isSyncing => _syncing;
  String? get lastSyncError => _lastSyncError;
  DateTime? get lastFullSyncStartedAt => _lastFullSyncStartedAt;
  DateTime? get lastFullSyncFinishedAt => _lastFullSyncFinishedAt;
  bool? get lastFullSyncSucceeded => _lastFullSyncSucceeded;
  Map<String, SyncTablePullStats> get lastPullStats =>
      Map<String, SyncTablePullStats>.unmodifiable(_lastPullStats);

  /// Most recent sync health report (null until first run).
  final healthReport = ValueNotifier<SyncHealthReport?>(null);

  /// Returns true if at least one core business table has local rows.
  /// Used to detect "flag says synced but local DB is still empty" cases.
  Future<bool> hasCoreLocalData() async {
    const coreTables = <String>[
      'products',
      'parties',
      'fabric_shades',
      'thread_shades',
      'employees',
    ];

    try {
      final db = await ErpDatabase.instance.database;
      for (final table in coreTables) {
        final rows = await db.query(table, columns: ['id'], limit: 1);
        if (rows.isNotEmpty) {
          return true;
        }
      }
    } catch (e) {
      debugPrint('[WARN] hasCoreLocalData: $e');
    }

    return false;
  }

  /// Compares local and cloud row counts for key tables.
  Future<SyncHealthReport> runHealthCheck({
    List<String>? tables,
  }) async {
    await init();
    final targets = tables ?? _healthTables;
    final rows = <SyncHealthRow>[];

    for (final table in targets) {
      try {
        final localCount = await _runSyncDbTask(() async {
          final db = await ErpDatabase.instance.database;
          final result =
              await db.rawQuery('SELECT COUNT(*) AS cnt FROM $table');
          final value = result.first['cnt'];
          if (value is int) return value;
          if (value is num) return value.toInt();
          return 0;
        });

        final snap = await _ref.child(table).get();
        final remoteCount =
            _effectiveRemoteCount(table, snap.exists ? snap.value : null);

        rows.add(
          SyncHealthRow(
            table: table,
            localCount: localCount,
            remoteCount: remoteCount,
          ),
        );
      } catch (e) {
        rows.add(
          SyncHealthRow(
            table: table,
            localCount: 0,
            remoteCount: null,
            error: e.toString(),
          ),
        );
      }
    }

    final report = SyncHealthReport(
      checkedAt: DateTime.now(),
      rows: rows,
    );
    healthReport.value = report;
    return report;
  }

  int _remoteRowCountFromValue(dynamic raw) {
    if (raw is Map) return raw.length;
    if (raw is List) {
      var count = 0;
      for (final row in raw) {
        if (row != null) count++;
      }
      return count;
    }
    return 0;
  }

  bool _isDeletedFlag(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value.toInt() == 1;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == '1' || normalized == 'true' || normalized == 'yes';
    }
    return false;
  }

  int _effectiveRemoteCount(String table, dynamic raw) {
    if (table != 'stock_ledger') {
      return _remoteRowCountFromValue(raw);
    }

    if (raw is Map) {
      var count = 0;
      for (final entry in raw.entries) {
        if (int.tryParse('${entry.key}') == null) continue;
        final row = entry.value;
        if (row is! Map) continue;
        if (_isDeletedFlag(row['is_deleted'])) continue;
        count++;
      }
      return count;
    }

    if (raw is List) {
      var count = 0;
      for (final row in raw) {
        if (row is! Map) continue;
        if (_isDeletedFlag(row['is_deleted'])) continue;
        count++;
      }
      return count;
    }

    return 0;
  }

  /// Incremented every time a remote change arrives.
  /// Pages can listen to this to refresh their UI.
  final syncVersion = ValueNotifier<int>(0);

  /// Number of operations waiting to sync to Firebase.
  /// UI can show a badge/indicator when this is > 0.
  final pendingSyncCount = ValueNotifier<int>(0);

  // ---------- PENDING DELETES (persisted to SQLite) ----------
  final _pendingDeletes = <String, Set<int>>{};

  Future<void> addPendingDelete(String table, int id) async {
    _pendingDeletes.putIfAbsent(table, () => <int>{}).add(id);
    await _persistPendingDelete(table, id);
  }

  void removePendingDelete(String table, int id) {
    _pendingDeletes[table]?.remove(id);
    if (_pendingDeletes[table]?.isEmpty ?? false) {
      _pendingDeletes.remove(table);
    }
  }

  bool _isPendingDelete(String table, int id) {
    return _pendingDeletes[table]?.contains(id) ?? false;
  }

  Future<void> _persistPendingDelete(String table, int id) async {
    try {
      await _runSyncDbTask(() async {
        final db = await ErpDatabase.instance.database;
        await db.delete(
          '_pending_sync',
          where: 'table_name=? AND record_id=? AND action=?',
          whereArgs: [table, id, 'delete'],
        );
        await db.insert(
          '_pending_sync',
          {
            'table_name': table,
            'record_id': id,
            'action': 'delete',
            'data': '',
            'created_at': DateTime.now().millisecondsSinceEpoch,
          },
        );
      });
      await _refreshPendingSyncCount();
    } catch (e) {
      debugPrint('[WARN] _persistPendingDelete: $e');
    }
  }

  /// Queue a failed push for retry. Persisted across app restarts.
  Future<void> _queueFailedPush(
    String table,
    int id,
    Map<String, dynamic> data,
  ) async {
    try {
      await _runSyncDbTask(() async {
        final db = await ErpDatabase.instance.database;
        await db.delete(
          '_pending_sync',
          where: 'table_name=? AND record_id=? AND action=?',
          whereArgs: [table, id, 'push'],
        );
        await db.insert(
          '_pending_sync',
          {
            'table_name': table,
            'record_id': id,
            'action': 'push',
            'data': jsonEncode(data),
            'created_at': DateTime.now().millisecondsSinceEpoch,
          },
        );
      });
      await _refreshPendingSyncCount();
    } catch (e) {
      debugPrint('[WARN] _queueFailedPush: $e');
    }
  }

  Future<void> queuePush(
      String table, int id, Map<String, dynamic> data) async {
    await _queueFailedPush(table, id, data);
  }

  Future<void> _refreshPendingSyncCount() async {
    try {
      await _runSyncDbTask(() async {
        final db = await ErpDatabase.instance.database;
        final result =
            await db.rawQuery('SELECT COUNT(*) as cnt FROM _pending_sync');
        pendingSyncCount.value = (result.first['cnt'] as int?) ?? 0;
      });
    } catch (_) {}
  }

  // ---------- INIT ----------
  /// True when running on a platform without native Firebase support; in that
  /// case all writes go through [RestSyncBackend].
  bool get _useRestBackend =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  Future<void> init() async {
    if (_initialized) return;
    if (_useRestBackend) {
      // Skip native ref/listeners; mark initialized so erp_database treats
      // sync as enabled and routes writes through REST.
      final db = await ErpDatabase.instance.database;
      await _ensureRemoteCompatibleSchema(db, 'stock_ledger');
      _initialized = true;
      await _loadPendingFromDb();
      return;
    }
    _ref = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: _dbUrl,
    ).ref('sync');
    final db = await ErpDatabase.instance.database;
    await _ensureRemoteCompatibleSchema(db, 'stock_ledger');
    _initialized = true;
    await _loadPendingFromDb();
  }

  void _warnOncePerBurst(String key, String message) {
    final count = (_warningCounts[key] ?? 0) + 1;
    _warningCounts[key] = count;
    if (count <= 3 || count % 50 == 0) {
      final suffix = count > 3 ? ' (repeated $count times)' : '';
      debugPrint('$message$suffix');
    }
  }

  /// Restore pending deletes from SQLite so they survive app restarts.
  Future<void> _loadPendingFromDb() async {
    try {
      await _runSyncDbTask(() async {
        final db = await ErpDatabase.instance.database;
        final rows = await db.query(
          '_pending_sync',
          where: 'action=?',
          whereArgs: ['delete'],
        );
        for (final row in rows) {
          final table = row['table_name'] as String;
          final id = row['record_id'] as int;
          _pendingDeletes.putIfAbsent(table, () => <int>{}).add(id);
        }
      });
      await _refreshPendingSyncCount();
    } catch (e) {
      debugPrint('[WARN] _loadPendingFromDb: $e');
    }
  }

  // ---------- ATOMIC ID COUNTER ----------
  Future<int> getNextId(String table) async {
    if (_useRestBackend) {
      return RestSyncBackend.instance.getNextId(table);
    }
    final counterRef = _ref.child('_counters/$table');
    final result = await counterRef.runTransaction((value) {
      return Transaction.success(((value as int?) ?? 0) + 1);
    });
    return result.snapshot.value as int;
  }

  // ---------- PUSH / DELETE ----------
  Future<void> pushRecord(
    String table,
    int id,
    Map<String, dynamic> data,
  ) async {
    if (_useRestBackend) {
      try {
        await RestSyncBackend.instance.push(table, id, data);
      } catch (e) {
        debugPrint('[WARN] REST push ($table/$id): $e');
        await _queueFailedPush(table, id, data);
      }
      return;
    }
    final keepQueuedUntilFullSyncEnds = _syncing;
    if (keepQueuedUntilFullSyncEnds) {
      await _queueFailedPush(table, id, data);
    }
    try {
      final pushData = Map<String, dynamic>.from(data);
      pushData['_ts'] = ServerValue.timestamp;
      await _ref.child('$table/$id').set(pushData);
      if (keepQueuedUntilFullSyncEnds) {
        await _removePendingSync(table, id, 'push');
      }
    } catch (e) {
      debugPrint('[WARN] sync push ($table/$id): $e');
      await _queueFailedPush(table, id, data);
    }
  }

  Future<void> deleteRecord(String table, int id) async {
    if (_useRestBackend) {
      try {
        await RestSyncBackend.instance.delete(table, id);
        debugPrint('[OK] REST delete ($table/$id) success');
        removePendingDelete(table, id);
        await _removePendingSync(table, id, 'delete');
      } catch (e) {
        debugPrint('[WARN] REST delete ($table/$id) failed: $e');
        rethrow;
      }
      return;
    }
    try {
      await _ref.child('$table/$id').remove();
      debugPrint('[OK] sync delete ($table/$id) success');
      removePendingDelete(table, id);
      await _removePendingSync(table, id, 'delete');
    } catch (e) {
      debugPrint('[WARN] sync delete ($table/$id) failed: $e');
      rethrow;
    }
  }

  Future<void> _removePendingSync(
    String table,
    int id,
    String action, {
    bool refreshCount = true,
  }) async {
    try {
      await _runSyncDbTask(() async {
        final db = await ErpDatabase.instance.database;
        await db.delete(
          '_pending_sync',
          where: 'table_name=? AND record_id=? AND action=?',
          whereArgs: [table, id, action],
        );
      });
      if (refreshCount) {
        await _refreshPendingSyncCount();
      }
    } catch (_) {}
  }

  // ---------- FAST / FULL SYNC ----------
  Future<void> fastSync() async {
    await init();
    startListening();
    await _runFastSyncInBackground();
    syncVersion.value++;
  }

  Future<void> _runFastSyncInBackground() async {
    if (_fastSyncInProgress) return;
    _fastSyncInProgress = true;
    try {
      final db = await ErpDatabase.instance.database;
      await _retryPendingDeletes(db);
      await _retryFailedPushes(db);
    } catch (e) {
      debugPrint('[WARN] fastSync background error: $e');
    } finally {
      _fastSyncInProgress = false;
      await _refreshPendingSyncCount();
    }
  }

  Future<bool> fullSync() async {
    await init();
    _syncing = true;
    _lastSyncError = null;
    _lastFullSyncStartedAt = DateTime.now();
    _lastFullSyncFinishedAt = null;
    _lastFullSyncSucceeded = null;
    _lastPullStats.clear();
    var success = true;
    try {
      final db = await ErpDatabase.instance.database;
      await _retryPendingDeletes(db);
      await _retryFailedPushes(db);
      await _pushLocalToFirebase(db);
      for (final table in _syncTables) {
        final pulled = await _pullTable(db, table);
        if (!pulled) {
          success = false;
        }
      }
      syncVersion.value++;
    } catch (e) {
      success = false;
      _lastSyncError = 'fullSync: $e';
      if (!e.toString().contains('database is locked')) {
        debugPrint('[WARN] fullSync error: $e');
      }
    } finally {
      _syncing = false;
      _lastFullSyncFinishedAt = DateTime.now();
      try {
        final db = await ErpDatabase.instance.database;
        await _retryFailedPushes(db);
      } catch (e) {
        success = false;
        _lastSyncError ??= 'retryAfterFullSync: $e';
        if (!e.toString().contains('database is locked')) {
          debugPrint('[WARN] retry after fullSync: $e');
        }
      }
      _lastFullSyncSucceeded = success;
    }
    return success;
  }

  Future<void> _pushLocalToFirebase(sql.Database db) async {
    for (final table in _syncTables) {
      try {
        await _ensureRemoteCompatibleSchema(db, table);

        final snap = await _ref.child(table).get();
        final remoteIds = <int>{};
        if (snap.exists) {
          final raw = snap.value;
          if (raw is Map) {
            for (final key in raw.keys) {
              final id = int.tryParse(key.toString());
              if (id != null) {
                remoteIds.add(id);
              }
            }
          } else if (raw is List) {
            for (var i = 0; i < raw.length; i++) {
              if (raw[i] != null) {
                remoteIds.add(i);
              }
            }
          }
        }

        var lastId = 0;
        while (true) {
          final localRows = await _runSyncDbTask(
            () => db.query(
              table,
              where: 'id > ?',
              whereArgs: [lastId],
              orderBy: 'id ASC',
              limit: _dbBatchSize,
            ),
          );
          if (localRows.isEmpty) break;

          final updates = <String, dynamic>{};
          final missingRows = <int, Map<String, dynamic>>{};
          for (final row in localRows) {
            final id = row['id'] as int?;
            if (id == null) continue;
            lastId = id;
            if (remoteIds.contains(id)) continue;
            final pushData = Map<String, dynamic>.from(row);
            pushData['_ts'] = ServerValue.timestamp;
            updates['$table/$id'] = pushData;
            missingRows[id] = Map<String, dynamic>.from(row);
          }

          if (updates.isNotEmpty) {
            try {
              await _ref.update(updates);
            } catch (e) {
              for (final entry in missingRows.entries) {
                await _queueFailedPush(table, entry.key, entry.value);
              }
              debugPrint(
                '[WARN] push batch ($table): $e - queued ${missingRows.length} rows',
              );
            }
          }
        }

        final maxIdRows = await _runSyncDbTask(
          () =>
              db.rawQuery('SELECT COALESCE(MAX(id), 0) AS max_id FROM $table'),
        );
        final maxIdRaw = maxIdRows.first['max_id'];
        final maxId = maxIdRaw is int
            ? maxIdRaw
            : maxIdRaw is num
                ? maxIdRaw.toInt()
                : 0;
        final counterRef = _ref.child('_counters/$table');
        await counterRef.runTransaction((value) {
          final current = (value as int?) ?? 0;
          if (maxId > current) {
            return Transaction.success(maxId);
          }
          return Transaction.abort();
        });
      } catch (e) {
        debugPrint('[WARN] push local ($table): $e');
      }
    }
  }

  Future<bool> _pullTable(sql.Database db, String table) async {
    var remoteRows = 0;
    var upserted = 0;
    var deleted = 0;
    try {
      await _ensureRemoteCompatibleSchema(db, table);
      final snap = await _ref.child(table).get();
      if (!snap.exists) {
        _lastPullStats[table] = SyncTablePullStats(
          table: table,
          remoteRows: 0,
          upsertedRows: 0,
          deletedRows: 0,
          success: true,
          checkedAt: DateTime.now(),
        );
        return true;
      }

      final map = <String, dynamic>{};
      final raw = snap.value;
      if (raw is Map) {
        map.addAll(
          Map<String, dynamic>.from(raw.map((k, v) => MapEntry('$k', v))),
        );
      } else if (raw is List) {
        for (var i = 0; i < raw.length; i++) {
          final value = raw[i];
          if (value != null) {
            map['$i'] = value;
          }
        }
      } else {
        _lastPullStats[table] = SyncTablePullStats(
          table: table,
          remoteRows: 0,
          upsertedRows: 0,
          deletedRows: 0,
          success: true,
          checkedAt: DateTime.now(),
        );
        return true;
      }
      remoteRows = map.length;
      await _runSyncDbTask(() async {
        final localIdSet = <int>{};
        var lastId = 0;
        while (true) {
          final localRows = await db.query(
            table,
            columns: ['id'],
            where: 'id > ?',
            whereArgs: [lastId],
            orderBy: 'id ASC',
            limit: _dbBatchSize,
          );
          if (localRows.isEmpty) break;
          for (final row in localRows) {
            final id = row['id'] as int?;
            if (id != null) {
              localIdSet.add(id);
              lastId = id;
            }
          }
        }

        final pendingPushIds = await _getPendingPushIds(db, table);
        final remoteIds = <int>{};

        var batch = db.batch();
        var pendingOps = 0;

        Future<void> flushBatch() async {
          if (pendingOps == 0) return;
          await batch.commit(noResult: true, continueOnError: true);
          batch = db.batch();
          pendingOps = 0;
        }

        for (final entry in map.entries) {
          final id = int.tryParse(entry.key.toString());
          if (id == null || _isPendingDelete(table, id)) continue;
          if (entry.value is! Map) continue;

          if (table == 'stock_ledger' &&
              _isDeletedFlag((entry.value as Map)['is_deleted'])) {
            continue;
          }

          remoteIds.add(id);
          final data = Map<String, dynamic>.from(entry.value as Map);
          data.remove('_ts');
          data['id'] = id;

          batch.insert(
            table,
            data,
            conflictAlgorithm: sql.ConflictAlgorithm.replace,
          );
          upserted++;
          pendingOps++;
          if (pendingOps >= _dbBatchSize) {
            await flushBatch();
          }
        }

        for (final localId in localIdSet) {
          if (!remoteIds.contains(localId) &&
              !pendingPushIds.contains(localId)) {
            batch.delete(table, where: 'id=?', whereArgs: [localId]);
            deleted++;
            pendingOps++;
            if (pendingOps >= _dbBatchSize) {
              await flushBatch();
            }
          }
        }

        await flushBatch();
      });
      _lastPullStats[table] = SyncTablePullStats(
        table: table,
        remoteRows: remoteRows,
        upsertedRows: upserted,
        deletedRows: deleted,
        success: true,
        checkedAt: DateTime.now(),
      );
    } catch (e) {
      _lastSyncError ??= 'pullTable($table): $e';
      _lastPullStats[table] = SyncTablePullStats(
        table: table,
        remoteRows: remoteRows,
        upsertedRows: upserted,
        deletedRows: deleted,
        success: false,
        error: e.toString(),
        checkedAt: DateTime.now(),
      );
      _warnOncePerBurst('pull:$table:$e', '[WARN] pull table ($table): $e');
      return false;
    }
    return true;
  }

  Future<void> _ensureRemoteCompatibleSchema(
    sql.Database db,
    String table,
  ) async {
    if (table != 'stock_ledger') return;

    final cols = await db.rawQuery('PRAGMA table_info(stock_ledger)');
    final hasIsDeleted = cols.any(
      (c) => (c['name'] ?? '').toString().toLowerCase() == 'is_deleted',
    );
    if (!hasIsDeleted) {
      await db.execute(
        'ALTER TABLE stock_ledger ADD COLUMN is_deleted INTEGER DEFAULT 0',
      );
    }
  }

  /// Get IDs that are queued for push (should not be deleted during pull).
  Future<Set<int>> _getPendingPushIds(
    sql.DatabaseExecutor db,
    String table,
  ) async {
    try {
      final rows = await db.query(
        '_pending_sync',
        columns: ['record_id'],
        where: 'table_name=? AND action=?',
        whereArgs: [table, 'push'],
      );
      return rows.map((r) => r['record_id'] as int).toSet();
    } catch (_) {
      return <int>{};
    }
  }

  Future<void> _retryPendingDeletes(sql.Database db) async {
    try {
      var pendingChanged = false;
      var lastPendingId = 0;
      while (true) {
        final rows = await _runSyncDbTask(
          () => db.query(
            '_pending_sync',
            where: 'action=? AND id > ?',
            whereArgs: ['delete', lastPendingId],
            orderBy: 'id ASC',
            limit: _dbBatchSize,
          ),
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          lastPendingId = row['id'] as int;
          final table = row['table_name'] as String;
          final id = row['record_id'] as int;
          try {
            await _ref.child('$table/$id').remove();
            removePendingDelete(table, id);
            await _removePendingSync(table, id, 'delete', refreshCount: false);
            pendingChanged = true;
            debugPrint('[OK] pending delete retry ($table/$id) success');
          } catch (e) {
            debugPrint('[WARN] pending delete retry ($table/$id): $e');
          }
        }
        // Yield to UI isolate between batches to avoid long input stalls.
        await Future<void>.delayed(Duration.zero);
      }
      if (pendingChanged) {
        await _refreshPendingSyncCount();
      }
    } catch (e) {
      debugPrint('[WARN] _retryPendingDeletes: $e');
    }
  }

  Future<void> _retryFailedPushes(sql.Database db) async {
    try {
      var pendingChanged = false;
      var lastPendingId = 0;
      while (true) {
        final rows = await _runSyncDbTask(
          () => db.query(
            '_pending_sync',
            where: 'action=? AND id > ?',
            whereArgs: ['push', lastPendingId],
            orderBy: 'id ASC',
            limit: _dbBatchSize,
          ),
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          lastPendingId = row['id'] as int;
          final table = row['table_name'] as String;
          final id = row['record_id'] as int;
          try {
            Map<String, dynamic>? pushData;
            final rawData = (row['data'] as String?)?.trim() ?? '';
            if (rawData.isNotEmpty) {
              final decoded = jsonDecode(rawData);
              if (decoded is Map) {
                pushData = Map<String, dynamic>.from(decoded);
              }
            }

            if (pushData == null || pushData.isEmpty) {
              final localRows = await _runSyncDbTask(
                () => db.query(table, where: 'id=?', whereArgs: [id], limit: 1),
              );
              if (localRows.isEmpty) {
                await _removePendingSync(
                  table,
                  id,
                  'push',
                  refreshCount: false,
                );
                pendingChanged = true;
                continue;
              }
              pushData = Map<String, dynamic>.from(localRows.first);
            }

            pushData['_ts'] = ServerValue.timestamp;
            await _ref.child('$table/$id').set(pushData);
            await _removePendingSync(table, id, 'push', refreshCount: false);
            pendingChanged = true;
            debugPrint('[OK] pending push retry ($table/$id) success');
          } catch (e) {
            debugPrint('[WARN] pending push retry ($table/$id): $e');
          }
        }
        // Yield to UI isolate between batches to avoid long input stalls.
        await Future<void>.delayed(Duration.zero);
      }
      if (pendingChanged) {
        await _refreshPendingSyncCount();
      }
    } catch (e) {
      debugPrint('[WARN] _retryFailedPushes: $e');
    }
  }

  // ---------- REAL-TIME LISTENERS ----------
  bool _listening = false;
  final List<StreamSubscription> _subscriptions = [];

  /// After fullSync, initial onChildAdded events are replays.
  /// We absorb them silently (INSERT OR REPLACE without UI bump)
  /// and only start refreshing UI after the initial burst settles.
  bool _initialListenDone = false;

  void _markInitialAddActivity() {
    if (_initialListenDone) return;
    _initialAddSettleTimer?.cancel();
    _initialAddSettleTimer = Timer(_initialAddSettleDelay, _finishInitialBurst);
  }

  void _finishInitialBurst() {
    if (_initialListenDone) return;
    _initialListenDone = true;
    if (_pendingDataVersionAfterInitial) {
      _pendingDataVersionAfterInitial = false;
      _scheduleVersionBump();
    }
  }

  void _queueDataVersionBump() {
    if (_initialListenDone) {
      _scheduleVersionBump();
    } else {
      _pendingDataVersionAfterInitial = true;
    }
  }

  Future<void> _onRemoteAdd(String table, DatabaseEvent event) async {
    _markInitialAddActivity();
    // The first onChildAdded wave is a replay of all existing rows.
    // Re-applying that full dataset on every startup can flood the UI isolate
    // and cause ANR on lower-memory devices. Fresh restores are still handled
    // via explicit fullSync from dashboard.
    if (!_initialListenDone) return;
    await _onRemoteChange(table, event);
  }

  void startListening() {
    if (_listening) return;
    _listening = true;
    _initialListenDone = false;
    _pendingDataVersionAfterInitial = false;
    _initialAddSettleTimer?.cancel();
    _remoteMutationFlushTimer?.cancel();
    _remoteMutationFlushTimer = null;
    _bufferedRemoteMutations.clear();

    for (final table in _syncTables) {
      _subscriptions.add(
        _ref.child(table).onChildAdded.listen(
              (e) => _onRemoteAdd(table, e),
              onError: (e) => debugPrint('[WARN] listener $table added: $e'),
            ),
      );
      _subscriptions.add(
        _ref.child(table).onChildChanged.listen(
              (e) => _onRemoteChange(table, e),
              onError: (e) => debugPrint('[WARN] listener $table changed: $e'),
            ),
      );
      _subscriptions.add(
        _ref.child(table).onChildRemoved.listen(
              (e) => _onRemoteRemove(table, e),
              onError: (e) => debugPrint('[WARN] listener $table removed: $e'),
            ),
      );
    }
    // In case there are no initial child-added events, complete quickly.
    _markInitialAddActivity();
  }

  Future<void> stopListening() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _versionBumpTimer?.cancel();
    _versionBumpTimer = null;
    _versionBumpQueued = false;
    _initialAddSettleTimer?.cancel();
    _initialAddSettleTimer = null;
    _remoteMutationFlushTimer?.cancel();
    _remoteMutationFlushTimer = null;
    _bufferedRemoteMutations.clear();
    _remoteMutationFlushInProgress = false;
    _pendingDataVersionAfterInitial = false;
    _listening = false;
  }

  Future<void> beginLocalDbWrite() async {
    _localDbWriteCompleter ??= Completer<void>();
    _localDbWriteDepth++;
    await _syncDbTaskCompleter?.future;
  }

  Future<void> endLocalDbWrite() async {
    if (_localDbWriteDepth > 0) {
      _localDbWriteDepth--;
    }
    if (_localDbWriteDepth > 0) return;

    _localDbWriteCompleter?.complete();
    _localDbWriteCompleter = null;

    if (_deferredRemoteMutations.isEmpty) return;

    final pending = _deferredRemoteMutations.values.toList();
    _deferredRemoteMutations.clear();
    await _applyRemoteMutationsBatch(pending);
    if (_bufferedRemoteMutations.isNotEmpty) {
      _scheduleBufferedRemoteFlush();
    }
  }

  Future<void> _waitForLocalDbWrites() async {
    if (_localDbWriteDepth == 0) return;
    await _localDbWriteCompleter?.future;
  }

  Future<T> _runSyncDbTask<T>(Future<T> Function() action) {
    final result = Completer<T>();

    _syncDbQueue = _syncDbQueue.then((_) async {
      await _waitForLocalDbWrites();
      _syncDbTaskCompleter ??= Completer<void>();
      _syncDbTaskDepth++;
      try {
        result.complete(await action());
      } catch (e, st) {
        result.completeError(e, st);
      } finally {
        if (_syncDbTaskDepth > 0) {
          _syncDbTaskDepth--;
        }
        if (_syncDbTaskDepth == 0) {
          _syncDbTaskCompleter?.complete();
          _syncDbTaskCompleter = null;
        }
      }
    });

    return result.future;
  }

  Future<void> _applyRemoteMutationsBatch(
    List<_DeferredRemoteMutation> mutations,
  ) async {
    if (mutations.isEmpty) return;
    try {
      await _runSyncDbTask(() async {
        final db = await ErpDatabase.instance.database;
        if (mutations.any((m) => m.table == 'stock_ledger')) {
          await _ensureRemoteCompatibleSchema(db, 'stock_ledger');
        }
        var batch = db.batch();
        var pendingOps = 0;

        Future<void> flushBatch() async {
          if (pendingOps == 0) return;
          await batch.commit(noResult: true, continueOnError: true);
          batch = db.batch();
          pendingOps = 0;
        }

        for (final mutation in mutations) {
          if (mutation.isRemove) {
            batch.delete(
              mutation.table,
              where: 'id=?',
              whereArgs: [mutation.id],
            );
            pendingOps++;
          } else if (mutation.data != null) {
            final data = Map<String, dynamic>.from(mutation.data!);
            if (mutation.table == 'stock_ledger' &&
                _isDeletedFlag(data['is_deleted'])) {
              batch.delete(
                mutation.table,
                where: 'id=?',
                whereArgs: [mutation.id],
              );
            } else {
              batch.insert(
                mutation.table,
                data,
                conflictAlgorithm: sql.ConflictAlgorithm.replace,
              );
            }
            pendingOps++;
          }

          if (pendingOps >= _dbBatchSize) {
            await flushBatch();
          }
        }

        await flushBatch();
      });

      _queueDataVersionBump();
    } catch (e) {
      _warnOncePerBurst(
        'remote-batch:$e',
        '[WARN] remote batch apply: $e',
      );
      for (final mutation in mutations) {
        if (mutation.isRemove) {
          await _applyRemoteRemove(mutation.table, mutation.id);
        } else if (mutation.data != null) {
          await _applyRemoteChange(mutation.table, mutation.id, mutation.data!);
        }
      }
    }
  }

  void _bufferRemoteMutation(_DeferredRemoteMutation mutation) {
    _bufferedRemoteMutations['${mutation.table}/${mutation.id}'] = mutation;
    _scheduleBufferedRemoteFlush();
  }

  void _scheduleBufferedRemoteFlush() {
    if (_remoteMutationFlushTimer != null) return;
    _remoteMutationFlushTimer = Timer(_remoteMutationFlushDelay, () {
      _remoteMutationFlushTimer = null;
      unawaited(_flushBufferedRemoteMutations());
    });
  }

  Future<void> _flushBufferedRemoteMutations() async {
    if (_remoteMutationFlushInProgress) return;
    if (_bufferedRemoteMutations.isEmpty) return;
    _remoteMutationFlushInProgress = true;
    try {
      while (_bufferedRemoteMutations.isNotEmpty) {
        if (_localDbWriteDepth > 0) {
          _scheduleBufferedRemoteFlush();
          break;
        }

        final keys = _bufferedRemoteMutations.keys
            .take(_remoteMutationMaxBatchSize)
            .toList(growable: false);
        if (keys.isEmpty) break;

        final batch = <_DeferredRemoteMutation>[];
        for (final key in keys) {
          final mutation = _bufferedRemoteMutations.remove(key);
          if (mutation != null) {
            batch.add(mutation);
          }
        }

        if (batch.isEmpty) break;
        await _applyRemoteMutationsBatch(batch);
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _remoteMutationFlushInProgress = false;
      if (_bufferedRemoteMutations.isNotEmpty) {
        _scheduleBufferedRemoteFlush();
      }
    }
  }

  void _scheduleVersionBump() {
    if (_versionBumpQueued) return;
    _versionBumpQueued = true;
    _versionBumpTimer?.cancel();
    _versionBumpTimer = Timer(_versionBumpDelay, () {
      _versionBumpQueued = false;
      syncVersion.value++;
      ErpDatabase.instance.dataVersion.value++;
    });
  }

  Future<void> _onRemoteChange(String table, DatabaseEvent event) async {
    if (_syncing) return;
    final id = int.tryParse(event.snapshot.key ?? '');
    if (id == null) return;
    if (event.snapshot.value is! Map) return;
    if (_isPendingDelete(table, id)) return;

    final data = Map<String, dynamic>.from(event.snapshot.value as Map);
    data.remove('_ts');
    data['id'] = id;

    if (_localDbWriteDepth > 0) {
      _deferredRemoteMutations['$table/$id'] = _DeferredRemoteMutation(
        table: table,
        id: id,
        data: data,
      );
      return;
    }

    _bufferRemoteMutation(
      _DeferredRemoteMutation(
        table: table,
        id: id,
        data: data,
      ),
    );
  }

  Future<void> _applyRemoteChange(
    String table,
    int id,
    Map<String, dynamic> data,
  ) async {
    try {
      await _runSyncDbTask(() async {
        final db = await ErpDatabase.instance.database;
        await _ensureRemoteCompatibleSchema(db, table);
        if (table == 'stock_ledger' && _isDeletedFlag(data['is_deleted'])) {
          await db.delete(table, where: 'id=?', whereArgs: [id]);
        } else {
          await db.insert(
            table,
            data,
            conflictAlgorithm: sql.ConflictAlgorithm.replace,
          );
        }
      });
      _queueDataVersionBump();
    } catch (e) {
      _warnOncePerBurst(
        'remote-change:$table:$e',
        '[WARN] remote change ($table/$id): $e',
      );
    }
  }

  Future<void> _applyRemoteRemove(String table, int id) async {
    try {
      await _runSyncDbTask(() async {
        final db = await ErpDatabase.instance.database;
        await db.delete(table, where: 'id=?', whereArgs: [id]);
      });
      _queueDataVersionBump();
    } catch (e) {
      debugPrint('[WARN] remote remove ($table/$id): $e');
    }
  }

  Future<void> _onRemoteRemove(String table, DatabaseEvent event) async {
    if (_syncing) return;
    final id = int.tryParse(event.snapshot.key ?? '');
    if (id == null) return;
    removePendingDelete(table, id);

    if (_localDbWriteDepth > 0) {
      _deferredRemoteMutations['$table/$id'] = _DeferredRemoteMutation(
        table: table,
        id: id,
        isRemove: true,
      );
      return;
    }

    _bufferRemoteMutation(
      _DeferredRemoteMutation(
        table: table,
        id: id,
        isRemove: true,
      ),
    );
  }
}

class _DeferredRemoteMutation {
  final String table;
  final int id;
  final Map<String, dynamic>? data;
  final bool isRemove;

  const _DeferredRemoteMutation({
    required this.table,
    required this.id,
    this.data,
    this.isRemove = false,
  });
}

class SyncTablePullStats {
  final String table;
  final int remoteRows;
  final int upsertedRows;
  final int deletedRows;
  final bool success;
  final String? error;
  final DateTime checkedAt;

  const SyncTablePullStats({
    required this.table,
    required this.remoteRows,
    required this.upsertedRows,
    required this.deletedRows,
    required this.success,
    required this.checkedAt,
    this.error,
  });
}

class SyncHealthReport {
  final DateTime checkedAt;
  final List<SyncHealthRow> rows;

  const SyncHealthReport({
    required this.checkedAt,
    required this.rows,
  });

  int get mismatchCount => rows.where((row) => !row.inSync).length;
}

class SyncHealthRow {
  final String table;
  final int localCount;
  final int? remoteCount;
  final String? error;

  const SyncHealthRow({
    required this.table,
    required this.localCount,
    required this.remoteCount,
    this.error,
  });

  bool get inSync => error == null && remoteCount != null && localCount == remoteCount;
}
