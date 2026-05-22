import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/constants/app_strings.dart';
import '../../core/routes/app_routes.dart';
import 'onboarding_model.dart';
import '../../core/services/local/onboarding_local_service.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> 
    with TickerProviderStateMixin {
  late final PageController _pageController;
  late final AnimationController _floatController;
  int _currentPage = 0;
  double _pageOffset = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController()
      ..addListener(() {
        setState(() {
          _pageOffset = _pageController.page ?? 0;
        });
      });
    
    // Continuous floating animation for illustrations
    _floatController = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    )..repeat(reverse: true);
  }

  void _nextPage() {
    if (_currentPage < onboardingPages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      );
    } else {
      OnboardingLocalService.markCompleted();
      Navigator.of(context).pushReplacementNamed(AppRoutes.login);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _floatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLastPage = _currentPage == onboardingPages.length - 1;
    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          /// 🎨 LAYER 1: Dynamic Animated Background
          _AnimatedBackground(
            currentPage: _currentPage,
            pageOffset: _pageOffset,
          ),

          /// 🖼 LAYER 2: Hero Illustrations with Smooth Transition
          PageView.builder(
            controller: _pageController,
            itemCount: onboardingPages.length,
            onPageChanged: (index) => setState(() => _currentPage = index),
            itemBuilder: (context, index) {
              final isActive = index == _currentPage;
              final isNext = index == _currentPage + 1;
              final isPrev = index == _currentPage - 1;
              
              // Calculate smooth transition progress
              double progress = 1.0;
              if (isActive) {
                progress = 1 - (_pageOffset - index).abs();
              } else if (isNext) {
                progress = _pageOffset - _currentPage;
              } else if (isPrev) {
                progress = 1 - (_currentPage - _pageOffset);
              }
              progress = progress.clamp(0.0, 1.0);
              
              return _HeroIllustration(
                imagePath: onboardingPages[index].imagePath,
                isActive: isActive,
                progress: progress,
                floatController: _floatController,
                screenHeight: screenSize.height,
              );
            },
          ),

          /// ⏭ LAYER 3: Skip Button
          SafeArea(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: isLastPage ? 0 : 1,
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 20, top: 8),
                  child: TextButton(
                    onPressed: isLastPage 
                        ? null 
                        : () async {
                          await OnboardingLocalService.markCompleted();
                          if (context.mounted) Navigator.of(context).pushReplacementNamed(AppRoutes.login);
                        },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white.withValues(alpha: 0.9),
                      backgroundColor: Colors.white.withValues(alpha: 0.1),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    child: Text(
                      AppStrings.onboardingSkip,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          /// 🧊 LAYER 4: Glass Bottom Panel
          _BottomGlassPanel(
            currentPage: _currentPage,
            isLastPage: isLastPage,
            onNext: _nextPage,
            onBack: () {
              if (_currentPage > 0) {
                _pageController.previousPage(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

/// ============================================================================
/// ANIMATED BACKGROUND WITH GRADIENT SHIFT
/// ============================================================================

class _AnimatedBackground extends StatelessWidget {
  final int currentPage;
  final double pageOffset;

  const _AnimatedBackground({
    required this.currentPage,
    required this.pageOffset,
  });

  @override
  Widget build(BuildContext context) {
    // Blend colors between pages during transition
    final currentColors = onboardingPages[currentPage].backgroundGradient;
    final nextIndex = currentPage + 1;
    
    if (nextIndex < onboardingPages.length && pageOffset > currentPage) {
      final nextColors = onboardingPages[nextIndex].backgroundGradient;
      final t = (pageOffset - currentPage).clamp(0.0, 1.0);
      
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(currentColors[0], nextColors[0], t)!,
              Color.lerp(currentColors[1], nextColors[1], t)!,
            ],
          ),
        ),
      );
    }
    
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: currentColors,
        ),
      ),
    );
  }
}

/// ============================================================================
/// HERO ILLUSTRATION WITH BLENDING & SMOOTH TRANSITIONS
/// ============================================================================

class _HeroIllustration extends StatelessWidget {
  final String imagePath;
  final bool isActive;
  final double progress;
  final AnimationController floatController;
  final double screenHeight;

  const _HeroIllustration({
    required this.imagePath,
    required this.isActive,
    required this.progress,
    required this.floatController,
    required this.screenHeight,
  });

  @override
  Widget build(BuildContext context) {
    // Scale animation during page transition
    final scale = isActive 
        ? 1.0 - ((1 - progress) * 0.15)  // Scale down slightly when leaving
        : 0.85 + (progress * 0.15);       // Scale up when entering
    
    // Opacity for smooth blending
    final opacity = isActive 
        ? 1.0
        : progress;
    
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Transform.scale(
        scale: scale.clamp(0.85, 1.0),
        child: AnimatedBuilder(
          animation: floatController,
          builder: (context, child) {
            // Continuous floating effect
            final floatY = floatController.value * 20 - 10;
            
            return Transform.translate(
              offset: Offset(0, floatY),
              child: Container(
                width: double.infinity,
                height: screenHeight * 0.72,
                decoration: BoxDecoration(
                  // GRADIENT OVERLAY FOR BLENDING INTO BACKGROUND
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.3),
                      Colors.black.withValues(alpha: 0.6),
                    ],
                    stops: const [0.0, 0.5, 0.85, 1.0],
                  ),
                ),
                child: Center(
                  child: Image.asset(
                    imagePath,
                    height: screenHeight * 0.6,
                    fit: BoxFit.contain,
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

/// ============================================================================
/// MODERN GLASS BOTTOM PANEL
/// ============================================================================

class _BottomGlassPanel extends StatelessWidget {
  final int currentPage;
  final bool isLastPage;
  final VoidCallback onNext;
  final VoidCallback onBack;

  const _BottomGlassPanel({
    required this.currentPage,
    required this.isLastPage,
    required this.onNext,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final page = onboardingPages[currentPage];
    final screenWidth = MediaQuery.of(context).size.width;

    return Align(
      alignment: Alignment.bottomCenter,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(40)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: EdgeInsets.fromLTRB(
              24, 
              32, 
              24, 
              32 + MediaQuery.of(context).padding.bottom,
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(40)),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.15),
                width: 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                /// Animated Text with Smooth Crossfade
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.2),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: Column(
                    key: ValueKey(page.title),
                    children: [
                      Text(
                        page.title,
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: -0.5,
                          height: 1.2,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          page.subtitle,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w400,
                            color: Colors.white.withValues(alpha: 0.85),
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                /// Animated Page Indicators with Morph Effect
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    onboardingPages.length,
                    (index) => _MorphingIndicator(
                      isActive: currentPage == index,
                      width: screenWidth,
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                /// Buttons Row
                Row(
                  children: [
                    if (!isLastPage) ...[
                      Expanded(
                        child: _GlassButton(
                          label: 'Back',
                          onPressed: currentPage > 0 ? onBack : null,
                          isPrimary: false,
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                    Expanded(
                      flex: isLastPage ? 1 : 2,
                      child: _GlassButton(
                        label: isLastPage ? 'Get Started' : 'Next',
                        onPressed: onNext,
                        isPrimary: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ============================================================================
/// MORPHING PAGE INDICATOR
/// ============================================================================

class _MorphingIndicator extends StatelessWidget {
  final bool isActive;
  final double width;

  const _MorphingIndicator({
    required this.isActive,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      width: isActive ? width * 0.08 : 8,
      height: 8,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: isActive 
            ? Colors.white 
            : Colors.white.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
        boxShadow: isActive ? [
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.5),
            blurRadius: 8,
            spreadRadius: 0,
          ),
        ] : null,
      ),
    );
  }
}

/// ============================================================================
/// GLASS BUTTON WITH HAPTIC FEEDBACK
/// ============================================================================

class _GlassButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isPrimary;

  const _GlassButton({
    required this.label,
    required this.onPressed,
    required this.isPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (onPressed != null) {
          // Haptic feedback for premium feel
          // Uncomment if haptics are available:
          // HapticFeedback.lightImpact();
          onPressed!();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 56,
        decoration: BoxDecoration(
          color: isPrimary
              ? Colors.white
              : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(28),
          border: isPrimary
              ? null
              : Border.all(color: Colors.white.withValues(alpha: 0.3)),
          boxShadow: isPrimary ? [
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.3),
              blurRadius: 20,
              spreadRadius: 0,
              offset: const Offset(0, 8),
            ),
          ] : null,
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: isPrimary ? Colors.black : Colors.white,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}