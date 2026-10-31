// features/auth/presentation/signup_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/theme/cts_theme.dart';
import '../../../core/routes/app_routes.dart';
import '../providers/auth_providers.dart';
import '../../auth/widgets/auth_widgets.dart';
import 'package:flutter/gestures.dart';
import '../../../../core/legal/legal_urls.dart'; // adjust depth to match

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen>
    with SingleTickerProviderStateMixin {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneKey = GlobalKey<PhoneInputFieldState>();
  final _formKey = GlobalKey<FormState>();

  bool _agreeToTerms = false;

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
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _animController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _signup() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_agreeToTerms) {
      _showError('Please accept the Terms & Conditions to continue');
      return;
    }
    HapticFeedback.mediumImpact();

    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final email = _emailController.text.trim();

    // ✅ E.164 number with country code from PhoneInputField
    final phone =
        _phoneKey.currentState?.fullNumber ?? _phoneController.text.trim();

    // ── Check if phone number already registered ──
    try {
      final existing = await FirebaseFirestore.instance
          .collection('users')
          .where('phoneNumber', isEqualTo: phone)
          .limit(1)
          .get();

      if (existing.docs.isNotEmpty) {
        _showError(
            'This number is already registered. Please sign in instead.');
        return;
      }
    } catch (e) {
      // Non-fatal — let the flow continue if check fails
      debugPrint('Phone existence check failed: $e');
    }

    await ref.read(authProvider.notifier).signUp(
          firstName: firstName,
          lastName: lastName,
          phone: phone,
          email: email,
          onCodeSent: () {
            Navigator.pushNamed(
              context,
              AppRoutes.otpVerification,
              arguments: {
                'phone': phone,
                'isSignUp': true,
                'firstName': firstName,
                'lastName': lastName,
                'email': email,
              },
            );
          },
          onAuthenticated: () {
            if (!context.mounted) return;

            Navigator.of(context).pushNamedAndRemoveUntil(
              AppRoutes.welcome,
              (_) => false,
            );
          },
          onError: (msg) {
            if (!context.mounted) return;

            // Keep your existing error UI.
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(msg)),
            );
          },
        );
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

  // ---------------------------------------------------------------------------
  // Validators
  // ---------------------------------------------------------------------------

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) return 'This field is required';
    if (value.trim().length < 2) return 'Must be at least 2 characters';
    return null;
  }

  String? _validatePhone(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Phone number is required';
    }
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 9) return 'Enter a valid phone number';
    return null;
  }

  String? _validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) return null; // optional
    final emailRegex = RegExp(r'^[\w\-.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(value.trim())) {
      return 'Enter a valid email address';
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(authProvider).isLoading;

    return Scaffold(
      backgroundColor: AppColors.background,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // Refined background glows - reduced size and opacity
          Positioned(
            top: -50,
            left: -60,
            child: AuthGlow(
              color: AppColors.primary,
              size: 200,
              opacity: 0.10,
            ),
          ),
          Positioned(
            bottom: 120,
            right: -50,
            child: AuthGlow(
              color: CtsTheme.apple,
              size: 160,
              opacity: 0.08,
            ),
          ),

          SafeArea(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: SlideTransition(
                position: _slideAnim,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 12),
                        // Premium Back Button - larger touch target
                        const _PremiumBackButton(),
                        const SizedBox(height: 24),
                        // Premium Logo - refined icon card
                        const _PremiumSignupLogo(),
                        const SizedBox(height: 32),

                        // Typography with better hierarchy
                        Semantics(
                          header: true,
                          child: const Text('Create account',
                              style: CtsText.title1),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Join thousands riding smarter across Ghana',
                          style: CtsText.body
                              .copyWith(color: CtsTheme.textSecondary),
                        ),
                        const SizedBox(height: 28),

                        // Name row with premium styling
                        Row(
                          children: [
                            Expanded(
                              child: AuthFormField(
                                label: 'First name',
                                hint: 'John',
                                controller: _firstNameController,
                                validator: _validateName,
                                enabled: !isLoading,
                                textCapitalization: TextCapitalization.words,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: AuthFormField(
                                label: 'Last name',
                                hint: 'Doe',
                                controller: _lastNameController,
                                validator: _validateName,
                                enabled: !isLoading,
                                textCapitalization: TextCapitalization.words,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),

                        // Phone with premium styling
                        const AuthFieldLabel('Phone number'),
                        const SizedBox(height: 6),
                        SizedBox(
                          child: PhoneInputField(
                            key: _phoneKey,
                            controller: _phoneController,
                            validator: _validatePhone,
                            enabled: !isLoading,
                          ),
                        ),
                        const SizedBox(height: 18),

                        // Email field with premium styling
                        AuthFormField(
                          label: 'Email (optional)',
                          hint: 'john@example.com',
                          controller: _emailController,
                          validator: _validateEmail,
                          enabled: !isLoading,
                          keyboardType: TextInputType.emailAddress,
                          prefixIcon: Icons.mail_outline_rounded,
                        ),
                        const SizedBox(height: 24),

                        // Premium Terms checkbox
                        _PremiumTermsCheckbox(
                          value: _agreeToTerms,
                          onChanged: (v) => setState(() => _agreeToTerms = v),
                        ),
                        const SizedBox(height: 32),

                        // Premium CTA Button with enhanced interactions
                        _PremiumSignupButton(
                          label: 'Create Account',
                          isLoading: isLoading,
                          onTap: _signup,
                        ),
                        const SizedBox(height: 24),

                        // Premium Sign in link
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const Text(
                              'Already have an account? ',
                              style: CtsText.bodySmall,
                            ),
                            GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                Navigator.pushReplacementNamed(
                                  context,
                                  AppRoutes.login,
                                );
                              },
                              child: Container(
                                constraints: const BoxConstraints(
                                    minHeight: CtsTheme.minTouch),
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                child: Text(
                                  'Sign in',
                                  style: CtsText.label.copyWith(
                                    color: CtsTheme.primary,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ],
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

// =============================================================================
// Premium Back Button
// =============================================================================

class _PremiumBackButton extends StatelessWidget {
  const _PremiumBackButton();

  @override
  Widget build(BuildContext context) {
    return const AuthBackButton();
  }
}

// =============================================================================
// Premium Signup Logo
// =============================================================================

class _PremiumSignupLogo extends StatelessWidget {
  const _PremiumSignupLogo();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Image.asset(
        'assets/logos/logo.png',
        width: 150,
        fit: BoxFit.contain,
      ),
    );
  }
}

// =============================================================================
// Premium Terms Checkbox
// =============================================================================

class _PremiumTermsCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _PremiumTermsCheckbox({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: value,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onChanged(!value);
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: value ? CtsTheme.primary : CtsTheme.surface,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: value ? CtsTheme.primary : CtsTheme.textTertiary,
                  width: 1.5,
                ),
              ),
              child: value
                  ? const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 16,
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: CtsText.bodySmall.copyWith(height: 1.5),
                  children: [
                    const TextSpan(
                        text: 'I confirm I am 18 or older and agree to the '),
                    TextSpan(
                      text: 'Terms & Conditions',
                      style: CtsText.bodySmall.copyWith(
                        color: CtsTheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                      recognizer: TapGestureRecognizer()
                        ..onTap =
                            () => LegalUrls.open(context, LegalUrls.terms),
                    ),
                    const TextSpan(text: ' and '),
                    TextSpan(
                      text: 'Privacy Policy',
                      style: CtsText.bodySmall.copyWith(
                        color: CtsTheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                      recognizer: TapGestureRecognizer()
                        ..onTap =
                            () => LegalUrls.open(context, LegalUrls.privacy),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Premium Signup Button
// =============================================================================

class _PremiumSignupButton extends StatefulWidget {
  final String label;
  final bool isLoading;
  final VoidCallback onTap;

  const _PremiumSignupButton({
    required this.label,
    required this.isLoading,
    required this.onTap,
  });

  @override
  State<_PremiumSignupButton> createState() => _PremiumSignupButtonState();
}

class _PremiumSignupButtonState extends State<_PremiumSignupButton>
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
                              Icons.person_add_rounded,
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
