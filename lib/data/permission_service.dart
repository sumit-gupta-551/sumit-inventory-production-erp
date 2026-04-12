import 'dart:convert';
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
    'issue_entry': 'Issue Entry',
    'requirement': 'Requirement',
    'stock_adjustment': 'Stock Adjustment',
    'history': 'History',
    'stock_ledger': 'Running Stock',
    'firms': 'Firms',
    'machine_allotment': 'Machine Allotment',
    'operator_live': 'Operator Live',
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
    'report_issue': 'Issue Report',
    'report_challan': 'Issue Challan',
    'report_shade_movement': 'Shade Movement',
    'report_daily_consumption': 'Daily Consumption',
    'report_requirement_history': 'Requirement History',
    'report_adjustment_history': 'Adjustment History',
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

  String get currentPhone => _currentPhone;
  String get currentRole => _currentRole;
  String get currentName => _currentName;
  bool get isSuper => _currentPhone == superPhone;
  bool get isAdmin => _currentRole == 'admin' || isSuper;

  DatabaseReference get _ref => FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: _dbUrl,
      ).ref();

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

    try {
      final snap = await _ref.child('app_users/$phone').get();
      if (snap.exists) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        _currentRole = (data['role'] as String?) ?? 'custom';
        _currentName = (data['name'] as String?) ?? '';
        if (data['permissions'] != null) {
          _permissions = Map<String, dynamic>.from(data['permissions'] as Map)
              .map((k, v) => MapEntry(k, v == true));
        }
      }
    } catch (e) {
      debugPrint('⚠ Load permissions failed: $e');
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

      await _ref.child('app_users/$phone').set({
        'name': name,
        'phone': phone,
        'password': hashedPassword,
        'role': role,
        'permissions': perms,
        'registered_at': ServerValue.timestamp,
      });

      _currentPhone = phone;
      _currentRole = role;
      _currentName = name;
      _permissions = perms;
    } catch (e) {
      debugPrint('⚠ Register user in Firebase failed: $e');
    }
  }

  /// Fetch every registered user (super-user management screen).
  Future<List<Map<String, dynamic>>> getAllUsers() async {
    try {
      final snap = await _ref.child('app_users').get();
      if (!snap.exists) return [];

      final data = Map<String, dynamic>.from(snap.value as Map);
      final users = <Map<String, dynamic>>[];

      for (final entry in data.entries) {
        final user = Map<String, dynamic>.from(entry.value as Map);
        user['phone'] = entry.key;
        users.add(user);
      }

      // super → admin → custom
      users.sort((a, b) {
        const order = {'super': 0, 'admin': 1, 'custom': 2};
        return (order[a['role']] ?? 3).compareTo(order[b['role']] ?? 3);
      });

      return users;
    } catch (e) {
      debugPrint('⚠ Get all users failed: $e');
      return [];
    }
  }

  /// Change a user's role (super only).
  Future<void> setUserRole(String phone, String role) async {
    if (!isSuper || phone == superPhone) return;

    try {
      await _ref.child('app_users/$phone/role').set(role);

      // Admin ⇒ grant all
      if (role == 'admin') {
        final perms = <String, bool>{};
        for (final key in allPermissions.keys) {
          perms[key] = true;
        }
        await _ref.child('app_users/$phone/permissions').set(perms);
      }
    } catch (e) {
      debugPrint('⚠ Set user role failed: $e');
    }
  }

  /// Set individual permissions for a custom user (super only).
  Future<void> setUserPermissions(String phone, Map<String, bool> perms) async {
    if (!isSuper || phone == superPhone) return;

    try {
      await _ref.child('app_users/$phone/permissions').set(perms);
    } catch (e) {
      debugPrint('⚠ Set permissions failed: $e');
    }
  }

  /// Create a new user with phone, name & password (super only).
  /// Returns null on success, or an error message.
  Future<String?> createUser(String phone, String name, String password) async {
    if (!isSuper) return 'Only super user can create users';

    try {
      // Check if user already exists
      final snap = await _ref.child('app_users/$phone').get();
      if (snap.exists) return 'User with this phone already exists';

      final hashedPassword = sha256.convert(utf8.encode(password)).toString();

      await _ref.child('app_users/$phone').set({
        'name': name,
        'phone': phone,
        'password': hashedPassword,
        'role': 'custom',
        'permissions': <String, bool>{},
        'registered_at': ServerValue.timestamp,
      });

      return null;
    } catch (e) {
      debugPrint('⚠ Create user failed: $e');
      return 'Failed to create user: $e';
    }
  }

  /// Delete a user from Firebase (super only).
  /// Returns null on success, or an error message.
  Future<String?> deleteUser(String phone) async {
    if (!isSuper) return 'Only super user can delete users';
    if (phone == superPhone) return 'Cannot delete super user';

    try {
      await _ref.child('app_users/$phone').remove();
      return null;
    } catch (e) {
      debugPrint('⚠ Delete user failed: $e');
      return 'Failed to delete user: $e';
    }
  }

  /// Verify login against Firebase.
  /// Returns user name on success, null on failure.
  Future<String?> verifyFirebaseLogin(
      String phone, String hashedPassword) async {
    try {
      final snap = await _ref.child('app_users/$phone').get();
      if (!snap.exists) return null;

      final data = Map<String, dynamic>.from(snap.value as Map);
      final savedHash = data['password'] as String? ?? '';

      if (savedHash == hashedPassword) {
        return (data['name'] as String?) ?? phone;
      }
      return null;
    } catch (e) {
      debugPrint('⚠ Firebase login verify failed: $e');
      return null;
    }
  }
}
