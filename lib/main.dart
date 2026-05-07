import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/erp_database.dart';
import 'package:sssj/data/firebase_sync_service.dart';
import 'data/permission_service.dart';
import 'data/rest_pull_sync_service.dart';
import 'theme/app_theme.dart';
import 'pages/dashboard_page.dart';
import 'pages/login_page.dart';

Timer? _autoFastSyncTimer;
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop platforms (Windows / Linux / macOS) need sqflite FFI.
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Show splash/loading UI instantly
  runApp(const SplashApp());

  // Heavy initialization in background
  await _initAndLaunch();
}

Future<void> _initAndLaunch() async {
  bool isLoggedIn = false;
  bool isRegistered = false;

  // Native Firebase plugins (firebase_core / firebase_database) are not
  // supported on Windows / Linux desktop. On those platforms we skip the
  // native init and rely on REST fallbacks (see PermissionService).
  final firebaseSupported = kIsWeb ||
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS;

  if (firebaseSupported) {
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
  } else {
    debugPrint('ℹ Skipping native Firebase init on this desktop platform.');
  }

  try {
    await ErpDatabase.instance.database;
    if (firebaseSupported) {
      await FirebaseSyncService.instance.init();
      ErpDatabase.instance.syncEnabled = true;
      _startAutoFastSync();
    } else {
      // Desktop: REST-only init (push/delete go via REST), and a periodic
      // pull mirror so we see changes other devices make.
      await FirebaseSyncService.instance.init();
      ErpDatabase.instance.syncEnabled = true;
      RestPullSyncService.instance.start();
    }
  } catch (e) {
    debugPrint('⚠ Database init failed: $e');
  }

  final prefs = await SharedPreferences.getInstance();
  isLoggedIn = prefs.getBool('is_logged_in') ?? false;
  isRegistered = prefs.getBool('is_registered') ?? false;

  if (isLoggedIn) {
    final phone = prefs.getString('user_phone') ?? '';
    await PermissionService.instance.loadPermissions(phone);
    if (firebaseSupported) {
      try {
        // For a fresh device install we need one full restore, otherwise the
        // local SQLite can stay empty even though server already has data.
        unawaited(_startSessionSync(prefs));
      } catch (e) {
        debugPrint('Sync startup failed: $e');
      }
    }
  }

  // Replace splash with real app
  runApp(
      MyApp(showLogin: isRegistered && !isLoggedIn, showDashboard: isLoggedIn));
}

// Simple splash screen while initializing
class SplashApp extends StatelessWidget {
  const SplashApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }
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

Future<void> _startSessionSync(SharedPreferences prefs) async {
  try {
    final sync = FirebaseSyncService.instance;
    final fullSyncDone =
        prefs.getBool(FirebaseSyncService.initialFullSyncDonePrefKey) ?? false;
    final hasLocalData = await sync.hasCoreLocalData();
    final needsBootstrap = !fullSyncDone || !hasLocalData;

    if (needsBootstrap) {
      var ok = await sync.fullSync();
      if (!ok) {
        await Future<void>.delayed(const Duration(seconds: 2));
        ok = await sync.fullSync();
      }
      if (ok) {
        await prefs.setBool(FirebaseSyncService.initialFullSyncDonePrefKey, true);
      } else {
        final reason = sync.lastSyncError ?? 'unknown';
        debugPrint(
          'Initial full sync incomplete (reason: $reason). Will retry next launch.',
        );
      }
    }

    await sync.fastSync();
  } catch (e) {
    debugPrint('Sync startup failed: $e');
  }
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
  static const _autoLogoutAfter = Duration(minutes: 15);
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
      builder: (context, child) {
        final inner = child ?? const SizedBox.shrink();
        Widget content = inner;
        // On desktop (Windows/Linux/macOS), constrain UI width so pages
        // don't stretch huge on wide monitors. Mobile is unaffected.
        final isDesktop = !kIsWeb &&
            (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
        if (isDesktop) {
          content = LayoutBuilder(
            builder: (ctx, constraints) {
              const maxW = 1180.0;
              if (constraints.maxWidth <= maxW) return inner;
              return ColoredBox(
                color: const Color(0xFFE9ECEF),
                child: Center(
                  child: SizedBox(
                    width: maxW,
                    height: constraints.maxHeight,
                    child: Material(
                      elevation: 2,
                      child: inner,
                    ),
                  ),
                ),
              );
            },
          );
        }
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _recordActivity(),
          onPointerSignal: (_) => _recordActivity(),
          child: content,
        );
      },
    );
  }
}
