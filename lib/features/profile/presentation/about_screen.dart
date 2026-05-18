import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const CTSRideAppBar(title: 'About CTSRide'),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // App logo + version
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.darkNavy,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(Icons.directions_car_rounded,
                        color: AppColors.background, size: 38),
                  ),
                  const SizedBox(height: 14),
                  Text('CTSRide',
                      style: AppTextStyles.heading2
                          .copyWith(color: AppColors.background)),
                  const SizedBox(height: 4),
                  Text('Version 1.0.0 (Build 100)',
                      style: AppTextStyles.bodySmall
                          .copyWith(color: AppColors.textOnDarkMuted)),
                  const SizedBox(height: 4),
                  Text('Accra, Ghana 🇬🇭',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textOnDarkMuted)),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Links
            _buildCard([
              _LinkTile(
                  icon: Icons.description_rounded,
                  label: 'Terms of Service',
                  onTap: () {}),
              const _Div(),
              _LinkTile(
                  icon: Icons.privacy_tip_rounded,
                  label: 'Privacy Policy',
                  onTap: () {}),
              const _Div(),
              _LinkTile(
                  icon: Icons.gavel_rounded,
                  label: 'Open source licences',
                  onTap: () {}),
              const _Div(),
              _LinkTile(
                  icon: Icons.star_rounded,
                  label: 'Rate the app',
                  onTap: () {}),
              const _Div(),
              _LinkTile(
                  icon: Icons.share_rounded,
                  label: 'Share CTSRide',
                  onTap: () {}),
            ]),
            const SizedBox(height: 20),

            // System info
            _buildCard([
              const _InfoRow(label: 'Platform', value: 'Android'),
              const _Div(),
              const _InfoRow(label: 'API version', value: '1.0'),
              const _Div(),
              const _InfoRow(label: 'Region', value: 'Ghana (GH)'),
            ]),
            const SizedBox(height: 28),

            Text('Made with ❤️ in Accra',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textTertiary)),
            const SizedBox(height: 4),
            Text('© 2025 CTSRide Technologies Ltd',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textTertiary)),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: children),
      );
}

class _LinkTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _LinkTile(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(icon, size: 18, color: AppColors.textSecondary)),
          const SizedBox(width: 14),
          Expanded(child: Text(label, style: AppTextStyles.bodyMedium)),
          const Icon(Icons.chevron_right_rounded,
              color: AppColors.textTertiary, size: 18),
        ]),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label, value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(children: [
        Expanded(child: Text(label, style: AppTextStyles.bodyMedium)),
        Text(value, style: AppTextStyles.bodySmall),
      ]),
    );
  }
}

class _Div extends StatelessWidget {
  const _Div();
  @override
  Widget build(BuildContext context) => const Divider(
      height: 0.5, thickness: 0.5, indent: 66, color: AppColors.borderLight);
}
