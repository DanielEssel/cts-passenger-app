import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../widgets/common/shared_widgets.dart';
import '../../../../core/routes/app_routes.dart';

class PrivacySecurityScreen extends StatefulWidget {
  const PrivacySecurityScreen({super.key});
  @override
  State<PrivacySecurityScreen> createState() => _PrivacySecurityScreenState();
}

class _PrivacySecurityScreenState extends State<PrivacySecurityScreen> {
  bool _biometrics = true;
  bool _locationAlways = false;
  bool _marketingEmails = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const CTSRideAppBar(title: 'Privacy & Security'),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Security ────────────────────────────────────────────────
            _sectionTitle('Security'),
            _buildCard(children: [
              _ActionTile(
                icon: Icons.lock_reset_rounded,
                label: 'Change password',
                onTap: () => _showChangePasswordSheet(),
              ),
              _divider(),
              _ToggleTile(
                icon: Icons.fingerprint_rounded,
                label: 'Biometric login',
                subtitle: 'Use fingerprint or face ID',
                value: _biometrics,
                onChanged: (v) => setState(() => _biometrics = v),
              ),
              _divider(),
              _ActionTile(
                icon: Icons.devices_rounded,
                label: 'Active sessions',
                trailing: '2 devices',
                onTap: () => _showSessionsSheet(),
              ),
            ]),

            const SizedBox(height: 16),

            // ── Privacy ────────────────────────────────────────────────
            _sectionTitle('Privacy'),
            _buildCard(children: [
              _ToggleTile(
                icon: Icons.location_on_rounded,
                label: 'Always share location',
                subtitle: 'Required for ride tracking',
                value: _locationAlways,
                onChanged: (v) => setState(() => _locationAlways = v),
              ),
              _divider(),
              _ToggleTile(
                icon: Icons.email_rounded,
                label: 'Marketing emails',
                subtitle: 'Promos and updates',
                value: _marketingEmails,
                onChanged: (v) => setState(() => _marketingEmails = v),
              ),
              _divider(),
              _ActionTile(
                icon: Icons.download_rounded,
                label: 'Download my data',
                onTap: () {},
              ),
            ]),

            const SizedBox(height: 16),

            // ── Danger zone ────────────────────────────────────────────
            _sectionTitle('Danger zone'),
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border:
                    Border.all(color: AppColors.error.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  _ActionTile(
                    icon: Icons.block_rounded,
                    label: 'Deactivate account',
                    labelColor: AppColors.error,
                    onTap: () => _confirmDeactivate(),
                  ),
                  _divider(),
                  _ActionTile(
                    icon: Icons.delete_forever_rounded,
                    label: 'Delete account',
                    labelColor: AppColors.error,
                    onTap: () => _confirmDelete(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: AppTextStyles.caption.copyWith(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
      );

  Widget _buildCard({required List<Widget> children}) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: children),
      );

  Widget _divider() => const Divider(
      height: 0.5, thickness: 0.5, indent: 66, color: AppColors.borderLight);

  void _showChangePasswordSheet() {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
                child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            const Text('Change password', style: AppTextStyles.heading3),
            const SizedBox(height: 16),
            _PasswordField(controller: currentCtrl, label: 'Current password'),
            const SizedBox(height: 12),
            _PasswordField(controller: newCtrl, label: 'New password'),
            const SizedBox(height: 12),
            _PasswordField(
                controller: confirmCtrl, label: 'Confirm new password'),
            const SizedBox(height: 20),
            PrimaryButton(
                label: 'Update password', onTap: () => Navigator.pop(context)),
          ],
        ),
      ),
    );
  }

  void _showSessionsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
                child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            const Text('Active sessions', style: AppTextStyles.heading3),
            const SizedBox(height: 16),
            const _SessionTile(
                device: 'Samsung Galaxy S23',
                location: 'Accra, Ghana',
                isCurrent: true),
            const SizedBox(height: 10),
            const _SessionTile(
                device: 'iPhone 14',
                location: 'Kumasi, Ghana',
                isCurrent: false),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.errorLight,
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: AppColors.error.withValues(alpha: 0.2)),
                ),
                child: const Text('Sign out all other devices',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.error)),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _confirmDeactivate() => showDialog(
        context: context,
        builder: (_) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title:
              const Text('Deactivate account?', style: AppTextStyles.heading3),
          content: const Text(
              'Your account will be hidden. You can reactivate it by logging in.',
              style: AppTextStyles.bodySmall),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pushNamedAndRemoveUntil(
                    context, AppRoutes.login, (r) => false);
              },
              child: Text('Deactivate',
                  style:
                      AppTextStyles.bodySmall.copyWith(color: AppColors.error)),
            ),
          ],
        ),
      );

  void _confirmDelete() => showDialog(
        context: context,
        builder: (_) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Delete account?', style: AppTextStyles.heading3),
          content: const Text(
              'This is permanent. All your data, ride history and wallet balance will be lost.',
              style: AppTextStyles.bodySmall),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pushNamedAndRemoveUntil(
                    context, AppRoutes.login, (r) => false);
              },
              child: Text('Delete permanently',
                  style:
                      AppTextStyles.bodySmall.copyWith(color: AppColors.error)),
            ),
          ],
        ),
      );
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  final Color? labelColor;
  final VoidCallback onTap;
  const _ActionTile(
      {required this.icon,
      required this.label,
      this.trailing,
      this.labelColor,
      required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(9)),
                  child: Icon(icon,
                      size: 18, color: labelColor ?? AppColors.textSecondary)),
              const SizedBox(width: 14),
              Expanded(
                  child: Text(label,
                      style: AppTextStyles.bodyMedium.copyWith(
                          color: labelColor ?? AppColors.textPrimary))),
              if (trailing != null)
                Text(trailing!, style: AppTextStyles.caption),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded,
                  color: labelColor ?? AppColors.textTertiary, size: 18),
            ],
          ),
        ),
      );
}

class _ToggleTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleTile(
      {required this.icon,
      required this.label,
      required this.subtitle,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(icon, size: 18, color: AppColors.textSecondary)),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTextStyles.bodyMedium),
                Text(subtitle, style: AppTextStyles.caption),
              ],
            )),
            Switch.adaptive(
                value: value,
                onChanged: onChanged,
                activeColor: AppColors.primary),
          ],
        ),
      );
}

class _SessionTile extends StatelessWidget {
  final String device, location;
  final bool isCurrent;
  const _SessionTile(
      {required this.device, required this.location, required this.isCurrent});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: isCurrent
                  ? AppColors.primary.withValues(alpha: 0.4)
                  : AppColors.border),
        ),
        child: Row(
          children: [
            Icon(Icons.phone_android_rounded,
                color: isCurrent ? AppColors.primary : AppColors.textSecondary,
                size: 22),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device, style: AppTextStyles.labelLarge),
                Text(location, style: AppTextStyles.caption),
              ],
            )),
            if (isCurrent)
              Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('This device',
                      style: AppTextStyles.caption.copyWith(
                          color: AppColors.success,
                          fontWeight: FontWeight.w600))),
          ],
        ),
      );
}

class _PasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  const _PasswordField({required this.controller, required this.label});
  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _obscure = true;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: AppTextStyles.labelLarge),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: TextField(
            controller: widget.controller,
            obscureText: _obscure,
            style: AppTextStyles.bodyMedium,
            decoration: InputDecoration(
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              suffixIcon: GestureDetector(
                onTap: () => setState(() => _obscure = !_obscure),
                child: Icon(
                    _obscure
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                    size: 18,
                    color: AppColors.textSecondary),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
