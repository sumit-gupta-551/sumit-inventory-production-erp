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
  ];

  late final DatabaseReference _ref;
  bool _initialized = false;
  bool _syncing = false;

  bool get isInitialized => _initialized;
  bool get isSyncing => _syncing;

  /// Incremented every time a remote change arrives.
  /// Pages can listen to this to refresh their UI.
  final syncVersion = ValueNotifier<int>(0);

  // ---------- INIT ----------
  Future<void> init() async {
    if (_initialized) return;
    _ref = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: _dbUrl,
    ).ref('sync');
    _initialized = true;
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
    if (_syncing) return;
    try {
      final pushData = Map<String, dynamic>.from(data);
      pushData['_ts'] = ServerValue.timestamp;
      await _ref.child('$table/$id').set(pushData);
    } catch (e) {
      debugPrint('⚠ sync push ($table/$id): $e');
    }
  }

  Future<void> deleteRecord(String table, int id) async {
    if (_syncing) return;
    try {
      await _ref.child('$table/$id').remove();
    } catch (e) {
      debugPrint('⚠ sync delete ($table/$id): $e');
    }
  }

  // ---------- FULL SYNC (startup) ----------
  Future<void> fullSync() async {
    await init();
    _syncing = true;
    try {
      final db = await ErpDatabase.instance.database;
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
        for (final row in localRows) {
          final id = row['id'] as int?;
          if (id == null) continue;
          if (remoteIds.contains(id)) continue;
          final pushData = Map<String, dynamic>.from(row);
          pushData['_ts'] = ServerValue.timestamp;
          updates['$table/$id'] = pushData;
        }
        if (updates.isNotEmpty) {
          await _ref.update(updates);
        }

        // Update counter so future inserts don't collide
        final maxId = localRows
            .map((r) => (r['id'] as int?) ?? 0)
            .fold<int>(0, (a, b) => a > b ? a : b);
        final counterSnap = await _ref.child('_counters/$table').get();
        final currentCounter = (counterSnap.value as int?) ?? 0;
        if (maxId > currentCounter) {
          await _ref.child('_counters/$table').set(maxId);
        }
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

        // Handle remote deletes
        for (final localId in localIdSet) {
          if (!remoteIds.contains(localId)) {
            await txn.delete(table, where: 'id=?', whereArgs: [localId]);
          }
        }
      });
    } catch (e) {
      debugPrint('⚠ pull table ($table): $e');
    }
  }

  // ---------- REAL-TIME LISTENERS ----------
  void startListening() {
    for (final table in _syncTables) {
      _ref.child(table).onChildAdded.listen(
            (e) => _onRemoteChange(table, e),
            onError: (e) => debugPrint('⚠ listener $table added: $e'),
          );
      _ref.child(table).onChildChanged.listen(
            (e) => _onRemoteChange(table, e),
            onError: (e) => debugPrint('⚠ listener $table changed: $e'),
          );
      _ref.child(table).onChildRemoved.listen(
            (e) => _onRemoteRemove(table, e),
            onError: (e) => debugPrint('⚠ listener $table removed: $e'),
          );
    }
  }

  Future<void> _onRemoteChange(String table, DatabaseEvent event) async {
    if (_syncing) return;
    final id = int.tryParse(event.snapshot.key ?? '');
    if (id == null) return;
    if (event.snapshot.value is! Map) return;

    final data = Map<String, dynamic>.from(event.snapshot.value as Map);
    data.remove('_ts');
    data['id'] = id;

    try {
      final db = await ErpDatabase.instance.database;
      final existing = await db.query(table, where: 'id=?', whereArgs: [id]);
      if (existing.isEmpty) {
        await db.insert(table, data);
      } else {
        await db.update(table, data, where: 'id=?', whereArgs: [id]);
      }
      syncVersion.value++;
    } catch (e) {
      debugPrint('⚠ remote change ($table/$id): $e');
    }
  }

  Future<void> _onRemoteRemove(String table, DatabaseEvent event) async {
    if (_syncing) return;
    final id = int.tryParse(event.snapshot.key ?? '');
    if (id == null) return;

    try {
      final db = await ErpDatabase.instance.database;
      await db.delete(table, where: 'id=?', whereArgs: [id]);
      syncVersion.value++;
    } catch (e) {
      debugPrint('⚠ remote remove ($table/$id): $e');
    }
  }
}
