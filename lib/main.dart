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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
  }

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
  } catch (e) {
    debugPrint('⚠ Database init failed: $e');
  }

  // Auto-sync: init → full sync → start real-time listeners
  try {
    await FirebaseSyncService.instance.init();
    await FirebaseSyncService.instance.fullSync();
    FirebaseSyncService.instance.startListening();
  } catch (e) {
    debugPrint('⚠ Firebase sync failed: $e');
  }

  final prefs = await SharedPreferences.getInstance();
  final isLoggedIn = prefs.getBool('is_logged_in') ?? false;
  final isRegistered = prefs.getBool('is_registered') ?? false;

  if (isLoggedIn) {
    final phone = prefs.getString('user_phone') ?? '';
    await PermissionService.instance.loadPermissions(phone);
  }

  runApp(
      MyApp(showLogin: isRegistered && !isLoggedIn, showDashboard: isLoggedIn));
}

class MyApp extends StatelessWidget {
  final bool showLogin;
  final bool showDashboard;

  const MyApp(
      {super.key, required this.showLogin, required this.showDashboard});

  @override
  Widget build(BuildContext context) {
    Widget home;
    if (showDashboard) {
      home = const DashboardPage();
    } else if (showLogin) {
      home = const LoginPage();
    } else {
      home = const LoginPage();
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ERP Inventory',
      theme: AppTheme.neonDark,
      home: home,
    );
  }
}
