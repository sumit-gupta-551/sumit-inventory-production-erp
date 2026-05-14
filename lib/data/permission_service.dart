import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

/// Manages user roles and page-level permissions via Firebase.
///
/// Roles:
///   - `super`  – hardcoded phone 9377670056, full access + can manage users
///   - `admin`  – full access to all pages (set by super)
///   - `custom` – only pages explicitly enabled by super
class PermissionService {
  static final PermissionService instance = PermissionService._();
  PermissionService._();

  /// The one and only super-user phone number.
  static const superPhone = '9377670056';

  static const _dbUrl =
      'https://mayur-synthetics-default-rtdb.asia-southeast1.firebasedatabase.app';

  // ─── All permission keys with display names ───
  static const allPermissions = <String, String>{
    // Modules
    'purchase_entry': 'Purchase Entry',
    'order_management': 'Order Management',
    'issue_entry': 'Issue Entry',
    'requirement': 'Requirement',
    'stock_adjustment': 'Stock Adjustment',
    'history': 'History',
    'stock_ledger': 'Running Stock',
    'firms': 'Firms',
    'machine_allotment': 'Machine Allotment',
    'operator_live': 'Operator Live',
    'program_card': 'Program Card Page',
    'dispatch_goods': 'Dispatch Goods',
    // Masters
    'master_parties': 'Parties',
    'master_products': 'Products / Items',
    'master_machines': 'Machines',
    'master_units': 'Units',
    'master_programs': 'Programs',
    'master_thread_shade': 'Thread Shade',
    'master_fabric_shade': 'Fabric Shade',
    'master_delay_reasons': 'Delay Reasons',
    // Reports
    'report_stock': 'Stock Report',
    'report_purchase': 'Purchase Report',
    'report_order': 'Order Report',
    'report_issue': 'Issue Report',
    'report_challan': 'Issue Challan',
    'report_shade_movement': 'Shade Movement',
    'report_daily_consumption': 'Daily Consumption',
    'report_requirement_history': 'Requirement History',
    'report_adjustment_history': 'Adjustment History',
    'report_program_card': 'Program Card Report',
    'report_dispatch': 'Dispatch Report',
    'report_paid_salary': 'Paid Salary Report',
    // Payroll
    'payroll_employee_master': 'Employee Master',
    'payroll_production_entry': 'Production Entry',
    'payroll_attendance': 'Attendance',
    'payroll_salary': 'Salary / Payroll',
    'payroll_advance': 'Employee Advance',
    'payroll_pay_salary': 'Pay Salary',
    'payroll_production_report': 'Production Report',
    'payroll_advance_report': 'Advance Report',
    // Admin actions
    'activity_log': 'Activity Log',
    'stock_ticker': 'Stock Ticker',
    'sync_data': 'Sync Data',
    'update_app': 'Update App',
    'clear_firebase': 'Clear Firebase Data',
  };

  // ─── State ───
  String _currentPhone = '';
  String _currentRole = 'custom';
  String _currentName = '';
  Map<String, bool> _permissions = {};
  // Per-user list of unit names this user may access in Attendance.
  // `null` (i.e. node missing in Firebase) means unrestricted (all units).
  // Empty list means the user is restricted to NO units.
  List<String>? _allowedAttendanceUnits;

  String get currentPhone => _currentPhone;
  String get currentRole => _currentRole;
  String get currentName => _currentName;
  bool get isSuper => _currentPhone == superPhone;
  bool get isAdmin => _currentRole == 'admin' || isSuper;

  /// Returns the list of allowed unit names for Attendance for the current user.
  /// `null` means unrestricted (all units allowed).
  List<String>? get allowedAttendanceUnits =>
      _allowedAttendanceUnits == null ? null : List.unmodifiable(_allowedAttendanceUnits!);

  /// Whether the current user can access attendance for the given unit name.
  /// Admin/super always pass. If no restriction list is configured, all units are allowed.
  bool canAccessAttendanceUnit(String unitName) {
    if (isSuper || isAdmin) return true;
    final allowed = _allowedAttendanceUnits;
    if (allowed == null) return true; // unrestricted
    return allowed.contains(unitName);
  }

  DatabaseReference get _ref => FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: _dbUrl,
      ).ref();

  bool get _hasFirebaseApp {
    try {
      Firebase.app();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> _restGetNode(String path) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final uri = Uri.parse('$_dbUrl/$path.json');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      if (body.isEmpty || body == 'null') return null;
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  Future<bool> _restPutNode(String path, Object? payload) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final uri = Uri.parse('$_dbUrl/$path.json');
      final req = await client.putUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  Future<bool> _restDeleteNode(String path) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final uri = Uri.parse('$_dbUrl/$path.json');
      final req = await client.deleteUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// REST fallback for platforms where the native Firebase RTDB plugin
  /// is unavailable (e.g. Windows / Linux desktop) or fails to connect.
  /// Returns the decoded `app_users/<phone>` map, or `null` if the node
  /// does not exist or the request failed.
  Future<Map<String, dynamic>?> _restGetUser(String phone) async =>
      _restGetNode('app_users/$phone');

  /// Whether the current user can access the given page/feature.
  bool hasPermission(String key) {
    if (isSuper || isAdmin) return true;
    return _permissions[key] ?? false;
  }

  /// Load permissions from Firebase for the given phone.
  Future<void> loadPermissions(String phone) async {
    _currentPhone = phone;

    if (phone == superPhone) {
      _currentRole = 'super';
      return;
    }

    Map<String, dynamic>? data;
    if (_hasFirebaseApp) {
      try {
        final snap = await _ref.child('app_users/$phone').get();
        if (snap.exists && snap.value is Map) {
          data = Map<String, dynamic>.from(snap.value as Map);
        }
      } catch (e) {
        debugPrint('? Load permissions (Firebase) failed: $e');
      }
    }

    // Fallback to REST when native plugin returned nothing or threw
    // (typical on Windows desktop builds).
    data ??= await _restGetUser(phone);
    if (data == null) return;

    _currentRole = (data['role'] as String?) ?? 'custom';
    _currentName = (data['name'] as String?) ?? '';
    if (data['permissions'] != null && data['permissions'] is Map) {
      _permissions = Map<String, dynamic>.from(data['permissions'] as Map)
          .map((k, v) => MapEntry(k, v == true));
    }
    if (data['allowed_attendance_units'] != null) {
      final raw = data['allowed_attendance_units'];
      if (raw is List) {
        _allowedAttendanceUnits = raw.map((e) => e.toString()).toList();
      } else if (raw is Map) {
        _allowedAttendanceUnits =
            raw.values.map((e) => e.toString()).toList();
      }
    } else {
      _allowedAttendanceUnits = null;
    }
  }

  /// Set the list of unit names a custom user may access in Attendance (super only).
  /// Pass `null` to clear restrictions (allow all units).
  Future<void> setUserAttendanceUnits(
      String phone, List<String>? units) async {
    if (!isSuper || phone == superPhone) return;
    try {
      if (_hasFirebaseApp) {
        if (units == null) {
          await _ref.child('app_users/$phone/allowed_attendance_units').remove();
        } else {
          await _ref
              .child('app_users/$phone/allowed_attendance_units')
              .set(units);
        }
      } else {
        if (units == null) {
          await _restDeleteNode('app_users/$phone/allowed_attendance_units');
        } else {
          await _restPutNode('app_users/$phone/allowed_attendance_units', units);
        }
      }
    } catch (e) {
      debugPrint('? Set attendance units failed: $e');
    }
  }

  /// Push a new user record to Firebase (called on registration).
  Future<void> registerUser(
      String phone, String name, String hashedPassword) async {
    try {
      final role = phone == superPhone ? 'super' : 'custom';
      final perms = <String, bool>{};
      if (phone == superPhone) {
        for (final key in allPermissions.keys) {
          perms[key] = true;
        }
      }
      final userData = <String, dynamic>{
        'name': name,
        'phone': phone,
        'password': hashedPassword,
        'role': role,
        'permissions': perms,
        'registered_at': _hasFirebaseApp
            ? ServerValue.timestamp
            : DateTime.now().millisecondsSinceEpoch,
      };
      if (_hasFirebaseApp) {
        await _ref.child('app_users/$phone').set(userData);
      } else {
        final ok = await _restPutNode('app_users/$phone', userData);
        if (!ok) throw Exception('REST register user failed');
      }
      _currentPhone = phone;
      _currentRole = role;
      _currentName = name;
      _permissions = perms;
    } catch (e) {
      debugPrint('? Register user failed: $e');
    }
  }

  /// Fetch every registered user (super-user management screen).
  Future<List<Map<String, dynamic>>> getAllUsers() async {
    try {
      Map<String, dynamic>? data;
      if (_hasFirebaseApp) {
        try {
          final snap = await _ref.child('app_users').get();
          if (snap.exists && snap.value is Map) {
            data = Map<String, dynamic>.from(snap.value as Map);
          }
        } catch (e) {
          debugPrint('? Get all users (Firebase) failed: $e');
        }
      }
      data ??= await _restGetNode('app_users');
      if (data == null) return [];
      final users = <Map<String, dynamic>>[];
      for (final entry in data.entries) {
        if (entry.value is! Map) continue;
        final user = Map<String, dynamic>.from(entry.value as Map);
        user['phone'] = entry.key;
        users.add(user);
      }
      users.sort((a, b) {
        const order = {'super': 0, 'admin': 1, 'custom': 2};
        return (order[a['role']] ?? 3).compareTo(order[b['role']] ?? 3);
      });
      return users;
    } catch (e) {
      debugPrint('? Get all users failed: $e');
      return [];
    }
  }

  /// Change a user role (super only).
  Future<void> setUserRole(String phone, String role) async {
    if (!isSuper || phone == superPhone) return;
    try {
      if (_hasFirebaseApp) {
        await _ref.child('app_users/$phone/role').set(role);
      } else {
        final ok = await _restPutNode('app_users/$phone/role', role);
        if (!ok) throw Exception('REST set role failed');
      }
      if (role == 'admin') {
        final perms = <String, bool>{};
        for (final key in allPermissions.keys) {
          perms[key] = true;
        }
        if (_hasFirebaseApp) {
          await _ref.child('app_users/$phone/permissions').set(perms);
        } else {
          final ok = await _restPutNode('app_users/$phone/permissions', perms);
          if (!ok) throw Exception('REST set admin permissions failed');
        }
      }
    } catch (e) {
      debugPrint('? Set user role failed: $e');
    }
  }

  /// Set individual permissions for a custom user (super only).
  Future<void> setUserPermissions(String phone, Map<String, bool> perms) async {
    if (!isSuper || phone == superPhone) return;
    try {
      if (_hasFirebaseApp) {
        await _ref.child('app_users/$phone/permissions').set(perms);
      } else {
        final ok = await _restPutNode('app_users/$phone/permissions', perms);
        if (!ok) throw Exception('REST set permissions failed');
      }
    } catch (e) {
      debugPrint('? Set permissions failed: $e');
    }
  }

  /// Create a new user with phone, name & password (super only).
  /// Returns null on success, or an error message.
  Future<String?> createUser(String phone, String name, String password) async {
    if (!isSuper) return 'Only super user can create users';
    try {
      final existing = _hasFirebaseApp
          ? ((() async { final snap = await _ref.child('app_users/$phone').get(); if (snap.exists && snap.value is Map) return Map<String, dynamic>.from(snap.value as Map); return null; })())
          : _restGetUser(phone);
      final existingData = await existing;
      if (existingData != null) return 'User with this phone already exists';
      final hashedPassword = sha256.convert(utf8.encode(password)).toString();
      final userData = <String, dynamic>{
        'name': name,
        'phone': phone,
        'password': hashedPassword,
        'role': 'custom',
        'permissions': <String, bool>{},
        'registered_at': _hasFirebaseApp
            ? ServerValue.timestamp
            : DateTime.now().millisecondsSinceEpoch,
      };
      if (_hasFirebaseApp) {
        await _ref.child('app_users/$phone').set(userData);
      } else {
        final ok = await _restPutNode('app_users/$phone', userData);
        if (!ok) return 'Failed to create user via REST';
      }
      return null;
    } catch (e) {
      debugPrint('? Create user failed: $e');
      return 'Failed to create user: $e';
    }
  }

  /// Delete a user from Firebase/REST (super only).
  /// Returns null on success, or an error message.
  Future<String?> deleteUser(String phone) async {
    if (!isSuper) return 'Only super user can delete users';
    if (phone == superPhone) return 'Cannot delete super user';
    try {
      if (_hasFirebaseApp) {
        await _ref.child('app_users/$phone').remove();
      } else {
        final ok = await _restDeleteNode('app_users/$phone');
        if (!ok) return 'Failed to delete user via REST';
      }
      return null;
    } catch (e) {
      debugPrint('? Delete user failed: $e');
      return 'Failed to delete user: $e';
    }
  }

  /// Verify login against Firebase.
  /// Returns user name on success, null on failure.
  Future<String?> verifyFirebaseLogin(
      String phone, String hashedPassword) async {
    Map<String, dynamic>? data;
    if (_hasFirebaseApp) {
      try {
        final snap = await _ref.child('app_users/$phone').get();
        if (snap.exists && snap.value is Map) {
          data = Map<String, dynamic>.from(snap.value as Map);
        }
      } catch (e) {
        debugPrint('? Firebase login verify failed: $e');
      }
    }

    // Fallback to REST when the native plugin couldn't fetch the record
    // (e.g. Windows desktop, missing firebase_options, network issues).
    data ??= await _restGetUser(phone);
    if (data == null) return null;

    final savedHash = data['password'] as String? ?? '';
    if (savedHash == hashedPassword) {
      return (data['name'] as String?) ?? phone;
    }
    return null;
  }
}
