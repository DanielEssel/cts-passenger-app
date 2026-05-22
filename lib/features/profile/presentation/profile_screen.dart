// lib/features/profile/presentation/screens/profile_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../core/routes/app_routes.dart';
import '../../auth/providers/auth_providers.dart';

// ── Real-time user stream ─────────────────────────────────────────────────────

final userStreamProvider = StreamProvider.autoDispose<UserData?>((ref) {
  final uid = ref.watch(userIdProvider);
  if (uid == null) return Stream.value(null);

  return FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .snapshots()
      .map((doc) => doc.exists ? UserData.fromFirestore(doc) : null);
});

// ─────────────────────────────────────────────────────────────────────────────

class ProfileScreen extends ConsumerWidget {
  final ScrollController scrollController;

  const ProfileScreen({super.key, required this.scrollController});

  static const List<_MenuItem> _menuItems = [
    _MenuItem(
      icon: Icons.edit_rounded,
      label: 'Edit Profile',
      route: AppRoutes.editProfile,
    ),
    _MenuItem(
      icon: Icons.location_on_rounded,
      label: 'Saved Places',
      route: AppRoutes.savedPlaces,
    ),
    _MenuItem(
      icon: Icons.credit_card_rounded,
      label: 'Payment Methods',
      route: AppRoutes.paymentMethods,
    ),
    _MenuItem(
      icon: Icons.lock_rounded,
      label: 'Privacy & Security',
      route: AppRoutes.privacySecurity,
    ),
    _MenuItem(
      icon: Icons.help_rounded,
      label: 'Help & Support',
      route: AppRoutes.helpSupport,
    ),
    _MenuItem(
      icon: Icons.info_rounded,
      label: 'About CTSRide',
      route: AppRoutes.about,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(userStreamProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          userAsync.when(
            data:    (u) => _buildHeader(context, ref, u),
            loading: ()  => _buildHeader(context, ref, null),
            error:   (_, __) => _buildHeader(context, ref, null),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              physics: const BouncingScrollPhysics(),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  _buildMenuCard(context),
                  const SizedBox(height: 16),
                  _buildLogoutButton(context, ref),
                  const SizedBox(height: 24),
                  Text('Version 1.0.0',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textTertiary)),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context, WidgetRef ref, UserData? user) {
    final displayName = user?.displayName ??
        [user?.firstName, user?.lastName]
            .where((s) => s != null && s.isNotEmpty)
            .join(' ');
    final phone = user?.phoneNumber ??
        ref.read(userPhoneProvider) ??
        '';

    return Container(
      decoration: const BoxDecoration(color: AppColors.darkNavy),
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 16,
        left: 20,
        right: 20,
        bottom: 28,
      ),
      child: Column(
        children: [
          // ── Avatar ──
          Stack(
            children: [
              AvatarWidget(
                photoURL: user?.photoURL,
                displayName: displayName.isNotEmpty ? displayName : '?',
                radius: 40,
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onTap: () =>
                      Navigator.pushNamed(context, AppRoutes.editProfile),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: AppColors.darkNavy, width: 2.5),
                    ),
                    child: const Icon(Icons.camera_alt_rounded,
                        size: 13, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // ── Name ──
          user == null
              ? _SkeletonLine(width: 140, height: 20)
              : Text(
                  displayName.isNotEmpty ? displayName : 'Passenger',
                  style: AppTextStyles.heading3
                      .copyWith(color: AppColors.background),
                ),

          const SizedBox(height: 6),

          // ── Phone ──
          user == null
              ? _SkeletonLine(width: 100, height: 14)
              : Text(
                  phone,
                  style: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.textOnDarkMuted),
                ),
        ],
      ),
    );
  }

  // ── Menu card ────────────────────────────────────────────────────────────────

  Widget _buildMenuCard(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: _menuItems.asMap().entries.map((e) {
            final isLast = e.key == _menuItems.length - 1;
            return Column(
              children: [
                _buildMenuTile(context, e.value, e.key),
                if (!isLast)
                  const Divider(
                    height: 0.5,
                    thickness: 0.5,
                    indent: 66,
                    color: AppColors.borderLight,
                  ),
              ],
            );
          }).toList(),
        ),
      );

  Widget _buildMenuTile(BuildContext context, _MenuItem item, int index) {
    final isFirst = index == 0;
    final isLast  = index == _menuItems.length - 1;

    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, item.route),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.only(
            topLeft:     isFirst ? const Radius.circular(16) : Radius.zero,
            topRight:    isFirst ? const Radius.circular(16) : Radius.zero,
            bottomLeft:  isLast  ? const Radius.circular(16) : Radius.zero,
            bottomRight: isLast  ? const Radius.circular(16) : Radius.zero,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(item.icon,
                  size: 18, color: AppColors.textSecondary),
            ),
            const SizedBox(width: 14),
            Expanded(
                child: Text(item.label, style: AppTextStyles.bodyMedium)),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textTertiary, size: 18),
          ],
        ),
      ),
    );
  }

  // ── Logout ───────────────────────────────────────────────────────────────────

  Widget _buildLogoutButton(BuildContext context, WidgetRef ref) =>
      GestureDetector(
        onTap: () => _confirmLogout(context, ref),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.errorLight,
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: AppColors.error.withValues(alpha: 0.2)),
          ),
          child: const Row(
            children: [
              Icon(Icons.logout_rounded, color: AppColors.error, size: 20),
              SizedBox(width: 12),
              Text(
                'Log Out',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.error,
                ),
              ),
            ],
          ),
        ),
      );

  void _confirmLogout(BuildContext context, WidgetRef ref) {
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog( // ← use dialogContext
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Log out?', style: AppTextStyles.heading3),
      content: const Text(
        'Are you sure you want to log out?',
        style: AppTextStyles.bodySmall,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext), // ← dialogContext
          child: Text('Cancel',
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textSecondary)),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop(dialogContext); // ← close dialog first
            try {
              await ref.read(authNotifierProvider.notifier).signOut();
            } catch (_) {}
            // Use root navigator to clear entire stack
            if (context.mounted) {
              Navigator.of(context, rootNavigator: true)
                  .pushNamedAndRemoveUntil(
                AppRoutes.login,
                (_) => false,
              );
            }
          },
          child: Text('Log out',
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.error)),
        ),
      ],
    ),
  );
}
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared avatar widget — used by both screens
// ─────────────────────────────────────────────────────────────────────────────

class AvatarWidget extends StatelessWidget {
  final String? photoURL;
  final String displayName;
  final double radius;

  const AvatarWidget({
    super.key, // ← add this
    required this.photoURL,
    required this.displayName,
    this.radius = 40,
  });

  /// Deterministic color from name so it's always the same per user
  Color get _bgColor {
    const colors = [
      Color(0xFF6366F1), Color(0xFF8B5CF6), Color(0xFFEC4899),
      Color(0xFFEF4444), Color(0xFFF97316), Color(0xFF10B981),
      Color(0xFF06B6D4), Color(0xFF3B82F6),
    ];
    final index = displayName.codeUnits.fold(0, (a, b) => a + b) % colors.length;
    return colors[index];
  }

  String get _initials {
    final parts = displayName.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return displayName.isNotEmpty
        ? displayName[0].toUpperCase()
        : '?';
  }

  @override
  Widget build(BuildContext context) {
    if (photoURL != null && photoURL!.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: NetworkImage(photoURL!),
        backgroundColor: _bgColor,
        onBackgroundImageError: (_, __) {},
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: _bgColor,
      child: Text(
        _initials,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: radius * 0.5,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

// ── Skeleton loader ───────────────────────────────────────────────────────────

class _SkeletonLine extends StatelessWidget {
  final double width;
  final double height;
  const _SkeletonLine({required this.width, required this.height});

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
      );
}

// ── Models ────────────────────────────────────────────────────────────────────

class _MenuItem {
  final IconData icon;
  final String   label;
  final String   route;
  const _MenuItem(
      {required this.icon, required this.label, required this.route});
}