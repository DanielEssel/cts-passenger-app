// lib/features/auth/presentation/screens/welcome_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../widgets/buttons/primary_button.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  String _firstName = '';

  @override
  void initState() {
    super.initState();
    _loadName();
  }

  Future<void> _loadName() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final name = (doc.data()?['displayName'] as String?)?.trim() ?? '';
    if (!mounted) return;
    setState(() => _firstName = name.isEmpty ? '' : name.split(' ').first);
  }

  // Marks welcome as seen so this never shows again, then routes onward.
  Future<void> _finish({required String route}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      // Fire-and-forget — a failed flag write shouldn't trap the user here.
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'hasSeenWelcome': true}).catchError((_) {});
    }
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, route, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // Celebratory mark
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.celebration_rounded,
                    size: 46, color: AppColors.primary),
              ),
              const SizedBox(height: 28),

              Text(
                _firstName.isEmpty ? 'Welcome! 🎉' : 'Welcome, $_firstName! 🎉',
                style: AppTextStyles.display,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Rides, deliveries and gas — all in one place, across Ghana.',
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 32),

              // Value chips
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: const [
                  _ValueChip(
                      icon: Icons.two_wheeler_rounded, label: 'Fast rides'),
                  _ValueChip(
                      icon: Icons.inventory_2_rounded, label: 'Deliveries'),
                  _ValueChip(
                      icon: Icons.local_fire_department_rounded,
                      label: 'Gas refills'),
                  _ValueChip(
                      icon: Icons.account_balance_wallet_rounded,
                      label: 'Wallet · MoMo · Cash'),
                ],
              ),

              const Spacer(flex: 3),

              PrimaryButton(
                label: "Let's go",
                onTap: () => _finish(route: AppRoutes.shell),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => _finish(route: AppRoutes.savedPlaces),
                child: Text(
                  'Set your home address first',
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: AppColors.primary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ValueChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _ValueChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: AppColors.primary),
            const SizedBox(width: 7),
            Text(label,
                style: AppTextStyles.bodySmall
                    .copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      );
}
