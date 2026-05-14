// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/erp_database.dart';
import '../data/firebase_sync_service.dart';
import '../data/permission_service.dart';
import '../data/rest_pull_sync_service.dart';
import 'dashboard_page.dart';
import 'register_page.dart';

// Widget to display current user's UID and role from /app_users
class SuperUserStatusWidget extends StatefulWidget {
  const SuperUserStatusWidget({super.key});

  @override
  State<SuperUserStatusWidget> createState() => _SuperUserStatusWidgetState();
}

class _SuperUserStatusWidgetState extends State<SuperUserStatusWidget> {
  String? _uid;
  String? _role;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchStatus();
  }

  Future<void> _fetchStatus() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        setState(() {
          _error = 'Not signed in.';
        });
        return;
      }
      final uid = user.uid;
      final ref = FirebaseDatabase.instance.ref('app_users/$uid/role');
      final snap = await ref.get();
      setState(() {
        _uid = uid;
        _role = snap.value?.toString();
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Current UID: ${_uid ?? "Unknown"}'),
        Text('Role: ${_role ?? "Unknown"}'),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.red)),
      ],
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final _phoneCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _passcodeCtrl = TextEditingController();

  final _localAuth = LocalAuthentication();

  bool _loading = false;
  bool _canBiometric = false;
  bool _showPasscode = false;
  bool _obscurePassword = true;

  String _userName = '';

  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _userName = prefs.getString('user_name') ?? '';
    _phoneCtrl.text = prefs.getString('user_phone') ?? '';

    try {
      _canBiometric = await _localAuth.canCheckBiometrics ||
          await _localAuth.isDeviceSupported();
    } catch (_) {
      _canBiometric = false;
    }

    if (mounted) {
      setState(() {});
      _animCtrl.forward();
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _phoneCtrl.dispose();
    _passwordCtrl.dispose();
    _passcodeCtrl.dispose();
    super.dispose();
  }

  // ---------- PASSWORD LOGIN ----------
  Future<void> _loginWithPassword() async {
    final phone = _phoneCtrl.text.trim();
    final password = _passwordCtrl.text.trim();

    if (phone.isEmpty || password.isEmpty) {
      _msg('Enter mobile number and password');
      return;
    }

    setState(() => _loading = true);

    final prefs = await SharedPreferences.getInstance();
    final savedPhone = prefs.getString('user_phone') ?? '';
    final savedHash = prefs.getString('user_password') ?? '';

    final inputHash = sha256.convert(utf8.encode(password)).toString();

    if (phone == savedPhone && inputHash == savedHash) {
      await prefs.setBool('is_logged_in', true);
      await PermissionService.instance.loadPermissions(phone);
      ErpDatabase.instance.logActivity(
        action: 'LOGIN',
        details: 'Password login - ${prefs.getString('user_name') ?? phone}',
      );
      await _goToDashboard();
      return;
    }

    // Fallback for users created in Firebase User Management.
    final fbName =
        await PermissionService.instance.verifyFirebaseLogin(phone, inputHash);
    if (fbName != null) {
      await prefs.setString('user_phone', phone);
      await prefs.setString('user_name', fbName);
      await prefs.setString('user_password', inputHash);
      await prefs.setBool('is_registered', true);
      await prefs.setBool('is_logged_in', true);
      await PermissionService.instance.loadPermissions(phone);
      ErpDatabase.instance.logActivity(
        action: 'LOGIN',
        details: 'Password login (Firebase) - $fbName',
      );
      await _goToDashboard();
      return;
    }

    setState(() => _loading = false);
    _msg('Invalid mobile number or password');
  }

  // ---------- BIOMETRIC LOGIN ----------
  Future<void> _loginWithBiometric() async {
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Authenticate to access SSSJ ERP',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );

      if (authenticated) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('is_logged_in', true);
        final phone = prefs.getString('user_phone') ?? '';
        await PermissionService.instance.loadPermissions(phone);
        ErpDatabase.instance.logActivity(
          action: 'LOGIN',
          details:
              'Biometric login - ${prefs.getString('user_name') ?? phone}',
        );
        await _goToDashboard();
      }
    } on PlatformException catch (e) {
      _msg('Biometric error: ${e.message}');
    }
  }

  // ---------- PASSCODE LOGIN ----------
  Future<void> _loginWithPasscode() async {
    final code = _passcodeCtrl.text.trim();
    if (code.isEmpty) {
      _msg('Enter passcode');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final savedHash = prefs.getString('user_passcode');

    if (savedHash == null) {
      final hash = sha256.convert(utf8.encode(code)).toString();
      await prefs.setString('user_passcode', hash);
      await prefs.setBool('is_logged_in', true);
      final phone = prefs.getString('user_phone') ?? '';
      await PermissionService.instance.loadPermissions(phone);
      ErpDatabase.instance.logActivity(
        action: 'LOGIN',
        details:
            'Passcode set & login - ${prefs.getString('user_name') ?? phone}',
      );
      _msg('Passcode set successfully!', success: true);
      await _goToDashboard();
    } else {
      final inputHash = sha256.convert(utf8.encode(code)).toString();
      if (inputHash == savedHash) {
        await prefs.setBool('is_logged_in', true);
        final phone = prefs.getString('user_phone') ?? '';
        await PermissionService.instance.loadPermissions(phone);
        ErpDatabase.instance.logActivity(
          action: 'LOGIN',
          details:
              'Passcode login - ${prefs.getString('user_name') ?? phone}',
        );
        await _goToDashboard();
      } else {
        _msg('Invalid passcode');
      }
    }
  }

  // ---------- NAV ----------
  Future<bool> _ensureRealtimeSyncStarted() async {
    // Desktop (Windows/Linux) has no native Firebase plugin; use REST pull.
    if (Platform.isWindows || Platform.isLinux) {
      try {
        return await RestPullSyncService.instance.pullNow();
      } catch (e) {
        debugPrint('REST pull on login failed: $e');
        return false;
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final sync = FirebaseSyncService.instance;
      final fullSyncDone =
          prefs.getBool(FirebaseSyncService.initialFullSyncDonePrefKey) ??
              false;
      final hasLocalData = await sync.hasCoreLocalData();
      final needsBootstrap = !fullSyncDone || !hasLocalData;

      if (needsBootstrap) {
        var ok = await sync.fullSync();
        if (!ok) {
          await Future<void>.delayed(const Duration(seconds: 2));
          ok = await sync.fullSync();
        }
        if (ok) {
          await prefs.setBool(
            FirebaseSyncService.initialFullSyncDonePrefKey,
            true,
          );
        } else {
          debugPrint('Initial full sync incomplete. Will retry next login.');
          return false;
        }
      }

      await sync.fastSync();
      return true;
    } catch (e) {
      debugPrint('Sync listener start failed: $e');
      return false;
    }
  }

  Future<void> _goToDashboard() async {
    setState(() => _loading = true);
    final syncReady = await _ensureRealtimeSyncStarted();
    if (!mounted) return;
    if (!syncReady) {
      final reason = (Platform.isWindows || Platform.isLinux)
          ? (RestPullSyncService.instance.lastError.value ?? 'unknown')
          : (FirebaseSyncService.instance.lastSyncError ?? 'unknown');
      _msg('Could not load server data now. Reason: $reason');
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const DashboardPage()),
    );
  }

  Future<void> _openRegister() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const RegisterPage()),
    );
    if (result == true) {
      await _goToDashboard();
    }
  }

  void _msg(String text, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(text, style: const TextStyle(fontWeight: FontWeight.w500)),
        backgroundColor:
            success ? const Color(0xFF10B981) : const Color(0xFFEF4444),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 820;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFFFFFFFF),
              Color(0xFFFCFDFF),
              Color(0xFFF8FBFF),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -140,
              left: -80,
              right: -80,
              child: Container(
                height: 280,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0x220EA5E9),
                      Color(0x2210B981),
                      Color(0x22F59E0B),
                      Color(0x22E11D8A),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(220),
                    bottomRight: Radius.circular(220),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _NeonGridPainter()),
              ),
            ),
            Positioned(
              top: -100,
              left: -80,
              child: _glowOrb(
                size: 260,
                color: const Color(0xFFDDF2FF),
                alpha: 0.9,
              ),
            ),
            Positioned(
              top: 140,
              right: -90,
              child: _glowOrb(
                size: 220,
                color: const Color(0xFFFFE5F4),
                alpha: 0.9,
              ),
            ),
            Positioned(
              bottom: -120,
              left: -70,
              child: _glowOrb(
                size: 250,
                color: const Color(0xFFE6FFF1),
                alpha: 0.88,
              ),
            ),
            Positioned(
              bottom: 120,
              right: -90,
              child: _glowOrb(
                size: 210,
                color: const Color(0xFFFFF1DE),
                alpha: 0.82,
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: FadeTransition(
                      opacity: _fadeAnim,
                      child: SlideTransition(
                        position: _slideAnim,
                        child: isWide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: _heroPanel(compact: false)),
                                  const SizedBox(width: 18),
                                  Expanded(child: _authPanel(compact: false)),
                                ],
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _heroPanel(compact: true),
                                  const SizedBox(height: 16),
                                  _authPanel(compact: true),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroPanel({required bool compact}) {
    return Container(
      padding: const EdgeInsets.all(1.4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          colors: [
            Color(0xFF0EA5E9),
            Color(0xFF10B981),
            Color(0xFFF59E0B),
            Color(0xFFE11D8A),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Container(
        padding: EdgeInsets.all(compact ? 16 : 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: compact ? 62 : 74,
                  height: compact ? 62 : 74,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFE9F7FF), Color(0xFFFFEFF8)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE7EDF5)),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Image.asset('assets/mslogo.png', fit: BoxFit.contain),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Mayur Synthetics ERP',
                        style: TextStyle(
                          color: Color(0xFF0F2238),
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.4,
                          fontFamily: 'serif',
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _userName.isEmpty
                            ? 'Operations in one beautiful workspace'
                            : 'Welcome back, $_userName',
                        style: const TextStyle(
                          color: Color(0xFF5F748A),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF9FBFF),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE6ECF5)),
              ),
              child: const Row(
                children: [
                  Expanded(child: _MetricTile(title: 'Inventory', value: 'Live')),
                  Expanded(child: _MetricTile(title: 'Orders', value: 'Smart')),
                  Expanded(child: _MetricTile(title: 'Reports', value: 'Fast')),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _NeonTag(label: 'Live Sync', color: Color(0xFF0EA5E9)),
                _NeonTag(label: 'Smart Reports', color: Color(0xFFE11D8A)),
                _NeonTag(label: 'Role Security', color: Color(0xFF10B981)),
              ],
            ),
            if (!compact) ...[
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFFCFDFF),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE7EDF5)),
                ),
                child: const Text(
                  'Track stock, process orders, and create reports with clarity and speed. Designed for day-to-day ERP work without clutter.',
                  style: TextStyle(
                    color: Color(0xFF3D566E),
                    height: 1.45,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _authPanel({required bool compact}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE6ECF4)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.08),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      padding: EdgeInsets.all(compact ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 7,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF0EA5E9),
                  Color(0xFF10B981),
                  Color(0xFFF59E0B),
                  Color(0xFFE11D8A),
                  Color(0xFF7C3AED),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Sign In',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0E233A),
              letterSpacing: 0.3,
              fontFamily: 'serif',
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Clean white UI with colourful energy',
            style: TextStyle(
              color: Color(0xFF60768D),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          _inputField(
            controller: _phoneCtrl,
            label: 'Mobile Number',
            prefixText: '+91 ',
            icon: Icons.call_rounded,
            keyboard: TextInputType.phone,
            maxLength: 10,
          ),
          const SizedBox(height: 12),
          _inputField(
            controller: _passwordCtrl,
            label: 'Password',
            icon: Icons.lock_outline_rounded,
            obscure: _obscurePassword,
            keyboard: TextInputType.visiblePassword,
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 20,
                color: const Color(0xFF7890A8),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFF0EA5E9),
                    Color(0xFF10B981),
                    Color(0xFFF59E0B),
                    Color(0xFFE11D8A),
                  ],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFE11D8A).withValues(alpha: 0.28),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _loginWithPassword,
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.login_rounded),
                label: Text(
                  _loading ? 'Signing In...' : 'Sign In',
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.35,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (_canBiometric)
                _quickActionButton(
                  icon: Icons.fingerprint_rounded,
                  label: 'Biometric',
                  accent: const Color(0xFFE11D8A),
                  onTap: _loginWithBiometric,
                ),
              _quickActionButton(
                icon: Icons.dialpad_rounded,
                label: _showPasscode ? 'Hide Passcode' : 'Use Passcode',
                accent: const Color(0xFF7C3AED),
                onTap: () => setState(() => _showPasscode = !_showPasscode),
              ),
            ],
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: !_showPasscode
                ? const SizedBox.shrink(key: ValueKey('hide'))
                : Padding(
                    key: const ValueKey('show'),
                    padding: const EdgeInsets.only(top: 14),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFCFDFF),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE7EDF5)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _inputField(
                            controller: _passcodeCtrl,
                            label: 'Enter Passcode',
                            icon: Icons.pin_outlined,
                            keyboard: TextInputType.number,
                            obscure: true,
                            maxLength: 6,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'First use will set passcode (4-6 digits).',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF627790),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            height: 40,
                            child: OutlinedButton(
                              onPressed: _loginWithPasscode,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF7C3AED),
                                side: BorderSide(
                                  color: const Color(0xFF7C3AED).withValues(alpha: 0.62),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                'Unlock With Passcode',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: _openRegister,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFE11D8A),
              ),
              child: const Text(
                'New user? Create account',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _glowOrb({
    required double size,
    required Color color,
    required double alpha,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            Colors.transparent,
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Column(
      children: [
        Container(
          width: 62,
          height: 62,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE7EDF5)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F172A).withValues(alpha: 0.05),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Image.asset(
            'assets/sssj.png',
            fit: BoxFit.contain,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Powered by SSSJ',
          style: TextStyle(
            color: Color(0xFF41596F),
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.35,
          ),
        ),
      ],
    );
  }

  // ---------- INPUT FIELD ----------
  Widget _inputField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? prefixText,
    TextInputType? keyboard,
    bool obscure = false,
    int? maxLength,
    Widget? suffixIcon,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboard,
      obscureText: obscure,
      maxLength: maxLength,
      style: const TextStyle(
        color: Color(0xFF1A2E44),
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(
          color: Color(0xFF5F748B),
          fontWeight: FontWeight.w600,
        ),
        prefixText: prefixText,
        prefixStyle: const TextStyle(
          color: Color(0xFF4E6480),
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
        prefixIcon: Icon(icon, color: const Color(0xFF0EA5E9), size: 20),
        suffixIcon: suffixIcon,
        counterText: '',
        filled: true,
        fillColor: const Color(0xFFFDFEFF),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
            color: Color(0xFFE2EAF4),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF7C3AED), width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }

  // ---------- QUICK ACTION BUTTON ----------
  Widget _quickActionButton({
    required IconData icon,
    required String label,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: accent.withValues(alpha: 0.32),
          ),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.14),
              blurRadius: 9,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: accent),
            const SizedBox(width: 7),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1F354A),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String title;
  final String value;

  const _MetricTile({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Color(0xFF0E233A),
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.35,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFF687C90),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _NeonTag extends StatelessWidget {
  final String label;
  final Color color;

  const _NeonTag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.08),
            blurRadius: 9,
          ),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.35,
        ),
      ),
    );
  }
}

class _NeonGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final minor = Paint()
      ..color = const Color(0xFF64748B).withValues(alpha: 0.035)
      ..strokeWidth = 1;
    final majorVertical = Paint()
      ..color = const Color(0xFF0EA5E9).withValues(alpha: 0.03)
      ..strokeWidth = 1.2;
    final majorHorizontal = Paint()
      ..color = const Color(0xFFE11D8A).withValues(alpha: 0.024)
      ..strokeWidth = 1.2;

    const minorGap = 38.0;
    const majorGap = 114.0;

    for (double x = 0; x <= size.width; x += minorGap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), minor);
    }
    for (double y = 0; y <= size.height; y += minorGap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), minor);
    }
    for (double x = 0; x <= size.width; x += majorGap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), majorVertical);
    }
    for (double y = 0; y <= size.height; y += majorGap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), majorHorizontal);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
