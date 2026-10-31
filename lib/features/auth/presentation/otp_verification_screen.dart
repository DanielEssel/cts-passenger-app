// features/auth/presentation/otp_verification_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/theme/cts_theme.dart';
import '../widgets/auth_widgets.dart';
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
  bool _verificationSubmitted = false;

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
    if (_verificationSubmitted) {
      debugPrint('⚠️ OTP SCREEN: duplicate verification prevented');
      return;
    }

    final code = _currentOtp;

    if (code.length < _otpLength) {
      _showError('Please enter the complete $_otpLength-digit code');
      return;
    }

    _verificationSubmitted = true;

    HapticFeedback.mediumImpact();

    final success = await ref.read(authProvider.notifier).verifyOtp(
          smsCode: code,
          pendingProfile: _pendingProfile,
          onAuthenticated: () {
            if (!mounted) return;

            HapticFeedback.heavyImpact();

            if (_isSignUp) {
              Navigator.of(context).pushNamedAndRemoveUntil(
                AppRoutes.welcome,
                (_) => false,
              );
            } else {
              Navigator.of(context).pushNamedAndRemoveUntil(
                AppRoutes.shell,
                (_) => false,
              );
            }
          },
          onError: (msg) {
            if (mounted) {
              _showError(msg);
            }
          },
        );

    if (!mounted) return;

    if (!success) {
      // Allow the user to try the same current session again if the
      // authentication attempt itself did not complete.
      _verificationSubmitted = false;
    }
  }

  Future<void> _resendOtp() async {
    if (_countdown > 0) return;

    final authState = ref.read(authProvider);

    if (authState.isLoading) {
      return;
    }

    HapticFeedback.selectionClick();

    await ref.read(authProvider.notifier).resendOtp(
          phone: _phone,
          pendingProfile: _isSignUp ? _pendingProfile : null,
          onCodeSent: () {
            if (!mounted) return;

            _verificationSubmitted = false;

            _startResendTimer();
            _clearFields();

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
          onAuthenticated: () {
            if (!mounted) return;

            _verificationSubmitted = true;

            HapticFeedback.heavyImpact();

            Navigator.of(context).pushNamedAndRemoveUntil(
              _isSignUp ? AppRoutes.welcome : AppRoutes.shell,
              (_) => false,
            );
          },
          onError: (msg) {
            if (!mounted) return;

            _verificationSubmitted = false;
            _showError(msg);
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
                        children: List.generate(
                          _otpLength,
                          (i) => Flexible(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 52),
                                child: _OtpDigitField(
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
                            ),
                          ),
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
      height: 60,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 1,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: CtsText.title2.copyWith(
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        decoration: InputDecoration(
          counterText: '',
          filled: true,
          fillColor: CtsTheme.surface,
          isDense: false,
          contentPadding: EdgeInsets.zero,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
            borderSide: const BorderSide(color: CtsTheme.border, width: 1.2),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
            borderSide: const BorderSide(color: CtsTheme.border, width: 1.2),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
            borderSide: const BorderSide(color: CtsTheme.primary, width: 2),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
            borderSide: const BorderSide(color: CtsTheme.borderLight),
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
