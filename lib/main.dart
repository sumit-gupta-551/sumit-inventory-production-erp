import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'data/erp_database.dart';
import 'data/firebase_sync_service.dart';
import 'data/permission_service.dart';
import 'theme/app_theme.dart';
import 'pages/dashboard_page.dart';
import 'pages/login_page.dart';

Timer? _autoFastSyncTimer;
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
  }

  // --- Minimal blocking init (only what's needed to show UI) ---
  try {
    await Firebase.initializeApp();
    FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL:
          'https://mayur-synthetics-default-rtdb.asia-southeast1.firebasedatabase.app',
    ).setPersistenceEnabled(true);
  } catch (e) {
    debugPrint('⚠ Firebase init failed: $e');
  }

  try {
    await ErpDatabase.instance.database;
    await FirebaseSyncService.instance.init();
    ErpDatabase.instance.syncEnabled = true;
    FirebaseSyncService.instance.startListening();
    _startAutoFastSync();
  } catch (e) {
    debugPrint('⚠ Database init failed: $e');
  }

  final prefs = await SharedPreferences.getInstance();
  final isLoggedIn = prefs.getBool('is_logged_in') ?? false;
  final isRegistered = prefs.getBool('is_registered') ?? false;

  if (isLoggedIn) {
    final phone = prefs.getString('user_phone') ?? '';
    await PermissionService.instance.loadPermissions(phone);
  }

  // Show app immediately — don't block on sync
  runApp(
      MyApp(showLogin: isRegistered && !isLoggedIn, showDashboard: isLoggedIn));

}

void _startAutoFastSync() {
  _autoFastSyncTimer?.cancel();
  _autoFastSyncTimer = Timer.periodic(const Duration(minutes: 30), (_) async {
    try {
      await FirebaseSyncService.instance.fastSync();
      debugPrint('Auto fast sync completed');
    } catch (e) {
      debugPrint('Auto fast sync failed: $e');
    }
  });
}

class MyApp extends StatefulWidget {
  final bool showLogin;
  final bool showDashboard;

  const MyApp(
      {super.key, required this.showLogin, required this.showDashboard});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const _autoLogoutAfter = Duration(minutes: 1);
  Timer? _logoutTimer;

  @override
  void initState() {
    super.initState();
    if (widget.showDashboard) {
      _resetLogoutTimer();
    }
  }

  @override
  void dispose() {
    _logoutTimer?.cancel();
    super.dispose();
  }

  void _resetLogoutTimer() {
    _logoutTimer?.cancel();
    _logoutTimer = Timer(_autoLogoutAfter, _autoLogout);
  }

  void _recordActivity() {
    _resetLogoutTimer();
  }

  Future<void> _autoLogout() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('is_logged_in') != true) return;

    await prefs.setBool('is_logged_in', false);
    ErpDatabase.instance.logActivity(
      action: 'AUTO_LOGOUT',
      details: 'User auto logged out after 1 minute of inactivity',
    );

    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    nav.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget home;
    if (widget.showDashboard) {
      home = const DashboardPage();
    } else if (widget.showLogin) {
      home = const LoginPage();
    } else {
      home = const LoginPage();
    }

    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'ERP Inventory',
      theme: AppTheme.light,
      home: home,
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _recordActivity(),
        onPointerSignal: (_) => _recordActivity(),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
