import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';

class ProfileScreen extends StatelessWidget {
  final ScrollController scrollController;

  const ProfileScreen({
    super.key,
    required this.scrollController,
  });

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
      icon: Icons.card_giftcard_rounded,
      label: 'Promotions & Referrals',
      route: AppRoutes.promotions,
      badge: '2 active',
    ),
    _MenuItem(
      icon: Icons.notifications_rounded,
      label: 'Notifications',
      route: AppRoutes.notifications,
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _buildProfileHeader(context),
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  // Menu card
                  Container(
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
                            _buildMenuItem(context, e.value, e.key),
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
                  ),
                  const SizedBox(height: 16),
                  // Logout
                  GestureDetector(
                    onTap: () => _confirmLogout(context),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: AppColors.errorLight,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: AppColors.error.withValues(alpha: 0.2)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.logout_rounded,
                              color: AppColors.error, size: 20),
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
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Version 1.0.0',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textTertiary),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileHeader(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(color: AppColors.darkNavy),
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 16,
        left: 20,
        right: 20,
        bottom: 24,
      ),
      child: Column(
        children: [
          Stack(
            children: [
              CircleAvatar(
                radius: 36,
                backgroundColor: AppColors.primary,
                child: Text('JD',
                    style: AppTextStyles.heading2
                        .copyWith(color: AppColors.background)),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onTap: () =>
                      Navigator.pushNamed(context, AppRoutes.editProfile),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.darkNavy, width: 2),
                    ),
                    child: const Icon(Icons.camera_alt_rounded,
                        size: 13, color: AppColors.textSecondary),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('John Doe',
              style:
                  AppTextStyles.heading3.copyWith(color: AppColors.background)),
          const SizedBox(height: 4),
          Text('+233 24 123 4567',
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textOnDarkMuted)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              children: [
                _ProfileStat(value: '23', label: 'Rides'),
                _VerticalDivider(),
                _ProfileStat(value: '4.9★', label: 'Rating'),
                _VerticalDivider(),
                _ProfileStat(value: '8', label: 'Deliveries'),
                _VerticalDivider(),
                _ProfileStat(value: 'Gold', label: 'Tier'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuItem(BuildContext context, _MenuItem item, int index) {
    final isFirst = index == 0;
    final isLast = index == _menuItems.length - 1;

    return GestureDetector(
      onTap: () {
        Navigator.pushNamed(context, item.route);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.only(
            topLeft: isFirst ? const Radius.circular(16) : Radius.zero,
            topRight: isFirst ? const Radius.circular(16) : Radius.zero,
            bottomLeft: isLast ? const Radius.circular(16) : Radius.zero,
            bottomRight: isLast ? const Radius.circular(16) : Radius.zero,
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
              child: Icon(item.icon, size: 18, color: AppColors.textSecondary),
            ),
            const SizedBox(width: 14),
            Expanded(child: Text(item.label, style: AppTextStyles.bodyMedium)),
            if (item.badge != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  item.badge!,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textTertiary, size: 18),
          ],
        ),
      ),
    );
  }

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Log out?', style: AppTextStyles.heading3),
        content: const Text(
          'Are you sure you want to log out of your account?',
          style: AppTextStyles.bodySmall,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel',
                style: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context); // close dialog
              // Clear entire stack back to login
              Navigator.pushNamedAndRemoveUntil(
                context,
                AppRoutes.login,
                (route) => false,
              );
            },
            child: Text('Log out',
                style:
                    AppTextStyles.bodySmall.copyWith(color: AppColors.error)),
          ),
        ],
      ),
    );
  }
}

class _MenuItem {
  final IconData icon;
  final String label;
  final String? badge;
  final String route;
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.route,
    this.badge,
  });
}

class _VerticalDivider extends StatelessWidget {
  const _VerticalDivider();
  @override
  Widget build(BuildContext context) => Container(
      width: 0.5, height: 32, color: Colors.white.withValues(alpha: 0.15));
}

class _ProfileStat extends StatelessWidget {
  final String value;
  final String label;
  const _ProfileStat({required this.value, required this.label});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style:
                  AppTextStyles.heading4.copyWith(color: AppColors.background)),
          const SizedBox(height: 2),
          Text(label,
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textOnDarkMuted),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
