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

  // Just initialize the sync service reference. No auto-pull, no listeners.
  // User taps "Update Data" on dashboard to sync from Firebase.
  FirebaseSyncService.instance.init().catchError((e) {
    debugPrint('⚠ Firebase sync init failed: $e');
  });

  final prefs = await SharedPreferences.getInstance();
  final isLoggedIn = prefs.getBool('is_logged_in') ?? false;
  final isRegistered = prefs.getBool('is_registered') ?? false;

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
      home: home,
    );
  }
}
