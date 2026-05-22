// lib/features/profile/presentation/screens/about_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../widgets/common/shared_widgets.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _version   = '—';
  String _buildNum  = '—';

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _version  = info.version;
      _buildNum = info.buildNumber;
    });
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link')),
        );
      }
    }
  }

  Future<void> _rateApp() async {
    // Replace with your Play Store / App Store ID
    const androidUrl =
        'https://play.google.com/store/apps/details?id=com.cts.passenger';
    await _launch(androidUrl);
  }

  void _shareApp() {
    Share.share(
      'Try CTSRide — fast, safe rides and deliveries in Ghana! '
      'Download: https://play.google.com/store/apps/details?id=com.cts.passenger',
      subject: 'CTSRide App',
    );
  }

  void _showLicenses() {
    showLicensePage(
      context: context,
      applicationName: 'CTSRide',
      applicationVersion: _version,
      applicationIcon: Padding(
        padding: const EdgeInsets.all(12),
        child: Image.asset('assests/logos/logo.png', width: 56, height: 56),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

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
            _buildHeroCard(),
            const SizedBox(height: 20),
            _buildLinksCard(),
            const SizedBox(height: 16),
            _buildInfoCard(),
            const SizedBox(height: 32),
            _buildFooter(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ── Hero ──────────────────────────────────────────────────────────────────

  Widget _buildHeroCard() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        decoration: BoxDecoration(
          color: AppColors.darkNavy,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            // Logo
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/logos/logo.png',
                  width: 80,
                  height: 80,
                  fit: BoxFit.contain,
                ),
              ),
            ),

            const SizedBox(height: 16),

            Text(
              'CTSRide',
              style: AppTextStyles.heading2
                  .copyWith(color: AppColors.background),
            ),
            const SizedBox(height: 6),

            // Version badge
            GestureDetector(
              onLongPress: () {
                // Long press copies version to clipboard — handy for bug reports
                Clipboard.setData(
                  ClipboardData(text: 'v$_version ($_buildNum)'),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Version copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'v$_version (Build $_buildNum)',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textOnDarkMuted),
                ),
              ),
            ),

            const SizedBox(height: 8),
            Text(
              'Accra, Ghana 🇬🇭',
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textOnDarkMuted),
            ),
          ],
        ),
      );

  // ── Links card ────────────────────────────────────────────────────────────

  Widget _buildLinksCard() => _Card(
        children: [
          _LinkTile(
            icon: Icons.description_rounded,
            label: 'Terms of Service',
            onTap: () => _launch('https://ctstransport.com/terms'),
          ),
          _LinkTile(
            icon: Icons.privacy_tip_rounded,
            label: 'Privacy Policy',
            onTap: () => _launch('https://ctstransport.com/privacy'),
          ),
          _LinkTile(
            icon: Icons.gavel_rounded,
            label: 'Open source licences',
            onTap: _showLicenses,
          ),
          _LinkTile(
            icon: Icons.star_rounded,
            iconColor: const Color(0xFFF59E0B),
            label: 'Rate CTSRide',
            onTap: _rateApp,
          ),
          _LinkTile(
            icon: Icons.share_rounded,
            iconColor: AppColors.primary,
            label: 'Share CTSRide',
            onTap: _shareApp,
            isLast: true,
          ),
        ],
      );

  // ── Info card ─────────────────────────────────────────────────────────────

  Widget _buildInfoCard() => _Card(
        children: [
          _InfoRow(label: 'Version',  value: _version),
          _InfoRow(label: 'Build',    value: _buildNum),
          _InfoRow(label: 'Region',   value: 'Ghana (GH)'),
          _InfoRow(label: 'Currency', value: 'GHS (₵)', isLast: true),
        ],
      );

  // ── Footer ────────────────────────────────────────────────────────────────

  Widget _buildFooter() => Column(
        children: [
          Text(
            'Made with ❤️ in Accra',
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: 4),
          Text(
            '© ${DateTime.now().year} CTSRide Technologies Ltd',
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textTertiary),
          ),
        ],
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Private widgets
// ─────────────────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: children),
      );
}

class _LinkTile extends StatelessWidget {
  final IconData     icon;
  final Color?       iconColor;
  final String       label;
  final VoidCallback onTap;
  final bool         isLast;

  const _LinkTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: (iconColor ?? AppColors.textSecondary)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: iconColor ?? AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                    child: Text(label, style: AppTextStyles.bodyMedium)),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textTertiary, size: 18),
              ],
            ),
          ),
        ),
        if (!isLast)
          const Divider(
            height: 0.5,
            thickness: 0.5,
            indent: 66,
            color: AppColors.borderLight,
          ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool   isLast;

  const _InfoRow({
    required this.label,
    required this.value,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Expanded(
                  child: Text(label, style: AppTextStyles.bodyMedium)),
              Text(
                value,
                style: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        if (!isLast)
          const Divider(
            height: 0.5,
            thickness: 0.5,
            indent: 16,
            color: AppColors.borderLight,
          ),
      ],
    );
  }
}