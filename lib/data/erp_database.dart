import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../models/product.dart';
import '../models/party.dart';
import '../models/stock_ledger.dart';

class ErpDatabase {
  static final ErpDatabase instance = ErpDatabase._init();
  static Database? _database;

  ErpDatabase._init();

  // ================= DATABASE INSTANCE =================
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'erp.db');

    return openDatabase(
      path,
      version: 6, // 🔥 IMPORTANT: increase version
      onCreate: _createDB,
      onUpgrade: _upgradeDB, // ✅ FIXED
    );
  }

  // ================= CREATE TABLES =================
  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
    CREATE TABLE IF NOT EXISTS products (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      category TEXT NOT NULL,
      unit TEXT NOT NULL,
      min_stock REAL NOT NULL
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS parties (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      address TEXT,
      contact TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS stock_ledger (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      product_id INTEGER NOT NULL,
      type TEXT NOT NULL,
      qty REAL NOT NULL,
      date INTEGER NOT NULL,
      reference TEXT,
      remarks TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS machines (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      machine_code TEXT NOT NULL,
      machine_type TEXT NOT NULL,
      status TEXT NOT NULL
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS fabric_shades (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      product_id INTEGER NOT NULL,
      shade_name TEXT NOT NULL,
      image_path TEXT
    )
    ''');

    // ✅ FIXED THREAD SHADES TABLE
    await db.execute('''
    CREATE TABLE IF NOT EXISTS thread_shades (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      shade_no TEXT NOT NULL,
      quality TEXT NOT NULL,
      image_path TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS program_master (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      program_no INTEGER NOT NULL UNIQUE,
      program_date INTEGER NOT NULL,
      party_id INTEGER NOT NULL,
      card_no TEXT NOT NULL,
      design_no TEXT NOT NULL,
      designer TEXT NOT NULL,
      fabric_shade TEXT NOT NULL,
      planned_qty REAL NOT NULL,
      status TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS program_thread_shades (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      program_no INTEGER NOT NULL,
      shade TEXT NOT NULL
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS program_allotment (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      program_no INTEGER NOT NULL,
      machine_id INTEGER NOT NULL,
      status TEXT NOT NULL,
      start_time INTEGER
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS program_activity_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      program_no INTEGER NOT NULL,
      machine_id INTEGER NOT NULL,
      status TEXT NOT NULL,
      reason TEXT,
      timestamp INTEGER NOT NULL
    )
    ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS delay_reasons (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      reason TEXT NOT NULL
    )
    ''');
  }

  // ================= DB UPGRADE (CRITICAL FIX) =================
  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 6) {
      // 🔥 FORCE DROP OLD STRUCTURE
      await db.execute('DROP TABLE IF EXISTS thread_shades');

      // 🔥 RECREATE WITH CORRECT COLUMNS
      await db.execute('''
        CREATE TABLE thread_shades (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          shade_no TEXT NOT NULL,
          quality TEXT NOT NULL,
          image_path TEXT
        )
      ''');
    }
  }

  // ================= PRODUCT =================
  Future<int> insertProduct(Product p) async =>
      (await database).insert('products', p.toMap());

  Future<List<Product>> getProducts() async {
    final res = await (await database).query('products', orderBy: 'name');
    return res.map(Product.fromMap).toList();
  }

  Future<int> updateProduct(Product p) async => (await database)
      .update('products', p.toMap(), where: 'id=?', whereArgs: [p.id]);

  Future<int> deleteProduct(int id) async =>
      (await database).delete('products', where: 'id=?', whereArgs: [id]);

// ================= UPDATE ALLOTMENT STATUS =================
  Future<void> updateAllotmentStatus(
    int programNo,
    String status,
  ) async {
    final db = await database;

    // Update allotment table
    await db.update(
      'program_allotment',
      {'status': status},
      where: 'program_no = ?',
      whereArgs: [programNo],
    );

    // Update program master status also
    await db.update(
      'program_master',
      {'status': status},
      where: 'program_no = ?',
      whereArgs: [programNo],
    );
  }

  // ================= PARTY =================
  Future<int> insertParty(Party p) async =>
      (await database).insert('parties', p.toMap());

  Future<List<Party>> getParties() async {
    final res = await (await database).query('parties', orderBy: 'name');
    return res.map(Party.fromMap).toList();
  }

  Future<int> updateParty(Party p) async => (await database)
      .update('parties', p.toMap(), where: 'id=?', whereArgs: [p.id]);

  Future<int> deleteParty(int id) async =>
      (await database).delete('parties', where: 'id=?', whereArgs: [id]);

  // ================= STOCK =================
  Future<int> insertLedger(StockLedger l) async =>
      (await database).insert('stock_ledger', l.toMap());

  Future<double> getProductBalance(int productId) async {
    final db = await database;
    final inQty = Sqflite.firstIntValue(await db.rawQuery(
            "SELECT SUM(qty) FROM stock_ledger WHERE product_id=? AND type='IN'",
            [productId])) ??
        0;
    final outQty = Sqflite.firstIntValue(await db.rawQuery(
            "SELECT SUM(qty) FROM stock_ledger WHERE product_id=? AND type='OUT'",
            [productId])) ??
        0;
    return (inQty - outQty).toDouble();
  }

  // ================= SHADES =================
  Future<List<String>> getFabricShades(int productId) async {
    final res = await (await database)
        .query('fabric_shades', where: 'product_id=?', whereArgs: [productId]);
    return res.map((e) => e['shade_name'] as String).toList();
  }
// ================= THREAD SHADES (FULL DATA) =================

  Future<List<Map<String, dynamic>>> getThreadShadesFull() async {
    final db = await database;
    return db.query(
      'thread_shades',
      orderBy: 'shade_no',
    );
  }

// ================= THREAD SHADE MASTER =================

// For Thread Shade Master page
  Future<List<Map<String, dynamic>>> getThreadShades() async {
    final db = await database;
    return db.query('thread_shades', orderBy: 'shade_no');
  }

  Future<int> insertThreadShade({
    required String shadeNo,
    required String quality,
    String? imagePath,
  }) async {
    final db = await database;
    return db.insert('thread_shades', {
      'shade_no': shadeNo,
      'quality': quality,
      'image_path': imagePath,
    });
  }

  Future<int> deleteThreadShade(int id) async {
    final db = await database;
    return db.delete(
      'thread_shades',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

// For Program Master (checkbox only)
  Future<List<String>> getThreadShadeNames() async {
    final db = await database;
    final res = await db.query('thread_shades', orderBy: 'shade_no');
    return res.map((e) => '${e['shade_no']} (${e['quality']})').toList();
  }

  // ================= PROGRAM =================
  Future<int> getNextProgramNo() async {
    final res = await (await database)
        .rawQuery('SELECT MAX(program_no) as maxNo FROM program_master');
    return ((res.first['maxNo'] as int?) ?? 0) + 1;
  }

  Future<int> insertProgram(Map<String, dynamic> data) async =>
      (await database).insert('program_master', data);

  Future<void> insertProgramThreadShade(int programNo, String shade) async =>
      (await database).insert(
          'program_thread_shades', {'program_no': programNo, 'shade': shade});

  Future<List<Map<String, dynamic>>> getPlannedPrograms() async {
    return (await database).rawQuery('''
      SELECT pm.*, p.name AS party_name
      FROM program_master pm
      JOIN parties p ON p.id = pm.party_id
      WHERE pm.status='PLANNED'
      ORDER BY pm.program_date DESC
    ''');
  }

  // ================= MACHINE =================
  Future<List<Map<String, dynamic>>> getMachines() async =>
      (await database).query('machines', orderBy: 'machine_code');

  Future<int> insertMachine(String code, String type) async =>
      (await database).insert('machines',
          {'machine_code': code, 'machine_type': type, 'status': 'IDLE'});

  Future<int> deleteMachine(int id) async =>
      (await database).delete('machines', where: 'id=?', whereArgs: [id]);

  // ================= PROGRAM FLOW =================
  Future<void> allotMachine(
      {required int programNo, required int machineId}) async {
    final db = await database;
    await db.insert('program_allotment', {
      'program_no': programNo,
      'machine_id': machineId,
      'status': 'ALLOTTED',
      'start_time': DateTime.now().millisecondsSinceEpoch,
    });
    await db.update('program_master', {'status': 'ALLOTTED'},
        where: 'program_no=?', whereArgs: [programNo]);
  }

  Future<void> startProgram(
      {required int programNo, required int machineId}) async {
    final db = await database;
    await db.update('program_allotment', {'status': 'RUNNING'},
        where: 'program_no=? AND machine_id=?',
        whereArgs: [programNo, machineId]);
    await db.update('program_master', {'status': 'RUNNING'},
        where: 'program_no=?', whereArgs: [programNo]);
    await logProgramActivity({
      'program_no': programNo,
      'machine_id': machineId,
      'status': 'RUNNING',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> pauseProgram(
      {required int programNo,
      required int machineId,
      required String reason}) async {
    final db = await database;
    await db.update('program_allotment', {'status': 'PAUSED'},
        where: 'program_no=? AND machine_id=?',
        whereArgs: [programNo, machineId]);
    await db.update('program_master', {'status': 'PAUSED'},
        where: 'program_no=?', whereArgs: [programNo]);
    await logProgramActivity({
      'program_no': programNo,
      'machine_id': machineId,
      'status': 'PAUSED',
      'reason': reason,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> completeProgram(
      {required int programNo, required int machineId}) async {
    final db = await database;
    await db.update('program_allotment', {'status': 'COMPLETED'},
        where: 'program_no=? AND machine_id=?',
        whereArgs: [programNo, machineId]);
    await db.update('program_master', {'status': 'COMPLETED'},
        where: 'program_no=?', whereArgs: [programNo]);
    await db.update('machines', {'status': 'IDLE'},
        where: 'id=?', whereArgs: [machineId]);
    await logProgramActivity({
      'program_no': programNo,
      'machine_id': machineId,
      'status': 'COMPLETED',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, dynamic>>> getActiveAllotments() async {
    return (await database).rawQuery('''
      SELECT pa.*, m.machine_code
      FROM program_allotment pa
      JOIN machines m ON m.id = pa.machine_id
      WHERE pa.status != 'COMPLETED'
    ''');
  }

  // ================= LOGS & DELAYS =================
  Future<void> logProgramActivity(Map<String, dynamic> log) async =>
      (await database).insert('program_activity_log', log);

  Future<List<Map<String, dynamic>>> getDelayReasons() async =>
      (await database).query('delay_reasons', orderBy: 'reason');

  Future<int> insertDelayReason(String reason) async =>
      (await database).insert('delay_reasons', {'reason': reason});

  Future<int> deleteDelayReason(int id) async =>
      (await database).delete('delay_reasons', where: 'id=?', whereArgs: [id]);
}
