// lib/widgets/common/glass_card.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';

/// A beautiful glassmorphism card widget with frosted glass effect
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final BorderRadiusGeometry? borderRadius; // Changed from double to BorderRadiusGeometry
  final double blurStrength;
  final Color? backgroundColor;
  final Border? border;
  final List<BoxShadow>? boxShadow;
  final VoidCallback? onTap;
  final bool enableBackdropFilter; // Option to disable backdrop filter for performance

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.borderRadius,
    this.blurStrength = 10,
    this.backgroundColor,
    this.border,
    this.boxShadow,
    this.onTap,
    this.enableBackdropFilter = true,
  });

  /// Helper constructor for circular glass cards
   GlassCard.circular({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.width,
    this.height,
    this.blurStrength = 10,
    this.backgroundColor,
    this.border,
    this.boxShadow,
    this.onTap,
    this.enableBackdropFilter = true,
  }) : borderRadius = BorderRadius.circular(100); // Circular border radius

  @override
  Widget build(BuildContext context) {
    final borderRadiusValue = borderRadius ?? BorderRadius.circular(16);
    
    Widget card = Container(
      width: width,
      height: height,
      padding: padding ?? const EdgeInsets.all(16),
      margin: margin,
      decoration: BoxDecoration(
        color: backgroundColor ?? Colors.white.withValues(alpha: 0.08),
        borderRadius: borderRadiusValue,
        border: border ??
            Border.all(
              color: Colors.white.withValues(alpha: 0.15),
              width: 0.5,
            ),
        boxShadow: boxShadow ??
            [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: blurStrength,
                offset: const Offset(0, 2),
              ),
            ],
      ),
      child: enableBackdropFilter
          ? ClipRRect(
              borderRadius: borderRadiusValue,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blurStrength, sigmaY: blurStrength),
                child: child,
              ),
            )
          : child,
    );

    if (onTap != null) {
      card = GestureDetector(
        onTap: onTap,
        child: card,
      );
    }

    return card;
  }
}

/// Glass card with gradient border
class GradientGlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadiusGeometry? borderRadius; // Changed from double to BorderRadiusGeometry
  final Gradient borderGradient;
  final double borderWidth;

  const GradientGlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius,
    this.borderGradient = const LinearGradient(
      colors: [AppColors.primary, Colors.purple],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    this.borderWidth = 1.5,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadiusValue = borderRadius ?? BorderRadius.circular(16);
    final innerBorderRadius = borderRadiusValue is BorderRadius
        ? BorderRadius.circular(borderRadiusValue.topLeft.x - borderWidth)
        : BorderRadius.circular(16 - borderWidth);
    
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadiusValue,
        gradient: borderGradient,
      ),
      child: Container(
        margin: EdgeInsets.all(borderWidth),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: innerBorderRadius,
        ),
        child: ClipRRect(
          borderRadius: innerBorderRadius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: padding ?? const EdgeInsets.all(16),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass card that expands on hover/tap (for web/desktop)
class InteractiveGlassCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final BorderRadiusGeometry? borderRadius; // Changed from double to BorderRadiusGeometry
  final double elevation;
  final Duration animationDuration;

  const InteractiveGlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding,
    this.borderRadius,
    this.elevation = 4,
    this.animationDuration = const Duration(milliseconds: 200),
  });

  @override
  State<InteractiveGlassCard> createState() => _InteractiveGlassCardState();
}

class _InteractiveGlassCardState extends State<InteractiveGlassCard> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final translateY = _isHovered ? -4.0 : 0.0;
    final scale = _isPressed ? 0.98 : 1.0;
    
    return MouseRegion(
  onEnter: (_) => setState(() => _isHovered = true),
  onExit: (_) => setState(() => _isHovered = false),
  child: AnimatedContainer(
    duration: widget.animationDuration,
    transform: Matrix4.identity()
      ..translate(0.0, translateY)
      ..scale(scale),
    child: GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      child: GlassCard(
        padding: widget.padding,
        borderRadius: widget.borderRadius,
        child: widget.child,
      ),
    ),
  ),
);
  }
}

/// Extension for easy GlassCard creation with radius values
extension GlassCardExtension on Widget {
  /// Wrap widget with GlassCard
  Widget withGlassCard({
    EdgeInsetsGeometry? padding,
    EdgeInsetsGeometry? margin,
    double? width,
    double? height,
    BorderRadiusGeometry? borderRadius,
    double blurStrength = 10,
    Color? backgroundColor,
    Border? border,
    List<BoxShadow>? boxShadow,
    VoidCallback? onTap,
    bool enableBackdropFilter = true,
  }) {
    return GlassCard(
      padding: padding,
      margin: margin,
      width: width,
      height: height,
      borderRadius: borderRadius,
      blurStrength: blurStrength,
      backgroundColor: backgroundColor,
      border: border,
      boxShadow: boxShadow,
      onTap: onTap,
      enableBackdropFilter: enableBackdropFilter,
      child: this,
    );
  }
}

/// Convenient radius values for common use cases
class GlassCardRadius {
  static const BorderRadius small = BorderRadius.all(Radius.circular(8));
  static const BorderRadius medium = BorderRadius.all(Radius.circular(12));
  static const BorderRadius large = BorderRadius.all(Radius.circular(16));
  static const BorderRadius xLarge = BorderRadius.all(Radius.circular(24));
  static const BorderRadius circular = BorderRadius.all(Radius.circular(100));
  
  // Custom radius creator
  static BorderRadius custom(double radius) => BorderRadius.all(Radius.circular(radius));
}

/// Theme extension for consistent GlassCard styling
class GlassCardTheme {
  final BorderRadiusGeometry defaultBorderRadius;
  final double defaultBlurStrength;
  final Color defaultBackgroundColor;
  final EdgeInsetsGeometry defaultPadding;
  
  const GlassCardTheme({
    this.defaultBorderRadius = const BorderRadius.all(Radius.circular(16)),
    this.defaultBlurStrength = 10,
    this.defaultBackgroundColor = const Color(0x14FFFFFF),
    this.defaultPadding = const EdgeInsets.all(16),
  });
  
  static GlassCardTheme of(BuildContext context) {
    // You can implement theme provider here
    return const GlassCardTheme();
  }
}