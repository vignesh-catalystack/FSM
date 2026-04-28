import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'login_notifier.dart';
import 'forgot_password_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _obscure = true;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loginState = ref.watch(loginProvider);

    return Scaffold(
      body: SafeArea(
        child: CustomPaint(
          painter: _BackgroundPainter(),
          child: SizedBox.expand(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final screenWidth = constraints.maxWidth;
                final isTablet = screenWidth >= 600 && screenWidth < 1024;
                final isDesktop = screenWidth >= 1024;
                final isWide = isTablet || isDesktop;

                // Card width caps on larger screens
                final cardMaxWidth = isDesktop
                    ? 420.0
                    : isTablet
                        ? 480.0
                        : double.infinity;

                // Horizontal padding scales with screen
                final hPadding = isDesktop
                    ? screenWidth * 0.30
                    : isTablet
                        ? screenWidth * 0.15
                        : 20.0;

                // Vertical padding increases on larger screens
                final vPadding = isWide ? 60.0 : 40.0;

                return Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: hPadding,
                      vertical: vPadding,
                    ),
                    child: Align(
                      alignment: Alignment.center,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: cardMaxWidth),
                        child: _GlassCard(
                          isWide: isWide,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [

                              // ── ICON ──────────────────────────────────
                              _ResponsiveIcon(isWide: isWide),

                              SizedBox(height: isWide ? 32 : 28),

                              // ── TITLE ─────────────────────────────────
                              Text(
                                'Sign in to FSM',
                                style: TextStyle(
                                  fontSize: isWide ? 28 : 24,
                                  fontWeight: FontWeight.w700,
                                  color: const Color(0xFF0F172A),
                                  letterSpacing: -0.5,
                                ),
                              ),

                              SizedBox(height: isWide ? 12 : 10),

                              // ── SUBTITLE ──────────────────────────────
                              Text(
                                'Manage jobs, technicians, and\nrevenue in one place',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: isWide ? 15 : 14,
                                  height: 1.55,
                                  color: const Color(0xFF64748B),
                                  fontWeight: FontWeight.w400,
                                ),
                              ),

                              SizedBox(height: isWide ? 36 : 32),

                              // ── EMAIL FIELD ───────────────────────────
                              _InputField(
                                controller: _emailController,
                                hint: 'Email',
                                icon: Icons.email,
                                keyboardType: TextInputType.emailAddress,
                              ),

                              SizedBox(height: isWide ? 14 : 12),

                              // ── PASSWORD FIELD ────────────────────────
                              _InputField(
                                controller: _passwordController,
                                hint: 'Password',
                                icon: Icons.lock,
                                obscure: _obscure,
                                suffix: GestureDetector(
                                  onTap: () =>
                                      setState(() => _obscure = !_obscure),
                                  child: Icon(
                                    _obscure
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    size: 20,
                                    color: const Color(0xFF94A3B8),
                                  ),
                                ),
                              ),

                              const SizedBox(height: 10),

                              // ── FORGOT PASSWORD ───────────────────────
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          const ForgotPasswordScreen(),
                                    ),
                                  ),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 4),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: const Text(
                                    'Forgot password?',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: Color(0xFF475569),
                                    ),
                                  ),
                                ),
                              ),

                              SizedBox(height: isWide ? 24 : 20),

                              // ── SIGN IN BUTTON ────────────────────────
                              SizedBox(
                                width: double.infinity,
                                height: isWide ? 56 : 52,
                                child: ElevatedButton(
                                  onPressed: loginState.loading
                                      ? null
                                      : () async {
                                          await ref
                                              .read(loginProvider.notifier)
                                              .login(
                                                _emailController.text.trim(),
                                                _passwordController.text.trim(),
                                              );
                                          final error =
                                              ref.read(loginProvider).error;
                                          if (error != null &&
                                              context.mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              SnackBar(
                                                content: Text(error),
                                                behavior:
                                                    SnackBarBehavior.floating,
                                              ),
                                            );
                                          }
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF1E2D42),
                                    disabledBackgroundColor:
                                        const Color(0xFF1E2D42).withOpacity(0.6),
                                    elevation: 8,
                                    shadowColor:
                                        const Color(0xFF0F172A).withOpacity(0.40),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  child: loginState.loading
                                      ? const SizedBox(
                                          height: 22,
                                          width: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Text(
                                          'Sign in',
                                          style: TextStyle(
                                            fontSize: isWide ? 17 : 16,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                            letterSpacing: 0.2,
                                          ),
                                        ),
                                ),
                              ),
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
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// RESPONSIVE ICON
// ─────────────────────────────────────────────────────────
class _ResponsiveIcon extends StatelessWidget {
  final bool isWide;
  const _ResponsiveIcon({required this.isWide});

  @override
  Widget build(BuildContext context) {
    final size = isWide ? 84.0 : 72.0;
    final iconSize = isWide ? 40.0 : 34.0;

    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(isWide ? 24 : 20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF90BBD9).withOpacity(0.28),
            blurRadius: 28,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Center(
        child: Image.asset(
          'assets/icons/login_icon.png',
          width: iconSize,
          height: iconSize,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Icon(
            Icons.login_rounded,
            size: iconSize - 2,
            color: const Color(0xFF1E293B),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// GLASS CARD
// ─────────────────────────────────────────────────────────
class _GlassCard extends StatelessWidget {
  final Widget child;
  final bool isWide;
  const _GlassCard({required this.child, this.isWide = false});

  @override
  Widget build(BuildContext context) {
    final cardPadding = isWide
        ? const EdgeInsets.fromLTRB(32, 48, 32, 48)
        : const EdgeInsets.fromLTRB(24, 40, 24, 40);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0C1E3C).withOpacity(0.10),
            blurRadius: 40,
            spreadRadius: 0,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: const Color(0xFF0C1E3C).withOpacity(0.05),
            blurRadius: 80,
            spreadRadius: 0,
            offset: const Offset(0, 24),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: CustomPaint(
            painter: _CardPainter(),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: const Color(0xFFBDD6EE).withOpacity(0.60),
                  width: 1.2,
                ),
              ),
              padding: cardPadding,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// BACKGROUND PAINTER — unchanged
// ─────────────────────────────────────────────────────────
class _BackgroundPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFFCEE4FC),
    );

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.82, size.height * 0.12),
        width: size.width * 0.85,
        height: size.height * 0.45,
      ),
      Paint()
        ..color = Colors.white.withOpacity(0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 55),
    );

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.18, size.height * 0.40),
        width: size.width * 0.65,
        height: size.height * 0.35,
      ),
      Paint()
        ..color = Colors.white.withOpacity(0.14)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 45),
    );

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.50, size.height * 0.82),
        width: size.width * 0.90,
        height: size.height * 0.38,
      ),
      Paint()
        ..color = Colors.white.withOpacity(0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 50),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// ─────────────────────────────────────────────────────────
// CARD PAINTER — unchanged
// ─────────────────────────────────────────────────────────
class _CardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);

    final cardPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFFB6DDFE),
          Color(0xFFCFE5FD),
          Color(0xFFEAF2FD),
          Color(0xFFFFFFFF),
          Color(0xFFEAF2FD),
          Color(0xFFCFE5FD),
          Color(0xFFB6DDFE),
        ],
        stops: [0.0, 0.18, 0.34, 0.50, 0.66, 0.82, 1.0],
      ).createShader(rect);

    canvas.drawRect(rect, cardPaint);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * 0.12),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFFB6DDFE).withOpacity(0.30),
            const Color(0xFFB6DDFE).withOpacity(0.0),
          ],
        ).createShader(
            Rect.fromLTWH(0, 0, size.width, size.height * 0.12)),
    );

    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.30, size.width, size.height * 0.60),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            const Color(0xFFB6DDFE).withOpacity(0.30),
            const Color(0xFFB6DDFE).withOpacity(0.0),
          ],
        ).createShader(
          Rect.fromLTWH(
              0, size.height * 0.88, size.width, size.height * 0.12),
        ),
    );

    // ── MICRO STROKES (TOP-LEFT) ──
_stroke(
  canvas,
  Offset(size.width * 0.30, size.height * 0.08),
  Offset(size.width * 0.12, size.height * 0.18),
  width: size.width * 0.02,
  opacity: 0.14,
  blur: 6,
);

_stroke(
  canvas,
  Offset(size.width * 0.38, size.height * 0.06),
  Offset(size.width * 0.18, size.height * 0.16),
  width: size.width * 0.015,
  opacity: 0.12,
  blur: 5,
);

    _stroke(canvas,
        Offset(size.width * 1.05, size.height * 0.02),
        Offset(size.width * -0.20, size.height * 0.50),
        width: 170, opacity: 0.07, blur: 44);

    // _stroke(canvas,
    //     Offset(size.width * 0.92, size.height * 0.0),
    //     Offset(size.width * -0.10, size.height * 0.42),
    //     width: 120, opacity: 0.09, blur: 24);
    _stroke(
  canvas,
  Offset(size.width * 1.02, size.height * 0.04),
  Offset(size.width * -0.08, size.height * 0.46),
  width: size.width * 0.23,
  opacity: 0.088,
  blur: size.width * 0.20,
);

    _stroke(canvas,
        Offset(size.width * 0.76, size.height * 0.01),
        Offset(size.width * 0.02, size.height * 0.38),
        width: 20, opacity: 0.14, blur: 8);
  }

  

  void _stroke(Canvas canvas, Offset a, Offset b,
      {required double width,
      required double opacity,
      required double blur}) {
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = Colors.white.withOpacity(opacity)
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// ─────────────────────────────────────────────────────────
// INPUT FIELD — unchanged
// ─────────────────────────────────────────────────────────
class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final Widget? suffix;
  final TextInputType? keyboardType;

  const _InputField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.suffix,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: const TextStyle(
        fontSize: 14,
        color: Color(0xFF0F172A),
        fontWeight: FontWeight.w500,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          color: Color(0xFF94A3B8),
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Icon(
            icon,
            size: 20,
            color: const Color(0xFF94A3B8),
          ),
        ),
        suffixIcon: suffix != null
            ? Padding(
                padding: const EdgeInsets.only(right: 14),
                child: suffix,
              )
            : null,
        suffixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
        filled: true,
        fillColor: const Color(0xFFF0F4F8),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 16,
          horizontal: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: Color(0xFFDDE8F2),
            width: 1.0,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: Color(0xFFDDE8F2),
            width: 1.0,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: Color(0xFFBFD7F5),
            width: 1.5,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: Color(0xFFEF4444),
            width: 1.5,
          ),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: Color(0xFFEF4444),
            width: 1.5,
          ),
        ),
      ),
    );
  }
}