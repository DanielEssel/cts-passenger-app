// lib/features/profile/presentation/screens/privacy_security_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:local_auth/local_auth.dart';
import 'package:app_settings/app_settings.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../../widgets/common/shared_widgets.dart';
import '../../auth/providers/auth_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Provider: loads persisted privacy prefs from Firestore
// ─────────────────────────────────────────────────────────────────────────────

final _privacyPrefsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final uid = ref.watch(userIdProvider);
  if (uid == null) return {};
  final doc =
      await FirebaseFirestore.instance.collection('users').doc(uid).get();
  final data = doc.data() ?? {};
  return {
    'biometrics': data['biometricsEnabled'] ?? false,
    'marketingEmails': data['marketingEmails'] ?? true,
  };
});

// ─────────────────────────────────────────────────────────────────────────────

class PrivacySecurityScreen extends ConsumerStatefulWidget {
  const PrivacySecurityScreen({super.key});

  @override
  ConsumerState<PrivacySecurityScreen> createState() =>
      _PrivacySecurityScreenState();
}

class _PrivacySecurityScreenState extends ConsumerState<PrivacySecurityScreen> {
  final _localAuth = LocalAuthentication();

  bool _biometrics = false;
  bool _marketingEmails = true;
  bool _prefsLoaded = false;

  // ── Seed toggles from Firestore once ────────────────────────────────────

  void _seedPrefs(Map<String, dynamic> prefs) {
    if (_prefsLoaded) return;
    _prefsLoaded = true;
    _biometrics = prefs['biometrics'] as bool? ?? false;
    _marketingEmails = prefs['marketingEmails'] as bool? ?? true;
  }

  // ── Persist a single pref to Firestore ──────────────────────────────────

  Future<void> _savePref(String key, dynamic value) async {
    final uid = ref.read(userIdProvider);
    if (uid == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .update({key: value});
  }

  // ── Biometrics toggle ────────────────────────────────────────────────────

  Future<void> _toggleBiometrics(bool value) async {
    if (value) {
      // Check device support
      final canCheck = await _localAuth.canCheckBiometrics;
      final isAvailable = await _localAuth.isDeviceSupported();

      if (!canCheck || !isAvailable) {
        _showError('Biometrics not available on this device');
        return;
      }

      // Require auth before enabling
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Confirm your identity to enable biometric login',
        persistAcrossBackgrounding: true,
      );

      if (!authenticated) return;
    }

    setState(() => _biometrics = value);
    await _savePref('biometricsEnabled', value);
  }

  // ── Marketing emails toggle ──────────────────────────────────────────────

  Future<void> _toggleMarketing(bool value) async {
    setState(() => _marketingEmails = value);
    await _savePref('marketingEmails', value);
  }

  // ── Delete account ───────────────────────────────────────────────────────

  Future<void> _deleteAccount() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      // Delete Firestore data
      final batch = FirebaseFirestore.instance.batch();
      batch.delete(FirebaseFirestore.instance.collection('users').doc(uid));
      batch.delete(FirebaseFirestore.instance.collection('wallets').doc(uid));
      await batch.commit();

      // Delete Auth account
      await FirebaseAuth.instance.currentUser?.delete();

      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(
            context, AppRoutes.login, (_) => false);
      }
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        _showError(
            'Please log out and log back in before deleting your account.');
      } else {
        _showError('Failed to delete account: ${e.message}');
      }
    } catch (e) {
      _showError('Something went wrong. Please try again.');
    }
  }

  // ── Deactivate account ───────────────────────────────────────────────────

  Future<void> _deactivateAccount() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'isDeactivated': true,
        'deactivatedAt': FieldValue.serverTimestamp(),
      });

      await ref.read(authNotifierProvider.notifier).signOut();

      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(
            context, AppRoutes.login, (_) => false);
      }
    } catch (e) {
      _showError('Failed to deactivate account. Please try again.');
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final prefsAsync = ref.watch(_privacyPrefsProvider);

    return prefsAsync.when(
      loading: () => const Scaffold(
        backgroundColor: AppColors.background,
        appBar: CTSRideAppBar(title: 'Privacy & Security'),
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: const CTSRideAppBar(title: 'Privacy & Security'),
        body: Center(child: Text('Error: $e')),
      ),
      data: (prefs) {
        _seedPrefs(prefs);
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: const CTSRideAppBar(title: 'Privacy & Security'),
          body: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Security ──
                _sectionLabel('Security'),
                _Card(children: [
                  _ToggleTile(
                    icon: Icons.fingerprint_rounded,
                    label: 'Biometric login',
                    subtitle: 'Use fingerprint or face ID to sign in',
                    value: _biometrics,
                    onChanged: _toggleBiometrics,
                  ),
                  _divider(),
                  _ActionTile(
                    icon: Icons.location_on_rounded,
                    label: 'Location permissions',
                    subtitle: 'Manage in system settings',
                    onTap: () => AppSettings.openAppSettings(
                        type: AppSettingsType.location),
                  ),
                ]),

                const SizedBox(height: 16),

                // ── Privacy ──
                _sectionLabel('Privacy'),
                _Card(children: [
                  _ToggleTile(
                    icon: Icons.email_rounded,
                    label: 'Marketing emails',
                    subtitle: 'Promotions, tips and app updates',
                    value: _marketingEmails,
                    onChanged: _toggleMarketing,
                  ),
                  _divider(),
                  _ActionTile(
                    icon: Icons.download_rounded,
                    label: 'Download my data',
                    subtitle: 'Request a copy of your data',
                    onTap: _requestDataDownload,
                  ),
                ]),

                const SizedBox(height: 16),

                // ── Danger zone ──
                _sectionLabel('Danger zone'),
                _Card(
                  isDanger: true,
                  children: [
                    _ActionTile(
                      icon: Icons.block_rounded,
                      label: 'Deactivate account',
                      subtitle: 'Hide your account — reactivate anytime',
                      labelColor: AppColors.error,
                      onTap: _confirmDeactivate,
                    ),
                    _divider(),
                    _ActionTile(
                      icon: Icons.delete_forever_rounded,
                      label: 'Delete account',
                      subtitle: 'Permanently remove all your data',
                      labelColor: AppColors.error,
                      onTap: _confirmDelete,
                    ),
                  ],
                ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      );

  Widget _divider() => const Divider(
      height: 0.5, thickness: 0.5, indent: 66, color: AppColors.borderLight);

  // ── Dialogs ───────────────────────────────────────────────────────────────

  void _requestDataDownload() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Request data export', style: AppTextStyles.heading3),
        content: const Text(
          'We will prepare your data and send a download link to your registered email within 48 hours.',
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
            onPressed: () async {
              Navigator.pop(context);
              // Write a request to Firestore — your backend processes it
              final uid = FirebaseAuth.instance.currentUser?.uid;
              if (uid != null) {
                await FirebaseFirestore.instance
                    .collection('data_export_requests')
                    .add({
                  'userId': uid,
                  'status': 'pending',
                  'createdAt': FieldValue.serverTimestamp(),
                });
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'Request received — we\'ll email you within 48 hours'),
                    backgroundColor: AppColors.success,
                  ),
                );
              }
            },
            child: Text('Request',
                style:
                    AppTextStyles.bodySmall.copyWith(color: AppColors.primary)),
          ),
        ],
      ),
    );
  }

  void _confirmDeactivate() => showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title:
              const Text('Deactivate account?', style: AppTextStyles.heading3),
          content: const Text(
            'Your profile will be hidden and you\'ll be signed out. You can reactivate by logging back in.',
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
                Navigator.pop(context);
                _deactivateAccount();
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
          backgroundColor: AppColors.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Delete account?', style: AppTextStyles.heading3),
          content: const Text(
            'This cannot be undone. Your ride history, wallet balance and all data will be permanently deleted.',
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
                Navigator.pop(context);
                _deleteAccount();
              },
              child: Text('Delete permanently',
                  style:
                      AppTextStyles.bodySmall.copyWith(color: AppColors.error)),
            ),
          ],
        ),
      );

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.error),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private widgets
// ─────────────────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final List<Widget> children;
  final bool isDanger;

  const _Card({required this.children, this.isDanger = false});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDanger
                ? AppColors.error.withValues(alpha: 0.3)
                : AppColors.border,
          ),
        ),
        child: Column(children: children),
      );
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color? labelColor;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.labelColor,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: (labelColor ?? AppColors.textSecondary)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon,
                    size: 18, color: labelColor ?? AppColors.textSecondary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: AppTextStyles.bodyMedium.copyWith(
                            color: labelColor ?? AppColors.textPrimary)),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.textTertiary)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: labelColor?.withValues(alpha: 0.5) ??
                      AppColors.textTertiary,
                  size: 18),
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
  final Future<void> Function(bool) onChanged;

  const _ToggleTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

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
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: AppColors.textSecondary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: AppTextStyles.bodyMedium),
                  Text(subtitle,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textTertiary)),
                ],
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeTrackColor: AppColors.primary,
            ),
          ],
        ),
      );
}
