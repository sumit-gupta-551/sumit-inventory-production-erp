import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' as sql;

import 'erp_database.dart';

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
    'activity_log',
  ];

  late final DatabaseReference _ref;
  bool _initialized = false;
  bool _syncing = false;

  bool get isInitialized => _initialized;
  bool get isSyncing => _syncing;

  /// Incremented every time a remote change arrives.
  /// Pages can listen to this to refresh their UI.
  final syncVersion = ValueNotifier<int>(0);

  /// Number of operations waiting to sync to Firebase.
  /// UI can show a badge/indicator when this is > 0.
  final pendingSyncCount = ValueNotifier<int>(0);

  // ---------- PENDING DELETES (persisted to SQLite) ----------
  final _pendingDeletes = <String, Set<int>>{};

  void addPendingDelete(String table, int id) {
    _pendingDeletes.putIfAbsent(table, () => <int>{}).add(id);
    _persistPendingDelete(table, id);
  }

  void removePendingDelete(String table, int id) {
    _pendingDeletes[table]?.remove(id);
    if (_pendingDeletes[table]?.isEmpty ?? false) _pendingDeletes.remove(table);
  }

  bool _isPendingDelete(String table, int id) {
    return _pendingDeletes[table]?.contains(id) ?? false;
  }

  Future<void> _persistPendingDelete(String table, int id) async {
    try {
      final db = await ErpDatabase.instance.database;
      // Remove existing entry for same table/record to avoid duplicates
      await db.delete('_pending_sync',
          where: 'table_name=? AND record_id=? AND action=?',
          whereArgs: [table, id, 'delete']);
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
      await _refreshPendingSyncCount();
    } catch (e) {
      debugPrint('⚠ _persistPendingDelete: $e');
    }
  }

  /// Queue a failed push for retry. Persisted across app restarts.
  Future<void> _queueFailedPush(
      String table, int id, Map<String, dynamic> data) async {
    try {
      final db = await ErpDatabase.instance.database;
      // Remove existing entry for same table/record/action to avoid duplicates
      await db.delete('_pending_sync',
          where: 'table_name=? AND record_id=? AND action=?',
          whereArgs: [table, id, 'push']);
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
      await _refreshPendingSyncCount();
    } catch (e) {
      debugPrint('⚠ _queueFailedPush: $e');
    }
  }

  Future<void> queuePush(String table, int id, Map<String, dynamic> data) async {
    await _queueFailedPush(table, id, data);
  }

  Future<void> _refreshPendingSyncCount() async {
    try {
      final db = await ErpDatabase.instance.database;
      final result =
          await db.rawQuery('SELECT COUNT(*) as cnt FROM _pending_sync');
      pendingSyncCount.value = (result.first['cnt'] as int?) ?? 0;
    } catch (_) {}
  }

  // ---------- INIT ----------
  Future<void> init() async {
    if (_initialized) return;
    _ref = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: _dbUrl,
    ).ref('sync');
    _initialized = true;
    // Load pending deletes from SQLite (survive app restart)
    await _loadPendingFromDb();
  }

  /// Restore pending deletes from SQLite so they survive app restarts.
  Future<void> _loadPendingFromDb() async {
    try {
      final db = await ErpDatabase.instance.database;
      final rows = await db
          .query('_pending_sync', where: 'action=?', whereArgs: ['delete']);
      for (final row in rows) {
        final table = row['table_name'] as String;
        final id = row['record_id'] as int;
        _pendingDeletes.putIfAbsent(table, () => <int>{}).add(id);
      }
      await _refreshPendingSyncCount();
    } catch (e) {
      debugPrint('⚠ _loadPendingFromDb: $e');
    }
  }

  // ---------- ATOMIC ID COUNTER ----------
  Future<int> getNextId(String table) async {
    final counterRef = _ref.child('_counters/$table');
    final result = await counterRef.runTransaction((value) {
      return Transaction.success(((value as int?) ?? 0) + 1);
    });
    return result.snapshot.value as int;
  }

  // ---------- PUSH / DELETE ----------
  Future<void> pushRecord(
      String table, int id, Map<String, dynamic> data) async {
    final keepQueuedUntilFullSyncEnds = _syncing;
    if (keepQueuedUntilFullSyncEnds) {
      await _queueFailedPush(table, id, data);
    }
    try {
      final pushData = Map<String, dynamic>.from(data);
      pushData['_ts'] = ServerValue.timestamp;
      await _ref.child('$table/$id').set(pushData);
      // If this was a queued retry, remove from pending
      if (!keepQueuedUntilFullSyncEnds) {
        await _removePendingSync(table, id, 'push');
      }
    } catch (e) {
      debugPrint('⚠ sync push ($table/$id): $e');
      // Queue for retry so data is not lost
      await _queueFailedPush(table, id, data);
    }
  }

  Future<void> deleteRecord(String table, int id) async {
    try {
      await _ref.child('$table/$id').remove();
      debugPrint('✅ sync delete ($table/$id) success');
      removePendingDelete(table, id);
      await _removePendingSync(table, id, 'delete');
    } catch (e) {
      debugPrint('⚠ sync delete ($table/$id) failed: $e');
      rethrow;
    }
  }

  Future<void> _removePendingSync(String table, int id, String action) async {
    try {
      final db = await ErpDatabase.instance.database;
      await db.delete(
        '_pending_sync',
        where: 'table_name=? AND record_id=? AND action=?',
        whereArgs: [table, id, action],
      );
      await _refreshPendingSyncCount();
    } catch (_) {}
  }

  // ---------- FAST / FULL SYNC ----------
  Future<void> fastSync() async {
    await init();
    final db = await ErpDatabase.instance.database;
    await _retryPendingDeletes(db);
    await _retryFailedPushes(db);
    startListening();
    syncVersion.value++;
    ErpDatabase.instance.dataVersion.value++;
  }

  Future<void> fullSync() async {
    await init();
    _syncing = true;
    try {
      final db = await ErpDatabase.instance.database;
      // 0. Retry any pending operations (deletes + failed pushes).
      await _retryPendingDeletes(db);
      await _retryFailedPushes(db);
      // 1. Push local data that Firebase doesn't have yet.
      await _pushLocalToFirebase(db);
      // 2. Pull everything from Firebase into local SQLite (batched).
      const batchSize = 5;
      for (var i = 0; i < _syncTables.length; i += batchSize) {
        final batch = _syncTables.sublist(
          i,
          (i + batchSize > _syncTables.length)
              ? _syncTables.length
              : i + batchSize,
        );
        await Future.wait(batch.map((table) => _pullTable(db, table)));
      }
      syncVersion.value++;
    } catch (e) {
      debugPrint('⚠ fullSync error: $e');
    } finally {
      _syncing = false;
      try {
        final db = await ErpDatabase.instance.database;
        await _retryFailedPushes(db);
      } catch (e) {
        debugPrint('âš  retry after fullSync: $e');
      }
    }
  }

  Future<void> _pushLocalToFirebase(sql.Database db) async {
    for (final table in _syncTables) {
      try {
        final localRows = await db.query(table);
        if (localRows.isEmpty) continue;

        // Which IDs does Firebase already have?
        final snap = await _ref.child(table).get();
        final remoteIds = <int>{};
        if (snap.exists && snap.value is Map) {
          for (final key in (snap.value as Map).keys) {
            remoteIds.add(int.tryParse(key.toString()) ?? -1);
          }
        }

        // Batch push missing rows using multi-path update
        final updates = <String, dynamic>{};
        final missingRows = <int, Map<String, dynamic>>{};
        for (final row in localRows) {
          final id = row['id'] as int?;
          if (id == null) continue;
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
            // Queue individual rows for retry so _pullTable won't delete them
            for (final entry in missingRows.entries) {
              await _queueFailedPush(table, entry.key, entry.value);
            }
            debugPrint(
                '⚠ push batch ($table): $e — queued ${missingRows.length} rows');
          }
        }

        // Update counter so future inserts don't collide (use transaction
        // to avoid racing with other devices generating IDs concurrently)
        final maxId = localRows
            .map((r) => (r['id'] as int?) ?? 0)
            .fold<int>(0, (a, b) => a > b ? a : b);
        final counterRef = _ref.child('_counters/$table');
        await counterRef.runTransaction((value) {
          final current = (value as int?) ?? 0;
          if (maxId > current) {
            return Transaction.success(maxId);
          }
          return Transaction.abort();
        });
      } catch (e) {
        debugPrint('⚠ push local ($table): $e');
      }
    }
  }

  Future<void> _pullTable(sql.Database db, String table) async {
    try {
      final snap = await _ref.child(table).get();
      if (!snap.exists || snap.value is! Map) return;

      final map = Map<String, dynamic>.from(snap.value as Map);

      // Get all local IDs in one query
      final localRows = await db.query(table, columns: ['id']);
      final localIdSet = <int>{};
      for (final row in localRows) {
        final id = row['id'] as int?;
        if (id != null) localIdSet.add(id);
      }

      final remoteIds = <int>{};

      // Use a single transaction for all inserts/updates
      await db.transaction((txn) async {
        for (final entry in map.entries) {
          final id = int.tryParse(entry.key.toString());
          if (id == null) continue;
          // Skip records that are pending delete locally
          if (_isPendingDelete(table, id)) continue;
          // For stock_ledger, skip remote entries marked as deleted
          if (table == 'stock_ledger' &&
              (entry.value is Map && (entry.value as Map)['is_deleted'] == 1)) {
            continue;
          }
          remoteIds.add(id);

          final data = Map<String, dynamic>.from(entry.value as Map);
          data.remove('_ts');
          data['id'] = id;

          if (localIdSet.contains(id)) {
            await txn.update(table, data, where: 'id=?', whereArgs: [id]);
          } else {
            await txn.insert(table, data);
          }
        }

        // Handle remote deletes — but only for IDs NOT in pending sync
        // (local data awaiting push should not be deleted)
        final pendingPushIds = await _getPendingPushIds(db, table);
        for (final localId in localIdSet) {
          if (!remoteIds.contains(localId) &&
              !pendingPushIds.contains(localId)) {
            await txn.delete(table, where: 'id=?', whereArgs: [localId]);
          }
        }
      });
    } catch (e) {
      debugPrint('⚠ pull table ($table): $e');
    }
  }

  /// Get IDs that are queued for push (should not be deleted during pull).
  Future<Set<int>> _getPendingPushIds(sql.Database db, String table) async {
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
    // Load from SQLite (persisted across restarts)
    try {
      final rows = await db
          .query('_pending_sync', where: 'action=?', whereArgs: ['delete']);
      for (final row in rows) {
        final table = row['table_name'] as String;
        final id = row['record_id'] as int;
        try {
          await _ref.child('$table/$id').remove();
          _pendingDeletes[table]?.remove(id);
          await _removePendingSync(table, id, 'delete');
          debugPrint('✅ pending delete retry ($table/$id) success');
        } catch (e) {
          debugPrint('⚠ pending delete retry ($table/$id): $e');
        }
      }
    } catch (e) {
      debugPrint('⚠ _retryPendingDeletes: $e');
    }
  }

  /// Retry all failed pushes that were queued in _pending_sync.
  Future<void> _retryFailedPushes(sql.Database db) async {
    try {
      final rows = await db
          .query('_pending_sync', where: 'action=?', whereArgs: ['push']);
      for (final row in rows) {
        final table = row['table_name'] as String;
        final id = row['record_id'] as int;
        try {
          // Re-read current data from local SQLite (most up-to-date)
          final localRows =
              await db.query(table, where: 'id=?', whereArgs: [id]);
          if (localRows.isEmpty) {
            // Record was deleted locally, remove from queue
            await _removePendingSync(table, id, 'push');
            continue;
          }
          final pushData = Map<String, dynamic>.from(localRows.first);
          pushData['_ts'] = ServerValue.timestamp;
          await _ref.child('$table/$id').set(pushData);
          await _removePendingSync(table, id, 'push');
          debugPrint('✅ pending push retry ($table/$id) success');
        } catch (e) {
          debugPrint('⚠ pending push retry ($table/$id): $e');
        }
      }
    } catch (e) {
      debugPrint('⚠ _retryFailedPushes: $e');
    }
  }

  // ---------- REAL-TIME LISTENERS ----------
  bool _listening = false;
  final List<StreamSubscription> _subscriptions = [];

  /// After fullSync, initial onChildAdded events are replays.
  /// We absorb them silently (INSERT OR REPLACE without UI bump)
  /// and only start refreshing UI after the initial burst settles.
  bool _initialListenDone = false;

  void startListening() {
    if (_listening) return;
    _listening = true;
    _initialListenDone = false;

    for (final table in _syncTables) {
      _subscriptions.add(
        _ref.child(table).onChildAdded.listen(
              (e) => _onRemoteChange(table, e),
              onError: (e) => debugPrint('⚠ listener $table added: $e'),
            ),
      );
      _subscriptions.add(
        _ref.child(table).onChildChanged.listen(
              (e) => _onRemoteChange(table, e),
              onError: (e) => debugPrint('⚠ listener $table changed: $e'),
            ),
      );
      _subscriptions.add(
        _ref.child(table).onChildRemoved.listen(
              (e) => _onRemoteRemove(table, e),
              onError: (e) => debugPrint('⚠ listener $table removed: $e'),
            ),
      );
    }

    // After a short delay the initial onChildAdded burst has settled
    Future.delayed(const Duration(seconds: 3), () {
      _initialListenDone = true;
    });
  }

  /// Cancel all real-time listeners.
  Future<void> stopListening() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _listening = false;
  }

  Future<void> _onRemoteChange(String table, DatabaseEvent event) async {
    if (_syncing) return;
    final id = int.tryParse(event.snapshot.key ?? '');
    if (id == null) return;
    if (event.snapshot.value is! Map) return;
    // Don't re-insert records that are pending local delete
    if (_isPendingDelete(table, id)) return;

    final data = Map<String, dynamic>.from(event.snapshot.value as Map);
    data.remove('_ts');
    data['id'] = id;

    try {
      final db = await ErpDatabase.instance.database;
      // Use INSERT OR REPLACE to avoid race conditions (no check-then-act)
      await db.insert(table, data,
          conflictAlgorithm: sql.ConflictAlgorithm.replace);
      // Only bump version after initial listener burst has settled
      // to avoid massive UI flickering on startup
      if (_initialListenDone) {
        syncVersion.value++;
        ErpDatabase.instance.dataVersion.value++;
      }
    } catch (e) {
      debugPrint('⚠ remote change ($table/$id): $e');
    }
  }

  Future<void> _onRemoteRemove(String table, DatabaseEvent event) async {
    if (_syncing) return;
    final id = int.tryParse(event.snapshot.key ?? '');
    if (id == null) return;
    removePendingDelete(table, id);

    try {
      final db = await ErpDatabase.instance.database;
      await db.delete(table, where: 'id=?', whereArgs: [id]);
      syncVersion.value++;
      // Also bump dataVersion so all pages refresh
      ErpDatabase.instance.dataVersion.value++;
    } catch (e) {
      debugPrint('⚠ remote remove ($table/$id): $e');
    }
  }
}
