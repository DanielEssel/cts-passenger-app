// lib/core/providers/navigation_providers.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Single global key — shared across the app
final navigatorKeyProvider = Provider<GlobalKey<NavigatorState>>((ref) {
  return appNavigatorKey;
});

// Declared here so main.dart and providers share the same instance
final appNavigatorKey = GlobalKey<NavigatorState>();