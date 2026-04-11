import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' as sql;

import 'erp_database.dart';
import 'permission_service.dart';

/// Mirrors all data tables to a secondary Firebase Realtime Database
/// as a silent backup. Only the super user can trigger this.
class FirebaseBackupService {
  static final FirebaseBackupService instance = FirebaseBackupService._();
  FirebaseBackupService._();

  /// Secondary (backup) Firebase DB URL.
  static const _backupDbUrl =
      'https://sssj-shiv-default-rtdb.asia-southeast1.firebasedatabase.app';

  /// Tables to back up (data only — no users/permissions).
  static const _backupTables = [
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
    // Payroll
    'employees',
    'employee_salary_history',
    'production_entries',
    'attendance',
    'salary_advances',
    'salary_payments',
    'units',
    // Programs
    'program_master',
    'program_fabrics',
    'program_thread_shades',
    'program_allotment',
    'program_logs',
    // Audit
    'activity_log',
  ];

  late final DatabaseReference _ref;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    _ref = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: _backupDbUrl,
    ).ref('backup');
    _initialized = true;
  }

  /// Run a full backup of all data tables to the secondary Firebase.
  /// Returns (tablesBackedUp, totalRows) on success.
  /// Only super user can call this.
  Future<({int tables, int rows, String? error})> runBackup({
    ValueChanged<String>? onProgress,
  }) async {
    if (!PermissionService.instance.isSuper) {
      return (tables: 0, rows: 0, error: 'Only super user can run backup');
    }

    await init();

    int totalTables = 0;
    int totalRows = 0;

    try {
      final db = await ErpDatabase.instance.database;

      // Write backup metadata
      await _ref.child('_meta').set({
        'started_at': ServerValue.timestamp,
        'device': PermissionService.instance.currentPhone,
      });

      for (final table in _backupTables) {
        onProgress?.call('Backing up $table...');
        try {
          final rows = await _backupTable(db, table);
          totalTables++;
          totalRows += rows;
        } catch (e) {
          debugPrint('⚠ backup ($table): $e');
        }
      }

      // Write completion metadata
      await _ref.child('_meta').update({
        'completed_at': ServerValue.timestamp,
        'tables': totalTables,
        'rows': totalRows,
      });

      return (tables: totalTables, rows: totalRows, error: null);
    } catch (e) {
      debugPrint('⚠ backup error: $e');
      return (tables: totalTables, rows: totalRows, error: e.toString());
    }
  }

  Future<int> _backupTable(sql.Database db, String table) async {
    try {
      final localRows = await db.query(table);
      if (localRows.isEmpty) {
        // Clear remote table if local is empty
        await _ref.child(table).remove();
        return 0;
      }

      final Map<String, dynamic> batch = {};
      for (final row in localRows) {
        final id = row['id'];
        if (id == null) continue;
        batch[id.toString()] = row;
      }

      // Overwrite entire table in one go
      await _ref.child(table).set(batch);
      return localRows.length;
    } catch (e) {
      debugPrint('⚠ _backupTable ($table): $e');
      rethrow;
    }
  }

  /// Get last backup info from the secondary Firebase.
  Future<Map<String, dynamic>?> getLastBackupInfo() async {
    await init();
    try {
      final snap = await _ref.child('_meta').get();
      if (snap.exists && snap.value is Map) {
        return Map<String, dynamic>.from(snap.value as Map);
      }
    } catch (e) {
      debugPrint('⚠ getLastBackupInfo: $e');
    }
    return null;
  }
}
