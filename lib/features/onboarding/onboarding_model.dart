

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
  // Page 1 — Ride Hailing
  OnboardingModel(
    id: 1,
    title: 'Ride Smarter',
    subtitle:
        'Book trusted rides in seconds and enjoy safe, comfortable journeys wherever life takes you.',
    imagePath: 'assets/images/step1.png',
    backgroundGradient: const [
      Color(0xFF0F2027),
      Color(0xFF203A43),
      Color(0xFF2C5364),
    ],
  ),

  // Page 2 — Delivery
  OnboardingModel(
    id: 2,
    title: 'Deliver with Ease',
    subtitle:
        'Send parcels, food, and everyday essentials with fast, reliable delivery right to the doorstep.',
    imagePath: 'assets/images/step2.png',
    backgroundGradient: const [
      Color(0xFF1A0A2E),
      Color(0xFF355C7D),
      Color(0xFF6C3B5B),
    ],
  ),

  // Page 3 — Gas Delivery
  OnboardingModel(
    id: 3,
    title: 'Energy on Demand',
    subtitle:
        'Order LPG safely and have it delivered to your home with real-time tracking and dependable service.',
    imagePath: 'assets/images/step3.png',
    backgroundGradient: const [
      Color(0xFF0A1F1C),
      Color(0xFF0D3B2E),
      Color(0xFF11614E),
    ],
  ),
];