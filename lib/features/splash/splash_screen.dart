// lib/features/splash/splash_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/app_colors.dart';
import '../../core/theme/cts_theme.dart';
import '../../core/startup/startup_resolver.dart';
import '../../core/startup/route_destination.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/update_required_dialog.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _boot();
  }

  void _initAnimations() {
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _fadeAnim = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.7, curve: Curves.easeIn),
    );
    _scaleAnim = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _controller.forward();
  }

  Future<void> _boot() async {
    final results = await Future.wait([
      StartupResolver.resolve(),
      AppUpdateService.check(),
      Future.delayed(const Duration(milliseconds: 1800)),
    ]);

    if (!mounted) return;

    final destination = results[0] as RouteDestination;
    final updateInfo = results[1] as AppUpdateInfo;

    if (updateInfo.updateRequired) {
      await UpdateRequiredDialog.show(context, updateInfo);
      if (!mounted) return;
    }

    Navigator.pushReplacementNamed(
      context,
      destination.route,
      arguments: destination.arguments,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Get screen dimensions for responsive positioning
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: CtsTheme.forest,
        body: Stack(
          children: [
            // Center positioned logo (using Positioned.fill for full screen)
            Positioned.fill(
              child: _buildLogo(),
            ),
            // Bottom positioned tagline
            Positioned(
              bottom: bottomPadding + 32,
              left: 0,
              right: 0,
              child: _buildBottomTagline(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return FadeTransition(
      opacity: _fadeAnim,
      child: ScaleTransition(
        scale: _scaleAnim,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Official CTSGo logo on a white plate (the artwork has a
              // white background, so it is never clipped or recoloured).
              Container(
                width: 112,
                height: 112,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Center(
                  child: Image.asset(
                    'assets/logos/ctsgo_logo.png',
                    width: 96,
                    height: 96,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.local_taxi_rounded,
                      size: 60,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              // Brand Name
              Text(
                'CTSGo',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.95),
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 16),
              // Decorative line with animation
              Container(
                width: 60,
                height: 2,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      CtsTheme.apple,
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Tagline
              Text(
                'Safe • Fast • Reliable',
                style: TextStyle(
                  color: CtsTheme.onForestMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomTagline() {
    return FadeTransition(
      opacity: _fadeAnim,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation<Color>(CtsTheme.apple),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            "GHANA'S CHOICE FOR LOGISTICS",
            style: TextStyle(
              color: CtsTheme.onForestMuted,
              fontSize: 12,
              letterSpacing: 1.6,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Version ${_getAppVersion()}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  String _getAppVersion() {
    // You can get this from pubspec.yaml or build.gradle
    return '1.0.0';
  }
}
