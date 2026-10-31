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
      Color(0xFF0A2416), // CTSGo deep greens
      Color(0xFF0F3D24),
      Color(0xFF166534),
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
      Color(0xFF0B2A1A),
      Color(0xFF124A2C),
      Color(0xFF1B6B3A),
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
      Color(0xFF0A2416),
      Color(0xFF0F3D24),
      Color(0xFF15803D),
    ],
  ),
];
