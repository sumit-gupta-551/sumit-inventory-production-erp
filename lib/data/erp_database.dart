import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/product.dart';
import '../models/party.dart';
import 'firebase_sync_service.dart';
import 'permission_service.dart';

class ErpDatabase {
  static final ErpDatabase instance = ErpDatabase._init();
  static Database? _db;
  bool _closedRequirementLedgerRepairDone = false;
  bool _closedRequirementDataRepairDone = false;
  int _bulkMutationDepth = 0;
  bool _bulkMutationDirty = false;
  int _suppressActivityLogDepth = 0;

  /// Incremented after every insert/update/delete.
  /// Pages listen to this to auto-refresh their data.
  /// Debounced so rapid-fire sync changes don't trigger reload storms.
  final dataVersion = _DebouncedIntNotifier(0);

  ErpDatabase._init();

  void _beginBulkMutation({bool suppressActivityLog = false}) {
    _bulkMutationDepth++;
    if (suppressActivityLog) {
      _suppressActivityLogDepth++;
    }
  }

  void _endBulkMutation({bool suppressActivityLog = false}) {
    if (_bulkMutationDepth > 0) {
      _bulkMutationDepth--;
    }
    if (_bulkMutationDepth == 0 && _bulkMutationDirty) {
      _bulkMutationDirty = false;
      dataVersion.value++;
    }
    if (suppressActivityLog && _suppressActivityLogDepth > 0) {
      _suppressActivityLogDepth--;
    }
  }

  void _markDataChanged() {
    if (_bulkMutationDepth > 0) {
      _bulkMutationDirty = true;
      return;
    }
    dataVersion.value++;
  }

  bool get _shouldWriteActivityLog => _suppressActivityLogDepth == 0;

  // ================= DATABASE INSTANCE =================
  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  // ================= INIT DB =================
  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'erp.db');

    final db = await openDatabase(
      path,
      version: 25,
      onConfigure: (db) async {
        // Best-effort tuning. Never fail DB open if another process/session
        // temporarily holds a lock.
        try {
          await db.execute('PRAGMA busy_timeout=6000');
        } catch (_) {}
        try {
          await db.execute('PRAGMA synchronous=NORMAL');
        } catch (_) {}
      },
      onCreate: (db, version) async {
        await _createDB(db, version);
        await _seedGstCategories(db);
      },
      onUpgrade: _upgradeDB,
    );

    // ðŸ”¥ ADD THIS LINE (VERY IMPORTANT)
    await _seedGstCategories(db);
    await _ensureAllTables(db);
    await _ensureStockLedgerColumns(db);
    await _ensurePurchaseMasterReportingColumns(db);
    await _ensurePurchaseMasterOrderNoColumn(db);
    await _ensureSalaryAdvanceMonthColumn(db);
    await _createIndexes(db);
    await _fixReqCloseRemarks(db);
    await _cleanupOrphanOrderPurchaseLedgerEntries(db);
    await _reopenOrphanCompletedProgramCards(db);
    await _restoreRecentlyDeletedDispatchBills(db);

    return db;
  }
  // Only keep the first definition block above. Remove all duplicate static fields, constructors, and methods below this point.

  /// Delete all attendance records for a given period
  Future<void> deleteAttendanceForPeriod(int fromMs, int toMs) async {
    final db = await database;
    await db.delete(
      'attendance',
      where: 'date >= ? AND date <= ?',
      whereArgs: [fromMs, toMs],
    );
  }

  /// Latest production entry id. Used for fast incremental attendance sync.
  Future<int> getMaxProductionEntryId() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(id), 0) AS max_id FROM production_entries',
    );
    final raw = rows.first['max_id'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return 0;
  }

  /// Update attendance for production entries since [sinceMs].
  /// Optionally restrict to a date range [from] to [to].
  Future<void> updateAttendanceFromProductionSince(
    int? sinceProductionId, {
    DateTime? from,
    DateTime? to,
  }) async {
    // ...existing code...
    final db = await database;
    final cols = await db.rawQuery("PRAGMA table_info(stock_ledger)");
    final hasIsDeleted = cols.any((c) => c['name'] == 'is_deleted');
    if (!hasIsDeleted) {
      await db.execute(
          "ALTER TABLE stock_ledger ADD COLUMN is_deleted INTEGER DEFAULT 0");
    }
    debugPrint(
        'SYNC: updateAttendanceFromProductionSince called with sinceProductionId=$sinceProductionId, from=$from, to=$to');
    String where = 'employee_id IS NOT NULL AND date IS NOT NULL';
    List whereArgs = [];
    if (sinceProductionId != null) {
      // Use production entry id for incremental sync.
      // Date can be backdated and would miss rows when compared to "last sync time".
      where += ' AND id > ?';
      whereArgs.add(sinceProductionId);
    }
    if (from != null) {
      where += ' AND date >= ?';
      whereArgs.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where += ' AND date <= ?';
      whereArgs.add(to.millisecondsSinceEpoch);
    }
    debugPrint('SYNC: where=$where, whereArgs=$whereArgs');
    final prodRows = await db.query(
      'production_entries',
      distinct: true,
      columns: ['employee_id', 'date'],
      where: where,
      whereArgs: whereArgs,
    );
    debugPrint('SYNC: Found ${prodRows.length} production entries to sync');

    // Optimization: Fetch all attendance records for the relevant dates in one query
    final empDates = prodRows
        .map((row) {
          final empId = row['employee_id'];
          final date = row['date'];
          if (empId == null || date == null) return null;
          final normDate = DateTime.fromMillisecondsSinceEpoch(
              date is int ? date : (date as num).toInt());
          final dayStart = DateTime(normDate.year, normDate.month, normDate.day)
              .millisecondsSinceEpoch;
          return {'employee_id': empId, 'date': dayStart};
        })
        .whereType<Map<String, dynamic>>()
        .toList();

    // Build a set of all (employee_id, date) pairs
    final empDateSet =
        empDates.map((e) => "${e['employee_id']}_${e['date']}").toSet();
    List<Map<String, dynamic>> existingAttendance = [];
    if (empDateSet.isNotEmpty) {
      final empIds = empDates.map((e) => e['employee_id']).toSet().toList();
      final minDate =
          empDates.map((e) => e['date'] as int).reduce((a, b) => a < b ? a : b);
      final maxDate =
          empDates.map((e) => e['date'] as int).reduce((a, b) => a > b ? a : b);
      existingAttendance = await db.query(
        'attendance',
        columns: ['id', 'employee_id', 'date'],
        where:
            'employee_id IN (${List.filled(empIds.length, '?').join(',')}) AND date >= ? AND date <= ?',
        whereArgs: [...empIds, minDate, maxDate],
      );
    }
    // Build a map for quick lookup
    final Map<String, Map<String, dynamic>> attendanceMap = {
      for (var row in existingAttendance)
        "${row['employee_id']}_${row['date']}": row
    };

    // Batch insert/update in a transaction
    final sync = FirebaseSyncService.instance;
    await sync.beginLocalDbWrite();
    try {
      await db.transaction((txn) async {
        for (final row in prodRows) {
          final empId = row['employee_id'];
          final date = row['date'];
          if (empId == null || date == null) continue;
          final normDate = DateTime.fromMillisecondsSinceEpoch(
              date is int ? date : (date as num).toInt());
          final dayStart = DateTime(normDate.year, normDate.month, normDate.day)
              .millisecondsSinceEpoch;
          final key = "${empId}_$dayStart";
          final existing = attendanceMap[key];
          if (existing == null) {
            await txn.insert('attendance', {
              'employee_id': empId,
              'date': dayStart,
              'status': 'present',
              'shift': 'day',
              'remarks': 'Auto: Production (update new)',
            });
          }
        }
      });
    } finally {
      await sync.endLocalDbWrite();
    }
  }

  /// Update attendance for all employees who have production entries.
  /// For every (employee, date) in production, set attendance to 'present'.
  Future<void> updateAttendanceFromAllProduction() async {
    debugPrint('--- SYNC: updateAttendanceFromAllProduction START ---');
    final db = await database;
    final prodRows = await db.rawQuery('''
      SELECT DISTINCT employee_id, date FROM production_entries
      WHERE employee_id IS NOT NULL AND date IS NOT NULL
    ''');
    for (final row in prodRows) {
      final empId = row['employee_id'];
      final date = row['date'];
      if (empId == null || date == null) continue;
      // Normalize date to start of day
      final normDate = DateTime.fromMillisecondsSinceEpoch(
          date is int ? date : (date as num).toInt());
      final dayStart = DateTime(normDate.year, normDate.month, normDate.day)
          .millisecondsSinceEpoch;
      debugPrint(
          'SYNC: Employee $empId, Date $dayStart (${normDate.year}-${normDate.month}-${normDate.day})');
      final existing = await db.query('attendance',
          columns: ['id'],
          where: 'employee_id = ? AND date = ?',
          whereArgs: [empId, dayStart],
          limit: 1);
      if (existing.isEmpty) {
        await _syncInsert('attendance', {
          'employee_id': empId,
          'date': dayStart,
          'status': 'present',
          'shift': 'day',
          'remarks': 'Auto: Production (update all)',
        });
      }
    }
    debugPrint('--- SYNC: updateAttendanceFromAllProduction END ---');
  }

  /// Sync all production entries to attendance: for every production entry, ensure attendance is present for that employee/date.
  Future<void> syncAllProductionToAttendance() async {
    final db = await database;
    // Get all unique (employee_id, date) pairs from production_entries
    final prodRows = await db.rawQuery('''
        SELECT DISTINCT employee_id, date FROM production_entries
        WHERE employee_id IS NOT NULL AND date IS NOT NULL
      ''');
    for (final row in prodRows) {
      final empId = row['employee_id'];
      final date = row['date'];
      if (empId == null || date == null) continue;
      // Normalize date to start of day
      final normDate = DateTime.fromMillisecondsSinceEpoch(
          date is int ? date : (date as num).toInt());
      final dayStart = DateTime(normDate.year, normDate.month, normDate.day)
          .millisecondsSinceEpoch;
      final existing = await db.query('attendance',
          columns: ['id'],
          where: 'employee_id = ? AND date = ?',
          whereArgs: [empId, dayStart],
          limit: 1);
      if (existing.isEmpty) {
        await _syncInsert('attendance', {
          'employee_id': empId,
          'date': dayStart,
          'status': 'present',
          'shift': 'day',
          'remarks': 'Auto: Production (sync)',
        });
      }
    }
  }

  /// Ensure every table exists (safe to call on every startup).
  Future<void> _ensureAllTables(Database db) async {
    const ddl = [
      '''CREATE TABLE IF NOT EXISTS gst_categories (
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, gst_percent REAL)''',
      '''CREATE TABLE IF NOT EXISTS products (
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, category TEXT,
        unit TEXT, min_stock REAL, gst_category_id INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS parties (
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, address TEXT,
        mobile TEXT, party_type TEXT DEFAULT 'Sales')''',
      '''CREATE TABLE IF NOT EXISTS firms (
        id INTEGER PRIMARY KEY AUTOINCREMENT, firm_name TEXT)''',
      '''CREATE TABLE IF NOT EXISTS purchase_master (
        id INTEGER PRIMARY KEY AUTOINCREMENT, purchase_no INTEGER,
        firm_id INTEGER, purchase_date INTEGER, invoice_no TEXT,
        party_id INTEGER, order_no INTEGER, gross_amount REAL, discount_amount REAL,
        cgst REAL, sgst REAL, igst REAL, total_amount REAL)''',
      '''CREATE TABLE IF NOT EXISTS purchase_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT, purchase_no INTEGER,
        product_id INTEGER, shade_id INTEGER, qty REAL, rate REAL,
        amount REAL)''',
      '''CREATE TABLE IF NOT EXISTS order_master (
        id INTEGER PRIMARY KEY AUTOINCREMENT, order_no INTEGER,
        firm_id INTEGER, order_date INTEGER, party_id INTEGER,
        remarks TEXT, status TEXT DEFAULT 'open',
        total_qty REAL DEFAULT 0, closed_at INTEGER, created_at INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS order_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT, order_no INTEGER,
        product_id INTEGER, shade_id INTEGER, qty REAL)''',
      '''CREATE TABLE IF NOT EXISTS machines (
        id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT, name TEXT,
        unit_name TEXT, status TEXT,
        bonus_per_stitch REAL DEFAULT 0, incentive_per_stitch REAL DEFAULT 0,
        incentive_after_stitch INTEGER DEFAULT 0, incentive_amount REAL DEFAULT 0,
        bonus REAL DEFAULT 0)''',
      '''CREATE TABLE IF NOT EXISTS fabric_shades (
        id INTEGER PRIMARY KEY AUTOINCREMENT, shade_no TEXT,
        shade_name TEXT, image_path TEXT)''',
      '''CREATE TABLE IF NOT EXISTS thread_shades (
        id INTEGER PRIMARY KEY AUTOINCREMENT, shade_no TEXT,
        company_name TEXT)''',
      '''CREATE TABLE IF NOT EXISTS delay_reasons (
        id INTEGER PRIMARY KEY AUTOINCREMENT, reason TEXT)''',
      '''CREATE TABLE IF NOT EXISTS program_master (
        id INTEGER PRIMARY KEY AUTOINCREMENT, program_no INTEGER,
        program_date INTEGER, party_id INTEGER, card_no TEXT,
        design_no TEXT, designer TEXT, status TEXT)''',
      '''CREATE TABLE IF NOT EXISTS program_fabrics (
        id INTEGER PRIMARY KEY AUTOINCREMENT, program_no INTEGER,
        fabric_shade_id INTEGER, qty REAL)''',
      '''CREATE TABLE IF NOT EXISTS program_thread_shades (
        id INTEGER PRIMARY KEY AUTOINCREMENT, program_no INTEGER,
        thread_shade_id INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS program_allotment (
        id INTEGER PRIMARY KEY AUTOINCREMENT, program_no INTEGER,
        machine_id INTEGER, status TEXT)''',
      '''CREATE TABLE IF NOT EXISTS program_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT, program_no INTEGER,
        message TEXT, date INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS stock_ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT, product_id INTEGER,
        fabric_shade_id INTEGER, qty REAL, type TEXT, date INTEGER,
        reference TEXT, remarks TEXT, is_deleted INTEGER DEFAULT 0,
        order_no INTEGER
      )''',
      '''CREATE TABLE IF NOT EXISTS challan_requirements (
        id INTEGER PRIMARY KEY AUTOINCREMENT, challan_no TEXT,
        party_id INTEGER, party_name TEXT, product_id INTEGER,
        fabric_shade_id INTEGER, qty REAL, date INTEGER,
        status TEXT DEFAULT 'pending', closed_date INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS employees (
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
        mobile TEXT, designation TEXT, unit_name TEXT,
        salary_type TEXT DEFAULT 'monthly', base_pay REAL DEFAULT 0,
        salary_base_days INTEGER DEFAULT 30,
        join_date INTEGER, status TEXT DEFAULT 'active')''',
      '''CREATE TABLE IF NOT EXISTS employee_salary_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL,
        base_pay REAL DEFAULT 0,
        salary_type TEXT DEFAULT 'monthly',
        salary_base_days INTEGER DEFAULT 30,
        effective_from INTEGER NOT NULL,
        created_at INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS production_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT, date INTEGER NOT NULL,
        unit_name TEXT, machine_id INTEGER, employee_id INTEGER,
        stitch INTEGER DEFAULT 0, bonus REAL DEFAULT 0,
        incentive_bonus REAL DEFAULT 0, total_bonus REAL DEFAULT 0,
        remarks TEXT)''',
      '''CREATE TABLE IF NOT EXISTS attendance (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL, date INTEGER NOT NULL,
        status TEXT DEFAULT 'present', shift TEXT DEFAULT 'day',
        remarks TEXT)''',
      '''CREATE TABLE IF NOT EXISTS units (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL)''',
      '''CREATE TABLE IF NOT EXISTS salary_advances (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL,
        amount REAL NOT NULL DEFAULT 0,
        payment_mode TEXT DEFAULT 'cash',
        date INTEGER NOT NULL,
        for_month INTEGER,
        remarks TEXT,
        created_at INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS salary_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL,
        amount REAL NOT NULL DEFAULT 0,
        payment_mode TEXT DEFAULT 'cash',
        date INTEGER NOT NULL,
        from_date INTEGER,
        to_date INTEGER,
        remarks TEXT,
        created_at INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS saved_payroll (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL,
        from_date INTEGER NOT NULL,
        to_date INTEGER NOT NULL,
        base_pay REAL DEFAULT 0,
        salary_type TEXT DEFAULT 'monthly',
        salary_base_days INTEGER DEFAULT 30,
        present_days INTEGER DEFAULT 0,
        half_days INTEGER DEFAULT 0,
        absent_days INTEGER DEFAULT 0,
        double_days INTEGER DEFAULT 0,
        effective_days REAL DEFAULT 0,
        base_salary REAL DEFAULT 0,
        total_bonus REAL DEFAULT 0,
        total_incentive REAL DEFAULT 0,
        total_all_bonus REAL DEFAULT 0,
        total_advance REAL DEFAULT 0,
        net_salary REAL DEFAULT 0,
        created_at INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS activity_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT NOT NULL,
        table_name TEXT,
        record_id INTEGER,
        details TEXT,
        user_name TEXT,
        timestamp INTEGER NOT NULL)''',
      '''CREATE TABLE IF NOT EXISTS program_cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        program_date INTEGER,
        company TEXT,
        party_id INTEGER,
        product_id INTEGER,
        design_no TEXT,
        card_no TEXT,
        tp REAL DEFAULT 0,
        line_no TEXT,
        status TEXT,
        status_dhaga_cutting INTEGER,
        status_alter INTEGER,
        status_stiching INTEGER,
        status_cutting INTEGER,
        status_checking INTEGER,
        status_shoulder_cutting INTEGER,
        status_ready_dispatch INTEGER,
        remarks TEXT,
        created_at INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS dispatch_bills (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bill_date INTEGER,
        bill_no TEXT,
        party_id INTEGER,
        remarks TEXT,
        created_at INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS dispatch_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bill_id INTEGER,
        program_card_id INTEGER,
        company TEXT,
        product_id INTEGER,
        design_no TEXT,
        card_no TEXT,
        qty REAL DEFAULT 0,
        pcs REAL DEFAULT 0,
        created_at INTEGER)''',
      '''CREATE TABLE IF NOT EXISTS _pending_sync (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        table_name TEXT NOT NULL,
        record_id INTEGER NOT NULL,
        action TEXT NOT NULL,
        data TEXT,
        created_at INTEGER)''',
    ];
    for (final sql in ddl) {
      try {
        await db.execute(sql);
      } catch (e) {
        debugPrint('âš  _ensureAllTables: $e');
      }
    }

    // Ensure missing columns on existing tables
    const alterMap = {
      'employees': ['salary_base_days', 'unit_name'],
      'machines': ['incentive_amount', 'bonus'],
      'program_cards': ['product_id'],
      'dispatch_items': ['product_id'],
    };
    for (final entry in alterMap.entries) {
      try {
        final cols = await db.rawQuery('PRAGMA table_info(${entry.key})');
        final existing =
            cols.map((c) => (c['name'] ?? '').toString().toLowerCase()).toSet();
        for (final col in entry.value) {
          if (!existing.contains(col.toLowerCase())) {
            final type = col.contains('amount') || col == 'bonus'
                ? 'REAL DEFAULT 0'
                : col.contains('days')
                    ? 'INTEGER DEFAULT 30'
                    : col.endsWith('_id')
                        ? 'INTEGER'
                        : 'TEXT';
            await db.execute('ALTER TABLE ${entry.key} ADD COLUMN $col $type');
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _ensurePurchaseMasterReportingColumns(Database db) async {
    try {
      final cols = await db.rawQuery('PRAGMA table_info(purchase_master)');
      final names =
          cols.map((e) => (e['name'] ?? '').toString().toLowerCase()).toSet();

      if (!names.contains('report_email')) {
        await db.execute(
            'ALTER TABLE purchase_master ADD COLUMN report_email TEXT');
      }
      if (!names.contains('report_mobile')) {
        await db.execute(
            'ALTER TABLE purchase_master ADD COLUMN report_mobile TEXT');
      }
      if (!names.contains('report_message')) {
        await db.execute(
            'ALTER TABLE purchase_master ADD COLUMN report_message TEXT');
      }
    } catch (_) {
      // Ignore if table does not exist yet or migration is in progress.
    }
  }

  Future<void> _ensurePurchaseMasterOrderNoColumn(Database db) async {
    try {
      final cols = await db.rawQuery('PRAGMA table_info(purchase_master)');
      final names =
          cols.map((e) => (e['name'] ?? '').toString().toLowerCase()).toSet();
      if (!names.contains('order_no')) {
        await db
            .execute('ALTER TABLE purchase_master ADD COLUMN order_no INTEGER');
      }
    } catch (_) {
      // Ignore if table does not exist yet or migration is in progress.
    }
  }

  Future<void> _ensureSalaryAdvanceMonthColumn(Database db) async {
    try {
      final cols = await db.rawQuery('PRAGMA table_info(salary_advances)');
      final names =
          cols.map((e) => (e['name'] ?? '').toString().toLowerCase()).toSet();
      if (!names.contains('for_month')) {
        await db.execute(
            'ALTER TABLE salary_advances ADD COLUMN for_month INTEGER');
      }

      final rows = await db.query(
        'salary_advances',
        columns: ['id', 'date', 'for_month'],
        where: 'for_month IS NULL OR for_month <= 0',
      );
      if (rows.isEmpty) return;

      await db.transaction((txn) async {
        for (final row in rows) {
          final id = (row['id'] as num?)?.toInt();
          final dateMs = (row['date'] as num?)?.toInt();
          if (id == null || dateMs == null || dateMs <= 0) continue;
          final d = DateTime.fromMillisecondsSinceEpoch(dateMs);
          final monthStart = DateTime(d.year, d.month).millisecondsSinceEpoch;
          await txn.update(
            'salary_advances',
            {'for_month': monthStart},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      });
    } catch (_) {
      // Ignore if table does not exist yet or migration is in progress.
    }
  }

  Future<void> _ensureStockLedgerColumns(Database db) async {
    try {
      final cols = await db.rawQuery('PRAGMA table_info(stock_ledger)');
      final names =
          cols.map((e) => (e['name'] ?? '').toString().toLowerCase()).toSet();

      if (!names.contains('is_deleted')) {
        await db.execute(
            'ALTER TABLE stock_ledger ADD COLUMN is_deleted INTEGER DEFAULT 0');
      }
      if (!names.contains('order_no')) {
        await db
            .execute('ALTER TABLE stock_ledger ADD COLUMN order_no INTEGER');
      }
    } catch (_) {
      // Ignore if the table is being created/migrated; _ensureAllTables runs first.
    }
  }

  // ================= CREATE TABLES =================
  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
    CREATE TABLE gst_categories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      gst_percent REAL
    )
    ''');

    await db.execute('''
    CREATE TABLE products (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      category TEXT,
      unit TEXT,
      min_stock REAL,
      gst_category_id INTEGER
    )
    ''');

    await db.execute('''
    CREATE TABLE parties (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      address TEXT,
      mobile TEXT,
      party_type TEXT DEFAULT 'Sales'
    )
    ''');

    await db.execute('''
    CREATE TABLE firms (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      firm_name TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE purchase_master (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      purchase_no INTEGER,
      firm_id INTEGER,
      purchase_date INTEGER,
      invoice_no TEXT,
      party_id INTEGER,
      order_no INTEGER,
      gross_amount REAL,
      discount_amount REAL,
      cgst REAL,
      sgst REAL,
      igst REAL,
      total_amount REAL
    )
    ''');

    await db.execute('''
    CREATE TABLE purchase_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      purchase_no INTEGER,
      product_id INTEGER,
      shade_id INTEGER,
      qty REAL,
      rate REAL,
      amount REAL
    )
    ''');

    await db.execute('''
    CREATE TABLE order_master (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      order_no INTEGER,
      firm_id INTEGER,
      order_date INTEGER,
      party_id INTEGER,
      remarks TEXT,
      status TEXT DEFAULT 'open',
      total_qty REAL DEFAULT 0,
      closed_at INTEGER,
      created_at INTEGER
    )
    ''');

    await db.execute('''
    CREATE TABLE order_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      order_no INTEGER,
      product_id INTEGER,
      shade_id INTEGER,
      qty REAL
    )
    ''');

    await db.execute('''
    CREATE TABLE machines (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      code TEXT,
      name TEXT,
      unit_name TEXT,
      status TEXT,
      bonus_per_stitch REAL DEFAULT 0,
      incentive_per_stitch REAL DEFAULT 0,
      bonus REAL DEFAULT 0,
      incentive_amount REAL DEFAULT 0
    )
    ''');

    await db.execute('''
    CREATE TABLE fabric_shades (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      shade_no TEXT,
      shade_name TEXT,
      image_path TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE thread_shades (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      shade_no TEXT,
      company_name TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE delay_reasons (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      reason TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE program_master (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      program_no INTEGER,
      program_date INTEGER,
      party_id INTEGER,
      card_no TEXT,
      design_no TEXT,
      designer TEXT,
      status TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE program_fabrics (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      program_no INTEGER,
      fabric_shade_id INTEGER,
      qty REAL
    )
    ''');

    await db.execute('''
    CREATE TABLE program_thread_shades (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      program_no INTEGER,
      thread_shade_id INTEGER
    )
    ''');

    await db.execute('''
    CREATE TABLE program_allotment (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      program_no INTEGER,
      machine_id INTEGER,
      status TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE program_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      program_no INTEGER,
      message TEXT,
      date INTEGER
    )
    ''');

    await db.execute('''
    CREATE TABLE stock_ledger (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      product_id INTEGER,
      fabric_shade_id INTEGER,
      qty REAL,
      type TEXT,
      date INTEGER,
      reference TEXT,
      remarks TEXT,
      is_deleted INTEGER DEFAULT 0,
      order_no INTEGER
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS challan_requirements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      challan_no TEXT,
      party_id INTEGER,
      party_name TEXT,
      product_id INTEGER,
      fabric_shade_id INTEGER,
      qty REAL,
      date INTEGER,
      status TEXT DEFAULT 'pending',
      closed_date INTEGER
    )
    ''');

    // Payroll tables
    await _createPayrollTables(db);

    // Performance indexes
    await _createIndexes(db);
  }

  Future<void> _createPayrollTables(Database db) async {
    await db.execute('''
    CREATE TABLE IF NOT EXISTS employees (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      mobile TEXT,
      designation TEXT,
      unit_name TEXT,
      salary_type TEXT DEFAULT 'monthly',
      base_pay REAL DEFAULT 0,
      join_date INTEGER,
      status TEXT DEFAULT 'active'
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS production_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      date INTEGER NOT NULL,
      unit_name TEXT,
      machine_id INTEGER,
      employee_id INTEGER,
      stitch INTEGER DEFAULT 0,
      bonus REAL DEFAULT 0,
      incentive_bonus REAL DEFAULT 0,
      total_bonus REAL DEFAULT 0,
      remarks TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS attendance (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      employee_id INTEGER NOT NULL,
      date INTEGER NOT NULL,
      status TEXT DEFAULT 'present',
      shift TEXT DEFAULT 'day',
      remarks TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS salary_advances (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      employee_id INTEGER NOT NULL,
      amount REAL NOT NULL DEFAULT 0,
      payment_mode TEXT DEFAULT 'cash',
      date INTEGER NOT NULL,
      for_month INTEGER,
      remarks TEXT,
      created_at INTEGER
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS salary_payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      employee_id INTEGER NOT NULL,
      amount REAL NOT NULL DEFAULT 0,
      payment_mode TEXT DEFAULT 'cash',
      date INTEGER NOT NULL,
      from_date INTEGER,
      to_date INTEGER,
      remarks TEXT,
      created_at INTEGER
    )
    ''');
  }

  Future<void> _createIndexes(Database db) async {
    const indexes = [
      'CREATE INDEX IF NOT EXISTS idx_stock_ledger_product ON stock_ledger(product_id)',
      'CREATE INDEX IF NOT EXISTS idx_stock_ledger_shade ON stock_ledger(fabric_shade_id)',
      'CREATE INDEX IF NOT EXISTS idx_stock_ledger_date ON stock_ledger(date)',
      'CREATE INDEX IF NOT EXISTS idx_stock_ledger_prod_shade ON stock_ledger(product_id, fabric_shade_id)',
      'CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items(purchase_no)',
      'CREATE INDEX IF NOT EXISTS idx_purchase_items_product ON purchase_items(product_id)',
      'CREATE INDEX IF NOT EXISTS idx_purchase_items_shade ON purchase_items(shade_id)',
      'CREATE INDEX IF NOT EXISTS idx_purchase_master_party ON purchase_master(party_id)',
      'CREATE INDEX IF NOT EXISTS idx_purchase_master_firm ON purchase_master(firm_id)',
      'CREATE INDEX IF NOT EXISTS idx_purchase_master_date ON purchase_master(purchase_date)',
      'CREATE INDEX IF NOT EXISTS idx_purchase_master_order_no ON purchase_master(order_no)',
      'CREATE INDEX IF NOT EXISTS idx_order_master_order_no ON order_master(order_no)',
      'CREATE INDEX IF NOT EXISTS idx_order_master_status ON order_master(status)',
      'CREATE INDEX IF NOT EXISTS idx_order_master_party ON order_master(party_id)',
      'CREATE INDEX IF NOT EXISTS idx_order_master_firm ON order_master(firm_id)',
      'CREATE INDEX IF NOT EXISTS idx_order_master_date ON order_master(order_date)',
      'CREATE INDEX IF NOT EXISTS idx_order_items_order_no ON order_items(order_no)',
      'CREATE INDEX IF NOT EXISTS idx_order_items_product ON order_items(product_id)',
      'CREATE INDEX IF NOT EXISTS idx_order_items_shade ON order_items(shade_id)',
      'CREATE INDEX IF NOT EXISTS idx_challan_req_party ON challan_requirements(party_id)',
      'CREATE INDEX IF NOT EXISTS idx_challan_req_product ON challan_requirements(product_id)',
      'CREATE INDEX IF NOT EXISTS idx_challan_req_shade ON challan_requirements(fabric_shade_id)',
      'CREATE INDEX IF NOT EXISTS idx_production_date ON production_entries(date)',
      'CREATE INDEX IF NOT EXISTS idx_production_employee ON production_entries(employee_id)',
      'CREATE INDEX IF NOT EXISTS idx_production_machine ON production_entries(machine_id)',
      'CREATE INDEX IF NOT EXISTS idx_production_unit ON production_entries(unit_name)',
      'CREATE INDEX IF NOT EXISTS idx_production_emp_date ON production_entries(employee_id, date)',
      'CREATE INDEX IF NOT EXISTS idx_attendance_employee ON attendance(employee_id)',
      'CREATE INDEX IF NOT EXISTS idx_attendance_date ON attendance(date)',
      'CREATE INDEX IF NOT EXISTS idx_attendance_emp_date ON attendance(employee_id, date)',
      'CREATE INDEX IF NOT EXISTS idx_salary_advances_emp ON salary_advances(employee_id)',
      'CREATE INDEX IF NOT EXISTS idx_salary_advances_date ON salary_advances(date)',
      'CREATE INDEX IF NOT EXISTS idx_salary_advances_emp_date ON salary_advances(employee_id, date)',
      'CREATE INDEX IF NOT EXISTS idx_salary_advances_for_month ON salary_advances(for_month)',
      'CREATE INDEX IF NOT EXISTS idx_salary_advances_emp_for_month ON salary_advances(employee_id, for_month)',
      'CREATE INDEX IF NOT EXISTS idx_salary_payments_emp ON salary_payments(employee_id)',
      'CREATE INDEX IF NOT EXISTS idx_salary_payments_date ON salary_payments(date)',
      'CREATE INDEX IF NOT EXISTS idx_saved_payroll_emp ON saved_payroll(employee_id)',
      'CREATE INDEX IF NOT EXISTS idx_saved_payroll_dates ON saved_payroll(from_date, to_date)',
      'CREATE INDEX IF NOT EXISTS idx_emp_salary_hist_emp ON employee_salary_history(employee_id)',
    ];
    for (final sql in indexes) {
      try {
        await db.execute(sql);
      } catch (_) {}
    }
  }

  /// One-time fix: patch old REQ-CLOSE stock_ledger remarks to include
  /// party name and completion date from matching challan_requirements.
  Future<void> _fixReqCloseRemarks(Database db) async {
    try {
      // Find REQ-CLOSE entries missing 'Party:' in remarks
      final rows = await db.rawQuery('''
        SELECT id, remarks, date FROM stock_ledger
        WHERE reference LIKE 'REQ-CLOSE%'
          AND (remarks NOT LIKE '%Party:%' OR remarks LIKE '%Requirement closed%')
          AND (is_deleted IS NULL OR is_deleted = 0)
        LIMIT 100
      ''');
      if (rows.isEmpty) return;

      for (final row in rows) {
        final id = row['id'] as int;
        final oldRemarks = (row['remarks'] ?? '').toString();
        final dateMs = row['date'] as int?;

        // Parse challan no from old remarks
        String challanNo = '';
        final chMatch = RegExp(r'Ch[No]*[:\s]+([^|]+)').firstMatch(oldRemarks);
        if (chMatch != null) challanNo = chMatch.group(1)!.trim();

        // Look up party_name from challan_requirements
        String partyName = '';
        if (challanNo.isNotEmpty) {
          final cr = await db.rawQuery('''
            SELECT party_name FROM challan_requirements
            WHERE challan_no = ? LIMIT 1
          ''', [challanNo]);
          if (cr.isNotEmpty) {
            partyName = (cr.first['party_name'] ?? '').toString();
          }
        }

        // Format completion date from the ledger entry date
        String dateStr = '';
        if (dateMs != null) {
          final d = DateTime.fromMillisecondsSinceEpoch(dateMs);
          dateStr =
              '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
        }

        final newRemarks = partyName.isNotEmpty
            ? 'Party: $partyName | ChNo: $challanNo | Req completed on: $dateStr'
            : 'ChNo: $challanNo | Req completed on: $dateStr';

        try {
          await db.update('stock_ledger', {'remarks': newRemarks},
              where: 'id=?', whereArgs: [id]);
        } catch (e) {
          // This is a one-time cosmetic fix; if DB is busy during startup,
          // skip immediately and try again on a future run.
          if (_isDatabaseLockedError(e)) {
            return;
          }
          rethrow;
        }
      }
      debugPrint('âœ… Fixed ${rows.length} REQ-CLOSE remarks');
    } catch (e) {
      if (_isDatabaseLockedError(e)) return;
      debugPrint('_fixReqCloseRemarks: $e');
    }
  }

  // ================= GST SEED =================
  Future<void> _seedGstCategories(Database db) async {
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM gst_categories'),
    );
    if (count != null && count > 0) return;

    await db.insert('gst_categories', {'name': 'GST 5%', 'gst_percent': 5});
    await db.insert('gst_categories', {'name': 'GST 12%', 'gst_percent': 12});
    await db.insert('gst_categories', {'name': 'GST 18%', 'gst_percent': 18});
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 4) {
      await db.execute('''
      CREATE TABLE IF NOT EXISTS fabric_shades (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        shade_no TEXT,
        shade_name TEXT,
        image_path TEXT
      )
      ''');

      await db.execute('''
      CREATE TABLE IF NOT EXISTS thread_shades (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        shade_no TEXT,
        company_name TEXT
      )
      ''');

      try {
        await db.execute(
          'ALTER TABLE thread_shades ADD COLUMN company_name TEXT',
        );
      } catch (_) {
        // Column exists or table created with correct schema.
      }
    }

    if (oldVersion < 5) {
      try {
        await db.execute(
            'ALTER TABLE purchase_master ADD COLUMN report_email TEXT');
      } catch (_) {
        // Column already exists.
      }
      try {
        await db.execute(
            'ALTER TABLE purchase_master ADD COLUMN report_mobile TEXT');
      } catch (_) {
        // Column already exists.
      }
      try {
        await db.execute(
            'ALTER TABLE purchase_master ADD COLUMN report_message TEXT');
      } catch (_) {
        // Column already exists.
      }
    }

    if (oldVersion < 6) {
      await db.execute('''
      CREATE TABLE IF NOT EXISTS challan_requirements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        challan_no TEXT,
        party_id INTEGER,
        party_name TEXT,
        product_id INTEGER,
        fabric_shade_id INTEGER,
        qty REAL,
        date INTEGER,
        status TEXT DEFAULT 'pending',
        closed_date INTEGER
      )
      ''');
    }

    if (oldVersion < 7) {
      try {
        await db.execute(
            "ALTER TABLE parties ADD COLUMN party_type TEXT DEFAULT 'Sales'");
      } catch (_) {
        // Column already exists.
      }
    }

    if (oldVersion < 8) {
      // Clean up orphaned records from previously deleted shades
      await db.execute('''
        DELETE FROM stock_ledger
        WHERE fabric_shade_id IS NOT NULL
          AND fabric_shade_id != 0
          AND fabric_shade_id NOT IN (SELECT id FROM fabric_shades)
      ''');
      await db.execute('''
        DELETE FROM purchase_items
        WHERE shade_id IS NOT NULL
          AND shade_id != 0
          AND shade_id NOT IN (SELECT id FROM fabric_shades)
      ''');
      await db.execute('''
        DELETE FROM challan_requirements
        WHERE fabric_shade_id IS NOT NULL
          AND fabric_shade_id != 0
          AND fabric_shade_id NOT IN (SELECT id FROM fabric_shades)
      ''');
    }

    if (oldVersion < 9) {
      await _createPayrollTables(db);
    }

    if (oldVersion < 10) {
      try {
        await db.execute('ALTER TABLE machines ADD COLUMN unit_name TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE employees ADD COLUMN unit_name TEXT');
      } catch (_) {}
    }

    if (oldVersion < 11) {
      try {
        await db.execute('''CREATE TABLE IF NOT EXISTS units (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL)''');
      } catch (_) {}
    }

    if (oldVersion < 12) {
      try {
        await db.execute(
            'ALTER TABLE machines ADD COLUMN bonus_per_stitch REAL DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE machines ADD COLUMN incentive_per_stitch REAL DEFAULT 0');
      } catch (_) {}
    }

    if (oldVersion < 13) {
      try {
        await db.execute('''CREATE TABLE IF NOT EXISTS machine_bonus_slabs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          machine_id INTEGER NOT NULL,
          from_stitch INTEGER NOT NULL,
          to_stitch INTEGER,
          bonus_amount REAL NOT NULL DEFAULT 0,
          incentive_amount REAL NOT NULL DEFAULT 0)''');
      } catch (_) {}
    }

    if (oldVersion < 14) {
      try {
        await db.execute(
            'ALTER TABLE machine_bonus_slabs ADD COLUMN incentive_amount REAL NOT NULL DEFAULT 0');
      } catch (_) {}
    }

    if (oldVersion < 15) {
      try {
        await db.execute(
            'ALTER TABLE machines ADD COLUMN incentive_after_stitch INTEGER DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE machines ADD COLUMN incentive_amount REAL DEFAULT 0');
      } catch (_) {}
    }

    if (oldVersion < 16) {
      try {
        await db
            .execute('ALTER TABLE machines ADD COLUMN bonus REAL DEFAULT 0');
      } catch (_) {}
    }

    if (oldVersion < 17) {
      try {
        await db.execute(
            'ALTER TABLE employees ADD COLUMN salary_base_days INTEGER DEFAULT 30');
      } catch (_) {}
      try {
        await db.execute('''CREATE TABLE IF NOT EXISTS employee_salary_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          employee_id INTEGER NOT NULL,
          base_pay REAL DEFAULT 0,
          salary_type TEXT DEFAULT 'monthly',
          salary_base_days INTEGER DEFAULT 30,
          effective_from INTEGER NOT NULL,
          created_at INTEGER)''');
      } catch (_) {}
    }

    if (oldVersion < 18) {
      try {
        await db.execute('''CREATE TABLE IF NOT EXISTS salary_advances (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          employee_id INTEGER NOT NULL,
          amount REAL NOT NULL DEFAULT 0,
          payment_mode TEXT DEFAULT 'cash',
          date INTEGER NOT NULL,
          for_month INTEGER,
          remarks TEXT,
          created_at INTEGER)''');
      } catch (_) {}
      try {
        await db.execute('''CREATE TABLE IF NOT EXISTS salary_payments (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          employee_id INTEGER NOT NULL,
          amount REAL NOT NULL DEFAULT 0,
          payment_mode TEXT DEFAULT 'cash',
          date INTEGER NOT NULL,
          from_date INTEGER,
          to_date INTEGER,
          remarks TEXT,
          created_at INTEGER)''');
      } catch (_) {}
    }

    if (oldVersion < 19) {
      try {
        await db.execute(
            "ALTER TABLE salary_advances ADD COLUMN payment_mode TEXT DEFAULT 'cash'");
      } catch (_) {}
    }

    if (oldVersion < 20) {
      try {
        await db.execute('''CREATE TABLE IF NOT EXISTS saved_payroll (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          employee_id INTEGER NOT NULL,
          from_date INTEGER NOT NULL,
          to_date INTEGER NOT NULL,
          base_pay REAL DEFAULT 0,
          salary_type TEXT DEFAULT 'monthly',
          salary_base_days INTEGER DEFAULT 30,
          present_days INTEGER DEFAULT 0,
          half_days INTEGER DEFAULT 0,
          absent_days INTEGER DEFAULT 0,
          double_days INTEGER DEFAULT 0,
          effective_days REAL DEFAULT 0,
          base_salary REAL DEFAULT 0,
          total_bonus REAL DEFAULT 0,
          total_incentive REAL DEFAULT 0,
          total_all_bonus REAL DEFAULT 0,
          total_advance REAL DEFAULT 0,
          net_salary REAL DEFAULT 0,
          created_at INTEGER)''');
      } catch (_) {}
    }

    if (oldVersion < 21) {
      // Fix: REQ-CLOSE entries were wrongly inserted as 'IN', should be 'OUT'
      try {
        await db.rawUpdate(
          "UPDATE stock_ledger SET type = 'OUT' WHERE reference LIKE 'REQ-CLOSE%' AND UPPER(type) = 'IN'",
        );
      } catch (_) {}
    }

    if (oldVersion < 22) {
      try {
        await db.execute('''CREATE TABLE IF NOT EXISTS order_master (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          order_no INTEGER,
          firm_id INTEGER,
          order_date INTEGER,
          party_id INTEGER,
          remarks TEXT,
          status TEXT DEFAULT 'open',
          total_qty REAL DEFAULT 0,
          closed_at INTEGER,
          created_at INTEGER)''');
      } catch (_) {}
      try {
        await db.execute('''CREATE TABLE IF NOT EXISTS order_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          order_no INTEGER,
          product_id INTEGER,
          shade_id INTEGER,
          qty REAL)''');
      } catch (_) {}
      try {
        await db
            .execute('ALTER TABLE purchase_master ADD COLUMN order_no INTEGER');
      } catch (_) {}
    }

    if (oldVersion < 23) {
      try {
        await db.execute('''CREATE TABLE IF NOT EXISTS program_cards (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          program_date INTEGER,
          company TEXT,
          party_id INTEGER,
          design_no TEXT,
          card_no TEXT,
          tp REAL DEFAULT 0,
          line_no TEXT,
          status TEXT,
          status_dhaga_cutting INTEGER,
          status_alter INTEGER,
          status_stiching INTEGER,
          status_cutting INTEGER,
          status_checking INTEGER,
          status_shoulder_cutting INTEGER,
          status_ready_dispatch INTEGER,
          remarks TEXT,
          created_at INTEGER)''');
      } catch (_) {}
    }

    if (oldVersion < 24) {
      try {
        await db.execute('''CREATE TABLE IF NOT EXISTS dispatch_bills (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          bill_date INTEGER,
          bill_no TEXT,
          party_id INTEGER,
          remarks TEXT,
          created_at INTEGER)''');
      } catch (_) {}
      try {
        await db.execute('''CREATE TABLE IF NOT EXISTS dispatch_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          bill_id INTEGER,
          program_card_id INTEGER,
          company TEXT,
          design_no TEXT,
          card_no TEXT,
          qty REAL DEFAULT 0,
          pcs REAL DEFAULT 0,
          created_at INTEGER)''');
      } catch (_) {}
    }

    if (oldVersion < 25) {
      try {
        await db
            .execute('ALTER TABLE program_cards ADD COLUMN product_id INTEGER');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE dispatch_items ADD COLUMN product_id INTEGER');
      } catch (_) {}
    }
  }

  /// One-time startup cleanup for legacy rows where order-linked purchases were
  /// deleted but their stock_ledger IN rows remained.
  Future<void> _cleanupOrphanOrderPurchaseLedgerEntries(
    Database db, {
    int limit = 500,
  }) async {
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      var fixed = 0;
      var lastId = 0;
      while (true) {
        final candidates = await db.rawQuery(
          '''
          SELECT id,
                 product_id,
                 COALESCE(fabric_shade_id, 0) AS shade_id,
                 COALESCE(qty, 0) AS qty,
                 remarks,
                 order_no
          FROM stock_ledger
          WHERE UPPER(type) = 'IN'
            AND id > ?
            AND (
              (order_no IS NOT NULL AND order_no > 0)
              OR remarks LIKE 'Purchase against Order #%'
            )
            AND (is_deleted IS NULL OR is_deleted = 0)
          ORDER BY id
          LIMIT ?
          ''',
          [lastId, limit],
        );
        if (candidates.isEmpty) break;

        for (final row in candidates) {
          final id = row['id'] as int?;
          final productId = row['product_id'] as int?;
          final shadeId = (row['shade_id'] as num?)?.toInt() ?? 0;
          final qty = (row['qty'] as num?)?.toDouble() ?? 0;
          final remarks = (row['remarks'] ?? '').toString();
          final explicitOrderNo = (row['order_no'] as num?)?.toInt();

          if (id == null) continue;
          if (id > lastId) lastId = id;
          if (productId == null || qty <= 0) continue;

          final match = RegExp(r'Order\s*#\s*(\d+)', caseSensitive: false)
              .firstMatch(remarks);
          final orderNo = explicitOrderNo ??
              (match == null ? null : int.tryParse(match.group(1) ?? ''));
          if (orderNo == null) continue;

          final linked = await db.rawQuery(
            '''
            SELECT 1
            FROM purchase_master pm
            JOIN purchase_items pi ON pi.purchase_no = pm.purchase_no
            WHERE pm.order_no = ?
              AND pi.product_id = ?
              AND COALESCE(pi.shade_id, 0) = ?
              AND ABS(COALESCE(pi.qty, 0) - ?) < 0.0001
            LIMIT 1
            ''',
            [orderNo, productId, shadeId, qty],
          );
          if (linked.isNotEmpty) continue;

          await db.update(
            'stock_ledger',
            {'is_deleted': 1},
            where: 'id = ?',
            whereArgs: [id],
          );

          // Queue remote delete so legacy rows are removed from Firebase too.
          try {
            await db.delete(
              '_pending_sync',
              where: 'table_name=? AND record_id=? AND action=?',
              whereArgs: ['stock_ledger', id, 'delete'],
            );
            await db.insert('_pending_sync', {
              'table_name': 'stock_ledger',
              'record_id': id,
              'action': 'delete',
              'data': '',
              'created_at': nowMs,
            });
          } catch (_) {}

          fixed++;
        }
      }

      if (fixed > 0) {
        debugPrint('Fixed $fixed orphan order-purchase stock rows');
      }
    } catch (e) {
      debugPrint('cleanup orphan order ledger failed: $e');
    }
  }

  // ================= SYNC HELPERS =================
  /// Set to false to disable Firebase sync (e.g. for adding sample data)
  bool syncEnabled = false;

  // ================= ACTIVITY LOG =================
  Future<void> logActivity({
    required String action,
    String? tableName,
    int? recordId,
    String? details,
  }) async {
    try {
      final userName = PermissionService.instance.currentName;
      await _syncInsert('activity_log', {
        'action': action,
        'table_name': tableName,
        'record_id': recordId,
        'details': details,
        'user_name': userName,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('âš  logActivity: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getActivityLogs({
    int limit = 200,
    int offset = 0,
    String? action,
    String? tableName,
    String? userName,
    int? fromMs,
    int? toMs,
    String? search,
  }) async {
    try {
      final db = await database;
      final where = <String>[];
      final args = <dynamic>[];
      if (action != null && action.isNotEmpty) {
        where.add('action = ?');
        args.add(action);
      }
      if (tableName != null && tableName.isNotEmpty) {
        where.add('table_name = ?');
        args.add(tableName);
      }
      if (userName != null && userName.isNotEmpty) {
        where.add('user_name = ?');
        args.add(userName);
      }
      if (fromMs != null) {
        where.add('timestamp >= ?');
        args.add(fromMs);
      }
      if (toMs != null) {
        where.add('timestamp < ?');
        args.add(toMs);
      }
      if (search != null && search.isNotEmpty) {
        where.add('(details LIKE ? OR table_name LIKE ? OR action LIKE ?)');
        final pattern = '%$search%';
        args.addAll([pattern, pattern, pattern]);
      }
      final whereClause = where.isEmpty ? null : where.join(' AND ');
      return await db.query(
        'activity_log',
        where: whereClause,
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'timestamp DESC',
        limit: limit,
        offset: offset,
      );
    } catch (e) {
      debugPrint('âš  getActivityLogs: $e');
      return [];
    }
  }

  /// Get distinct user names from activity log (for filter dropdown)
  Future<List<String>> getActivityLogUsers() async {
    try {
      final db = await database;
      final rows = await db.rawQuery(
        "SELECT DISTINCT user_name FROM activity_log WHERE user_name IS NOT NULL AND user_name != '' ORDER BY user_name",
      );
      return rows.map((r) => r['user_name'].toString()).toList();
    } catch (_) {
      return [];
    }
  }

  /// Get distinct table names from activity log (for filter dropdown)
  Future<List<String>> getActivityLogTables() async {
    try {
      final db = await database;
      final rows = await db.rawQuery(
        "SELECT DISTINCT table_name FROM activity_log WHERE table_name IS NOT NULL AND table_name != '' ORDER BY table_name",
      );
      return rows.map((r) => r['table_name'].toString()).toList();
    } catch (_) {
      return [];
    }
  }

  bool _isDatabaseLockedError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('database is locked') ||
        msg.contains('sqlite_error: 5') ||
        msg.contains('(code 5)');
  }

  Future<T> _withDbLockRetry<T>(
    Future<T> Function() operation, {
    String opName = 'db op',
    int maxAttempts = 4,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await operation();
      } catch (e) {
        lastError = e;
        if (!_isDatabaseLockedError(e) || attempt >= maxAttempts) rethrow;
        final waitMs = 80 * attempt * attempt;
        debugPrint(
            'SQLite locked during $opName (attempt $attempt/$maxAttempts). Retrying in ${waitMs}ms...');
        await Future.delayed(Duration(milliseconds: waitMs));
      }
    }
    throw lastError ?? Exception('Unknown database operation failure');
  }

  Future<int> _syncInsert(String table, Map<String, dynamic> data) async {
    final db = await database;
    final sync = FirebaseSyncService.instance;
    int id;
    if (syncEnabled && sync.isInitialized) {
      int? firebaseId;
      try {
        firebaseId = await sync.getNextId(table);
      } catch (e) {
        debugPrint('âš  _syncInsert getNextId ($table): $e');
        // No network â€” fall through to local-only insert
      }
      if (firebaseId != null) {
        id = firebaseId;
        data['id'] = id;
        try {
          await _withDbLockRetry(
            () => db.insert(
              table,
              data,
              conflictAlgorithm: ConflictAlgorithm.replace,
            ),
            opName: 'insert $table/$id',
          );
        } catch (e) {
          debugPrint('âš  _syncInsert local insert ($table/$id): $e');
          // Local failed but we have a Firebase ID â€” still push to Firebase
          // so the data is at least saved remotely
          await sync.pushRecord(table, id, data);
          rethrow;
        }
        // pushRecord queues for retry internally if it fails
        await sync.pushRecord(table, id, data);
        _markDataChanged();
        if (table != 'activity_log' && _shouldWriteActivityLog) {
          logActivity(
              action: 'INSERT',
              tableName: table,
              recordId: id,
              details: _buildRowDetails(table, data));
        }
        return id;
      }
    }
    data.remove('id');
    id = await _withDbLockRetry(
      () => db.insert(table, data),
      opName: 'insert $table',
    );
    if (syncEnabled) {
      data['id'] = id;
      await sync.queuePush(table, id, data);
    }
    _markDataChanged();
    if (table != 'activity_log' && _shouldWriteActivityLog) {
      logActivity(
          action: 'INSERT',
          tableName: table,
          recordId: id,
          details: _buildRowDetails(table, data));
    }
    return id;
  }

  Future<void> _syncUpdate(
      String table, Map<String, dynamic> data, int id) async {
    final db = await database;
    // Local FIRST, then push the merged full row to Firebase.
    // Pushing only partial update payload can overwrite remote fields with null.
    final updatedData = Map<String, dynamic>.from(data)..['id'] = id;
    await _withDbLockRetry(
      () => db.update(table, updatedData, where: 'id=?', whereArgs: [id]),
      opName: 'update $table/$id',
    );

    final rows = await _withDbLockRetry(
      () => db.query(
        table,
        where: 'id=?',
        whereArgs: [id],
        limit: 1,
      ),
      opName: 'query $table/$id',
    );
    final payload = rows.isNotEmpty
        ? Map<String, dynamic>.from(rows.first)
        : Map<String, dynamic>.from(updatedData);

    _markDataChanged();
    final sync = FirebaseSyncService.instance;
    if (syncEnabled) {
      if (sync.isInitialized) {
        await sync.pushRecord(table, id, payload);
      } else {
        await sync.queuePush(table, id, payload);
      }
    }
    if (table != 'activity_log' && _shouldWriteActivityLog) {
      logActivity(
          action: 'UPDATE',
          tableName: table,
          recordId: id,
          details: _buildRowDetails(table, payload));
    }
  }

  Future<void> _syncDelete(String table, int id) async {
    final db = await database;
    final sync = FirebaseSyncService.instance;

    // Capture row details BEFORE deleting so the activity log is meaningful
    String? deleteDetails;
    if (table != 'activity_log') {
      try {
        final rows = await _withDbLockRetry(
          () => db.query(table, where: 'id=?', whereArgs: [id]),
          opName: 'query-before-delete $table/$id',
        );
        if (rows.isNotEmpty) {
          deleteDetails = _buildRowDetails(table, rows.first);
        }
      } catch (_) {}
    }

    if (syncEnabled) {
      // Mark as pending delete so real-time listeners
      // won't re-insert the record. Cleared by _onRemoteRemove.
      await sync.addPendingDelete(table, id);
    }
    // Delete locally FIRST (ensures data is removed even if Firebase call fails)
    if (table == 'stock_ledger') {
      await _withDbLockRetry(
        () => db.update('stock_ledger', {'is_deleted': 1},
            where: 'id=?', whereArgs: [id]),
        opName: 'soft-delete stock_ledger/$id',
      );
    } else {
      await _withDbLockRetry(
        () => db.delete(table, where: 'id=?', whereArgs: [id]),
        opName: 'delete $table/$id',
      );
    }
    _markDataChanged();
    // Then remove from Firebase
    if (syncEnabled && sync.isInitialized) {
      try {
        await sync.deleteRecord(table, id);
      } catch (e) {
        debugPrint('[WARN] _syncDelete Firebase failed ($table/$id): $e');
      }
    }
    if (table != 'activity_log' && _shouldWriteActivityLog) {
      logActivity(
          action: 'DELETE',
          tableName: table,
          recordId: id,
          details: deleteDetails);
    }
  }

  /// Build a human-readable summary of a row for activity log
  String _buildRowDetails(String table, Map<String, dynamic> row) {
    switch (table) {
      case 'stock_ledger':
        final type = row['type'] ?? '';
        final qty = row['qty'] ?? '';
        final pId = row['product_id'];
        final sId = row['fabric_shade_id'];
        final remarks = row['remarks'] ?? '';
        return 'Type: $type, Qty: $qty, Product ID: $pId, Shade ID: $sId${remarks.toString().isNotEmpty ? ', Remarks: $remarks' : ''}';
      case 'products':
        return 'Product: ${row['name'] ?? row['product_name'] ?? ''}';
      case 'parties':
        return 'Party: ${row['name'] ?? ''}';
      case 'fabric_shades':
        return 'Shade: ${row['shade_name'] ?? row['name'] ?? ''}, Code: ${row['shade_code'] ?? ''}';
      case 'employees':
        return 'Employee: ${row['name'] ?? ''}';
      case 'machines':
        return 'Machine: ${row['name'] ?? row['machine_name'] ?? ''}';
      case 'production_entries':
        return 'Production: Program ${row['program_no'] ?? ''}, Qty: ${row['quantity'] ?? ''}, Machine: ${row['machine_id'] ?? ''}';
      case 'attendance':
        String dateStr = '';
        final dateRaw = row['date'];
        if (dateRaw is num) {
          try {
            final d = DateTime.fromMillisecondsSinceEpoch(dateRaw.toInt());
            dateStr =
                '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
          } catch (_) {}
        }
        final shift = (row['shift'] ?? '').toString();
        return 'Attendance: Employee ID ${row['employee_id'] ?? ''}, '
            'Date: ${dateStr.isNotEmpty ? dateStr : '-'}, '
            'Status: ${row['status'] ?? ''}'
            '${shift.isNotEmpty ? ', Shift: $shift' : ''}';
      case 'challan_requirements':
        return 'Challan Req: Challan ${row['challan_no'] ?? ''}, Product ID: ${row['product_id'] ?? ''}, Qty: ${row['required_qty'] ?? ''}';
      case 'purchase_items':
        final amt = row['amount'];
        return 'Purchase Item: Purchase #${row['purchase_no'] ?? ''}, '
            'Product ID ${row['product_id'] ?? ''}'
            '${row['shade_id'] != null ? ', Shade ID ${row['shade_id']}' : ''}'
            ', Qty: ${row['qty'] ?? 0}, Rate: ${row['rate'] ?? 0}'
            '${amt != null ? ', Amount: $amt' : ''}';
      case 'purchase_master':
        String pDate = '';
        final pd = row['purchase_date'];
        if (pd is num) {
          try {
            final d = DateTime.fromMillisecondsSinceEpoch(pd.toInt());
            pDate =
                '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
          } catch (_) {}
        }
        return 'Purchase: No ${row['purchase_no'] ?? ''}'
            '${(row['invoice_no'] ?? '').toString().isNotEmpty ? ', Invoice: ${row['invoice_no']}' : ''}'
            '${pDate.isNotEmpty ? ', Date: $pDate' : ''}'
            ', Party ID: ${row['party_id'] ?? ''}'
            '${row['firm_id'] != null ? ', Firm ID: ${row['firm_id']}' : ''}'
            '${row['order_no'] != null ? ', Order #${row['order_no']}' : ''}'
            '${row['total_amount'] != null ? ', Total: ${row['total_amount']}' : ''}';
      case 'order_master':
        String oDate = '';
        final od = row['order_date'];
        if (od is num) {
          try {
            final d = DateTime.fromMillisecondsSinceEpoch(od.toInt());
            oDate =
                '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
          } catch (_) {}
        }
        return 'Order: No ${row['order_no'] ?? ''}'
            '${oDate.isNotEmpty ? ', Date: $oDate' : ''}'
            ', Party ID: ${row['party_id'] ?? ''}'
            '${row['firm_id'] != null ? ', Firm ID: ${row['firm_id']}' : ''}'
            ', Status: ${row['status'] ?? ''}'
            '${row['total_qty'] != null ? ', Total Qty: ${row['total_qty']}' : ''}'
            '${(row['remarks'] ?? '').toString().isNotEmpty ? ', Remarks: ${row['remarks']}' : ''}';
      case 'order_items':
        return 'Order Item: Order #${row['order_no'] ?? ''}, '
            'Product ID ${row['product_id'] ?? ''}'
            '${row['shade_id'] != null ? ', Shade ID ${row['shade_id']}' : ''}'
            ', Qty: ${row['qty'] ?? 0}';
      case 'salary_advances':
        return 'Advance: Employee ID ${row['employee_id'] ?? ''}, Amount: ${row['amount'] ?? ''}';
      case 'program_master':
        return 'Program: No ${row['program_no'] ?? ''}, Party ID: ${row['party_id'] ?? ''}, Status: ${row['status'] ?? ''}';
      case 'units':
        return 'Unit: ${row['name'] ?? ''}';
      default:
        // Generic: show key fields
        final buf = StringBuffer();
        for (final key in row.keys) {
          if (key == 'id') continue;
          final v = row[key];
          if (v != null && v.toString().isNotEmpty) {
            if (buf.isNotEmpty) buf.write(', ');
            buf.write('$key: $v');
            if (buf.length > 200) break;
          }
        }
        return buf.toString();
    }
  }

  // ================= PRODUCTS =================
  Future<List<Product>> getProducts() async {
    final rows = await (await database).query('products', orderBy: 'name');
    final byId = <int, Product>{};
    final withoutId = <Product>[];
    for (final row in rows) {
      final product = Product.fromMap(row);
      final id = product.id;
      if (id == null) {
        withoutId.add(product);
      } else {
        byId[id] = product;
      }
    }
    return [...byId.values, ...withoutId];
  }

  Future<void> insertProduct(Product p) async {
    final data = p.toMap();
    await _syncInsert('products', data);
  }

  Future<void> updateProduct(Product p) async {
    final data = p.toMap();
    data.remove('id');
    await _syncUpdate('products', data, p.id!);
  }

  Future<void> deleteProduct(int id) async => _syncDelete('products', id);

  // ================= PARTIES =================
  Future<List<Party>> getParties() async {
    final rows = await (await database).query('parties', orderBy: 'name');
    final byId = <int, Party>{};
    final withoutId = <Party>[];
    for (final row in rows) {
      final party = Party.fromMap(row);
      final id = party.id;
      if (id == null) {
        withoutId.add(party);
      } else {
        byId[id] = party;
      }
    }
    return [...byId.values, ...withoutId];
  }

  // ================= FIRMS =================
  Future<List<Map<String, dynamic>>> getFirms() async =>
      (await database).query('firms');

  Future<void> insertFirmRaw(Map<String, dynamic> data) async =>
      _syncInsert('firms', data);

  // ================= PROGRAM CARDS =================
  /// Returns program cards ordered by date desc.
  /// [company] filter by company code (SLH/MS/SI/MS-SI). Pass null for all.
  /// [status] filter by current status. Pass null for all.
  Future<List<Map<String, dynamic>>> getProgramCards({
    String? company,
    String? status,
    String? search,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];
    if (company != null && company.isNotEmpty) {
      where.add('company = ?');
      args.add(company);
    }
    if (status != null && status.isNotEmpty) {
      final normalized = status.trim().toLowerCase();
      if (normalized == 'dispatched' || normalized == 'completed') {
        // Legacy compatibility: treat old "Completed" as closed/dispatched too.
        where.add("LOWER(TRIM(COALESCE(status, ''))) IN (?, ?)");
        args.addAll(['dispatched', 'completed']);
      } else {
        where.add('status = ?');
        args.add(status);
      }
    }
    if (search != null && search.isNotEmpty) {
      where.add('(card_no LIKE ? OR design_no LIKE ? OR line_no LIKE ?)');
      final s = '%$search%';
      args.addAll([s, s, s]);
    }
    return db.query(
      'program_cards',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'program_date DESC, id DESC',
    );
  }

  /// Program cards selectable in Dispatch:
  /// - must have reached Ready-to-Dispatch step
  /// - must NOT be closed (Dispatched/Completed), even with case/space variants
  Future<List<Map<String, dynamic>>> getDispatchSelectableProgramCards({
    String? company,
    String? search,
  }) async {
    final db = await database;
    final where = <String>[
      'status_ready_dispatch IS NOT NULL',
      "LOWER(TRIM(COALESCE(status, ''))) NOT IN (?, ?)",
    ];
    final args = <Object?>['dispatched', 'completed'];

    if (company != null && company.isNotEmpty) {
      where.add('company = ?');
      args.add(company);
    }
    if (search != null && search.isNotEmpty) {
      where.add('(card_no LIKE ? OR design_no LIKE ? OR line_no LIKE ?)');
      final s = '%$search%';
      args.addAll([s, s, s]);
    }

    return db.query(
      'program_cards',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'program_date DESC, id DESC',
    );
  }

  Future<int> insertProgramCard(Map<String, dynamic> data) async {
    data['created_at'] ??= DateTime.now().millisecondsSinceEpoch;
    return _syncInsert('program_cards', data);
  }

  Future<void> updateProgramCard(int id, Map<String, dynamic> data) async {
    await _syncUpdate('program_cards', data, id);
  }

  Future<void> deleteProgramCard(int id) async =>
      _syncDelete('program_cards', id);

  Future<Map<String, dynamic>?> getProgramCardById(int id) async {
    final db = await database;
    final r = await db.query('program_cards',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : r.first;
  }

  /// Sum of (qty * pcs) already dispatched for a program card,
  /// optionally excluding a particular bill (the one currently being edited).
  Future<double> getDispatchedQtyForCard(int programCardId,
      {int? excludeBillId}) async {
    final db = await database;
    final where = <String>['program_card_id = ?'];
    final args = <Object?>[programCardId];
    if (excludeBillId != null) {
      where.add('bill_id != ?');
      args.add(excludeBillId);
    }
    final rows = await db.query(
      'dispatch_items',
      columns: ['qty', 'pcs'],
      where: where.join(' AND '),
      whereArgs: args,
    );
    double total = 0;
    for (final r in rows) {
      final q = (r['qty'] as num?)?.toDouble() ?? 0;
      final p = (r['pcs'] as num?)?.toDouble() ?? 0;
      total += q * p;
    }
    return total;
  }

  // ================= DISPATCH GOODS =================
  /// Repairs program cards that were closed (status='Dispatched' or legacy
  /// status='Completed') but no longer have a valid dispatch bill link.
  /// This covers both:
  /// - no dispatch_items for the card
  /// - dispatch_items exist, but their dispatch_bills header is missing
  /// Optionally restricts to cards whose `status_ready_dispatch` timestamp is
  /// inside [fromReadyDispatchMs, toReadyDispatchMs).
  /// Returns number of reopened cards.
  Future<int> _reopenOrphanCompletedProgramCards(
    Database db, {
    int? fromReadyDispatchMs,
    int? toReadyDispatchMs,
  }) async {
    try {
      // Tables may not exist yet on a brand-new install — guard with PRAGMA.
      final t1 = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='program_cards'");
      final t2 = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='dispatch_items'");
      final t3 = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='dispatch_bills'");
      if (t1.isEmpty || t2.isEmpty || t3.isEmpty) return 0;

      final where = StringBuffer(
          "LOWER(TRIM(COALESCE(pc.status, ''))) IN ('dispatched', 'completed')");
      final args = <Object?>[];
      if (fromReadyDispatchMs != null) {
        where.write(' AND COALESCE(pc.status_ready_dispatch, 0) >= ?');
        args.add(fromReadyDispatchMs);
      }
      if (toReadyDispatchMs != null) {
        where.write(' AND COALESCE(pc.status_ready_dispatch, 0) < ?');
        args.add(toReadyDispatchMs);
      }

      final orphans = await db.rawQuery('''
        SELECT pc.id FROM program_cards pc
        WHERE ${where.toString()}
          AND NOT EXISTS (
            SELECT 1
            FROM dispatch_items di
            INNER JOIN dispatch_bills db ON db.id = di.bill_id
            WHERE di.program_card_id = pc.id
          )
      ''', args);
      for (final row in orphans) {
        final id = row['id'] as int?;
        if (id == null) continue;
        await db.update(
          'program_cards',
          {'status': 'Ready to Dispatch'},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      if (orphans.isNotEmpty) {
        debugPrint('Reopened ${orphans.length} orphan closed program card(s).');
      }
      return orphans.length;
    } catch (e) {
      debugPrint('⚠ _reopenOrphanCompletedProgramCards: $e');
      return 0;
    }
  }

  /// Public entrypoint to run dispatch card unlock recovery on-demand.
  Future<int> reopenOrphanClosedDispatchCardsNow() async {
    final db = await database;
    final reopened = await _reopenOrphanCompletedProgramCards(db);
    if (reopened > 0) _markDataChanged();
    return reopened;
  }

  /// Reopens orphan closed dispatch cards only for one local calendar day,
  /// based on `status_ready_dispatch` timestamp.
  Future<int> reopenOrphanClosedDispatchCardsForDayNow(DateTime day) async {
    final db = await database;
    final from = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final to =
        DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch;
    final reopened = await _reopenOrphanCompletedProgramCards(
      db,
      fromReadyDispatchMs: from,
      toReadyDispatchMs: to,
    );
    if (reopened > 0) _markDataChanged();
    return reopened;
  }

  Map<String, String> _parseActivityDetails(String details) {
    final out = <String, String>{};
    for (final rawPart in details.split(',')) {
      final part = rawPart.trim();
      if (part.isEmpty) continue;
      final idx = part.indexOf(':');
      if (idx <= 0 || idx >= part.length - 1) continue;
      final key = part.substring(0, idx).trim();
      final value = part.substring(idx + 1).trim();
      if (key.isEmpty) continue;
      out[key] = value;
    }
    return out;
  }

  /// Best-effort recovery:
  /// Older buggy builds could save a dispatch bill then delete its header.
  /// Recover recently deleted bill headers from activity_log so users can
  /// still see and reopen those bills.
  Future<int> _restoreRecentlyDeletedDispatchBills(Database db) async {
    try {
      final cutoff =
          DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
      final rows = await db.query(
        'activity_log',
        columns: ['record_id', 'details', 'timestamp'],
        where: 'table_name = ? AND action = ? AND timestamp >= ?',
        whereArgs: ['dispatch_bills', 'DELETE', cutoff],
        orderBy: 'id DESC',
        limit: 200,
      );
      if (rows.isEmpty) return 0;

      var restored = 0;
      for (final row in rows) {
        final billId = (row['record_id'] as num?)?.toInt();
        if (billId == null || billId <= 0) continue;

        final existing = await db.query(
          'dispatch_bills',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [billId],
          limit: 1,
        );
        if (existing.isNotEmpty) continue;

        final details = (row['details'] ?? '').toString().trim();
        if (details.isEmpty || !details.contains('bill_no:')) continue;

        final parsed = _parseActivityDetails(details);
        final billNo = (parsed['bill_no'] ?? '').trim();
        final billDate = int.tryParse((parsed['bill_date'] ?? '').trim()) ?? 0;
        final partyId = int.tryParse((parsed['party_id'] ?? '').trim());
        final createdAt =
            int.tryParse((parsed['created_at'] ?? '').trim()) ??
                ((row['timestamp'] as num?)?.toInt() ??
                    DateTime.now().millisecondsSinceEpoch);

        if (billNo.isEmpty || billDate <= 0) continue;

        await db.insert(
          'dispatch_bills',
          {
            'id': billId,
            'bill_date': billDate,
            'bill_no': billNo,
            'party_id': partyId,
            'remarks': '',
            'created_at': createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        restored++;
      }

      if (restored > 0) {
        debugPrint('Restored $restored recently deleted dispatch bill(s).');
      }
      return restored;
    } catch (e) {
      debugPrint('restoreRecentlyDeletedDispatchBills: $e');
      return 0;
    }
  }

  /// Public entrypoint to run dispatch bill header recovery on-demand.
  Future<int> restoreRecentlyDeletedDispatchBillsNow() async {
    final db = await database;
    return _restoreRecentlyDeletedDispatchBills(db);
  }

  Future<List<Map<String, dynamic>>> getDispatchBills({
    int? fromMs,
    int? toMs,
    String? search,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];
    if (fromMs != null) {
      where.add('bill_date >= ?');
      args.add(fromMs);
    }
    if (toMs != null) {
      where.add('bill_date <= ?');
      args.add(toMs);
    }
    if (search != null && search.isNotEmpty) {
      where.add('bill_no LIKE ?');
      args.add('%$search%');
    }
    return db.query(
      'dispatch_bills',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'bill_date DESC, id DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getDispatchItems(int billId) async {
    final db = await database;
    return db.query('dispatch_items',
        where: 'bill_id = ?', whereArgs: [billId], orderBy: 'id ASC');
  }

  /// Flattened dispatch report rows from items + bill header + program card.
  /// Uses LEFT JOIN so rows still appear even if bill/card header is missing.
  Future<List<Map<String, dynamic>>> getDispatchReportRows() async {
    final db = await database;
    return db.rawQuery('''
      SELECT *
      FROM (
        SELECT
          di.id AS item_id,
          di.bill_id AS bill_id,
          COALESCE(db.bill_no, '') AS bill_no,
          db.bill_date AS bill_date,
          db.party_id AS party_id,
          COALESCE(di.company, '') AS company,
          di.product_id AS product_id,
          COALESCE(di.design_no, '') AS design_no,
          COALESCE(di.card_no, '') AS card_no,
          COALESCE(di.qty, 0) AS qty,
          COALESCE(di.pcs, 0) AS pcs,
          COALESCE(pc.tp, 0) AS tp,
          COALESCE(pc.line_no, '') AS line_no
        FROM dispatch_items di
        LEFT JOIN dispatch_bills db ON db.id = di.bill_id
        LEFT JOIN program_cards pc ON pc.id = di.program_card_id
        UNION ALL
        SELECT
          NULL AS item_id,
          db.id AS bill_id,
          COALESCE(db.bill_no, '') AS bill_no,
          db.bill_date AS bill_date,
          db.party_id AS party_id,
          '' AS company,
          NULL AS product_id,
          '' AS design_no,
          '' AS card_no,
          0 AS qty,
          0 AS pcs,
          0 AS tp,
          '' AS line_no
        FROM dispatch_bills db
        WHERE NOT EXISTS (
          SELECT 1
          FROM dispatch_items di2
          WHERE di2.bill_id = db.id
        )
      ) t
      ORDER BY COALESCE(t.bill_date, 0) DESC, COALESCE(t.item_id, 0) DESC
    ''');
  }

  /// Deletes orphan dispatch bills that have no dispatch_items rows.
  /// Returns number of removed bill headers.
  Future<int> cleanupEmptyDispatchBills() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT b.id
      FROM dispatch_bills b
      LEFT JOIN dispatch_items i ON i.bill_id = b.id
      GROUP BY b.id
      HAVING COUNT(i.id) = 0
    ''');

    var removed = 0;
    for (final row in rows) {
      final id = (row['id'] as num?)?.toInt();
      if (id == null) continue;
      await _syncDelete('dispatch_bills', id);
      removed++;
    }
    return removed;
  }

  /// Atomically saves a dispatch bill graph:
  /// - upserts bill
  /// - deletes removed dispatch_items
  /// - upserts current dispatch_items
  /// - closes selected program cards (status='Dispatched')
  /// - reopens orphan completed cards previously linked to this bill
  ///
  /// Returns final bill id.
  Future<int> saveDispatchBillAtomic({
    int? existingBillId,
    required Map<String, dynamic> billData,
    required List<Map<String, dynamic>> itemRows,
    List<int> removedItemIds = const [],
    Set<int> closeProgramCardIds = const <int>{},
  }) async {
    final db = await database;
    final sync = FirebaseSyncService.instance;

    int? asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v');

    final rows = itemRows.map((e) => Map<String, dynamic>.from(e)).toList();
    final removedIds = removedItemIds.toSet().toList();
    final closeIds = closeProgramCardIds.where((e) => e > 0).toSet();

    // Candidate cards for possible reopen if this edit removes their final
    // dispatch references.
    final reopenCandidates = <int>{};
    if (existingBillId != null) {
      final old = await db.query(
        'dispatch_items',
        columns: ['program_card_id'],
        where: 'bill_id = ?',
        whereArgs: [existingBillId],
      );
      for (final it in old) {
        final pcId = asInt(it['program_card_id']);
        if (pcId != null) reopenCandidates.add(pcId);
      }
    }

    // When sync is initialized, reserve remote IDs up-front so multi-device
    // inserts remain collision-safe.
    int? reservedBillId = existingBillId;
    if (syncEnabled && sync.isInitialized && existingBillId == null) {
      try {
        reservedBillId = await sync.getNextId('dispatch_bills');
      } catch (_) {
        // fall back to local AUTOINCREMENT
      }
    }
    if (syncEnabled && sync.isInitialized) {
      for (final row in rows) {
        if (row['id'] != null) continue;
        try {
          row['id'] = await sync.getNextId('dispatch_items');
        } catch (_) {
          // fall back to local AUTOINCREMENT
        }
      }
    }

    final touchedItemIds = <int>{};
    final deletedItemIds = <int>{};
    final touchedProgramCardIds = <int>{};
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    late final int billId;

    await sync.beginLocalDbWrite();
    try {
      await db.transaction((txn) async {
        final billPayload = Map<String, dynamic>.from(billData);
        billPayload['created_at'] ??= nowMs;

        if (existingBillId == null) {
          if (reservedBillId != null) billPayload['id'] = reservedBillId;
          final inserted = await txn.insert(
            'dispatch_bills',
            billPayload,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          billId = reservedBillId ?? inserted;
        } else {
          billId = existingBillId;
          billPayload['id'] = billId;
          await txn.update(
            'dispatch_bills',
            billPayload,
            where: 'id = ?',
            whereArgs: [billId],
          );
        }

        for (final id in removedIds) {
          await txn.delete('dispatch_items', where: 'id = ?', whereArgs: [id]);
          deletedItemIds.add(id);
        }

        for (final raw in rows) {
          final payload = Map<String, dynamic>.from(raw);
          payload['bill_id'] = billId;
          payload['created_at'] ??= nowMs;
          final id = asInt(payload['id']);
          if (id == null) {
            final inserted = await txn.insert(
              'dispatch_items',
              payload,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            touchedItemIds.add(asInt(payload['id']) ?? inserted);
          } else {
            payload['id'] = id;
            final updated = await txn.update(
              'dispatch_items',
              payload,
              where: 'id = ?',
              whereArgs: [id],
            );
            if (updated == 0) {
              // New row with a pre-reserved id: update won't find a record,
              // so insert explicitly.
              await txn.insert(
                'dispatch_items',
                payload,
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            }
            touchedItemIds.add(id);
          }
        }

        for (final pcId in closeIds) {
          await txn.update(
            'program_cards',
            {'status': 'Dispatched'},
            where: 'id = ?',
            whereArgs: [pcId],
          );
          touchedProgramCardIds.add(pcId);
        }

        // If a previously linked closed card has no remaining dispatch rows,
        // reopen it so it becomes selectable again.
        for (final pcId in reopenCandidates) {
          if (closeIds.contains(pcId)) continue;
          final remaining = await txn.query(
            'dispatch_items',
            columns: ['id'],
            where: 'program_card_id = ?',
            whereArgs: [pcId],
            limit: 1,
          );
          if (remaining.isNotEmpty) continue;

          final card = await txn.query(
            'program_cards',
            columns: ['status'],
            where: 'id = ?',
            whereArgs: [pcId],
            limit: 1,
          );
          if (card.isEmpty) continue;
          final status = (card.first['status'] ?? '').toString();
          final statusNorm = status.trim().toLowerCase();
          if (statusNorm == 'dispatched' || statusNorm == 'completed') {
            await txn.update(
              'program_cards',
              {'status': 'Ready to Dispatch'},
              where: 'id = ?',
              whereArgs: [pcId],
            );
            touchedProgramCardIds.add(pcId);
          }
        }
      });
    } finally {
      await sync.endLocalDbWrite();
    }

    // Hard safety check: a dispatch bill save with itemRows must leave at
    // least one dispatch_items row for that bill.
    if (rows.isNotEmpty) {
      final persisted = await db.rawQuery(
        'SELECT COUNT(*) AS cnt FROM dispatch_items WHERE bill_id = ?',
        [billId],
      );
      final persistedCount = ((persisted.first['cnt'] as num?) ?? 0).toInt();
      if (persistedCount <= 0) {
        throw Exception(
          'Dispatch save integrity check failed: no rows persisted for bill $billId',
        );
      }
    }

    _markDataChanged();

    Future<void> pushOrQueue(String table, int id) async {
      if (!syncEnabled) return;
      final r =
          await db.query(table, where: 'id = ?', whereArgs: [id], limit: 1);
      if (r.isEmpty) return;
      final payload = Map<String, dynamic>.from(r.first);
      if (sync.isInitialized) {
        await sync.pushRecord(table, id, payload);
      } else {
        await sync.queuePush(table, id, payload);
      }
    }

    await pushOrQueue('dispatch_bills', billId);
    for (final id in touchedItemIds) {
      await pushOrQueue('dispatch_items', id);
    }
    for (final id in touchedProgramCardIds) {
      await pushOrQueue('program_cards', id);
    }

    if (syncEnabled) {
      for (final id in deletedItemIds) {
        await sync.addPendingDelete('dispatch_items', id);
        if (sync.isInitialized) {
          try {
            await sync.deleteRecord('dispatch_items', id);
          } catch (_) {
            // keep pending for later retry
          }
        }
      }
    }

    if (_shouldWriteActivityLog) {
      await logActivity(
        action: existingBillId == null ? 'INSERT' : 'UPDATE',
        tableName: 'dispatch_bills',
        recordId: billId,
        details:
            'Dispatch bill saved. Items: ${rows.length}, Removed: ${deletedItemIds.length}, Closed cards: ${closeIds.length}',
      );
    }

    return billId;
  }

  Future<int> insertDispatchBill(Map<String, dynamic> data) async {
    data['created_at'] ??= DateTime.now().millisecondsSinceEpoch;
    return _syncInsert('dispatch_bills', data);
  }

  Future<void> updateDispatchBill(int id, Map<String, dynamic> data) async {
    await _syncUpdate('dispatch_bills', data, id);
  }

  Future<void> deleteDispatchBill(int id) async {
    final db = await database;
    final items =
        await db.query('dispatch_items', where: 'bill_id = ?', whereArgs: [id]);

    // Collect all program_card ids referenced in this bill so we can
    // re-open any that were closed (Dispatched/Completed) when this bill was
    // saved.
    final pcIds = <int>{
      for (final it in items)
        if (it['program_card_id'] != null) it['program_card_id'] as int,
    };

    for (final it in items) {
      final iid = it['id'] as int?;
      if (iid != null) await _syncDelete('dispatch_items', iid);
    }
    await _syncDelete('dispatch_bills', id);

    // For each card, if it has no remaining dispatch items anywhere AND it is
    // currently closed, revert it to "Ready to Dispatch" so it shows up
    // again in the dispatch picker.
    for (final pcId in pcIds) {
      final remaining = await db.query('dispatch_items',
          where: 'program_card_id = ?', whereArgs: [pcId], limit: 1);
      if (remaining.isNotEmpty) continue;
      final card = await db.query('program_cards',
          where: 'id = ?', whereArgs: [pcId], limit: 1);
      if (card.isEmpty) continue;
      final status = (card.first['status'] ?? '').toString();
      final statusNorm = status.trim().toLowerCase();
      if (statusNorm == 'dispatched' || statusNorm == 'completed') {
        await _syncUpdate(
            'program_cards', {'status': 'Ready to Dispatch'}, pcId);
      }
    }
  }

  Future<int> insertDispatchItem(Map<String, dynamic> data) async {
    data['created_at'] ??= DateTime.now().millisecondsSinceEpoch;
    return _syncInsert('dispatch_items', data);
  }

  Future<void> updateDispatchItem(int id, Map<String, dynamic> data) async {
    await _syncUpdate('dispatch_items', data, id);
  }

  Future<void> deleteDispatchItem(int id) async =>
      _syncDelete('dispatch_items', id);

  // ================= FABRIC / THREAD =================
  Future<List<Map<String, dynamic>>> getFabricShades() async =>
      (await database).query('fabric_shades');

  /// Returns shades that are already related to the given product
  /// from historical order/purchase/stock data.
  Future<List<Map<String, dynamic>>> getShadesForProduct(int productId) async {
    final db = await database;
    return db.rawQuery(
      '''
      SELECT DISTINCT fs.id, fs.shade_no, fs.shade_name, fs.image_path
      FROM (
        SELECT fs0.id AS shade_id
        FROM fabric_shades fs0
        JOIN products p ON p.id = ?
        WHERE LOWER(TRIM(COALESCE(fs0.shade_name, ''))) =
              LOWER(TRIM(COALESCE(p.name, '')))
        UNION
        SELECT oi.shade_id AS shade_id
        FROM order_items oi
        WHERE oi.product_id = ? AND oi.shade_id IS NOT NULL
        UNION
        SELECT pi.shade_id AS shade_id
        FROM purchase_items pi
        WHERE pi.product_id = ? AND pi.shade_id IS NOT NULL
        UNION
        SELECT sl.fabric_shade_id AS shade_id
        FROM stock_ledger sl
        WHERE sl.product_id = ?
          AND sl.fabric_shade_id IS NOT NULL
          AND (sl.is_deleted IS NULL OR sl.is_deleted = 0)
      ) rel
      JOIN fabric_shades fs ON fs.id = rel.shade_id
      ORDER BY fs.shade_no
      ''',
      [productId, productId, productId, productId],
    );
  }

  Future<List<Map<String, dynamic>>> getThreadShades() async =>
      (await database).query('thread_shades');

  // ================= DELAY =================
  Future<List<Map<String, dynamic>>> getDelayReasons() async =>
      (await database).query('delay_reasons');

  // ================= PROGRAM =================
  Future<int> getNextProgramNo() async {
    final r = await (await database)
        .rawQuery('SELECT MAX(program_no) maxNo FROM program_master');
    return ((r.first['maxNo'] as int?) ?? 0) + 1;
  }

  Future<void> insertProgram(Map<String, dynamic> data) async =>
      _syncInsert('program_master', data);

  Future<void> deleteProgram(int programNo) async {
    final db = await database;
    // Delete child records individually for Firebase sync
    final fabrics = await db.query('program_fabrics',
        columns: ['id'], where: 'program_no=?', whereArgs: [programNo]);
    for (final row in fabrics) {
      await _syncDelete('program_fabrics', row['id'] as int);
    }
    final threads = await db.query('program_thread_shades',
        columns: ['id'], where: 'program_no=?', whereArgs: [programNo]);
    for (final row in threads) {
      await _syncDelete('program_thread_shades', row['id'] as int);
    }
    // Delete master record
    final masters = await db.query('program_master',
        columns: ['id'], where: 'program_no=?', whereArgs: [programNo]);
    for (final row in masters) {
      await _syncDelete('program_master', row['id'] as int);
    }
  }

  Future<void> insertProgramFabric(
          int programNo, int shadeId, double qty) async =>
      _syncInsert('program_fabrics',
          {'program_no': programNo, 'fabric_shade_id': shadeId, 'qty': qty});

  Future<void> insertProgramThreadShade(int programNo, int shadeId) async =>
      _syncInsert('program_thread_shades',
          {'program_no': programNo, 'thread_shade_id': shadeId});

  Future<Map<String, dynamic>> getProgramByNo(int programNo) async =>
      (await database).rawQuery(
        'SELECT * FROM program_master WHERE program_no=?',
        [programNo],
      ).then((r) => r.first);

  Future<List<Map<String, dynamic>>> getProgramFabrics(int programNo) async =>
      (await database).rawQuery(
        'SELECT * FROM program_fabrics WHERE program_no=?',
        [programNo],
      );

  Future<List<Map<String, dynamic>>> getProgramThreads(int programNo) async =>
      (await database).rawQuery(
        'SELECT * FROM program_thread_shades WHERE program_no=?',
        [programNo],
      );

  // ================= PURCHASE / STOCK =================
  Future<int> getNextOrderNo() async {
    final rows = await (await database).rawQuery(
        'SELECT COALESCE(MAX(order_no), 0) AS max_no FROM order_master');
    final raw = rows.first['max_no'];
    final maxNo = raw is int
        ? raw
        : raw is num
            ? raw.toInt()
            : 0;
    return maxNo + 1;
  }

  Future<void> insertOrderMaster(Map<String, dynamic> data) async =>
      _syncInsert('order_master', data);

  Future<void> insertOrderItem(Map<String, dynamic> data) async =>
      _syncInsert('order_items', data);

  Future<Map<String, dynamic>?> getOrderMasterByNo(int orderNo) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT om.*,
             p.name AS party_name,
             f.firm_name
      FROM order_master om
      LEFT JOIN parties p ON p.id = om.party_id
      LEFT JOIN firms f ON f.id = om.firm_id
      WHERE om.order_no = ?
      ORDER BY om.id DESC
      LIMIT 1
      ''',
      [orderNo],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> getOrderSummaries({
    String status = 'all',
    int? fromDateMs,
    int? toDateMs,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <dynamic>[];

    if (status != 'all') {
      where.add('LOWER(om.status) = ?');
      args.add(status.toLowerCase());
    }
    if (fromDateMs != null) {
      where.add('om.order_date >= ?');
      args.add(fromDateMs);
    }
    if (toDateMs != null) {
      where.add('om.order_date <= ?');
      args.add(toDateMs);
    }

    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    return db.rawQuery(
      '''
      SELECT om.*,
             p.name AS party_name,
             f.firm_name,
             COALESCE(ot.order_qty, 0) AS order_qty,
             COALESCE(pt.purchase_qty, 0) AS purchase_qty,
             CASE
               WHEN COALESCE(ot.order_qty, 0) - COALESCE(pt.purchase_qty, 0) < 0 THEN 0
               ELSE COALESCE(ot.order_qty, 0) - COALESCE(pt.purchase_qty, 0)
             END AS pending_qty
      FROM order_master om
      LEFT JOIN parties p ON p.id = om.party_id
      LEFT JOIN firms f ON f.id = om.firm_id
      LEFT JOIN (
        SELECT order_no, SUM(COALESCE(qty, 0)) AS order_qty
        FROM order_items
        GROUP BY order_no
      ) ot ON ot.order_no = om.order_no
      LEFT JOIN (
        SELECT pm.order_no, SUM(COALESCE(pi.qty, 0)) AS purchase_qty
        FROM purchase_master pm
        JOIN purchase_items pi ON pi.purchase_no = pm.purchase_no
        WHERE pm.order_no IS NOT NULL
        GROUP BY pm.order_no
      ) pt ON pt.order_no = om.order_no
      $whereClause
      ORDER BY om.order_date DESC, om.order_no DESC
      ''',
      args,
    );
  }

  Future<List<Map<String, dynamic>>> getOrderShadeWiseSummaries({
    String status = 'all',
    int? fromDateMs,
    int? toDateMs,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <dynamic>[];

    if (status != 'all') {
      where.add('LOWER(om.status) = ?');
      args.add(status.toLowerCase());
    }
    if (fromDateMs != null) {
      where.add('om.order_date >= ?');
      args.add(fromDateMs);
    }
    if (toDateMs != null) {
      where.add('om.order_date <= ?');
      args.add(toDateMs);
    }

    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    return db.rawQuery(
      '''
      SELECT
        om.order_no,
        om.order_date,
        om.status,
        p.name AS party_name,
        f.firm_name,
        oi.product_id,
        pr.name AS product_name,
        COALESCE(pr.unit, 'Mtr') AS product_unit,
        oi.shade_id,
        COALESCE(fs.shade_no, 'NO SHADE') AS shade_no,
        COALESCE(oi.qty, 0) AS order_qty,
        COALESCE(pp.purchase_qty, 0) AS purchase_qty,
        CASE
          WHEN COALESCE(oi.qty, 0) - COALESCE(pp.purchase_qty, 0) < 0 THEN 0
          ELSE COALESCE(oi.qty, 0) - COALESCE(pp.purchase_qty, 0)
        END AS pending_qty
      FROM order_master om
      JOIN order_items oi ON oi.order_no = om.order_no
      LEFT JOIN parties p ON p.id = om.party_id
      LEFT JOIN firms f ON f.id = om.firm_id
      LEFT JOIN products pr ON pr.id = oi.product_id
      LEFT JOIN fabric_shades fs ON fs.id = oi.shade_id
      LEFT JOIN (
        SELECT
          pm.order_no,
          pi.product_id,
          COALESCE(pi.shade_id, 0) AS shade_key,
          SUM(COALESCE(pi.qty, 0)) AS purchase_qty
        FROM purchase_master pm
        JOIN purchase_items pi ON pi.purchase_no = pm.purchase_no
        WHERE pm.order_no IS NOT NULL
        GROUP BY pm.order_no, pi.product_id, COALESCE(pi.shade_id, 0)
      ) pp ON pp.order_no = oi.order_no
           AND pp.product_id = oi.product_id
           AND pp.shade_key = COALESCE(oi.shade_id, 0)
      $whereClause
      ORDER BY om.order_date DESC, om.order_no DESC, pr.name, fs.shade_no, oi.id
      ''',
      args,
    );
  }

  Future<List<Map<String, dynamic>>> getOrderLineProgress(int orderNo) async {
    final db = await database;
    return db.rawQuery(
      '''
      SELECT oi.id,
             oi.order_no,
             oi.product_id,
             oi.shade_id,
             COALESCE(oi.qty, 0) AS order_qty,
             COALESCE(pp.purchase_qty, 0) AS purchase_qty,
             CASE
               WHEN COALESCE(oi.qty, 0) - COALESCE(pp.purchase_qty, 0) < 0 THEN 0
               ELSE COALESCE(oi.qty, 0) - COALESCE(pp.purchase_qty, 0)
             END AS pending_qty,
             pr.name AS product_name,
             COALESCE(pr.unit, 'Mtr') AS product_unit,
             COALESCE(fs.shade_no, 'NO SHADE') AS shade_no
      FROM order_items oi
      LEFT JOIN products pr ON pr.id = oi.product_id
      LEFT JOIN fabric_shades fs ON fs.id = oi.shade_id
      LEFT JOIN (
        SELECT pm.order_no,
               pi.product_id,
               COALESCE(pi.shade_id, 0) AS shade_key,
               SUM(COALESCE(pi.qty, 0)) AS purchase_qty
        FROM purchase_master pm
        JOIN purchase_items pi ON pi.purchase_no = pm.purchase_no
        WHERE pm.order_no = ?
        GROUP BY pm.order_no, pi.product_id, COALESCE(pi.shade_id, 0)
      ) pp ON pp.order_no = oi.order_no
          AND pp.product_id = oi.product_id
          AND pp.shade_key = COALESCE(oi.shade_id, 0)
      WHERE oi.order_no = ?
      ORDER BY pr.name, fs.shade_no, oi.id
      ''',
      [orderNo, orderNo],
    );
  }

  Future<void> refreshOrderStatusByNo(int orderNo) async {
    final rows = await getOrderLineProgress(orderNo);
    final hasPending = rows.any(
      (r) => ((r['pending_qty'] as num?)?.toDouble() ?? 0) > 0.0001,
    );
    final nextStatus = hasPending ? 'open' : 'closed';

    final db = await database;
    final masters = await db.query(
      'order_master',
      columns: ['id', 'status', 'closed_at'],
      where: 'order_no = ?',
      whereArgs: [orderNo],
    );

    for (final row in masters) {
      final id = row['id'] as int?;
      if (id == null) continue;
      final oldStatus = (row['status'] ?? '').toString().toLowerCase();
      final oldClosedAt = row['closed_at'];
      final nextClosedAt = hasPending
          ? null
          : (oldClosedAt is int
              ? oldClosedAt
              : DateTime.now().millisecondsSinceEpoch);
      if (oldStatus == nextStatus && oldClosedAt == nextClosedAt) continue;
      await _syncUpdate(
        'order_master',
        {'status': nextStatus, 'closed_at': nextClosedAt},
        id,
      );
    }
  }

  Future<int> createPurchaseFromOrder({
    required int orderNo,
    required int firmId,
    required int partyId,
    required int purchaseDateMs,
    required String invoiceNo,
    required List<Map<String, dynamic>> items,
  }) async {
    final purchaseNo = DateTime.now().millisecondsSinceEpoch;

    await insertPurchaseMaster({
      'purchase_no': purchaseNo,
      'firm_id': firmId,
      'party_id': partyId,
      'purchase_date': purchaseDateMs,
      'invoice_no': invoiceNo,
      'order_no': orderNo,
      'gross_amount': 0,
      'discount_amount': 0,
      'cgst': 0,
      'sgst': 0,
      'igst': 0,
      'total_amount': 0,
    });

    for (final item in items) {
      final productId = item['product_id'] as int?;
      final qty = (item['qty'] as num?)?.toDouble() ?? 0;
      if (productId == null || qty <= 0) continue;
      final shadeId = item['shade_id'] as int?;

      await insertPurchaseItem({
        'purchase_no': purchaseNo,
        'product_id': productId,
        'shade_id': shadeId,
        'qty': qty,
        'rate': 0,
        'amount': 0,
      });

      await insertLedger({
        'product_id': productId,
        'fabric_shade_id': shadeId,
        'qty': qty,
        'type': 'IN',
        'date': purchaseDateMs,
        'reference': invoiceNo,
        'order_no': orderNo,
        'remarks': 'Purchase against Order #$orderNo',
      });
    }

    await refreshOrderStatusByNo(orderNo);
    return purchaseNo;
  }

  Future<int> getOrderPurchaseCount(int orderNo) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM purchase_master WHERE order_no = ?',
      [orderNo],
    );
    final raw = rows.first['cnt'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return 0;
  }

  Future<void> updateOrderByNo({
    required int orderNo,
    required int firmId,
    required int partyId,
    required int orderDateMs,
    required String remarks,
    required List<Map<String, dynamic>> items,
  }) async {
    if (items.isEmpty) {
      throw Exception('Order must have at least one item.');
    }

    final normalized = <String, Map<String, dynamic>>{};
    for (final item in items) {
      final productId = item['product_id'] as int?;
      final shadeId = item['shade_id'] as int?;
      final shadeKey = shadeId ?? 0;
      final qty = (item['qty'] as num?)?.toDouble() ?? 0;
      if (productId == null || qty <= 0) continue;

      final key = '$productId:$shadeKey';
      final existing = normalized[key];
      if (existing == null) {
        normalized[key] = {
          'product_id': productId,
          'shade_id': shadeId,
          'qty': qty,
        };
      } else {
        existing['qty'] = ((existing['qty'] as num?)?.toDouble() ?? 0) + qty;
      }
    }

    if (normalized.isEmpty) {
      throw Exception('Order must have at least one valid item.');
    }

    final db = await database;

    final purchasedRows = await db.rawQuery(
      '''
      SELECT
        pi.product_id,
        COALESCE(pi.shade_id, 0) AS shade_key,
        SUM(COALESCE(pi.qty, 0)) AS purchase_qty
      FROM purchase_master pm
      JOIN purchase_items pi ON pi.purchase_no = pm.purchase_no
      WHERE pm.order_no = ?
      GROUP BY pi.product_id, COALESCE(pi.shade_id, 0)
      ''',
      [orderNo],
    );

    final purchasedByKey = <String, double>{};
    for (final row in purchasedRows) {
      final productId = row['product_id'] as int?;
      final shadeKey = (row['shade_key'] as num?)?.toInt() ?? 0;
      final purchaseQty = (row['purchase_qty'] as num?)?.toDouble() ?? 0;
      if (productId == null || purchaseQty <= 0) continue;
      purchasedByKey['$productId:$shadeKey'] = purchaseQty;
    }

    for (final entry in purchasedByKey.entries) {
      final current = normalized[entry.key];
      if (current == null) {
        throw Exception(
          'Cannot remove purchased line from order. Add it back before saving.',
        );
      }
      final currentQty = (current['qty'] as num?)?.toDouble() ?? 0;
      if (currentQty + 0.0001 < entry.value) {
        throw Exception(
          'Order qty cannot be less than purchased qty for one or more lines.',
        );
      }
    }

    final masters = await db.query(
      'order_master',
      columns: ['id'],
      where: 'order_no = ?',
      whereArgs: [orderNo],
    );
    if (masters.isEmpty) {
      throw Exception('Order not found.');
    }

    final totalQty = normalized.values.fold<double>(
      0,
      (sum, row) => sum + ((row['qty'] as num?)?.toDouble() ?? 0),
    );

    for (final master in masters) {
      final id = master['id'] as int?;
      if (id == null) continue;
      await _syncUpdate(
        'order_master',
        {
          'firm_id': firmId,
          'party_id': partyId,
          'order_date': orderDateMs,
          'remarks': remarks.trim(),
          'total_qty': totalQty,
        },
        id,
      );
    }

    final oldItems = await db.query(
      'order_items',
      columns: ['id'],
      where: 'order_no = ?',
      whereArgs: [orderNo],
    );
    for (final row in oldItems) {
      final id = row['id'] as int?;
      if (id == null) continue;
      await _syncDelete('order_items', id);
    }

    for (final row in normalized.values) {
      await _syncInsert('order_items', {
        'order_no': orderNo,
        'product_id': row['product_id'],
        'shade_id': row['shade_id'],
        'qty': row['qty'],
      });
    }

    await refreshOrderStatusByNo(orderNo);
  }

  Future<void> deleteOrderByNo(
    int orderNo, {
    bool removeLinkedPurchases = true,
  }) async {
    final db = await database;
    final orderRemark = 'Purchase against Order #$orderNo';
    final orderRemarkLike = '$orderRemark%';
    final stockLedgerCols =
        await db.rawQuery('PRAGMA table_info(stock_ledger)');
    final hasStockLedgerOrderNo = stockLedgerCols.any(
      (c) => (c['name'] ?? '').toString().toLowerCase() == 'order_no',
    );
    _beginBulkMutation(suppressActivityLog: true);
    try {
      if (removeLinkedPurchases) {
        final purchaseMasters = await db.query(
          'purchase_master',
          columns: ['id', 'purchase_no', 'invoice_no', 'purchase_date'],
          where: 'order_no = ?',
          whereArgs: [orderNo],
        );
        final ledgerIdsToDelete = <int>{};

        final explicitOrderLedgers = await db.rawQuery(
          '''
          SELECT id
          FROM stock_ledger
          WHERE UPPER(type) = 'IN'
            AND (is_deleted IS NULL OR is_deleted = 0)
            AND (
              ${hasStockLedgerOrderNo ? 'order_no = ? OR' : ''}
              COALESCE(TRIM(remarks), '') = ?
              OR UPPER(COALESCE(remarks, '')) LIKE UPPER(?)
            )
          ''',
          [
            if (hasStockLedgerOrderNo) orderNo,
            orderRemark,
            orderRemarkLike,
          ],
        );
        for (final row in explicitOrderLedgers) {
          final id = row['id'] as int?;
          if (id != null) ledgerIdsToDelete.add(id);
        }

        for (final row in purchaseMasters) {
          final purchaseMasterId = row['id'] as int?;
          final purchaseNo = row['purchase_no'] as int?;
          final invoiceNo = (row['invoice_no'] ?? '').toString().trim();
          final purchaseDateMs = (row['purchase_date'] as num?)?.toInt() ?? 0;
          if (purchaseNo == null) {
            if (purchaseMasterId != null) {
              await _syncDelete('purchase_master', purchaseMasterId);
            }
            continue;
          }

          final purchaseItems = await db.query(
            'purchase_items',
            where: 'purchase_no = ?',
            whereArgs: [purchaseNo],
          );

          for (final item in purchaseItems) {
            final purchaseItemId = item['id'] as int?;
            final productId = item['product_id'] as int?;
            final shadeId = item['shade_id'] as int?;
            final shadeKey = shadeId ?? 0;
            final qty = (item['qty'] as num?)?.toDouble() ?? 0;

            if (productId != null && qty > 0) {
              final ledgerArgs = <dynamic>[
                productId,
                shadeKey,
                qty,
                if (invoiceNo.isNotEmpty) invoiceNo,
                orderRemark,
                purchaseDateMs,
              ];

              final ledgerRows = await db.rawQuery(
                '''
                SELECT id
                FROM stock_ledger
                WHERE product_id = ?
                  AND COALESCE(fabric_shade_id, 0) = ?
                  AND UPPER(type) = 'IN'
                  AND ABS(COALESCE(qty, 0) - ?) < 0.0001
                  AND (is_deleted IS NULL OR is_deleted = 0)
                  ${invoiceNo.isNotEmpty ? 'AND reference = ?' : ''}
                ORDER BY
                  CASE WHEN remarks = ? THEN 0 ELSE 1 END,
                  ABS(COALESCE(date, 0) - ?),
                  id DESC
                LIMIT 25
                ''',
                ledgerArgs,
              );

              if (ledgerRows.isNotEmpty) {
                for (final lr in ledgerRows) {
                  final ledgerId = lr['id'] as int?;
                  if (ledgerId != null) {
                    ledgerIdsToDelete.add(ledgerId);
                  }
                }
              } else if (invoiceNo.isNotEmpty) {
                final relaxedRows = await db.rawQuery(
                  '''
                  SELECT id
                  FROM stock_ledger
                  WHERE product_id = ?
                    AND COALESCE(fabric_shade_id, 0) = ?
                    AND UPPER(type) = 'IN'
                    AND (is_deleted IS NULL OR is_deleted = 0)
                    AND reference = ?
                    AND ABS(COALESCE(date, 0) - ?) <= ?
                  ORDER BY ABS(COALESCE(date, 0) - ?), id DESC
                  LIMIT 25
                  ''',
                  [
                    productId,
                    shadeKey,
                    invoiceNo,
                    purchaseDateMs,
                    const Duration(days: 7).inMilliseconds,
                    purchaseDateMs,
                  ],
                );
                for (final lr in relaxedRows) {
                  final ledgerId = lr['id'] as int?;
                  if (ledgerId != null) {
                    ledgerIdsToDelete.add(ledgerId);
                  }
                }
              }
            }

            if (purchaseItemId != null) {
              await _syncDelete('purchase_items', purchaseItemId);
            }
          }

          if (purchaseMasterId != null) {
            await _syncDelete('purchase_master', purchaseMasterId);
          }
        }

        // Final sweep for any lingering rows with explicit order remarks.
        final lingeringOrderLedgers = await db.rawQuery(
          '''
          SELECT id
          FROM stock_ledger
          WHERE UPPER(type) = 'IN'
            AND (is_deleted IS NULL OR is_deleted = 0)
            AND (
              ${hasStockLedgerOrderNo ? 'order_no = ? OR' : ''}
              UPPER(COALESCE(remarks, '')) LIKE UPPER(?)
            )
          ''',
          [
            if (hasStockLedgerOrderNo) orderNo,
            orderRemarkLike,
          ],
        );
        for (final row in lingeringOrderLedgers) {
          final id = row['id'] as int?;
          if (id != null) ledgerIdsToDelete.add(id);
        }

        for (final ledgerId in ledgerIdsToDelete) {
          await _syncDelete('stock_ledger', ledgerId);
        }
      }

      final orderItems = await db.query(
        'order_items',
        columns: ['id'],
        where: 'order_no = ?',
        whereArgs: [orderNo],
      );
      for (final row in orderItems) {
        final id = row['id'] as int?;
        if (id == null) continue;
        await _syncDelete('order_items', id);
      }

      final orderMasters = await db.query(
        'order_master',
        columns: ['id'],
        where: 'order_no = ?',
        whereArgs: [orderNo],
      );
      for (final row in orderMasters) {
        final id = row['id'] as int?;
        if (id == null) continue;
        await _syncDelete('order_master', id);
      }
    } finally {
      _endBulkMutation(suppressActivityLog: true);
    }

    await logActivity(
      action: 'DELETE',
      tableName: 'order_master',
      details: 'Bulk delete order #$orderNo with linked purchases and stock',
    );
  }

  Future<void> insertPurchaseMaster(Map<String, dynamic> data) async =>
      _syncInsert('purchase_master', data);

  Future<void> insertPurchaseItem(Map<String, dynamic> data) async =>
      _syncInsert('purchase_items', data);

  Future<void> insertLedger(Map<String, dynamic> data) async =>
      _syncInsert('stock_ledger', data);

  Future<double> getCurrentStockBalance({
    required int productId,
    int? fabricShadeId,
  }) async {
    final db = await database;
    final shadeKey = fabricShadeId ?? 0;
    final rows = await db.rawQuery(
      '''
      SELECT COALESCE(
        SUM(
          CASE
            WHEN UPPER(type) = 'OUT' THEN -qty
            ELSE qty
          END
        ),
        0
      ) AS balance
      FROM stock_ledger
      WHERE product_id = ?
        AND COALESCE(fabric_shade_id, 0) = ?
        AND (is_deleted IS NULL OR is_deleted = 0)
      ''',
      [productId, shadeKey],
    );

    if (rows.isEmpty) return 0;
    return ((rows.first['balance'] as num?)?.toDouble() ?? 0);
  }

  Future<List<Map<String, dynamic>>> getNegativeFabricRequirements() async {
    final db = await database;
    return db.rawQuery('''
      SELECT 
        x.product_id,
        x.shade_id,
        x.product_name,
        x.shade_no,
        x.balance,
        ABS(x.balance) AS required_qty
      FROM (
        SELECT
          l.product_id,
          COALESCE(l.fabric_shade_id, 0) AS shade_id,
          p.name AS product_name,
          COALESCE(f.shade_no, 'NO SHADE') AS shade_no,
          COALESCE(
            SUM(
              CASE
                WHEN UPPER(l.type) = 'OUT' THEN -l.qty
                ELSE l.qty
              END
            ),
            0
          ) AS balance
        FROM stock_ledger l
        JOIN products p ON p.id = l.product_id
        LEFT JOIN fabric_shades f ON f.id = l.fabric_shade_id
        WHERE (l.fabric_shade_id IS NULL OR l.fabric_shade_id = 0 OR f.id IS NOT NULL)
          AND (l.is_deleted IS NULL OR l.is_deleted = 0)
        GROUP BY l.product_id, COALESCE(l.fabric_shade_id, 0)
      ) x
      WHERE x.balance < 0
      ORDER BY x.product_name, x.shade_no
    ''');
  }

  Future<List<Map<String, dynamic>>> getAllStockBalances() async {
    final db = await database;
    return db.rawQuery('''
      SELECT
        l.product_id,
        COALESCE(l.fabric_shade_id, 0) AS shade_id,
        p.name AS product_name,
        COALESCE(p.unit, 'Mtr') AS product_unit,
        COALESCE(f.shade_no, 'NO SHADE') AS shade_no,
        COALESCE(
          SUM(
            CASE
              WHEN UPPER(l.type) = 'OUT' THEN -l.qty
              ELSE l.qty
            END
          ),
          0
        ) AS balance
      FROM stock_ledger l
      JOIN products p ON p.id = l.product_id
      LEFT JOIN fabric_shades f ON f.id = l.fabric_shade_id
      WHERE (l.fabric_shade_id IS NULL OR l.fabric_shade_id = 0 OR f.id IS NOT NULL)
        AND (l.is_deleted IS NULL OR l.is_deleted = 0)
      GROUP BY l.product_id, COALESCE(l.fabric_shade_id, 0)
      ORDER BY p.name, f.shade_no
    ''');
  }

  Future<List<Map<String, dynamic>>> getStockTickerBalances({
    int limit = 80,
  }) async {
    final db = await database;
    return db.rawQuery('''
      SELECT *
      FROM (
        SELECT
          l.product_id,
          COALESCE(l.fabric_shade_id, 0) AS shade_id,
          p.name AS product_name,
          COALESCE(p.unit, 'Mtr') AS product_unit,
          COALESCE(f.shade_no, 'NO SHADE') AS shade_no,
          COALESCE(
            SUM(
              CASE
                WHEN UPPER(l.type) = 'OUT' THEN -l.qty
                ELSE l.qty
              END
            ),
            0
          ) AS balance
        FROM stock_ledger l
        JOIN products p ON p.id = l.product_id
        LEFT JOIN fabric_shades f ON f.id = l.fabric_shade_id
        WHERE (l.fabric_shade_id IS NULL OR l.fabric_shade_id = 0 OR f.id IS NOT NULL)
          AND (l.is_deleted IS NULL OR l.is_deleted = 0)
        GROUP BY l.product_id, COALESCE(l.fabric_shade_id, 0)
      ) x
      WHERE ABS(x.balance) > 0.0001
      ORDER BY x.product_name, x.shade_no
      LIMIT ?
    ''', [limit]);
  }

  Future<void> updateLedgerFull({
    required int id,
    required int productId,
    required int fabricShadeId,
    required String type,
    required double qty,
    String? remarks,
  }) async {
    final data = {
      'product_id': productId,
      'fabric_shade_id': fabricShadeId,
      'type': type,
      'qty': qty,
      'remarks': remarks,
    };
    await _syncUpdate('stock_ledger', data, id);
  }

  Future<void> deleteLedgerEntry(int id) async {
    await _syncDelete('stock_ledger', id);
  }

  // ================= MACHINE / OPERATOR =================
  Future<List<Map<String, dynamic>>> getPlannedPrograms() async =>
      (await database).query('program_master', where: "status='PLANNED'");

  Future<List<Map<String, dynamic>>> getPlannedProgramDetails() async =>
      (await database).rawQuery('''
        SELECT pm.program_no, pm.party_id, pm.status, p.name AS party_name
        FROM program_master pm
        LEFT JOIN parties p ON p.id = pm.party_id
        WHERE pm.status = 'PLANNED'
        ORDER BY pm.program_no DESC
      ''');

  Future<void> updateProgramStatus(int programNo, String status) async {
    final db = await database;
    final rows = await db.query('program_master',
        columns: ['id'], where: 'program_no=?', whereArgs: [programNo]);
    for (final row in rows) {
      await _syncUpdate('program_master', {'status': status}, row['id'] as int);
    }
  }

  Future<void> allotMachine(
          {required int programNo, required int machineId}) async =>
      _syncInsert('program_allotment', {
        'program_no': programNo,
        'machine_id': machineId,
        'status': 'ALLOTTED'
      });

  Future<List<Map<String, dynamic>>> getActiveAllotments() async =>
      (await database).rawQuery('''
        SELECT pa.program_no, pa.machine_id, pa.status, m.code
        FROM program_allotment pa
        JOIN machines m ON m.id = pa.machine_id
        WHERE pa.status != 'COMPLETED'
      ''');

  Future<void> updateAllotmentStatus(int programNo, String status) async {
    final db = await database;
    final rows = await db.query('program_allotment',
        columns: ['id'], where: 'program_no=?', whereArgs: [programNo]);
    for (final row in rows) {
      await _syncUpdate(
          'program_allotment', {'status': status}, row['id'] as int);
    }
  }

  Future<void> logProgramActivity(Map<String, dynamic> log) async =>
      _syncInsert('program_logs', {
        'program_no': log['program_no'],
        'message': log['message'],
        'date': log['date']
      });
  // ================= THREAD SHADES =================
  Future<void> insertThreadShade({
    required String shadeNo,
    required String companyName,
  }) async {
    await _syncInsert('thread_shades', {
      'shade_no': shadeNo,
      'company_name': companyName,
    });
  }

// ================= FABRIC SHADES =================
  Future<void> insertFabricShade({
    required String shadeNo,
    required String shadeName,
    String? imagePath,
  }) async {
    await _syncInsert('fabric_shades', {
      'shade_no': shadeNo,
      'shade_name': shadeName,
      'image_path': imagePath,
    });
  }

  Future<int> insertFabricShadeReturningId({
    required String shadeNo,
    required String shadeName,
    String? imagePath,
  }) async {
    return _syncInsert('fabric_shades', {
      'shade_no': shadeNo,
      'shade_name': shadeName,
      'image_path': imagePath,
    });
  }

  Future<void> updateFabricShade(
    int id, {
    required String shadeNo,
    required String shadeName,
    String? imagePath,
  }) async {
    await _syncUpdate(
        'fabric_shades',
        {
          'shade_no': shadeNo,
          'shade_name': shadeName,
          'image_path': imagePath,
        },
        id);
  }

  Future<void> deleteFabricShade(int id) async {
    final db = await database;

    // Delete related stock_ledger entries for this shade
    final ledgerRows = await db.query('stock_ledger',
        columns: ['id'], where: 'fabric_shade_id = ?', whereArgs: [id]);
    for (final row in ledgerRows) {
      await _syncDelete('stock_ledger', row['id'] as int);
    }

    // Delete related challan_requirements for this shade
    final challanRows = await db.query('challan_requirements',
        columns: ['id'], where: 'fabric_shade_id = ?', whereArgs: [id]);
    for (final row in challanRows) {
      await _syncDelete('challan_requirements', row['id'] as int);
    }

    // Delete related purchase_items for this shade
    final purchaseRows = await db.query('purchase_items',
        columns: ['id'], where: 'shade_id = ?', whereArgs: [id]);
    for (final row in purchaseRows) {
      await _syncDelete('purchase_items', row['id'] as int);
    }

    await _syncDelete('fabric_shades', id);
  }

// ================= MACHINES =================
  Future<List<Map<String, dynamic>>> getMachines() async {
    final db = await database;
    return await db.query('machines');
  }

  Future<int> insertMachine(Map<String, dynamic> data) async =>
      _syncInsert('machines', data);

  Future<void> updateMachine(Map<String, dynamic> data, int id) async =>
      _syncUpdate('machines', data, id);

  Future<void> deleteMachine(int id) async => _syncDelete('machines', id);

// ================= PARTIES (MODEL-BASED) =================
  Future<void> insertParty(Party party) async {
    final data = party.toMap();
    await _syncInsert('parties', data);
  }

  Future<void> updateParty(Party party) async {
    final data = party.toMap();
    data.remove('id');
    await _syncUpdate('parties', data, party.id!);
  }

  Future<void> deleteParty(int id) async => _syncDelete('parties', id);

// ================= DELAY REASONS =================
  Future<void> insertDelayReason(String reason) async =>
      _syncInsert('delay_reasons', {'reason': reason});

  Future<void> deleteDelayReason(int id) async =>
      _syncDelete('delay_reasons', id);

// ================= UNITS (FACTORY UNITS) =================
  Future<List<Map<String, dynamic>>> getUnits() async {
    final db = await database;
    return db.query('units', orderBy: 'name');
  }

  Future<void> insertUnit(String name) async =>
      _syncInsert('units', {'name': name});

  Future<void> updateUnit(int id, String name) async =>
      _syncUpdate('units', {'name': name}, id);

  Future<void> deleteUnit(int id) async => _syncDelete('units', id);

// ================= GST CATEGORIES =================
  Future<List<Map<String, dynamic>>> getGstCategories() async {
    final db = await database;
    return await db.query('gst_categories', orderBy: 'gst_percent');
  }

// ================= RAW PRODUCT INSERT (FORM PAGE) =================
  Future<void> insertProductRaw(Map<String, dynamic> data) async =>
      _syncInsert('products', data);

  // ================= CHALLAN REQUIREMENTS =================
  Future<void> insertChallanRequirement(Map<String, dynamic> data) async {
    try {
      await _syncInsert('challan_requirements', data);
    } catch (_) {
      final db = await database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS challan_requirements (
          id INTEGER PRIMARY KEY AUTOINCREMENT, challan_no TEXT,
          party_id INTEGER, party_name TEXT, product_id INTEGER,
          fabric_shade_id INTEGER, qty REAL, date INTEGER,
          status TEXT DEFAULT 'pending', closed_date INTEGER)
      ''');
      await _syncInsert('challan_requirements', data);
    }
  }

  Future<void> updateChallanRequirement(
      int id, Map<String, dynamic> data) async {
    await _syncUpdate('challan_requirements', data, id);
  }

  Future<void> deleteChallanRequirement(int id) async {
    await _syncDelete('challan_requirements', id);
  }

  Future<List<Map<String, dynamic>>> getPendingChallanRequirements() async {
    final db = await database;
    return db.rawQuery('''
      SELECT cr.id, cr.challan_no, cr.party_id, cr.party_name,
             cr.product_id, cr.fabric_shade_id, cr.qty, cr.date, cr.status,
             p.name AS product_name,
             COALESCE(f.shade_no, 'NO SHADE') AS shade_no
      FROM challan_requirements cr
      JOIN products p ON p.id = cr.product_id
      LEFT JOIN fabric_shades f ON f.id = cr.fabric_shade_id
      WHERE cr.status = 'pending'
      ORDER BY cr.challan_no, p.name, f.shade_no
    ''');
  }

  Future<void> closeChallanRequirement(int id) async {
    final db = await database;
    final rows = await db.query(
      'challan_requirements',
      where: "id = ? AND status = 'pending'",
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await closeChallanRequirementWithLedger(rows.first);
  }

  Future<void> closeChallanRequirementsByChallan(String challanNo) async {
    final db = await database;
    final pendingRows = await db.query(
      'challan_requirements',
      where: "challan_no = ? AND status = 'pending'",
      whereArgs: [challanNo],
    );

    for (final row in pendingRows) {
      await closeChallanRequirementWithLedger(row);
    }
  }

  Future<void> closeChallanRequirementWithLedger(
    Map<String, dynamic> requirement,
  ) async {
    final id = requirement['id'] as int?;
    if (id == null) return;

    final db = await database;
    final currentRows = await db.query(
      'challan_requirements',
      where: "id = ? AND status = 'pending'",
      whereArgs: [id],
      limit: 1,
    );
    if (currentRows.isEmpty) return;

    final row = currentRows.first;
    final productId = row['product_id'] as int?;
    final shadeId = row['fabric_shade_id'] as int?;
    final qty = (row['qty'] as num?)?.toDouble() ?? 0;
    final challanNo = (row['challan_no'] ?? '').toString();
    final partyName = (row['party_name'] ?? '').toString();
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final today = '${now.day.toString().padLeft(2, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-${now.year}';
    final ledgerReference = 'REQ-CLOSE-$id';

    if (productId != null && qty > 0) {
      final existingLedger = await db.query(
        'stock_ledger',
        columns: ['id'],
        where: 'reference = ? AND (is_deleted IS NULL OR is_deleted = 0)',
        whereArgs: [ledgerReference],
        limit: 1,
      );

      if (existingLedger.isEmpty) {
        await insertLedger({
          'product_id': productId,
          'fabric_shade_id': shadeId,
          'qty': qty,
          'type': 'OUT',
          'date': nowMs,
          'reference': ledgerReference,
          'remarks':
              'Party: $partyName | ChNo: $challanNo | Req completed on: $today',
        });
      }
    }

    await _syncUpdate(
      'challan_requirements',
      {
        'status': 'closed',
        'closed_date': nowMs,
      },
      id,
    );
  }

  Future<int> _countClosedRequirementRowsNeedingLedgerRepair(
      Database db) async {
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS cnt
      FROM challan_requirements cr
      WHERE cr.status = 'closed'
        AND cr.product_id IS NOT NULL
        AND COALESCE(cr.qty, 0) > 0
        AND NOT EXISTS (
          SELECT 1
          FROM stock_ledger sl
          WHERE sl.reference = ('REQ-CLOSE-' || cr.id)
            AND (sl.is_deleted IS NULL OR sl.is_deleted = 0)
        )
    ''');
    final raw = rows.first['cnt'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return 0;
  }

  Future<int> _countBrokenClosedRequirementRows(Database db) async {
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS cnt
      FROM challan_requirements
      WHERE status = 'closed'
        AND (
          challan_no IS NULL OR TRIM(challan_no) = '' OR
          party_name IS NULL OR TRIM(party_name) = '' OR
          product_id IS NULL OR qty IS NULL OR qty <= 0 OR date IS NULL
        )
    ''');
    final raw = rows.first['cnt'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return 0;
  }

  Map<String, String?> _parseReqCloseRemarks(String remarks) {
    if (remarks.trim().isEmpty) {
      return const {'party': null, 'challan': null};
    }
    final partyMatch = RegExp(
      r'Party:\s*(.*?)\s*(?:\||$)',
      caseSensitive: false,
    ).firstMatch(remarks);
    final challanMatch = RegExp(
      r'ChNo:\s*(.*?)\s*(?:\||$)',
      caseSensitive: false,
    ).firstMatch(remarks);

    final party = (partyMatch?.group(1) ?? '').trim();
    final challan = (challanMatch?.group(1) ?? '').trim();
    return {
      'party': party.isEmpty ? null : party,
      'challan': challan.isEmpty ? null : challan,
    };
  }

  Future<int?> _findPartyIdByName(Database db, String partyName) async {
    final normalized = partyName.trim();
    if (normalized.isEmpty) return null;
    final rows = await db.query(
      'parties',
      columns: ['id'],
      where: 'LOWER(name) = LOWER(?)',
      whereArgs: [normalized],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['id'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return null;
  }

  Future<Map<String, dynamic>?> _findFallbackCloseLedgerForBrokenRequirement(
    Database db,
    Map<String, dynamic> requirementRow,
    Set<int> usedLedgerIds,
  ) async {
    final productId = requirementRow['product_id'] as int?;
    final shadeId = requirementRow['fabric_shade_id'] as int?;
    final closedDateMs = (requirementRow['closed_date'] as num?)?.toInt();
    final challanNo = (requirementRow['challan_no'] ?? '').toString().trim();
    final partyName = (requirementRow['party_name'] ?? '').toString().trim();

    final where = <String>[
      "UPPER(type) = 'OUT'",
      "reference LIKE 'REQ-CLOSE%'",
      '(is_deleted IS NULL OR is_deleted = 0)',
      'COALESCE(qty, 0) > 0',
    ];
    final args = <dynamic>[];

    if (productId != null) {
      where.add('product_id = ?');
      args.add(productId);
    }
    if (shadeId != null) {
      where.add('COALESCE(fabric_shade_id, 0) = ?');
      args.add(shadeId);
    }
    if (closedDateMs != null && closedDateMs > 0) {
      final fromMs = closedDateMs - const Duration(days: 10).inMilliseconds;
      final toMs = closedDateMs + const Duration(days: 10).inMilliseconds;
      where.add('COALESCE(date, 0) BETWEEN ? AND ?');
      args.add(fromMs);
      args.add(toMs);
    }

    final orderBy = (closedDateMs != null && closedDateMs > 0)
        ? 'ABS(COALESCE(date, 0) - $closedDateMs), id DESC'
        : 'id DESC';

    Future<Map<String, dynamic>?> pickBest({
      required bool enforceRemarkHints,
    }) async {
      final rows = await db.query(
        'stock_ledger',
        columns: [
          'id',
          'product_id',
          'fabric_shade_id',
          'qty',
          'date',
          'remarks'
        ],
        where: where.join(' AND '),
        whereArgs: args,
        orderBy: orderBy,
        limit: 80,
      );
      if (rows.isEmpty) return null;

      for (final row in rows) {
        final id = (row['id'] as num?)?.toInt();
        if (id == null || usedLedgerIds.contains(id)) continue;

        if (!enforceRemarkHints) {
          return row;
        }

        final parsed = _parseReqCloseRemarks((row['remarks'] ?? '').toString());
        final parsedParty = (parsed['party'] ?? '').trim().toLowerCase();
        final parsedChallan = (parsed['challan'] ?? '').trim().toLowerCase();
        final needParty = partyName.isNotEmpty;
        final needChallan = challanNo.isNotEmpty;
        final partyOk = !needParty || parsedParty == partyName.toLowerCase();
        final challanOk =
            !needChallan || parsedChallan == challanNo.toLowerCase();
        if (partyOk && challanOk) {
          return row;
        }
      }
      return null;
    }

    // Pass 1: strict match if we have party/challan hints.
    final hasHints = challanNo.isNotEmpty || partyName.isNotEmpty;
    if (hasHints) {
      final strict = await pickBest(enforceRemarkHints: true);
      if (strict != null) return strict;
    }

    // Pass 2: relaxed nearest candidate in date/product/shade space.
    return pickBest(enforceRemarkHints: false);
  }

  Future<int> repairClosedRequirementLedgers({int limit = 200}) async {
    final db = await database;
    if (_closedRequirementLedgerRepairDone) {
      final remaining =
          await _countClosedRequirementRowsNeedingLedgerRepair(db);
      if (remaining <= 0) return 0;
    }

    final rows = await db.rawQuery('''
      SELECT id, challan_no, party_name, product_id, fabric_shade_id,
             qty, date, closed_date
      FROM challan_requirements
      WHERE status = 'closed'
        AND product_id IS NOT NULL
        AND qty IS NOT NULL
      ORDER BY id
      LIMIT ?
    ''', [limit]);

    var fixed = 0;
    _beginBulkMutation(suppressActivityLog: true);
    try {
      for (final row in rows) {
        final id = row['id'] as int?;
        final productId = row['product_id'] as int?;
        final qty = (row['qty'] as num?)?.toDouble() ?? 0;
        if (id == null || productId == null || qty <= 0) continue;

        final shadeId = row['fabric_shade_id'] as int?;
        final challanNo = (row['challan_no'] ?? '').toString();
        final partyName = (row['party_name'] ?? '').toString();
        final ledgerReference = 'REQ-CLOSE-$id';

        final existingNew = await db.query(
          'stock_ledger',
          columns: ['id'],
          where: 'reference = ? AND (is_deleted IS NULL OR is_deleted = 0)',
          whereArgs: [ledgerReference],
          limit: 1,
        );
        if (existingNew.isNotEmpty) continue;

        final legacyRows = await db.rawQuery('''
        SELECT id FROM stock_ledger
        WHERE reference LIKE 'REQ-CLOSE%'
          AND reference != ?
          AND product_id = ?
          AND qty = ?
          AND (is_deleted IS NULL OR is_deleted = 0)
          AND (${shadeId == null ? 'fabric_shade_id IS NULL' : 'fabric_shade_id = ?'})
          AND (? = '' OR remarks LIKE ?)
        LIMIT 2
        ''', [
          ledgerReference,
          productId,
          qty,
          if (shadeId != null) shadeId,
          challanNo,
          '%$challanNo%',
        ]);

        final repairedDateMs = (row['closed_date'] as int?) ??
            (row['date'] as int?) ??
            DateTime.now().millisecondsSinceEpoch;
        final repairedDate =
            DateTime.fromMillisecondsSinceEpoch(repairedDateMs);
        final dateText = '${repairedDate.day.toString().padLeft(2, '0')}-'
            '${repairedDate.month.toString().padLeft(2, '0')}-'
            '${repairedDate.year}';
        final remarks =
            'Party: $partyName | ChNo: $challanNo | Req completed on: $dateText';

        if (legacyRows.length == 1) {
          final ledgerId = legacyRows.first['id'] as int?;
          if (ledgerId == null) continue;
          await _syncUpdate(
            'stock_ledger',
            {
              'reference': ledgerReference,
              'remarks': remarks,
              'type': 'OUT',
            },
            ledgerId,
          );
          fixed++;
          continue;
        }

        if (legacyRows.length > 1) continue;

        await _syncInsert('stock_ledger', {
          'product_id': productId,
          'fabric_shade_id': shadeId,
          'qty': qty,
          'type': 'OUT',
          'date': repairedDateMs,
          'reference': ledgerReference,
          'remarks': remarks,
        });
        fixed++;
      }
    } finally {
      _endBulkMutation(suppressActivityLog: true);
    }

    if (fixed > 0) {
      debugPrint('Fixed $fixed old closed requirement ledger entries');
    }
    final remaining = await _countClosedRequirementRowsNeedingLedgerRepair(db);
    _closedRequirementLedgerRepairDone = remaining <= 0;
    return fixed;
  }

  /// Restore old closed requirement rows that were overwritten with partial data
  /// during sync updates. It backfills qty/product/shade/date using REQ-CLOSE
  /// stock_ledger entries.
  Future<int> repairClosedRequirementDataFromLedger({int limit = 500}) async {
    final db = await database;
    if (_closedRequirementDataRepairDone) {
      final remaining = await _countBrokenClosedRequirementRows(db);
      if (remaining <= 0) return 0;
    }

    final brokenRows = await db.rawQuery('''
      SELECT id, challan_no, party_name, product_id, fabric_shade_id,
             qty, date, closed_date
      FROM challan_requirements
      WHERE status = 'closed'
        AND (
          challan_no IS NULL OR TRIM(challan_no) = '' OR
          party_name IS NULL OR TRIM(party_name) = '' OR
          product_id IS NULL OR qty IS NULL OR qty <= 0 OR date IS NULL
        )
      ORDER BY id
      LIMIT ?
    ''', [limit]);

    if (brokenRows.isEmpty) {
      _closedRequirementDataRepairDone = true;
      return 0;
    }

    var fixed = 0;
    final usedLedgerIds = <int>{};
    _beginBulkMutation(suppressActivityLog: true);
    try {
      for (final row in brokenRows) {
        final id = row['id'] as int?;
        if (id == null) continue;

        Map<String, dynamic>? ledger;
        final directRows = await db.query(
          'stock_ledger',
          columns: [
            'id',
            'product_id',
            'fabric_shade_id',
            'qty',
            'date',
            'remarks',
          ],
          where: 'reference = ? AND (is_deleted IS NULL OR is_deleted = 0)',
          whereArgs: ['REQ-CLOSE-$id'],
          orderBy: 'id DESC',
          limit: 1,
        );
        if (directRows.isNotEmpty) {
          ledger = Map<String, dynamic>.from(directRows.first);
        } else {
          ledger = await _findFallbackCloseLedgerForBrokenRequirement(
            db,
            row,
            usedLedgerIds,
          );
        }
        if (ledger == null) continue;

        final ledgerId = (ledger['id'] as num?)?.toInt();
        if (ledgerId != null) usedLedgerIds.add(ledgerId);

        final updateData = <String, dynamic>{};

        if (row['product_id'] == null && ledger['product_id'] != null) {
          updateData['product_id'] = ledger['product_id'];
        }
        if (row['fabric_shade_id'] == null &&
            ledger['fabric_shade_id'] != null) {
          updateData['fabric_shade_id'] = ledger['fabric_shade_id'];
        }

        final challanNo = (row['challan_no'] ?? '').toString().trim();
        final partyName = (row['party_name'] ?? '').toString().trim();
        final parsed =
            _parseReqCloseRemarks((ledger['remarks'] ?? '').toString());
        final parsedParty = (parsed['party'] ?? '').trim();
        final parsedChallan = (parsed['challan'] ?? '').trim();

        if (partyName.isEmpty && parsedParty.isNotEmpty) {
          updateData['party_name'] = parsedParty;
        }
        if (challanNo.isEmpty && parsedChallan.isNotEmpty) {
          updateData['challan_no'] = parsedChallan;
        }
        if (row['party_id'] == null) {
          final effectiveParty = partyName.isNotEmpty ? partyName : parsedParty;
          if (effectiveParty.isNotEmpty) {
            final partyId = await _findPartyIdByName(db, effectiveParty);
            if (partyId != null) {
              updateData['party_id'] = partyId;
            }
          }
        }

        final qty = (row['qty'] as num?)?.toDouble() ?? 0;
        final ledgerQty = (ledger['qty'] as num?)?.toDouble() ?? 0;
        if (qty <= 0 && ledgerQty > 0) {
          updateData['qty'] = ledgerQty;
        }

        final rowDate = (row['date'] as num?)?.toInt();
        if (rowDate == null || rowDate <= 0) {
          final closedDate = (row['closed_date'] as num?)?.toInt();
          final ledgerDate = (ledger['date'] as num?)?.toInt();
          updateData['date'] =
              closedDate ?? ledgerDate ?? DateTime.now().millisecondsSinceEpoch;
        }

        if (updateData.isEmpty) continue;
        await _syncUpdate('challan_requirements', updateData, id);
        fixed++;
      }
    } finally {
      _endBulkMutation(suppressActivityLog: true);
    }

    if (fixed > 0) {
      debugPrint('Repaired $fixed closed requirement rows from ledger');
    }
    final remaining = await _countBrokenClosedRequirementRows(db);
    _closedRequirementDataRepairDone = remaining <= 0;
    return fixed;
  }

  // ================= EMPLOYEES =================
  Future<List<Map<String, dynamic>>> getEmployees({String? status}) async {
    final db = await database;
    if (status != null) {
      return db.query('employees',
          where: 'status = ?', whereArgs: [status], orderBy: 'name');
    }
    return db.query('employees', orderBy: 'name');
  }

  Future<int> insertEmployee(Map<String, dynamic> data) async {
    return _syncInsert('employees', data);
  }

  Future<void> updateEmployee(Map<String, dynamic> data, int id,
      {DateTime? effectiveFrom}) async {
    // Auto-create salary history if pay/type/base-days changed
    final salaryFields = ['base_pay', 'salary_type', 'salary_base_days'];
    if (salaryFields.any((f) => data.containsKey(f))) {
      final db = await database;
      final rows =
          await db.query('employees', where: 'id = ?', whereArgs: [id]);
      if (rows.isNotEmpty) {
        final old = rows.first;
        final oldPay = (old['base_pay'] as num?)?.toDouble() ?? 0;
        final oldType = old['salary_type'] ?? 'monthly';
        final oldDays = (old['salary_base_days'] as num?)?.toInt() ?? 30;
        final newPay = data.containsKey('base_pay')
            ? (data['base_pay'] as num?)?.toDouble() ?? 0
            : oldPay;
        final newType = data['salary_type'] ?? oldType;
        final newDays = data.containsKey('salary_base_days')
            ? (data['salary_base_days'] as num?)?.toInt() ?? 30
            : oldDays;
        if (newPay != oldPay || newType != oldType || newDays != oldDays) {
          final effMs = effectiveFrom?.millisecondsSinceEpoch ??
              DateTime.now().millisecondsSinceEpoch;
          await insertSalaryHistory({
            'employee_id': id,
            'base_pay': newPay,
            'salary_type': newType,
            'salary_base_days': newDays,
            'effective_from': effMs,
            'created_at': DateTime.now().millisecondsSinceEpoch,
          });
        }
      }
    }
    await _syncUpdate('employees', data, id);
  }

  /// Update employee without auto salary history (used when history is already inserted manually)
  Future<void> updateEmployeeRaw(Map<String, dynamic> data, int id) async {
    await _syncUpdate('employees', data, id);
  }

  Future<void> deleteEmployee(int id) async {
    await _syncDelete('employees', id);
  }

  // ================= PRODUCTION ENTRIES =================
  Future<List<Map<String, dynamic>>> getProductionEntries({
    int? dateMs,
    int? fromMs,
    int? toMs,
    int? employeeId,
    int? machineId,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <dynamic>[];

    if (dateMs != null) {
      where.add('pe.date = ?');
      args.add(dateMs);
    }
    if (fromMs != null) {
      where.add('pe.date >= ?');
      args.add(fromMs);
    }
    if (toMs != null) {
      where.add('pe.date < ?');
      args.add(toMs);
    }
    if (employeeId != null) {
      where.add('pe.employee_id = ?');
      args.add(employeeId);
    }
    if (machineId != null) {
      where.add('pe.machine_id = ?');
      args.add(machineId);
    }

    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    return db.rawQuery('''
      SELECT pe.*,
             e.name AS employee_name,
             m.name AS machine_name,
             m.code AS machine_code
      FROM production_entries pe
      LEFT JOIN employees e ON e.id = pe.employee_id
      LEFT JOIN machines m ON m.id = pe.machine_id
      $whereClause
      ORDER BY pe.date DESC, pe.id DESC
    ''', args);
  }

  Future<void> _deleteAutoProductionAttendanceIfNoProduction(
    Database db,
    Object empId,
    Object date,
  ) async {
    final rawDate = date is int ? date : (date as num).toInt();
    final normDate = DateTime.fromMillisecondsSinceEpoch(rawDate);
    final dayStart = DateTime(normDate.year, normDate.month, normDate.day)
        .millisecondsSinceEpoch;
    final otherProd = await db.query('production_entries',
        where: 'employee_id = ? AND date = ?',
        whereArgs: [empId, rawDate],
        limit: 1);
    if (otherProd.isNotEmpty) return;

    await db.delete(
      'attendance',
      where:
          "employee_id = ? AND date = ? AND remarks LIKE 'Auto: Production%'",
      whereArgs: [empId, dayStart],
    );
  }

  Future<int> insertProductionEntry(Map<String, dynamic> data) async {
    final db = await database;
    final id = await _syncInsert('production_entries', data);
    // Production can create a missing attendance row, but must not rewrite
    // manually marked attendance.
    final empId = data['employee_id'];
    final date = data['date'];
    if (empId != null && date != null) {
      // Normalize date to start of day
      final normDate = DateTime.fromMillisecondsSinceEpoch(date);
      final dayStart = DateTime(normDate.year, normDate.month, normDate.day)
          .millisecondsSinceEpoch;
      final existing = await db.query('attendance',
          columns: ['id'],
          where: 'employee_id = ? AND date = ?',
          whereArgs: [empId, dayStart],
          limit: 1);
      if (existing.isEmpty) {
        await _syncInsert('attendance', {
          'employee_id': empId,
          'date': dayStart,
          'status': 'present',
          'shift': 'day',
          'remarks': 'Auto: Production',
        });
      }
    }
    return id;
  }

  Future<void> updateProductionEntry(Map<String, dynamic> data, int id) async {
    final db = await database;
    // Get the old production entry to check if employee/date changed
    final oldProd = await db.query('production_entries',
        where: 'id = ?', whereArgs: [id], limit: 1);
    await _syncUpdate('production_entries', data, id);
    final newEmpId = data['employee_id'];
    final newDate = data['date'];
    if (oldProd.isNotEmpty) {
      final oldEmpId = oldProd.first['employee_id'];
      final oldDate = oldProd.first['date'];
      // If employee or date changed, remove only the old auto-generated row.
      if ((oldEmpId != newEmpId || oldDate != newDate) &&
          oldEmpId != null &&
          oldDate != null) {
        await _deleteAutoProductionAttendanceIfNoProduction(
          db,
          oldEmpId,
          oldDate,
        );
      }
    }
    // Insert missing attendance for new employee/date. Existing attendance is
    // manual data and should not be overwritten by production.
    if (newEmpId != null && newDate != null) {
      final normDate = DateTime.fromMillisecondsSinceEpoch(
          newDate is int ? newDate : (newDate as num).toInt());
      final dayStart = DateTime(normDate.year, normDate.month, normDate.day)
          .millisecondsSinceEpoch;
      final existing = await db.query('attendance',
          columns: ['id'],
          where: 'employee_id = ? AND date = ?',
          whereArgs: [newEmpId, dayStart],
          limit: 1);
      if (existing.isEmpty) {
        await _syncInsert('attendance', {
          'employee_id': newEmpId,
          'date': dayStart,
          'status': 'present',
          'shift': 'day',
          'remarks': 'Auto: Production',
        });
      }
    }
  }

  Future<void> deleteProductionEntry(int id) async {
    final db = await database;
    // Get the production entry to find employee_id and date
    final prod = await db.query('production_entries',
        where: 'id = ?', whereArgs: [id], limit: 1);
    int? empId;
    int? date;
    if (prod.isNotEmpty) {
      empId = prod.first['employee_id'] as int?;
      date = prod.first['date'] as int?;
    }
    await _syncDelete('production_entries', id);
    // After deleting, check if any other production exists for this employee/date
    if (empId != null && date != null) {
      await _deleteAutoProductionAttendanceIfNoProduction(db, empId, date);
    }
  }

  Future<void> deleteProductionEntriesByDate(int dateMs) async {
    final db = await database;
    final rows = await db.query('production_entries',
        columns: ['id'], where: 'date = ?', whereArgs: [dateMs]);
    final ids = rows.map((r) => r['id'] as int).toList();
    if (ids.isEmpty) return;

    final sync = FirebaseSyncService.instance;
    // Mark all as pending delete first to block listeners
    if (syncEnabled && sync.isInitialized) {
      for (final id in ids) {
        await sync.addPendingDelete('production_entries', id);
      }
    }
    // Delete from Firebase
    if (syncEnabled && sync.isInitialized) {
      for (final id in ids) {
        try {
          await sync.deleteRecord('production_entries', id);
        } catch (e) {
          debugPrint('âš  bulk delete Firebase (production_entries/$id): $e');
        }
      }
    }
    // Delete all from SQLite in one batch
    final placeholders = ids.map((_) => '?').join(',');
    // Also update attendance for these production entries
    final prodRows = await db.query('production_entries',
        columns: ['employee_id', 'date'],
        where: 'id IN ($placeholders)',
        whereArgs: ids);
    await db.delete('production_entries',
        where: 'id IN ($placeholders)', whereArgs: ids);
    for (final row in prodRows) {
      final empId = row['employee_id'];
      final date = row['date'];
      if (empId != null && date != null) {
        await _deleteAutoProductionAttendanceIfNoProduction(db, empId, date);
      }
    }
    dataVersion.value++;
    logActivity(
        action: 'DELETE',
        tableName: 'production_entries',
        recordId: ids.first,
        details: 'Bulk delete ${ids.length} entries for date $dateMs');
  }

  Future<void> deleteProductionEntriesByDateAndUnit(
      int dateMs, String unitName) async {
    final db = await database;
    final rows = await db.query('production_entries',
        columns: ['id'],
        where: 'date = ? AND unit_name = ?',
        whereArgs: [dateMs, unitName]);
    final ids = rows.map((r) => r['id'] as int).toList();
    if (ids.isEmpty) return;

    final sync = FirebaseSyncService.instance;
    // Mark all as pending delete first to block listeners
    if (syncEnabled && sync.isInitialized) {
      for (final id in ids) {
        await sync.addPendingDelete('production_entries', id);
      }
    }
    // Delete from Firebase
    if (syncEnabled && sync.isInitialized) {
      for (final id in ids) {
        try {
          await sync.deleteRecord('production_entries', id);
        } catch (e) {
          debugPrint('âš  bulk delete Firebase (production_entries/$id): $e');
        }
      }
    }
    // Delete all from SQLite in one batch
    final placeholders = ids.map((_) => '?').join(',');
    // Also update attendance for these production entries
    final prodRows = await db.query('production_entries',
        columns: ['employee_id', 'date'],
        where: 'id IN ($placeholders)',
        whereArgs: ids);
    await db.delete('production_entries',
        where: 'id IN ($placeholders)', whereArgs: ids);
    for (final row in prodRows) {
      final empId = row['employee_id'];
      final date = row['date'];
      if (empId != null && date != null) {
        await _deleteAutoProductionAttendanceIfNoProduction(db, empId, date);
      }
    }
    dataVersion.value++;
    logActivity(
        action: 'DELETE',
        tableName: 'production_entries',
        recordId: ids.first,
        details:
            'Bulk delete ${ids.length} entries for unit $unitName date $dateMs');
  }

  /// Get distinct employee IDs that have production entries in a date range
  Future<List<int>> getProductionEmployeeIds({
    required int fromMs,
    required int toMs,
  }) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT DISTINCT employee_id FROM production_entries
      WHERE date >= ? AND date < ? AND employee_id IS NOT NULL
    ''', [fromMs, toMs]);
    return rows.map((r) => (r['employee_id'] as num).toInt()).toList();
  }

  // ================= ATTENDANCE =================
  Future<List<Map<String, dynamic>>> getAttendance({
    int? dateMs,
    int? fromMs,
    int? toMs,
    int? employeeId,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <dynamic>[];

    if (dateMs != null) {
      where.add('a.date = ?');
      args.add(dateMs);
    }
    if (fromMs != null) {
      where.add('a.date >= ?');
      args.add(fromMs);
    }
    if (toMs != null) {
      where.add('a.date < ?');
      args.add(toMs);
    }
    if (employeeId != null) {
      where.add('a.employee_id = ?');
      args.add(employeeId);
    }

    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    return db.rawQuery('''
      SELECT a.*, e.name AS employee_name, e.designation
      FROM attendance a
      LEFT JOIN employees e ON e.id = a.employee_id
      $whereClause
      ORDER BY a.date DESC, e.name ASC
    ''', args);
  }

  Future<int> insertAttendance(Map<String, dynamic> data) async {
    return _syncInsert('attendance', data);
  }

  Future<void> updateAttendance(Map<String, dynamic> data, int id) async {
    await _syncUpdate('attendance', data, id);
  }

  Future<void> deleteAttendance(int id) async {
    await _syncDelete('attendance', id);
  }

  /// Attendance report: present/absent/half/double counts per employee for a month range.
  Future<List<Map<String, dynamic>>> getAttendanceReport({
    required int fromMs,
    required int toMs,
  }) async {
    final db = await database;
    return db.rawQuery('''
      SELECT
        e.id AS employee_id,
        e.name AS employee_name,
        e.designation,
        e.unit_name,
        SUM(CASE WHEN a.status = 'present' THEN 1 ELSE 0 END) AS present_days,
        SUM(CASE WHEN a.status = 'absent' THEN 1 ELSE 0 END) AS absent_days,
        SUM(CASE WHEN a.status = 'half_day' THEN 1 ELSE 0 END) AS half_days,
        SUM(CASE WHEN a.status = 'double' THEN 1 ELSE 0 END) AS double_days
      FROM employees e
      LEFT JOIN attendance a
        ON a.employee_id = e.id
        AND a.date >= ? AND a.date < ?
      WHERE e.status = 'active'
      GROUP BY e.id
      ORDER BY e.unit_name, e.designation, e.name
    ''', [fromMs, toMs]);
  }

  int _monthStartMs(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(d.year, d.month).millisecondsSinceEpoch;
  }

  int _nextMonthStartMs(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(d.year, d.month + 1).millisecondsSinceEpoch;
  }

  /// Bulk salary summary for ALL active employees in a date range.
  /// Uses only ~6 queries total instead of 5 per employee.
  Future<Map<int, Map<String, dynamic>>> getAllEmployeeSalarySummaries({
    required int fromMs,
    required int toMs,
  }) async {
    final db = await database;

    // 1. All active employees
    final empList = await db.query('employees',
        where: "status = 'active'", orderBy: 'name');

    // 2. All salary history records effective before or at fromMs (one per employee)
    final histRows = await db.rawQuery('''
      SELECT h.* FROM employee_salary_history h
      INNER JOIN (
        SELECT employee_id, MAX(effective_from) as max_ef
        FROM employee_salary_history
        WHERE effective_from <= ?
        GROUP BY employee_id
      ) latest ON h.employee_id = latest.employee_id
                AND h.effective_from = latest.max_ef
    ''', [fromMs]);
    final histMap = <int, Map<String, dynamic>>{};
    for (final h in histRows) {
      histMap[(h['employee_id'] as int)] = h;
    }

    // 3. Auto-generate attendance for production employees who have no attendance
    //    This ensures payroll counts them even if attendance page was never opened.
    final prodDates = await db.rawQuery('''
      SELECT DISTINCT employee_id, date FROM production_entries
      WHERE date >= ? AND date < ? AND employee_id IS NOT NULL
    ''', [fromMs, toMs]);
    for (final row in prodDates) {
      final empId = row['employee_id'] as int;
      final date = row['date'] as int;
      final existing = await db.query('attendance',
          columns: ['id'],
          where: 'employee_id = ? AND date = ?',
          whereArgs: [empId, date],
          limit: 1);
      if (existing.isEmpty) {
        await _syncInsert('attendance', {
          'employee_id': empId,
          'date': date,
          'status': 'present',
          'shift': 'day',
          'remarks': 'Auto: Production',
        });
      }
    }
    // dataVersion already bumped by _syncInsert for each record

    // 4. Attendance counts grouped by employee
    final attRows = await db.rawQuery('''
      SELECT employee_id, status, shift, COUNT(*) as cnt
      FROM attendance
      WHERE date >= ? AND date < ?
      GROUP BY employee_id, status, shift
    ''', [fromMs, toMs]);
    final attMap = <int, Map<String, int>>{};
    for (final r in attRows) {
      final eid = r['employee_id'] as int;
      final status = (r['status'] ?? '').toString();
      final shift = (r['shift'] ?? '').toString();
      final cnt = (r['cnt'] as int?) ?? 0;
      attMap.putIfAbsent(
          eid,
          () => {
                'present': 0,
                'half_day': 0,
                'absent': 0,
                'double': 0,
                'night': 0,
              });
      final m = attMap[eid]!;
      if (status == 'present') {
        m['present'] = (m['present'] ?? 0) + cnt;
        if (shift == 'night') m['night'] = (m['night'] ?? 0) + cnt;
      } else if (status == 'half_day') {
        m['half_day'] = (m['half_day'] ?? 0) + cnt;
      } else if (status == 'absent') {
        m['absent'] = (m['absent'] ?? 0) + cnt;
      } else if (status == 'double') {
        m['double'] = (m['double'] ?? 0) + cnt;
        if (shift == 'night') m['night'] = (m['night'] ?? 0) + cnt;
      }
    }

    // 4. Production totals grouped by employee
    final prodRows = await db.rawQuery('''
      SELECT employee_id,
        COALESCE(SUM(stitch), 0) as total_stitch,
        COALESCE(SUM(bonus), 0) as total_bonus,
        COALESCE(SUM(incentive_bonus), 0) as total_incentive,
        COALESCE(SUM(total_bonus), 0) as total_all_bonus
      FROM production_entries
      WHERE date >= ? AND date < ?
      GROUP BY employee_id
    ''', [fromMs, toMs]);
    final prodMap = <int, Map<String, dynamic>>{};
    for (final r in prodRows) {
      prodMap[(r['employee_id'] as int)] = r;
    }

    // 5. Advance totals grouped by employee.
    // Use explicit payroll month assignment (`for_month`) when available.
    final advFromMonth = _monthStartMs(fromMs);
    final advToMonthExclusive =
        _nextMonthStartMs(toMs > fromMs ? toMs - 1 : fromMs);
    final advRows = await db.rawQuery('''
      SELECT employee_id, COALESCE(SUM(amount), 0) as total_advance
      FROM salary_advances
      WHERE (
        (for_month IS NOT NULL AND for_month > 0 AND for_month >= ? AND for_month < ?)
        OR
        ((for_month IS NULL OR for_month <= 0) AND date >= ? AND date < ?)
      )
      GROUP BY employee_id
    ''', [advFromMonth, advToMonthExclusive, fromMs, toMs]);
    final advMap = <int, double>{};
    for (final r in advRows) {
      advMap[(r['employee_id'] as int)] =
          (r['total_advance'] as num?)?.toDouble() ?? 0;
    }

    // Build result map
    final result = <int, Map<String, dynamic>>{};
    for (final emp in empList) {
      final eid = emp['id'] as int;

      final hist = histMap[eid];
      final double basePay;
      final String salaryType;
      final int salaryBaseDays;
      if (hist != null) {
        basePay = (hist['base_pay'] as num?)?.toDouble() ?? 0;
        salaryType = (hist['salary_type'] ?? 'monthly').toString();
        salaryBaseDays = (hist['salary_base_days'] as num?)?.toInt() ?? 30;
      } else {
        basePay = (emp['base_pay'] as num?)?.toDouble() ?? 0;
        salaryType = (emp['salary_type'] ?? 'monthly').toString();
        salaryBaseDays = (emp['salary_base_days'] as num?)?.toInt() ?? 30;
      }

      final att = attMap[eid] ?? {};
      final presentDays = att['present'] ?? 0;
      final halfDays = att['half_day'] ?? 0;
      final absentDays = att['absent'] ?? 0;
      final doubleDays = att['double'] ?? 0;
      final nightShifts = att['night'] ?? 0;

      final effectiveDays = presentDays + (halfDays * 0.5) + (doubleDays * 2.0);
      final baseDays = salaryBaseDays > 0 ? salaryBaseDays : 30;

      double baseSalary = 0;
      if (salaryType == 'monthly') {
        // Proportional: (basePay / baseDays) * effectiveDays
        baseSalary = (basePay / baseDays) * effectiveDays;
      } else {
        // daily: basePay * effectiveDays
        baseSalary = basePay * effectiveDays;
      }

      final prod = prodMap[eid] ?? {};
      final totalBonus = (prod['total_all_bonus'] as num?)?.toDouble() ?? 0;
      final totalAdvance = advMap[eid] ?? 0;
      final netSalaryRaw = baseSalary + totalBonus - totalAdvance;
      final netSalary = (netSalaryRaw / 10).round() * 10.0;

      result[eid] = {
        'employee': emp,
        'present_days': presentDays,
        'half_days': halfDays,
        'absent_days': absentDays,
        'double_days': doubleDays,
        'night_shifts': nightShifts,
        'effective_days': effectiveDays,
        'base_pay': basePay,
        'salary_type': salaryType,
        'salary_base_days': baseDays,
        'base_salary': baseSalary,
        'total_stitch': (prod['total_stitch'] as num?)?.toInt() ?? 0,
        'total_bonus': (prod['total_bonus'] as num?)?.toDouble() ?? 0,
        'total_incentive': (prod['total_incentive'] as num?)?.toDouble() ?? 0,
        'total_all_bonus': totalBonus,
        'total_advance': totalAdvance,
        'net_salary': netSalary,
      };
    }
    return result;
  }

  /// Get salary summary for an employee in a date range
  ///
  /// Uses employee_salary_history to find the effective salary for the period.
  /// Falls back to the current employees.base_pay if no history exists.
  Future<Map<String, dynamic>> getEmployeeSalarySummary({
    required int employeeId,
    required int fromMs,
    required int toMs,
  }) async {
    final db = await database;

    // Employee info
    final empRows =
        await db.query('employees', where: 'id = ?', whereArgs: [employeeId]);
    final emp = empRows.isNotEmpty ? empRows.first : <String, dynamic>{};

    // Find effective salary for this period from salary history
    // Pick the history record whose effective_from is <= the start of the period
    // (most recent one before or at the period start)
    final histRows = await db.rawQuery('''
      SELECT * FROM employee_salary_history
      WHERE employee_id = ? AND effective_from <= ?
      ORDER BY effective_from DESC
      LIMIT 1
    ''', [employeeId, fromMs]);

    final double basePay;
    final String salaryType;
    final int salaryBaseDays;

    if (histRows.isNotEmpty) {
      final h = histRows.first;
      basePay = (h['base_pay'] as num?)?.toDouble() ?? 0;
      salaryType = (h['salary_type'] ?? 'monthly').toString();
      salaryBaseDays = (h['salary_base_days'] as num?)?.toInt() ?? 30;
    } else {
      basePay = (emp['base_pay'] as num?)?.toDouble() ?? 0;
      salaryType = (emp['salary_type'] ?? 'monthly').toString();
      salaryBaseDays = (emp['salary_base_days'] as num?)?.toInt() ?? 30;
    }

    // Auto-generate attendance from production entries for this employee
    // to keep single-employee summary consistent with bulk payroll summary.
    final prodDates = await db.rawQuery('''
      SELECT DISTINCT date FROM production_entries
      WHERE employee_id = ? AND date >= ? AND date < ?
    ''', [employeeId, fromMs, toMs]);
    for (final row in prodDates) {
      final date = row['date'] as int?;
      if (date == null) continue;
      final existing = await db.query(
        'attendance',
        columns: ['id'],
        where: 'employee_id = ? AND date = ?',
        whereArgs: [employeeId, date],
        limit: 1,
      );
      if (existing.isEmpty) {
        await _syncInsert('attendance', {
          'employee_id': employeeId,
          'date': date,
          'status': 'present',
          'shift': 'day',
          'remarks': 'Auto: Production',
        });
      }
    }

    // Attendance counts
    final attRows = await db.rawQuery('''
      SELECT status, shift, COUNT(*) as cnt
      FROM attendance
      WHERE employee_id = ? AND date >= ? AND date < ?
      GROUP BY status, shift
    ''', [employeeId, fromMs, toMs]);

    int presentDays = 0;
    int halfDays = 0;
    int absentDays = 0;
    int doubleDays = 0;
    int nightShifts = 0;

    for (final r in attRows) {
      final status = (r['status'] ?? '').toString();
      final shift = (r['shift'] ?? '').toString();
      final cnt = (r['cnt'] as int?) ?? 0;
      if (status == 'present') {
        presentDays += cnt;
        if (shift == 'night') nightShifts += cnt;
      } else if (status == 'half_day') {
        halfDays += cnt;
      } else if (status == 'absent') {
        absentDays += cnt;
      } else if (status == 'double') {
        doubleDays += cnt;
        if (shift == 'night') nightShifts += cnt;
      }
    }

    // Production bonus totals
    final prodRows = await db.rawQuery('''
      SELECT
        COALESCE(SUM(stitch), 0) as total_stitch,
        COALESCE(SUM(bonus), 0) as total_bonus,
        COALESCE(SUM(incentive_bonus), 0) as total_incentive,
        COALESCE(SUM(total_bonus), 0) as total_all_bonus
      FROM production_entries
      WHERE employee_id = ? AND date >= ? AND date < ?
    ''', [employeeId, fromMs, toMs]);

    final prod = prodRows.isNotEmpty ? prodRows.first : <String, dynamic>{};

    // Effective working days: present + half*0.5 + double*2
    final effectiveDays = presentDays + (halfDays * 0.5) + (doubleDays * 2.0);

    final int baseDays = salaryBaseDays > 0 ? salaryBaseDays : 30;

    double baseSalary = 0;
    if (salaryType == 'monthly') {
      // Proportional: (basePay / baseDays) * effectiveDays
      baseSalary = (basePay / baseDays) * effectiveDays;
    } else {
      // daily: basePay * effectiveDays
      baseSalary = basePay * effectiveDays;
    }

    final totalBonus = (prod['total_all_bonus'] as num?)?.toDouble() ?? 0;

    // Advance total:
    // - Prefer the mapped payroll month (`for_month`)
    // - Fallback to old date-based behavior for legacy rows
    final advFromMonth = _monthStartMs(fromMs);
    final advToMonthExclusive =
        _nextMonthStartMs(toMs > fromMs ? toMs - 1 : fromMs);
    final advRows = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total_advance
      FROM salary_advances
      WHERE employee_id = ?
        AND (
          (for_month IS NOT NULL AND for_month > 0 AND for_month >= ? AND for_month < ?)
          OR
          ((for_month IS NULL OR for_month <= 0) AND date >= ? AND date < ?)
        )
    ''', [employeeId, advFromMonth, advToMonthExclusive, fromMs, toMs]);
    final totalAdvance =
        (advRows.isNotEmpty ? advRows.first['total_advance'] as num? : null)
                ?.toDouble() ??
            0;

    final netSalaryRaw = baseSalary + totalBonus - totalAdvance;
    // Round to nearest 10 (0-4 down, 5-9 up)
    final netSalary = (netSalaryRaw / 10).round() * 10.0;

    return {
      'employee': emp,
      'present_days': presentDays,
      'half_days': halfDays,
      'absent_days': absentDays,
      'double_days': doubleDays,
      'night_shifts': nightShifts,
      'effective_days': effectiveDays,
      'base_pay': basePay,
      'salary_type': salaryType,
      'salary_base_days': baseDays,
      'base_salary': baseSalary,
      'total_stitch': (prod['total_stitch'] as num?)?.toInt() ?? 0,
      'total_bonus': (prod['total_bonus'] as num?)?.toDouble() ?? 0,
      'total_incentive': (prod['total_incentive'] as num?)?.toDouble() ?? 0,
      'total_all_bonus': totalBonus,
      'total_advance': totalAdvance,
      'net_salary': netSalary,
    };
  }

  // ================= SALARY HISTORY =================
  Future<List<Map<String, dynamic>>> getEmployeeSalaryHistory(
      int employeeId) async {
    final db = await database;
    return db.query('employee_salary_history',
        where: 'employee_id = ?',
        whereArgs: [employeeId],
        orderBy: 'effective_from DESC');
  }

  Future<int> insertSalaryHistory(Map<String, dynamic> data) async {
    return _syncInsert('employee_salary_history', data);
  }

  Future<void> deleteSalaryHistory(int id) async {
    await _syncDelete('employee_salary_history', id);
  }

  // ================= SALARY ADVANCES =================
  Future<List<Map<String, dynamic>>> getSalaryAdvances({
    int? employeeId,
    int? fromMs,
    int? toMs,
    int? forMonthMs,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <dynamic>[];
    if (employeeId != null) {
      where.add('sa.employee_id = ?');
      args.add(employeeId);
    }
    if (fromMs != null) {
      where.add('sa.date >= ?');
      args.add(fromMs);
    }
    if (toMs != null) {
      where.add('sa.date < ?');
      args.add(toMs);
    }
    if (forMonthMs != null) {
      final toMonthMs = _nextMonthStartMs(forMonthMs);
      where.add('('
          '(sa.for_month IS NOT NULL AND sa.for_month > 0 AND sa.for_month = ?)'
          ' OR '
          '((sa.for_month IS NULL OR sa.for_month <= 0) AND sa.date >= ? AND sa.date < ?)'
          ')');
      args.add(forMonthMs);
      args.add(forMonthMs);
      args.add(toMonthMs);
    }
    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    return db.rawQuery('''
      SELECT sa.*, e.name AS employee_name, e.designation, e.unit_name
      FROM salary_advances sa
      LEFT JOIN employees e ON e.id = sa.employee_id
      $whereClause
      ORDER BY sa.date DESC, e.name ASC
    ''', args);
  }

  Future<int> insertSalaryAdvance(Map<String, dynamic> data) async {
    final row = Map<String, dynamic>.from(data);
    final forMonth = (row['for_month'] as num?)?.toInt() ?? 0;
    if (forMonth <= 0) {
      final dateMs = (row['date'] as num?)?.toInt() ?? 0;
      if (dateMs > 0) {
        row['for_month'] = _monthStartMs(dateMs);
      }
    }
    return _syncInsert('salary_advances', row);
  }

  Future<void> updateSalaryAdvance(Map<String, dynamic> data, int id) async {
    final row = Map<String, dynamic>.from(data);
    final forMonth = (row['for_month'] as num?)?.toInt() ?? 0;
    if (forMonth <= 0) {
      final dateMs = (row['date'] as num?)?.toInt() ?? 0;
      if (dateMs > 0) {
        row['for_month'] = _monthStartMs(dateMs);
      }
    }
    await _syncUpdate('salary_advances', row, id);
  }

  Future<void> deleteSalaryAdvance(int id) async {
    await _syncDelete('salary_advances', id);
  }

  // ================= SALARY PAYMENTS =================
  Future<List<Map<String, dynamic>>> getSalaryPayments({
    int? employeeId,
    int? fromMs,
    int? toMs,
    int? salaryMonthMs,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <dynamic>[];
    if (employeeId != null) {
      where.add('sp.employee_id = ?');
      args.add(employeeId);
    }
    if (fromMs != null) {
      where.add('sp.date >= ?');
      args.add(fromMs);
    }
    if (toMs != null) {
      where.add('sp.date < ?');
      args.add(toMs);
    }
    if (salaryMonthMs != null) {
      final monthEndExclusive = _nextMonthStartMs(salaryMonthMs);
      where.add('('
          '(sp.from_date IS NOT NULL AND sp.from_date > 0 AND sp.from_date = ?)'
          ' OR '
          '((sp.from_date IS NULL OR sp.from_date <= 0) AND sp.date >= ? AND sp.date < ?)'
          ')');
      args.add(salaryMonthMs);
      args.add(salaryMonthMs);
      args.add(monthEndExclusive);
    }
    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    return db.rawQuery('''
      SELECT sp.*, e.name AS employee_name, e.designation, e.unit_name
      FROM salary_payments sp
      LEFT JOIN employees e ON e.id = sp.employee_id
      $whereClause
      ORDER BY sp.date DESC, e.name ASC
    ''', args);
  }

  Future<int> insertSalaryPayment(Map<String, dynamic> data) async {
    return _syncInsert('salary_payments', data);
  }

  Future<void> updateSalaryPayment(Map<String, dynamic> data, int id) async {
    await _syncUpdate('salary_payments', data, id);
  }

  Future<void> deleteSalaryPayment(int id) async {
    await _syncDelete('salary_payments', id);
  }

  // ================= SAVED PAYROLL =================
  Future<int> insertSavedPayroll(Map<String, dynamic> data) async {
    return _syncInsert('saved_payroll', data);
  }

  Future<void> deleteSavedPayroll(int id) async {
    await _syncDelete('saved_payroll', id);
  }

  /// Delete all saved payroll for a given period
  Future<void> deleteSavedPayrollForPeriod(int fromMs, int toMs) async {
    final db = await database;
    final rows = await db.query('saved_payroll',
        columns: ['id'],
        where: 'from_date = ? AND to_date = ?',
        whereArgs: [fromMs, toMs]);
    for (final row in rows) {
      await _syncDelete('saved_payroll', row['id'] as int);
    }
  }

  /// Get saved payroll rows for a period, optionally for one employee
  Future<List<Map<String, dynamic>>> getSavedPayroll({
    required int fromMs,
    required int toMs,
    int? employeeId,
  }) async {
    final db = await database;
    final where = <String>['sp.from_date = ?', 'sp.to_date = ?'];
    final args = <dynamic>[fromMs, toMs];
    if (employeeId != null) {
      where.add('sp.employee_id = ?');
      args.add(employeeId);
    }
    return db.rawQuery('''
      SELECT sp.*, e.name AS employee_name, e.designation, e.unit_name
      FROM saved_payroll sp
      LEFT JOIN employees e ON e.id = sp.employee_id
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY e.unit_name ASC, e.designation ASC, e.name ASC
    ''', args);
  }

  /// Check if payroll is saved for this period
  Future<bool> isPayrollSaved(int fromMs, int toMs) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM saved_payroll WHERE from_date = ? AND to_date = ?',
      [fromMs, toMs],
    );
    return (rows.first['cnt'] as int? ?? 0) > 0;
  }
}

class _DebouncedIntNotifier extends ChangeNotifier
    implements ValueListenable<int> {
  _DebouncedIntNotifier(this._value);

  static const Duration _delay = Duration(milliseconds: 120);
  int _value;
  Timer? _timer;
  bool _disposed = false;

  @override
  int get value => _value;

  set value(int newValue) {
    _value = newValue;
    _timer?.cancel();
    _timer = Timer(_delay, () {
      if (_disposed) return;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Cleanup duplicate attendance records: keep only the latest per employee per day.
extension AttendanceCleanup on ErpDatabase {
  Future<void> cleanupDuplicateAttendance() async {
    final db = await database;
    // Find duplicates (employee_id, date) with more than one record
    final dups = await db.rawQuery('''
      SELECT employee_id, date, COUNT(*) as cnt
      FROM attendance
      GROUP BY employee_id, date
      HAVING cnt > 1
    ''');
    for (final dup in dups) {
      final empId = dup['employee_id'];
      final date = dup['date'];
      // Get all ids for this employee/date, order by id DESC (keep latest)
      final rows = await db.query(
        'attendance',
        columns: ['id'],
        where: 'employee_id = ? AND date = ?',
        whereArgs: [empId, date],
        orderBy: 'id DESC',
      );
      if (rows.length > 1) {
        // Keep the first (latest), delete the rest
        final idsToDelete = rows.skip(1).map((r) => r['id']).toList();
        for (final id in idsToDelete) {
          await db.delete('attendance', where: 'id = ?', whereArgs: [id]);
        }
      }
    }
  }

  /// Add a unique index to enforce one attendance per employee per day.
  Future<void> ensureAttendanceUniqueIndex() async {
    final db = await database;
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_attendance_employee_date
      ON attendance(employee_id, date)
    ''');
  }
}
