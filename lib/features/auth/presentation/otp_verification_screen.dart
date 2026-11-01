// features/auth/presentation/otp_verification_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/theme/cts_theme.dart';
import '../domain/phone_number.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/otp_code_field.dart';
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

  final _codeController = TextEditingController();
  bool _hasError = false;
  bool _argsRead = false;

  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  Timer? _resendTimer;
  int _countdown = _resendSeconds;

  // Arguments passed from login / signup screens (read once).
  String _phone = '';

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
    _codeController.addListener(() {
      if (_hasError) setState(() => _hasError = false);
    });

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarBrightness: Brightness.dark,
      statusBarIconBrightness: Brightness.light,
    ));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    _phone = args?['phone'] as String? ?? '';
  }

  @override
  void dispose() {
    _codeController.dispose();
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
  // Duplicate submissions (auto-submit on the last digit plus a button tap,
  // or automatic verification racing a typed code) are refused by the
  // notifier; the screen only reflects its isLoading state.

  Future<void> _verifyOtp() async {
    if (ref.read(authProvider).isLoading) return;

    final code = _codeController.text;
    if (code.length < _otpLength) {
      setState(() => _hasError = true);
      _showError('Enter the $_otpLength-digit code from the SMS.');
      return;
    }

    HapticFeedback.mediumImpact();
    await ref.read(authProvider.notifier).verifyOtp(
          smsCode: code,
          onAuthenticated: _openDestination,
          onError: (msg) {
            if (!mounted) return;
            setState(() => _hasError = true);
            _showError(msg);
          },
        );
  }

  void _openDestination(String route) {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    Navigator.of(context).pushNamedAndRemoveUntil(route, (_) => false);
  }

  Future<void> _resendOtp() async {
    if (_countdown > 0 || ref.read(authProvider).isLoading) return;

    HapticFeedback.selectionClick();
    await ref.read(authProvider.notifier).resendOtp(
          phone: _phone,
          // Only after Firebase confirms the new SMS.
          onCodeSent: () {
            if (!mounted) return;
            _startResendTimer();
            _codeController.clear();
            setState(() => _hasError = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('A new code has been sent'),
                backgroundColor: AppColors.success,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              ),
            );
          },
          onAuthenticated: _openDestination,
          onError: (msg) {
            if (!mounted) return;
            _showError(msg);
          },
        );
  }

  void _showError(String message) => showAuthError(context, message);

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
                      const AuthBackButton(),

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
                        child: Semantics(
                          header: true,
                          child: const Text(
                            'Verify your phone',
                            textAlign: TextAlign.center,
                            style: CtsText.title1,
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
                                text: formatPhoneForDisplay(_phone),
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

                      // OTP code: paste, SMS autofill and auto-submit.
                      OtpCodeField(
                        controller: _codeController,
                        enabled: !isLoading,
                        hasError: _hasError,
                        onCompleted: (_) => _verifyOtp(),
                      ),

                      const SizedBox(height: 16),
                      Center(
                        child: Text(
                          isLoading
                              ? 'Verifying…'
                              : "We'll fill the code in automatically if we can.",
                          textAlign: TextAlign.center,
                          style: AppTextStyles.bodySmall
                              .copyWith(color: AppColors.textSecondary),
                        ),
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
                            : TextButton(
                                onPressed: _resendOtp,
                                child: const Text('Resend code'),
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

// ── Verify button ─────────────────────────────────────────────────────────────

class _VerifyButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onTap;

  const _VerifyButton({required this.isLoading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: !isLoading,
      child: GestureDetector(
        onTap: isLoading ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: CtsTheme.buttonHeight),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isLoading
                ? CtsTheme.vivid.withValues(alpha: 0.7)
                : CtsTheme.vivid,
            borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
          ),
          child: Center(
            child: isLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: CtsTheme.onVivid),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          'Verify & Continue',
                          textAlign: TextAlign.center,
                          style:
                              CtsText.button.copyWith(color: CtsTheme.onVivid),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.arrow_forward_rounded,
                          color: CtsTheme.onVivid, size: 18),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
