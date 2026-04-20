

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

    /// Incremented after every insert/update/delete.
    /// Pages listen to this to auto-refresh their data.
    /// Debounced so rapid-fire changes don't cause continuous reloads.
    // Use ValueNotifier instead of _DebouncedNotifier if not defined
    final dataVersion = ValueNotifier<int>(0);

    ErpDatabase._init();

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
        version: 21,
        onCreate: (db, version) async {
          await _createDB(db, version);
          await _seedGstCategories(db);
        },
        onUpgrade: _upgradeDB,
      );

      // 🔥 ADD THIS LINE (VERY IMPORTANT)
      await _seedGstCategories(db);
      await _ensureAllTables(db);
      await _ensurePurchaseMasterReportingColumns(db);
      await _createIndexes(db);
      await _fixReqCloseRemarks(db);

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

  /// Update attendance for production entries since [sinceMs].
  /// Optionally restrict to a date range [from] to [to].
  Future<void> updateAttendanceFromProductionSince(int? sinceMs, {DateTime? from, DateTime? to}) async {
    // ...existing code...
    final db = await database;
    final cols = await db.rawQuery("PRAGMA table_info(stock_ledger)");
    final hasIsDeleted = cols.any((c) => c['name'] == 'is_deleted');
    if (!hasIsDeleted) {
      await db.execute("ALTER TABLE stock_ledger ADD COLUMN is_deleted INTEGER DEFAULT 0");
    }
    debugPrint('SYNC: updateAttendanceFromProductionSince called with sinceMs=[1m$sinceMs[22m, from=$from, to=$to');
    String where = 'employee_id IS NOT NULL AND date IS NOT NULL';
    List whereArgs = [];
    if (sinceMs != null) {
      where += ' AND date > ?';
      whereArgs.add(sinceMs);
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
    final prodRows = await db.query('production_entries',
      distinct: true,
      columns: ['employee_id', 'date'],
      where: where,
      whereArgs: whereArgs,
    );
    debugPrint('SYNC: Found ${prodRows.length} production entries to sync');

    // Optimization: Fetch all attendance records for the relevant dates in one query
    final empDates = prodRows.map((row) {
      final empId = row['employee_id'];
      final date = row['date'];
      if (empId == null || date == null) return null;
      final normDate = DateTime.fromMillisecondsSinceEpoch(date is int ? date : (date as num).toInt());
      final dayStart = DateTime(normDate.year, normDate.month, normDate.day).millisecondsSinceEpoch;
      return {'employee_id': empId, 'date': dayStart};
    }).whereType<Map<String, dynamic>>().toList();

    // Build a set of all (employee_id, date) pairs
    final empDateSet = empDates.map((e) => "${e['employee_id']}_${e['date']}").toSet();
    List<Map<String, dynamic>> existingAttendance = [];
    if (empDateSet.isNotEmpty) {
      final empIds = empDates.map((e) => e['employee_id']).toSet().toList();
      final minDate = empDates.map((e) => e['date'] as int).reduce((a, b) => a < b ? a : b);
      final maxDate = empDates.map((e) => e['date'] as int).reduce((a, b) => a > b ? a : b);
      existingAttendance = await db.query(
        'attendance',
        columns: ['id', 'employee_id', 'date'],
        where: 'employee_id IN (${List.filled(empIds.length, '?').join(',')}) AND date >= ? AND date <= ?',
        whereArgs: [...empIds, minDate, maxDate],
      );
    }
    // Build a map for quick lookup
    final Map<String, Map<String, dynamic>> attendanceMap = {
      for (var row in existingAttendance)
        "${row['employee_id']}_${row['date']}": row
    };

    // Batch insert/update in a transaction
    await db.transaction((txn) async {
      for (final row in prodRows) {
        final empId = row['employee_id'];
        final date = row['date'];
        if (empId == null || date == null) continue;
        final normDate = DateTime.fromMillisecondsSinceEpoch(date is int ? date : (date as num).toInt());
        final dayStart = DateTime(normDate.year, normDate.month, normDate.day).millisecondsSinceEpoch;
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
        } else {
          // Only update if needed (optional, can skip if always same)
          await txn.update('attendance', {
            'employee_id': empId,
            'date': dayStart,
            'status': 'present',
            'shift': 'day',
            'remarks': 'Auto: Production (update new)',
          }, where: 'id = ?', whereArgs: [existing['id']]);
        }
      }
    });
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
      final normDate = DateTime.fromMillisecondsSinceEpoch(date is int ? date : (date as num).toInt());
      final dayStart = DateTime(normDate.year, normDate.month, normDate.day).millisecondsSinceEpoch;
        debugPrint('SYNC: Employee $empId, Date $dayStart (${normDate.year}-${normDate.month}-${normDate.day})');
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
      } else {
        await _syncUpdate('attendance', {
          'employee_id': empId,
          'date': dayStart,
          'status': 'present',
          'shift': 'day',
          'remarks': 'Auto: Production (update all)',
        }, existing.first['id'] as int);
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
        final normDate = DateTime.fromMillisecondsSinceEpoch(date is int ? date : (date as num).toInt());
        final dayStart = DateTime(normDate.year, normDate.month, normDate.day).millisecondsSinceEpoch;
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
        } else {
          await _syncUpdate('attendance', {
            'status': 'present',
            'shift': 'day',
            'remarks': 'Auto: Production (sync)',
          }, existing.first['id'] as int);
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
        party_id INTEGER, gross_amount REAL, discount_amount REAL,
        cgst REAL, sgst REAL, igst REAL, total_amount REAL)''',
      '''CREATE TABLE IF NOT EXISTS purchase_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT, purchase_no INTEGER,
        product_id INTEGER, shade_id INTEGER, qty REAL, rate REAL,
        amount REAL)''',
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
        reference TEXT, remarks TEXT, is_deleted INTEGER DEFAULT 0
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
        debugPrint('⚠ _ensureAllTables: $e');
      }
    }

    // Ensure missing columns on existing tables
    const alterMap = {
      'employees': ['salary_base_days', 'unit_name'],
      'machines': ['incentive_amount', 'bonus'],
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
      is_deleted INTEGER DEFAULT 0
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
        WHERE reference = 'REQ-CLOSE'
          AND (remarks NOT LIKE '%Party:%' OR remarks LIKE '%Requirement closed%')
          AND (is_deleted IS NULL OR is_deleted = 0)
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

        await db.update('stock_ledger', {'remarks': newRemarks},
            where: 'id=?', whereArgs: [id]);
      }
      debugPrint('✅ Fixed ${rows.length} REQ-CLOSE remarks');
    } catch (e) {
      debugPrint('⚠ _fixReqCloseRemarks: $e');
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
          "UPDATE stock_ledger SET type = 'OUT' WHERE reference = 'REQ-CLOSE' AND UPPER(type) = 'IN'",
        );
      } catch (_) {}
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
      debugPrint('⚠ logActivity: $e');
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
      debugPrint('⚠ getActivityLogs: $e');
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

  Future<int> _syncInsert(String table, Map<String, dynamic> data) async {
    final db = await database;
    final sync = FirebaseSyncService.instance;
    int id;
    if (syncEnabled && sync.isInitialized) {
      int? firebaseId;
      try {
        firebaseId = await sync.getNextId(table);
      } catch (e) {
        debugPrint('⚠ _syncInsert getNextId ($table): $e');
        // No network — fall through to local-only insert
      }
      if (firebaseId != null) {
        id = firebaseId;
        data['id'] = id;
        try {
          await db.insert(table, data,
              conflictAlgorithm: ConflictAlgorithm.replace);
        } catch (e) {
          debugPrint('⚠ _syncInsert local insert ($table/$id): $e');
          // Local failed but we have a Firebase ID — still push to Firebase
          // so the data is at least saved remotely
          await sync.pushRecord(table, id, data);
          rethrow;
        }
        // pushRecord queues for retry internally if it fails
        await sync.pushRecord(table, id, data);
        dataVersion.value++;
        if (table != 'activity_log') {
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
    id = await db.insert(table, data);
    if (syncEnabled) {
      data['id'] = id;
      await sync.queuePush(table, id, data);
    }
    dataVersion.value++;
    if (table != 'activity_log') {
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
    // Local FIRST, then push to Firebase (if local fails, don't push stale data)
    data['id'] = id;
    await db.update(table, data, where: 'id=?', whereArgs: [id]);
    dataVersion.value++;
    final sync = FirebaseSyncService.instance;
    if (syncEnabled) {
      if (sync.isInitialized) {
        await sync.pushRecord(table, id, data);
      } else {
        await sync.queuePush(table, id, data);
      }
    }
    if (table != 'activity_log') {
      logActivity(
          action: 'UPDATE',
          tableName: table,
          recordId: id,
          details: _buildRowDetails(table, data));
    }
  }

  Future<void> _syncDelete(String table, int id) async {
    final db = await database;
    final sync = FirebaseSyncService.instance;

    // Capture row details BEFORE deleting so the activity log is meaningful
    String? deleteDetails;
    if (table != 'activity_log') {
      try {
        final rows = await db.query(table, where: 'id=?', whereArgs: [id]);
        if (rows.isNotEmpty) {
          deleteDetails = _buildRowDetails(table, rows.first);
        }
      } catch (_) {}
    }

    if (syncEnabled && sync.isInitialized) {
      // Mark as pending delete so real-time listeners
      // won't re-insert the record. Cleared by _onRemoteRemove.
      sync.addPendingDelete(table, id);
    }
    // Delete locally FIRST (ensures data is removed even if Firebase call fails)
    if (table == 'stock_ledger') {
      await db.update('stock_ledger', {'is_deleted': 1}, where: 'id=?', whereArgs: [id]);
    } else {
      await db.delete(table, where: 'id=?', whereArgs: [id]);
    }
    dataVersion.value++;
    // Then remove from Firebase
    if (syncEnabled && sync.isInitialized) {
      try {
        await sync.deleteRecord(table, id);
      } catch (e) {
        debugPrint('⚠ _syncDelete Firebase failed ( $table/$id): $e');
      }
    }
    if (table != 'activity_log') {
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
        return 'Attendance: Employee ID ${row['employee_id'] ?? ''}, Status: ${row['status'] ?? ''}';
      case 'challan_requirements':
        return 'Challan Req: Challan ${row['challan_no'] ?? ''}, Product ID: ${row['product_id'] ?? ''}, Qty: ${row['required_qty'] ?? ''}';
      case 'purchase_items':
        return 'Purchase: Product ID ${row['product_id'] ?? ''}, Qty: ${row['qty'] ?? ''}, Rate: ${row['rate'] ?? ''}';
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

  // ================= FABRIC / THREAD =================
  Future<List<Map<String, dynamic>>> getFabricShades() async =>
      (await database).query('fabric_shades');

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
      GROUP BY l.product_id, COALESCE(l.fabric_shade_id, 0)
      ORDER BY p.name, f.shade_no
    ''');
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
    final db = await database;
    // Soft delete: set is_deleted = 1
    await db.update('stock_ledger', {'is_deleted': 1}, where: 'id=?', whereArgs: [id]);
    // Sync to Firebase as deleted
    if (syncEnabled && FirebaseSyncService.instance.isInitialized) {
      try {
        await FirebaseSyncService.instance.pushRecord(
          'stock_ledger',
          id,
          {'is_deleted': 1},
        );
      } catch (e) {
        debugPrint('⚠ Failed to push soft delete for stock_ledger/ $id: $e');
      }
    }
    dataVersion.value++;
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
    final data = {
      'status': 'closed',
      'closed_date': DateTime.now().millisecondsSinceEpoch,
    };
    await _syncUpdate('challan_requirements', data, id);
  }

  Future<void> closeChallanRequirementsByChallan(String challanNo) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final updateData = {'status': 'closed', 'closed_date': now};

    // Find affected rows so we can sync each one
    final affected = await db.query(
      'challan_requirements',
      where: "challan_no = ? AND status = 'pending'",
      whereArgs: [challanNo],
    );

    if (affected.isEmpty) return;

    await db.update(
      'challan_requirements',
      updateData,
      where: "challan_no = ? AND status = 'pending'",
      whereArgs: [challanNo],
    );

    dataVersion.value++;

    // Push each affected row to Firebase
    final sync = FirebaseSyncService.instance;
    if (syncEnabled && sync.isInitialized && !sync.isSyncing) {
      for (final row in affected) {
        final id = row['id'] as int?;
        if (id == null) continue;
        final fullRow = Map<String, dynamic>.from(row);
        fullRow.addAll(updateData);
        await sync.pushRecord('challan_requirements', id, fullRow);
      }
    }

    logActivity(
        action: 'UPDATE',
        tableName: 'challan_requirements',
        details: 'Batch close challan $challanNo (${affected.length} rows)');
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


  Future<int> insertProductionEntry(Map<String, dynamic> data) async {
    final db = await database;
    final id = await _syncInsert('production_entries', data);
    // Insert or update attendance for this employee/date
    final empId = data['employee_id'];
    final date = data['date'];
    if (empId != null && date != null) {
      // Normalize date to start of day
      final normDate = DateTime.fromMillisecondsSinceEpoch(date);
      final dayStart = DateTime(normDate.year, normDate.month, normDate.day).millisecondsSinceEpoch;
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
      } else {
        await _syncUpdate('attendance', {
          'status': 'present',
          'shift': 'day',
          'remarks': 'Auto: Production',
        }, existing.first['id'] as int);
      }
    }
    return id;
  }

  Future<void> updateProductionEntry(Map<String, dynamic> data, int id) async {
    final db = await database;
    // Get the old production entry to check if employee/date changed
    final oldProd = await db.query('production_entries', where: 'id = ?', whereArgs: [id], limit: 1);
    await _syncUpdate('production_entries', data, id);
    final newEmpId = data['employee_id'];
    final newDate = data['date'];
    if (oldProd.isNotEmpty) {
      final oldEmpId = oldProd.first['employee_id'];
      final oldDate = oldProd.first['date'];
      // If employee or date changed, remove old attendance
      if ((oldEmpId != newEmpId || oldDate != newDate) && oldEmpId != null && oldDate != null) {
        await db.delete('attendance', where: 'employee_id = ? AND date = ?', whereArgs: [oldEmpId, oldDate]);
      }
    }
    // Insert or update attendance for new employee/date
    if (newEmpId != null && newDate != null) {
      final existing = await db.query('attendance',
        columns: ['id'],
        where: 'employee_id = ? AND date = ?',
        whereArgs: [newEmpId, newDate],
        limit: 1);
      if (existing.isEmpty) {
        await _syncInsert('attendance', {
          'employee_id': newEmpId,
          'date': newDate,
          'status': 'present',
          'shift': 'day',
          'remarks': 'Auto: Production',
        });
      } else {
        await _syncUpdate('attendance', {
          'status': 'present',
          'shift': 'day',
          'remarks': 'Auto: Production',
        }, existing.first['id'] as int);
      }
    }
  }

  Future<void> deleteProductionEntry(int id) async {
    final db = await database;
    // Get the production entry to find employee_id and date
    final prod = await db.query('production_entries', where: 'id = ?', whereArgs: [id], limit: 1);
    int? empId;
    int? date;
    if (prod.isNotEmpty) {
      empId = prod.first['employee_id'] as int?;
      date = prod.first['date'] as int?;
    }
    await _syncDelete('production_entries', id);
    // After deleting, check if any other production exists for this employee/date
    if (empId != null && date != null) {
      final otherProd = await db.query('production_entries',
        where: 'employee_id = ? AND date = ?',
        whereArgs: [empId, date],
        limit: 1);
      if (otherProd.isEmpty) {
        // Set attendance to absent (if exists)
        final attRows = await db.query('attendance',
          columns: ['id'],
          where: 'employee_id = ? AND date = ?',
          whereArgs: [empId, date],
          limit: 1);
        if (attRows.isNotEmpty) {
          await _syncUpdate('attendance', {
            'status': 'absent',
            'shift': 'day',
            'remarks': 'Auto: No Production',
          }, attRows.first['id'] as int);
        }
      }
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
        sync.addPendingDelete('production_entries', id);
      }
    }
    // Delete from Firebase
    if (syncEnabled && sync.isInitialized) {
      for (final id in ids) {
        try {
          await sync.deleteRecord('production_entries', id);
        } catch (e) {
          debugPrint('⚠ bulk delete Firebase (production_entries/$id): $e');
        }
      }
    }
    // Delete all from SQLite in one batch
    final placeholders = ids.map((_) => '?').join(',');
    // Also update attendance for these production entries
    final prodRows = await db.query('production_entries', columns: ['employee_id', 'date'], where: 'id IN ($placeholders)', whereArgs: ids);
    await db.delete('production_entries', where: 'id IN ($placeholders)', whereArgs: ids);
    for (final row in prodRows) {
      final empId = row['employee_id'];
      final date = row['date'];
      if (empId != null && date != null) {
        // Check if any other production exists for this employee/date
        final otherProd = await db.query('production_entries',
          where: 'employee_id = ? AND date = ?',
          whereArgs: [empId, date],
          limit: 1);
        if (otherProd.isEmpty) {
          // Set attendance to absent (if exists)
          final attRows = await db.query('attendance',
            columns: ['id'],
            where: 'employee_id = ? AND date = ?',
            whereArgs: [empId, date],
            limit: 1);
          if (attRows.isNotEmpty) {
            await _syncUpdate('attendance', {
              'status': 'absent',
              'shift': 'day',
              'remarks': 'Auto: No Production',
            }, attRows.first['id'] as int);
          }
        }
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
        sync.addPendingDelete('production_entries', id);
      }
    }
    // Delete from Firebase
    if (syncEnabled && sync.isInitialized) {
      for (final id in ids) {
        try {
          await sync.deleteRecord('production_entries', id);
        } catch (e) {
          debugPrint('⚠ bulk delete Firebase (production_entries/$id): $e');
        }
      }
    }
    // Delete all from SQLite in one batch
    final placeholders = ids.map((_) => '?').join(',');
    // Also update attendance for these production entries
    final prodRows = await db.query('production_entries', columns: ['employee_id', 'date'], where: 'id IN ($placeholders)', whereArgs: ids);
    await db.delete('production_entries', where: 'id IN ($placeholders)', whereArgs: ids);
    for (final row in prodRows) {
      final empId = row['employee_id'];
      final date = row['date'];
      if (empId != null && date != null) {
        // Check if any other production exists for this employee/date
        final otherProd = await db.query('production_entries',
          where: 'employee_id = ? AND date = ?',
          whereArgs: [empId, date],
          limit: 1);
        if (otherProd.isEmpty) {
          // Set attendance to absent (if exists)
          final attRows = await db.query('attendance',
            columns: ['id'],
            where: 'employee_id = ? AND date = ?',
            whereArgs: [empId, date],
            limit: 1);
          if (attRows.isNotEmpty) {
            await _syncUpdate('attendance', {
              'status': 'absent',
              'shift': 'day',
              'remarks': 'Auto: No Production',
            }, attRows.first['id'] as int);
          }
        }
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
    bool autoInserted = false;
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
        autoInserted = true;
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

    // 5. Advance totals grouped by employee (till end of period)
    final advRows = await db.rawQuery('''
      SELECT employee_id, COALESCE(SUM(amount), 0) as total_advance
      FROM salary_advances
      WHERE date <= ?
      GROUP BY employee_id
    ''', [toMs]);
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

    // Advance total till end-of-period
    final advRows = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total_advance
      FROM salary_advances
      WHERE employee_id = ? AND date <= ?
    ''', [employeeId, toMs]);
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
    return _syncInsert('salary_advances', data);
  }

  Future<void> updateSalaryAdvance(Map<String, dynamic> data, int id) async {
    await _syncUpdate('salary_advances', data, id);
  }

  Future<void> deleteSalaryAdvance(int id) async {
    await _syncDelete('salary_advances', id);
  }

  // ================= SALARY PAYMENTS =================
  Future<List<Map<String, dynamic>>> getSalaryPayments({
    int? employeeId,
    int? fromMs,
    int? toMs,
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
      final rows = await db.query('attendance',
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
