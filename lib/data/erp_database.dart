import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../models/product.dart';
import '../models/party.dart';
import 'firebase_sync_service.dart';

class ErpDatabase {
  static final ErpDatabase instance = ErpDatabase._init();
  static Database? _db;

  /// Incremented after every insert/update/delete.
  /// Pages listen to this to auto-refresh their data.
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
      version: 8,
      onCreate: (db, version) async {
        await _createDB(db, version);
        await _seedGstCategories(db);
      },
      onUpgrade: _upgradeDB,
    );

    // 🔥 ADD THIS LINE (VERY IMPORTANT)
    await _seedGstCategories(db);
    await _ensurePurchaseMasterReportingColumns(db);
    await _ensureChallanRequirementsTable(db);

    return db;
  }

  Future<void> _ensureChallanRequirementsTable(Database db) async {
    try {
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
    } catch (_) {}
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
      status TEXT
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
      remarks TEXT
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
  }

  // ================= SYNC HELPERS =================
  Future<int> _syncInsert(String table, Map<String, dynamic> data) async {
    final db = await database;
    final sync = FirebaseSyncService.instance;
    int id;
    if (sync.isInitialized && !sync.isSyncing) {
      try {
        id = await sync.getNextId(table);
        data['id'] = id;
        await db.insert(table, data,
            conflictAlgorithm: ConflictAlgorithm.replace);
        await sync.pushRecord(table, id, data);
        dataVersion.value++;
        return id;
      } catch (e) {
        debugPrint('⚠ _syncInsert ($table): $e');
      }
    }
    data.remove('id');
    id = await db.insert(table, data);
    dataVersion.value++;
    return id;
  }

  Future<void> _syncUpdate(
      String table, Map<String, dynamic> data, int id) async {
    final db = await database;
    await db.update(table, data, where: 'id=?', whereArgs: [id]);
    final sync = FirebaseSyncService.instance;
    if (sync.isInitialized && !sync.isSyncing) {
      data['id'] = id;
      await sync.pushRecord(table, id, data);
    }
    dataVersion.value++;
  }

  Future<void> _syncDelete(String table, int id) async {
    final db = await database;
    await db.delete(table, where: 'id=?', whereArgs: [id]);
    final sync = FirebaseSyncService.instance;
    if (sync.isInitialized && !sync.isSyncing) {
      await sync.deleteRecord(table, id);
    }
    dataVersion.value++;
  }

  // ================= PRODUCTS =================
  Future<List<Product>> getProducts() async =>
      (await database).query('products').then(
            (r) => r.map((e) => Product.fromMap(e)).toList(),
          );

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
  Future<List<Party>> getParties() async =>
      (await database).query('parties').then(
            (r) => r.map((e) => Party.fromMap(e)).toList(),
          );

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
      (await database).insert('program_master', data);

  Future<void> deleteProgram(int programNo) async {
    final db = await database;
    await db.delete('program_master',
        where: 'program_no=?', whereArgs: [programNo]);
    await db.delete('program_fabrics',
        where: 'program_no=?', whereArgs: [programNo]);
    await db.delete('program_thread_shades',
        where: 'program_no=?', whereArgs: [programNo]);
  }

  Future<void> insertProgramFabric(
          int programNo, int shadeId, double qty) async =>
      (await database).insert('program_fabrics',
          {'program_no': programNo, 'fabric_shade_id': shadeId, 'qty': qty});

  Future<void> insertProgramThreadShade(int programNo, int shadeId) async =>
      (await database).insert('program_thread_shades',
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
        GROUP BY l.product_id, COALESCE(l.fabric_shade_id, 0)
      ) x
      WHERE x.balance < 0
      ORDER BY x.product_name, x.shade_no
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

  Future<void> updateProgramStatus(int programNo, String status) async =>
      (await database).update(
        'program_master',
        {'status': status},
        where: 'program_no=?',
        whereArgs: [programNo],
      );

  Future<void> allotMachine(
          {required int programNo, required int machineId}) async =>
      (await database).insert('program_allotment', {
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

  Future<void> updateAllotmentStatus(int programNo, String status) async =>
      (await database).update('program_allotment', {'status': status},
          where: 'program_no=?', whereArgs: [programNo]);

  Future<void> logProgramActivity(Map<String, dynamic> log) async =>
      (await database).insert('program_logs', {
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

  Future<void> updateFabricShade(int id, {
    required String shadeNo,
    required String shadeName,
    String? imagePath,
  }) async {
    await _syncUpdate('fabric_shades', {
      'shade_no': shadeNo,
      'shade_name': shadeName,
      'image_path': imagePath,
    }, id);
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
      await _ensureChallanRequirementsTable(db);
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
    await _ensureChallanRequirementsTable(db);
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

    await db.update(
      'challan_requirements',
      updateData,
      where: "challan_no = ? AND status = 'pending'",
      whereArgs: [challanNo],
    );

    // Push each affected row to Firebase
    final sync = FirebaseSyncService.instance;
    if (sync.isInitialized && !sync.isSyncing) {
      for (final row in affected) {
        final id = row['id'] as int?;
        if (id == null) continue;
        final fullRow = Map<String, dynamic>.from(row);
        fullRow.addAll(updateData);
        await sync.pushRecord('challan_requirements', id, fullRow);
      }
    }
  }
}
