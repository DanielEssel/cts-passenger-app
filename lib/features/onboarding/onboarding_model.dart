// lib/features/onboarding/onboarding_model.dart
//
// ✅ Page 3 gradient darkened — bright #38EF7D was unreadable with white text
// ✅ All gradients now use 3 stops for smoother blending
// ✅ Colors stay in the dark cinematic palette across all pages

import 'package:flutter/material.dart';

class OnboardingModel {
  final int id;
  final String title;
  final String subtitle;
  final String imagePath;
  final List<Color> backgroundGradient;

  const OnboardingModel({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.imagePath,
    required this.backgroundGradient,
  });
}

final List<OnboardingModel> onboardingPages = [
  // Page 1 — deep ocean blue
  OnboardingModel(
    id: 1,
    title: 'Book Rides in Seconds',
    subtitle:
        'Connect with nearby drivers instantly and travel safely and comfortably.',
    imagePath: 'assets/images/step1.png',
    backgroundGradient: const [
      Color(0xFF0F2027),
      Color(0xFF203A43),
      Color(0xFF2C5364),
    ],
  ),

  // Page 2 — deep purple-rose
  OnboardingModel(
    id: 2,
    title: 'Lightning-Fast Delivery',
    subtitle:
        'Send food, parcels, and packages across the city quickly and reliably.',
    imagePath: 'assets/images/step2.png',
    backgroundGradient: const [
      Color(0xFF1A0A2E),
      Color(0xFF355C7D),
      Color(0xFF6C3B5B),
    ],
  ),

  // Page 3 — dark teal (was bright green — now readable with white text)
  OnboardingModel(
    id: 3,
    title: 'Safe & Cashless Payments',
    subtitle:
        'Pay securely with multiple payment options and track every trip in real time.',
    imagePath: 'assets/images/step3.png',
    backgroundGradient: const [
      Color(0xFF0A1F1C),
      Color(0xFF0D3B2E),
      Color(0xFF11614E),
    ],
  ),
];