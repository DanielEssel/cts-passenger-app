// features/auth/presentation/otp_verification_screen.dart

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../providers/auth_providers.dart';

class OtpVerificationScreen extends ConsumerStatefulWidget {
  const OtpVerificationScreen({super.key});

  @override
  ConsumerState<OtpVerificationScreen> createState() =>
      _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends ConsumerState<OtpVerificationScreen>
    with SingleTickerProviderStateMixin {
  // Firebase phone OTP is always 6 digits
  static const int _otpLength = 6;
  static const int _resendSeconds = 60;

  final List<TextEditingController> _controllers =
      List.generate(_otpLength, (_) => TextEditingController());
  final List<FocusNode> _focusNodes =
      List.generate(_otpLength, (_) => FocusNode());

  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  Timer? _resendTimer;
  int _countdown = _resendSeconds;

  // Arguments passed from login / signup screens
  late String _phone;
  bool _isSignUp = false;
  Map<String, dynamic>? _pendingProfile;

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    );
    _slideAnim = Tween(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    ));
    _animController.forward();

    _startResendTimer();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarBrightness: Brightness.dark,
      statusBarIconBrightness: Brightness.light,
    ));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

    _phone = args?['phone'] as String? ?? '';
    _isSignUp = args?['isSignUp'] as bool? ?? false;

    if (_isSignUp) {
      _pendingProfile = {
        'firstName': args?['firstName'],
        'lastName': args?['lastName'],
        'phone': _phone,
        'email': args?['email'] ?? '',
      };
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final n in _focusNodes) {
      n.dispose();
    }
    _resendTimer?.cancel();
    _animController.dispose();
    super.dispose();
  }

  // ── Timer ──────────────────────────────────────────────────────────────────

  void _startResendTimer() {
    _resendTimer?.cancel();
    setState(() => _countdown = _resendSeconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        if (_countdown > 0) {
          _countdown--;
        } else {
          t.cancel();
        }
      });
    });
  }

  // ── OTP logic ──────────────────────────────────────────────────────────────

  String get _currentOtp => _controllers.map((c) => c.text).join();

  Future<void> _verifyOtp() async {
    final code = _currentOtp;
    if (code.length < _otpLength) {
      _showError('Please enter the complete $_otpLength-digit code');
      return;
    }

    HapticFeedback.mediumImpact();

    final success = await ref.read(authProvider.notifier).verifyOtp(
          smsCode: code,
          pendingProfile: _pendingProfile,
          onError: (msg) {
            if (mounted) _showError(msg);
          },
        );

    if (!success || !mounted) return;

    HapticFeedback.heavyImpact();

    // ── If sign-up flow → always go to shell (profile was just created) ──
    if (_isSignUp) {
      Navigator.of(context).pushNamedAndRemoveUntil(
        AppRoutes.welcome,
        (_) => false,
      );
      return;
    }
    // ── Login flow → check if user document exists ──
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _showError('Authentication failed. Please try again.');
      return;
    }

    try {
      // Check users collection (where AuthNotifier writes)
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();

      if (!mounted) return;

      if (!userDoc.exists) {
         if (!context.mounted) return;
        // No account found — redirect to signup
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('No account found. Please sign up first.'),
            backgroundColor: AppColors.warning,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          ),
        );
        // Sign out the Firebase Auth session
        await FirebaseAuth.instance.signOut();
        // Go back to login
        Navigator.of(context).pushNamedAndRemoveUntil(
          AppRoutes.login,
          (_) => false,
        );
        return;
      }

      // User exists → go to shell
      Navigator.of(context).pushNamedAndRemoveUntil(
        AppRoutes.shell,
        (_) => false,
      );
    } catch (e) {
      if (mounted) _showError('Something went wrong. Please try again.');
    }
  }

  Future<void> _resendOtp() async {
    if (_countdown > 0) return;
    HapticFeedback.selectionClick();

    await ref.read(authProvider.notifier).sendOtp(
          phone: _phone,
          onCodeSent: () {
            if (!mounted) return;
            _startResendTimer();
            _clearFields();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('A new code has been sent'),
                backgroundColor: AppColors.success,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              ),
            );
          },
          onError: (msg) {
            if (mounted) _showError(msg);
          },
        );
  }

  void _clearFields() {
    for (final c in _controllers) {
      c.clear();
    }
    _focusNodes.first.requestFocus();
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(authProvider).isLoading;

    return Scaffold(
      backgroundColor: AppColors.background,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // Background glow
          Positioned(
            top: -60,
            right: -80,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  AppColors.primary.withValues(alpha: 0.15),
                  AppColors.primary.withValues(alpha: 0.0),
                ]),
              ),
            ),
          ),

          SafeArea(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: SlideTransition(
                position: _slideAnim,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 18),

                      // Back button
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppColors.border.withValues(alpha: 0.3)),
                          ),
                          child: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            color: AppColors.textPrimary,
                            size: 16,
                          ),
                        ),
                      ),

                      const SizedBox(height: 40),

                      const SizedBox(height: 24),

                      Center(
                        child: SizedBox(
                          width: 240,
                          height: 240,
                          child: Image.asset(
                            'assets/images/otp_illustration.png',
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      Center(
                        child: Text(
                          'Verify your phone',
                          textAlign: TextAlign.center,
                          style: AppTextStyles.heading1.copyWith(
                            fontSize: 34,
                            height: 1.1,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Center(
                        child: RichText(
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style: AppTextStyles.bodyMedium.copyWith(
                              color: AppColors.textSecondary,
                              height: 1.6,
                            ),
                            children: [
                              const TextSpan(
                                text:
                                    'We sent a 6-digit verification code to\n',
                              ),
                              TextSpan(
                                text: _phone,
                                style: AppTextStyles.bodyMedium.copyWith(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 28),

                      // OTP fields
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: List.generate(
                              _otpLength,
                              (i) => _OtpDigitField(
                                controller: _controllers[i],
                                focusNode: _focusNodes[i],
                                enabled: !isLoading,
                                onChanged: (val) {
                                  if (val.isNotEmpty && i < _otpLength - 1) {
                                    _focusNodes[i + 1].requestFocus();
                                  } else if (val.isEmpty && i > 0) {
                                    _focusNodes[i - 1].requestFocus();
                                  }
                                  // Auto-submit when last digit entered
                                  if (i == _otpLength - 1 &&
                                      val.isNotEmpty &&
                                      _currentOtp.length == _otpLength) {
                                    _verifyOtp();
                                  }
                                },
                              ),
                            ),
                          )
                        ],
                      ),

                      const SizedBox(height: 32),

                      // Verify button
                      _VerifyButton(
                        isLoading: isLoading,
                        onTap: _verifyOtp,
                      ),

                      const SizedBox(height: 32),

                      // Resend
                      Center(
                        child: _countdown > 0
                            ? RichText(
                                text: TextSpan(
                                  style: AppTextStyles.bodySmall
                                      .copyWith(color: AppColors.textSecondary),
                                  children: [
                                    const TextSpan(text: 'Resend code in '),
                                    TextSpan(
                                      text: '${_countdown}s',
                                      style: AppTextStyles.bodySmall.copyWith(
                                        color: AppColors.primary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : GestureDetector(
                                onTap: _resendOtp,
                                child: Text(
                                  'Resend code',
                                  style: AppTextStyles.bodySmall.copyWith(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                      ),

                      SizedBox(
                          height: MediaQuery.of(context).padding.bottom + 32),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── OTP digit field ───────────────────────────────────────────────────────────

class _OtpDigitField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _OtpDigitField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 54,
      height: 64,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 1,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          color: AppColors.textPrimary,
        ),
        decoration: InputDecoration(
          counterText: '',
          filled: true,
          fillColor: AppColors.surfaceAlt,
          contentPadding: EdgeInsets.zero,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: AppColors.border, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: AppColors.border, width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: AppColors.primary, width: 2),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(
                color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

// ── Verify button ─────────────────────────────────────────────────────────────

class _VerifyButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onTap;

  const _VerifyButton({required this.isLoading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isLoading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: isLoading
              ? AppColors.primary.withValues(alpha: 0.6)
              : AppColors.primary,
          borderRadius: BorderRadius.circular(16),
          boxShadow: isLoading
              ? null
              : [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: Center(
          child: isLoading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: Colors.white),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Verify & Continue',
                      style: AppTextStyles.button.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward_rounded,
                        color: Colors.white, size: 18),
                  ],
                ),
        ),
      ),
    );
  }
}
