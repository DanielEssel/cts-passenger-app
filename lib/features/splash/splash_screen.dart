// lib/features/splash/splash_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/app_colors.dart';
import '../../core/startup/startup_resolver.dart';
import '../../core/startup/route_destination.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double>   _fadeAnim;
  late final Animation<double>   _scaleAnim;

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _boot();
  }

  void _initAnimations() {
    _controller = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1400),
    );
    _fadeAnim = CurvedAnimation(
      parent: _controller,
      curve:  const Interval(0.0, 0.7, curve: Curves.easeIn),
    );
    _scaleAnim = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _controller.forward();
  }

  Future<void> _boot() async {
    final results = await Future.wait([
      StartupResolver.resolve(),
      Future.delayed(const Duration(milliseconds: 1800)),
    ]);

    if (!mounted) return;

    final destination = results[0] as RouteDestination;

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
        backgroundColor: const Color(0xFF0B1019),
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
              // Logo Container with proper sizing
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.primaryColor.withValues(alpha: 0.1),
                      AppColors.primaryColor.withValues(alpha: 0.05),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Image.asset(
                    'assets/logos/logo.png',
                    width: 80,
                    height: 80,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.local_taxi_rounded,
                      size:  60,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              // Brand Name
              Text(
                'CTS TRANSPORT',
                style: TextStyle(
                  color:         Colors.white.withValues(alpha: 0.95),
                  fontSize:      18,
                  fontWeight:    FontWeight.w600,
                  letterSpacing: 8,
                  fontFamily: 'Poppins',
                ),
              ),
              const SizedBox(height: 16),
              // Decorative line with animation
              Container(
                width:  60,
                height: 2,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      AppColors.primaryColor,
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
                  color:         Colors.white.withValues(alpha: 0.5),
                  fontSize:      12,
                  fontWeight:    FontWeight.w400,
                  letterSpacing: 2,
                  fontFamily: 'Inter',
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
            width:  24,
            height: 24,
            child:  CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white24),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            "GHANA'S CHOICE FOR LOGISTICS",
            style: TextStyle(
              color:         Colors.white24,
              fontSize:      10,
              letterSpacing: 2,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Version ${_getAppVersion()}',
            style: const TextStyle(
              color:         Colors.white12,
              fontSize:      8,
              letterSpacing: 1,
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