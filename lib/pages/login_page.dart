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
  void _goToDashboard() {
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
            colors: [Color(0xFFFFFEFC), Color(0xFFFFF8EE), Color(0xFFFFF1DB)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            // Decorative circles
            Positioned(
              top: -80,
              right: -60,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFFFFD700).withValues(alpha: 0.15),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -100,
              left: -80,
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFFDAA520).withValues(alpha: 0.12),
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
                                const SizedBox(height: 32),
                                // App logo
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFDAA520).withValues(alpha: 0.25),
                                  blurRadius: 30,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Image.asset(
                              'assets/mslogo.png',
                              width: 120,
                              height: 120,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              color: const Color(0xFFFFF8EE),
                              colorBlendMode: BlendMode.multiply,
                            ),
                          ),
                          if (_userName.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              'Welcome back, $_userName',
                              style: TextStyle(
                                color: const Color(0xFFB8860B)
                                    .withValues(alpha: 0.7),
                                fontSize: 15,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),

                          // Glass card
                          ClipRRect(
                            borderRadius: BorderRadius.circular(28),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                              child: Container(
                                padding: const EdgeInsets.all(28),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.75),
                                  borderRadius: BorderRadius.circular(28),
                                  border: Border.all(
                                    color: const Color(0xFFDAA520)
                                        .withValues(alpha: 0.12),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFFDAA520)
                                          .withValues(alpha: 0.08),
                                      blurRadius: 24,
                                      offset: const Offset(0, 8),
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
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF1E293B),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        'Enter your credentials to continue',
                                        style: TextStyle(
                                          color: const Color(0xFF64748B)
                                              .withValues(alpha: 0.8),
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
                                              ? Icons.visibility_off_rounded
                                              : Icons.visibility_rounded,
                                          color: const Color(0xFF94A3B8),
                                          size: 20,
                                        ),
                                        onPressed: () => setState(() =>
                                            _obscurePassword =
                                                !_obscurePassword),
                                      ),
                                    ),
                                    const SizedBox(height: 16),

                                    // LOGIN BUTTON
                                    SizedBox(
                                      width: double.infinity,
                                      height: 42,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: const LinearGradient(
                                            colors: [
                                              Color(0xFFB8860B),
                                              Color(0xFFDAA520),
                                            ],
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(16),
                                          boxShadow: [
                                            BoxShadow(
                                              color: const Color(0xFFDAA520)
                                                  .withValues(alpha: 0.35),
                                              blurRadius: 16,
                                              offset: const Offset(0, 6),
                                            ),
                                          ],
                                        ),
                                        child: ElevatedButton(
                                          onPressed: _loading
                                              ? null
                                              : _loginWithPassword,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.transparent,
                                            shadowColor: Colors.transparent,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                          ),
                                          child: _loading
                                              ? const SizedBox(
                                                  width: 22,
                                                  height: 22,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2.5,
                                                    color: Colors.white,
                                                  ),
                                                )
                                              : const Text(
                                                  'SIGN IN',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 14,
                                                    color: Colors.white,
                                                    letterSpacing: 1.2,
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ),

                                    const SizedBox(height: 16),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Divider(
                                              color: const Color(0xFF94A3B8)
                                                  .withValues(alpha: 0.3)),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 14),
                                          child: Text(
                                            'or continue with',
                                            style: TextStyle(
                                              color: const Color(0xFF64748B)
                                                  .withValues(alpha: 0.7),
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Divider(
                                              color: const Color(0xFF94A3B8)
                                                  .withValues(alpha: 0.3)),
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
                                            icon: Icons.fingerprint_rounded,
                                            label: 'Biometric',
                                            onTap: _loginWithBiometric,
                                          ),
                                          const SizedBox(width: 24),
                                        ],
                                        _quickLoginBtn(
                                          icon: Icons.dialpad_rounded,
                                          label: 'Passcode',
                                          onTap: () => setState(() =>
                                              _showPasscode = !_showPasscode),
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
                                            color: const Color(0xFF94A3B8)
                                                .withValues(alpha: 0.8),
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      SizedBox(
                                        width: double.infinity,
                                        height: 38,
                                        child: OutlinedButton(
                                          onPressed: _loginWithPasscode,
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor:
                                                const Color(0xFFB8860B),
                                            side: BorderSide(
                                              color: const Color(0xFFDAA520)
                                                  .withValues(alpha: 0.4),
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                            ),
                                          ),
                                          child: const Text(
                                            'UNLOCK WITH PASSCODE',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
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

                          const SizedBox(height: 15),

                          // REGISTER LINK
                          GestureDetector(
                            onTap: _openRegister,
                            child: RichText(
                              text: TextSpan(
                                text: "Don't have an account?  ",
                                style: TextStyle(
                                  color: const Color(0xFF64748B)
                                      .withValues(alpha: 0.8),
                                  fontSize: 14,
                                ),
                                children: const [
                                  TextSpan(
                                    text: 'Register',
                                    style: TextStyle(
                                      color: Color(0xFFB8860B),
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
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFDAA520).withValues(alpha: 0.2),
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: Image.asset(
                              'assets/sssj.png',
                              width: 55,
                              height: 55,
                              fit: BoxFit.contain,                              filterQuality: FilterQuality.high,                              color: const Color(0xFFFFF8EE),
                              colorBlendMode: BlendMode.multiply,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Powered & Built by SSSJ',
                            style: TextStyle(
                              color: const Color(0xFFB8860B).withValues(alpha: 0.6),
                              fontSize: 5,
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
      style: const TextStyle(color: Color(0xFF1E293B), fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
        prefixText: prefixText,
        prefixStyle: const TextStyle(color: Color(0xFF475569), fontSize: 15),
        prefixIcon: Icon(icon, color: const Color(0xFFDAA520), size: 20),
        suffixIcon: suffixIcon,
        counterText: '',
        filled: true,
        fillColor: const Color(0xFFFFFBF0),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              BorderSide(color: const Color(0xFFDAA520).withValues(alpha: 0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFDAA520), width: 1.5),
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
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8EE),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: const Color(0xFFDAA520).withValues(alpha: 0.15)),
            ),
            child: Icon(icon, size: 20, color: const Color(0xFFB8860B)),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF64748B),
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
