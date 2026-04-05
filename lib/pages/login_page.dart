// ignore_for_file: use_build_context_synchronously

import 'dart:convert';
import 'dart:ui';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'register_page.dart';
import 'dashboard_page.dart';
import '../data/permission_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with TickerProviderStateMixin {
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

  late AnimationController _blinkCtrl;
  late Animation<double> _blinkAnim;

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

    _blinkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat(reverse: true);
    _blinkAnim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _blinkCtrl, curve: Curves.easeInOut),
    );

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
    _blinkCtrl.dispose();
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

    // Try local credentials first
    if (phone == savedPhone && inputHash == savedHash) {
      await prefs.setBool('is_logged_in', true);
      _goToDashboard();
      return;
    }

    // Try Firebase (user created by super user)
    final fbResult =
        await PermissionService.instance.verifyFirebaseLogin(phone, inputHash);
    if (fbResult != null) {
      // Save locally so next time it's instant
      await prefs.setString('user_phone', phone);
      await prefs.setString('user_name', fbResult);
      await prefs.setString('user_password', inputHash);
      await prefs.setBool('is_registered', true);
      await prefs.setBool('is_logged_in', true);
      _goToDashboard();
    } else {
      setState(() => _loading = false);
      _msg('Invalid mobile number or password');
    }
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
        _goToDashboard();
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
      _msg('Passcode set successfully!', success: true);
      _goToDashboard();
    } else {
      final inputHash = sha256.convert(utf8.encode(code)).toString();
      if (inputHash == savedHash) {
        await prefs.setBool('is_logged_in', true);
        _goToDashboard();
      } else {
        _msg('Invalid passcode');
      }
    }
  }

  // ---------- NAV ----------
  Future<void> _goToDashboard() async {
    final prefs = await SharedPreferences.getInstance();
    final phone = prefs.getString('user_phone') ?? '';
    await PermissionService.instance.loadPermissions(phone);
    if (!mounted) return;
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
      _goToDashboard();
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
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF5F5F5), Color(0xFFE3F2FD), Color(0xFFF5F5F5)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            // Neon glow orbs
            Positioned(
              top: -100,
              right: -60,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFF1565C0).withValues(alpha: 0.15),
                      const Color(0xFF1565C0).withValues(alpha: 0.04),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.4, 1.0],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -140,
              left: -80,
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFFE91E63).withValues(alpha: 0.12),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 350,
              left: -50,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFF673AB7).withValues(alpha: 0.10),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // Main content
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(
                        child: FadeTransition(
                          opacity: _fadeAnim,
                          child: SlideTransition(
                            position: _slideAnim,
                            child: Column(
                              children: [
                                const SizedBox(height: 20),

                                // Logo
                                Container(
                                  width: 100,
                                  height: 100,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(24),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF1565C0)
                                            .withValues(alpha: 0.40),
                                        blurRadius: 32,
                                        spreadRadius: 4,
                                        offset: const Offset(0, 4),
                                      ),
                                      BoxShadow(
                                        color: const Color(0xFFE91E63)
                                            .withValues(alpha: 0.20),
                                        blurRadius: 24,
                                        spreadRadius: 2,
                                        offset: const Offset(0, -2),
                                      ),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(24),
                                    child: Image.asset(
                                      'assets/mslogo.png',
                                      width: 100,
                                      height: 100,
                                      fit: BoxFit.contain,
                                      filterQuality: FilterQuality.high,
                                    ),
                                  ),
                                ),

                                const SizedBox(height: 10),
                                FadeTransition(
                                  opacity: _blinkAnim,
                                  child: ShaderMask(
                                    shaderCallback: (rect) =>
                                        const LinearGradient(
                                      colors: [
                                        Color(0xFF1565C0),
                                        Color(0xFFE91E63),
                                        Color(0xFF673AB7),
                                      ],
                                    ).createShader(rect),
                                    child: const Text(
                                      '✩ Mayur Synthetics ✩',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                        fontStyle: FontStyle.italic,
                                        letterSpacing: 2.0,
                                      ),
                                    ),
                                  ),
                                ),

                                if (_userName.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1565C0)
                                          .withValues(alpha: 0.06),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: const Color(0xFF1565C0)
                                            .withValues(alpha: 0.15),
                                      ),
                                    ),
                                    child: Text(
                                      'Welcome back, $_userName',
                                      style: TextStyle(
                                        color: const Color(0xFF1565C0)
                                            .withValues(alpha: 0.8),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 18),

                                // Glass card
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(28),
                                  child: BackdropFilter(
                                    filter: ImageFilter.blur(
                                        sigmaX: 20, sigmaY: 20),
                                    child: Container(
                                      padding: const EdgeInsets.all(22),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFFFFFF)
                                            .withValues(alpha: 0.90),
                                        borderRadius: BorderRadius.circular(28),
                                        border: Border.all(
                                          color: const Color(0xFF1565C0)
                                              .withValues(alpha: 0.12),
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black
                                                .withValues(alpha: 0.08),
                                            blurRadius: 32,
                                            offset: const Offset(0, 10),
                                          ),
                                          BoxShadow(
                                            color: const Color(0xFF1565C0)
                                                .withValues(alpha: 0.06),
                                            blurRadius: 60,
                                            offset: const Offset(0, 20),
                                          ),
                                        ],
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              'Sign In',
                                              style: TextStyle(
                                                fontSize: 22,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFF212121),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              'Enter your credentials to continue',
                                              style: TextStyle(
                                                color: const Color(0xFF757575),
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 24),

                                          // PHONE
                                          _glassField(
                                            controller: _phoneCtrl,
                                            label: 'Mobile Number',
                                            prefixText: '+91 ',
                                            icon: Icons.phone_android_rounded,
                                            keyboard: TextInputType.phone,
                                            maxLength: 10,
                                          ),
                                          const SizedBox(height: 16),

                                          // PASSWORD
                                          _glassField(
                                            controller: _passwordCtrl,
                                            label: 'Password',
                                            icon: Icons.lock_rounded,
                                            obscure: _obscurePassword,
                                            suffixIcon: IconButton(
                                              icon: Icon(
                                                _obscurePassword
                                                    ? Icons
                                                        .visibility_off_rounded
                                                    : Icons.visibility_rounded,
                                                color: const Color(0xFF64748B),
                                                size: 20,
                                              ),
                                              onPressed: () => setState(() =>
                                                  _obscurePassword =
                                                      !_obscurePassword),
                                            ),
                                          ),
                                          const SizedBox(height: 20),

                                          // LOGIN BUTTON
                                          SizedBox(
                                            width: double.infinity,
                                            height: 48,
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                gradient: const LinearGradient(
                                                  colors: [
                                                    Color(0xFF1565C0),
                                                    Color(0xFF673AB7),
                                                  ],
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color:
                                                        const Color(0xFF1565C0)
                                                            .withValues(
                                                                alpha: 0.40),
                                                    blurRadius: 24,
                                                    offset: const Offset(0, 8),
                                                  ),
                                                ],
                                              ),
                                              child: ElevatedButton(
                                                onPressed: _loading
                                                    ? null
                                                    : _loginWithPassword,
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor:
                                                      Colors.transparent,
                                                  shadowColor:
                                                      Colors.transparent,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            16),
                                                  ),
                                                ),
                                                child: _loading
                                                    ? const SizedBox(
                                                        width: 22,
                                                        height: 22,
                                                        child:
                                                            CircularProgressIndicator(
                                                          strokeWidth: 2.5,
                                                          color:
                                                              Color(0xFFF5F5F5),
                                                        ),
                                                      )
                                                    : const Text(
                                                        'SIGN IN',
                                                        style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.w800,
                                                          fontSize: 15,
                                                          color:
                                                              Color(0xFFF5F5F5),
                                                          letterSpacing: 1.5,
                                                        ),
                                                      ),
                                              ),
                                            ),
                                          ),

                                          const SizedBox(height: 20),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Divider(
                                                    color: Colors.white
                                                        .withValues(
                                                            alpha: 0.08)),
                                              ),
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 14),
                                                child: Text(
                                                  'or continue with',
                                                  style: TextStyle(
                                                    color: Colors.white
                                                        .withValues(
                                                            alpha: 0.30),
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ),
                                              Expanded(
                                                child: Divider(
                                                    color: Colors.white
                                                        .withValues(
                                                            alpha: 0.08)),
                                              ),
                                            ],
                                          ),

                                          const SizedBox(height: 20),

                                          // QUICK LOGIN OPTIONS
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              if (_canBiometric) ...[
                                                _quickLoginBtn(
                                                  icon:
                                                      Icons.fingerprint_rounded,
                                                  label: 'Biometric',
                                                  onTap: _loginWithBiometric,
                                                ),
                                                const SizedBox(width: 24),
                                              ],
                                              _quickLoginBtn(
                                                icon: Icons.dialpad_rounded,
                                                label: 'Passcode',
                                                onTap: () => setState(() =>
                                                    _showPasscode =
                                                        !_showPasscode),
                                              ),
                                            ],
                                          ),

                                          // PASSCODE INPUT
                                          if (_showPasscode) ...[
                                            const SizedBox(height: 20),
                                            _glassField(
                                              controller: _passcodeCtrl,
                                              label: 'Enter Passcode',
                                              icon: Icons.dialpad_rounded,
                                              keyboard: TextInputType.number,
                                              obscure: true,
                                              maxLength: 6,
                                            ),
                                            const SizedBox(height: 6),
                                            Align(
                                              alignment: Alignment.centerLeft,
                                              child: Text(
                                                'Set on first use, 4-6 digits',
                                                style: TextStyle(
                                                  color:
                                                      const Color(0xFF9E9E9E),
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            SizedBox(
                                              width: double.infinity,
                                              height: 40,
                                              child: OutlinedButton(
                                                onPressed: _loginWithPasscode,
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor:
                                                      const Color(0xFF1565C0),
                                                  side: BorderSide(
                                                    color:
                                                        const Color(0xFF1565C0)
                                                            .withValues(
                                                                alpha: 0.3),
                                                  ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            14),
                                                  ),
                                                ),
                                                child: const Text(
                                                  'UNLOCK WITH PASSCODE',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: 13,
                                                    letterSpacing: 0.8,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),

                                const SizedBox(height: 14),

                                // HINT + REGISTER LINK
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981)
                                        .withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: const Color(0xFF10B981)
                                          .withValues(alpha: 0.12),
                                    ),
                                  ),
                                  child: Text(
                                    'After app update? Just sign in — no need to register again.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: const Color(0xFF10B981)
                                          .withValues(alpha: 0.8),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                GestureDetector(
                                  onTap: _openRegister,
                                  child: RichText(
                                    text: TextSpan(
                                      text: "New user?  ",
                                      style: TextStyle(
                                        color: const Color(0xFF757575),
                                        fontSize: 14,
                                      ),
                                      children: const [
                                        TextSpan(
                                          text: 'Register here',
                                          style: TextStyle(
                                            color: Color(0xFF1565C0),
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),

                                const Spacer(),

                                // SSSJ logo at bottom
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF5F5F5),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: const Color(0xFFE0E0E0),
                                    ),
                                  ),
                                  child: Image.asset(
                                    'assets/sssj.png',
                                    width: 45,
                                    height: 45,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.high,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Powered & Built by SSSJ',
                                  style: TextStyle(
                                    color: const Color(0xFFBDBDBD),
                                    fontSize: 9,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- GLASS TEXT FIELD ----------
  Widget _glassField({
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
      style: const TextStyle(color: Color(0xFF212121), fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF9E9E9E)),
        prefixText: prefixText,
        prefixStyle: const TextStyle(color: Color(0xFF757575), fontSize: 15),
        prefixIcon: Icon(icon, color: const Color(0xFF1565C0), size: 20),
        suffixIcon: suffixIcon,
        counterText: '',
        filled: true,
        fillColor: const Color(0xFFF5F5F5).withValues(alpha: 0.8),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF1565C0), width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  // ---------- QUICK LOGIN BUTTON ----------
  Widget _quickLoginBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: const Color(0xFF1565C0).withValues(alpha: 0.15)),
            ),
            child: Icon(icon, size: 22, color: const Color(0xFF1565C0)),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF757575),
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
