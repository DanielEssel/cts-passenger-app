// features/auth/presentation/login_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../providers/auth_providers.dart';
import '../../auth/widgets/auth_widgets.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _phoneController = TextEditingController();
  final _phoneKey = GlobalKey<PhoneInputFieldState>();
  final _formKey = GlobalKey<FormState>();

  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarBrightness: Brightness.dark,
      statusBarIconBrightness: Brightness.light,
    ));

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
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
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _animController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _requestOtp() async {
    if (!_formKey.currentState!.validate()) return;
    HapticFeedback.mediumImpact();

    // ✅ Use E.164 number from PhoneInputField (includes country code)
    final phone = _phoneKey.currentState?.fullNumber
        ?? _phoneController.text.trim();

    await ref.read(authProvider.notifier).sendOtp(
      phone: phone,
      onCodeSent: () {
        if (!mounted) return;
        Navigator.pushNamed(
          context,
          AppRoutes.otpVerification,
          arguments: {'phone': phone},
        );
      },
      onError: (msg) {
        if (mounted) _showError(msg);
      },
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      ),
    );
  }

  String? _validatePhone(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Phone number is required';
    }
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 9) return 'Enter a valid phone number';
    return null;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(authProvider).isLoading;
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: AppColors.background,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // Background glows
          Positioned(
            top: -80,
            right: -60,
            child: AuthGlow(
                color: AppColors.primary, size: 260, opacity: 0.18),
          ),
          Positioned(
            bottom: size.height * 0.3,
            left: -80,
            child: AuthGlow(
                color: AppColors.secondary, size: 200, opacity: 0.12),
          ),

          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: FadeTransition(
                opacity: _fadeAnim,
                child: SlideTransition(
                  position: _slideAnim,
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 24),
                        const AuthBackButton(),
                        SizedBox(height: size.height * 0.06),
                        const AuthLogo(),
                        const SizedBox(height: 36),

                        Text(
                          'Welcome\nback',
                          style: AppTextStyles.heading1.copyWith(
                            fontSize: 42,
                            height: 1.1,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Enter your phone number to\ncontinue your journey.',
                          style: AppTextStyles.bodyMedium.copyWith(
                            color: AppColors.textSecondary,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 48),

                        const AuthFieldLabel('PHONE NUMBER'),
                        const SizedBox(height: 10),

                        // ✅ PhoneInputField with country picker
                        PhoneInputField(
                          key: _phoneKey,
                          controller: _phoneController,
                          validator: _validatePhone,
                          enabled: !isLoading,
                        ),
                        const SizedBox(height: 40),

                        AuthCtaButton(
                          label: 'Continue',
                          isLoading: isLoading,
                          onTap: _requestOtp,
                        ),
                        const SizedBox(height: 32),

                        Row(children: [
                          const Expanded(
                              child: Divider(color: AppColors.border)),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16),
                            child: Text(
                              'New to CTS?',
                              style: AppTextStyles.caption.copyWith(
                                  color: AppColors.textTertiary),
                            ),
                          ),
                          const Expanded(
                              child: Divider(color: AppColors.border)),
                        ]),
                        const SizedBox(height: 24),

                        GestureDetector(
                          onTap: () => Navigator.pushNamed(
                              context, AppRoutes.signup),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                vertical: 16),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(16),
                              border:
                                  Border.all(color: AppColors.border),
                            ),
                            child: Center(
                              child: Text(
                                'Create an account',
                                style: AppTextStyles.button.copyWith(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          height:
                              MediaQuery.of(context).padding.bottom + 32,
                        ),
                      ],
                    ),
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