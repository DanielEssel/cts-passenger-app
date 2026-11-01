// features/auth/presentation/login_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/theme/cts_theme.dart';
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
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    );
    _slideAnim = Tween(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
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
    if (ref.read(authProvider).isLoading) return;
    if (!_formKey.currentState!.validate()) return;
    final phone = _phoneKey.currentState?.e164;
    if (phone == null) return;
    FocusScope.of(context).unfocus();
    HapticFeedback.mediumImpact();

    await ref.read(authProvider.notifier).sendOtp(
          phone: phone,
          // Only after Firebase confirms the SMS was sent.
          onCodeSent: () {
            if (!mounted) return;
            Navigator.pushNamed(
              context,
              AppRoutes.otpVerification,
              arguments: {
                'phone': phone,
                'isSignUp': false,
              },
            );
          },
          // Instant verification or auto-retrieved SMS, possibly while the
          // OTP screen is open on top of this one.
          onAuthenticated: (route) {
            if (!mounted) return;
            Navigator.of(context).pushNamedAndRemoveUntil(route, (_) => false);
          },
          onError: (msg) {
            if (!mounted) return;
            showAuthError(context, msg);
          },
        );
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
          // Refined background glows - reduced size and opacity
          Positioned(
            top: -60,
            right: -40,
            child: AuthGlow(
              color: AppColors.primary,
              size: 200,
              opacity: 0.12,
            ),
          ),
          Positioned(
            bottom: size.height * 0.35,
            left: -60,
            child: AuthGlow(
              color: CtsTheme.apple,
              size: 160,
              opacity: 0.08,
            ),
          ),

          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: FadeTransition(
                opacity: _fadeAnim,
                child: SlideTransition(
                  position: _slideAnim,
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 12),
                        // Premium Back Button - larger touch target

                        const SizedBox(height: 28),
                        // Premium Logo - refined icon card
                        const Center(
                          child: _PremiumLogo(),
                        ),
                        const SizedBox(height: 28),

                        // Typography with better hierarchy
                        Semantics(
                          header: true,
                          child:
                              const Text('Welcome back', style: CtsText.title1),
                        ),
                        const SizedBox(height: 8),

                        Text(
                          'Enter your phone number to continue',
                          style: CtsText.body
                              .copyWith(color: CtsTheme.textSecondary),
                        ),
                        const SizedBox(height: 32),

                        // Phone input with premium styling
                        const AuthFieldLabel('Phone number'),
                        const SizedBox(height: 8),
                        SizedBox(
                          child: PhoneInputField(
                            key: _phoneKey,
                            controller: _phoneController,
                            enabled: !isLoading,
                            onSubmitted: _requestOtp,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // Premium CTA Button with enhanced interactions
                        _PremiumCtaButton(
                          label: 'Continue',
                          isLoading: isLoading,
                          onTap: _requestOtp,
                        ),
                        OtpRequestStatus(visible: isLoading),
                        const SizedBox(height: 28),

                        // Refined Divider
                        Row(
                          children: [
                            const Expanded(
                              child: Divider(
                                color: AppColors.border,
                                thickness: 0.5,
                              ),
                            ),
                            Flexible(
                              flex: 4,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: const Text(
                                  'New to CTSGo?',
                                  textAlign: TextAlign.center,
                                  style: CtsText.bodySmall,
                                ),
                              ),
                            ),
                            const Expanded(
                              child: Divider(
                                color: AppColors.border,
                                thickness: 0.5,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // Premium Secondary Button
                        _PremiumSecondaryButton(
                          onTap: () => Navigator.pushNamed(
                            context,
                            AppRoutes.signup,
                          ),
                        ),
                        SizedBox(
                          height: MediaQuery.of(context).padding.bottom + 24,
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

class _PremiumLogo extends StatelessWidget {
  const _PremiumLogo();

  @override
  Widget build(BuildContext context) {
    // White plate: the CTSGo artwork has a white background, so it sits on
    // a matching tile instead of a visible square on the off-white page.
    return Center(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: CtsTheme.border),
        ),
        child: Image.asset(
          'assets/logos/ctsgo_logo.png',
          width: 88,
          height: 88,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

// ── Premium CTA Button ──────────────────────────────────────────────────────

class _PremiumCtaButton extends StatefulWidget {
  final String label;
  final bool isLoading;
  final VoidCallback onTap;

  const _PremiumCtaButton({
    required this.label,
    required this.isLoading,
    required this.onTap,
  });

  @override
  State<_PremiumCtaButton> createState() => _PremiumCtaButtonState();
}

class _PremiumCtaButtonState extends State<_PremiumCtaButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scaleController;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      lowerBound: 0.97,
      upperBound: 1.0,
      value: 1.0,
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: !widget.isLoading,
      child: GestureDetector(
        onTapDown: (_) {
          if (!widget.isLoading) {
            _scaleController.reverse();
            HapticFeedback.lightImpact();
          }
        },
        onTapUp: (_) {
          _scaleController.forward();
          if (!widget.isLoading) {
            widget.onTap();
          }
        },
        onTapCancel: () {
          _scaleController.forward();
        },
        child: AnimatedBuilder(
          animation: _scaleController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleController.value,
              child: Container(
                width: double.infinity,
                constraints:
                    const BoxConstraints(minHeight: CtsTheme.buttonHeight),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: widget.isLoading
                      ? CtsTheme.vivid.withValues(alpha: 0.7)
                      : CtsTheme.vivid,
                  borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
                ),
                child: Center(
                  child: widget.isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              CtsTheme.onVivid,
                            ),
                          ),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                widget.label,
                                textAlign: TextAlign.center,
                                style: CtsText.button
                                    .copyWith(color: CtsTheme.onVivid),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.arrow_forward_rounded,
                              color: CtsTheme.onVivid,
                              size: 20,
                            ),
                          ],
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ── Premium Secondary Button ────────────────────────────────────────────────

class _PremiumSecondaryButton extends StatefulWidget {
  final VoidCallback onTap;

  const _PremiumSecondaryButton({
    required this.onTap,
  });

  @override
  State<_PremiumSecondaryButton> createState() =>
      _PremiumSecondaryButtonState();
}

class _PremiumSecondaryButtonState extends State<_PremiumSecondaryButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scaleController;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      lowerBound: 0.98,
      upperBound: 1.0,
      value: 1.0,
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        onTapDown: (_) {
          _scaleController.reverse();
          HapticFeedback.lightImpact();
        },
        onTapUp: (_) {
          _scaleController.forward();
          widget.onTap();
        },
        onTapCancel: () {
          _scaleController.forward();
        },
        child: AnimatedBuilder(
          animation: _scaleController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleController.value,
              child: Container(
                width: double.infinity,
                constraints:
                    const BoxConstraints(minHeight: CtsTheme.buttonHeight),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: CtsTheme.surface,
                  borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
                  border: Border.all(color: CtsTheme.border, width: 1.2),
                ),
                child: Center(
                  child: Text(
                    'Create an account',
                    textAlign: TextAlign.center,
                    style: CtsText.button.copyWith(color: CtsTheme.textPrimary),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
