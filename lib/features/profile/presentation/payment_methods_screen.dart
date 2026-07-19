// lib/features/profile/presentation/screens/payment_methods_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../widgets/common/shared_widgets.dart';
import '../../wallet/presentation/providers/wallet_providers.dart';
import '../../wallet/domain/entities/wallet.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

class SavedMoMo {
  final String? id;
  final String phone;
  final String network; // 'mtn' | 'vodafone' | 'airteltigo'
  final bool isDefault;
  final DateTime? createdAt;

  const SavedMoMo({
    this.id,
    required this.phone,
    required this.network,
    this.isDefault = false,
    this.createdAt,
  });

  factory SavedMoMo.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return SavedMoMo(
      id: doc.id,
      phone: d['phone'] as String? ?? '',
      network: d['network'] as String? ?? 'mtn',
      isDefault: d['isDefault'] as bool? ?? false,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'phone': phone,
        'network': network,
        'isDefault': isDefault,
        'createdAt': FieldValue.serverTimestamp(),
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

final _momoMethodsProvider = StreamProvider.autoDispose<List<SavedMoMo>>((ref) {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return Stream.value([]);

  return FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .collection('momo_methods')
      .orderBy('createdAt', descending: false)
      .snapshots()
      .map((s) => s.docs.map(SavedMoMo.fromFirestore).toList());
});

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class PaymentMethodsScreen extends ConsumerWidget {
  const PaymentMethodsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final walletAsync = ref.watch(walletStreamProvider);
    final momoAsync = ref.watch(_momoMethodsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const CTSTransportAppBar(title: 'Payment Methods'),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Wallet card ──
            walletAsync.when(
              data: (w) => _WalletCard(wallet: w),
              loading: () => _WalletCard(wallet: null),
              error: (_, __) => _WalletCard(wallet: null),
            ),

            const SizedBox(height: 24),

            // ── Mobile Money ──
            const Text('Mobile Money', style: AppTextStyles.heading4),
            const SizedBox(height: 10),

            momoAsync.when(
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              ),
              error: (e, _) => _ErrorTile(message: e.toString()),
              data: (methods) => Column(
                children: [
                  ...methods.map((m) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _MoMoTile(
                          momo: m,
                          onSetDefault: () => _setDefault(context, m, methods),
                          onDelete: () => _deleteMoMo(context, m),
                        ),
                      )),
                  _AddOptionTile(
                    icon: Icons.phone_android_rounded,
                    label: 'Add Mobile Money number',
                    color: const Color(0xFFFFCC00),
                    onTap: () => _showAddMoMoSheet(context),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── Cards via Paystack ──
            const Text('Debit / Credit Card', style: AppTextStyles.heading4),
            const SizedBox(height: 10),
            _InfoTile(
              icon: Icons.credit_card_rounded,
              title: 'Pay by card via Paystack',
              subtitle:
                  'Cards are handled securely by Paystack during checkout. '
                  'No card details are stored on our servers.',
            ),

            const SizedBox(height: 24),

            // ── How payments work ──
            _HowItWorksCard(),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ── Set default ──────────────────────────────────────────────────────────

  Future<void> _setDefault(
    BuildContext context,
    SavedMoMo selected,
    List<SavedMoMo> all,
  ) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final col = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('momo_methods');

    final batch = FirebaseFirestore.instance.batch();

    // Clear all defaults then set the selected one
    for (final m in all) {
      if (m.id != null) {
        batch.update(col.doc(m.id), {'isDefault': m.id == selected.id});
      }
    }

    try {
      await batch.commit();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to update: $e'),
          backgroundColor: AppColors.error,
        ));
      }
    }
  }

  // ── Delete MoMo ──────────────────────────────────────────────────────────

  Future<void> _deleteMoMo(BuildContext context, SavedMoMo momo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove number?', style: AppTextStyles.heading3),
        content: Text(
          'Remove ${momo.phone} from your payment methods?',
          style: AppTextStyles.bodySmall,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel',
                style: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Remove',
                style:
                    AppTextStyles.bodySmall.copyWith(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirmed != true || momo.id == null) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('momo_methods')
          .doc(momo.id)
          .delete();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to remove: $e'),
          backgroundColor: AppColors.error,
        ));
      }
    }
  }

  // ── Add MoMo sheet ────────────────────────────────────────────────────────

  void _showAddMoMoSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => _AddMoMoSheet(
        onSaved: (momo) async {
          Navigator.pop(sheetCtx);
          await _saveMoMo(context, momo);
        },
      ),
    );
  }

  Future<void> _saveMoMo(BuildContext context, SavedMoMo momo) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('momo_methods')
          .add(momo.toFirestore());

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(children: [
              Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('Mobile Money number saved'),
            ]),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to save: $e'),
          backgroundColor: AppColors.error,
        ));
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add MoMo sheet
// ─────────────────────────────────────────────────────────────────────────────

class _AddMoMoSheet extends StatefulWidget {
  final void Function(SavedMoMo) onSaved;
  const _AddMoMoSheet({required this.onSaved});

  @override
  State<_AddMoMoSheet> createState() => _AddMoMoSheetState();
}

class _AddMoMoSheetState extends State<_AddMoMoSheet> {
  final _phoneCtrl = TextEditingController();
  String _network = 'mtn';

  static const _networks = [
    _Network(key: 'mtn', label: 'MTN', color: Color(0xFFFFCC00)),
    _Network(key: 'vodafone', label: 'Vodafone', color: Color(0xFFE60000)),
    _Network(key: 'airteltigo', label: 'AirtelTigo', color: Color(0xFF0070CD)),
  ];

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final phone = _phoneCtrl.text.trim();

    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a phone number'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    // Basic Ghana phone validation
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 9 || digits.length > 12) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid Ghana phone number'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    widget.onSaved(SavedMoMo(
      phone: phone,
      network: _network,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
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
          // Handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Add Mobile Money', style: AppTextStyles.heading3),
          const SizedBox(height: 4),
          const Text(
            'Save a number for faster checkout',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 20),

          // ── Network selector ──
          const Text('Network', style: AppTextStyles.labelLarge),
          const SizedBox(height: 10),
          Row(
            children: _networks.map((n) {
              final isSel = _network == n.key;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _network = n.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: isSel
                          ? n.color.withValues(alpha: 0.15)
                          : AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSel ? n.color : AppColors.border,
                        width: isSel ? 1.5 : 0.5,
                      ),
                    ),
                    child: Text(
                      n.label,
                      style: AppTextStyles.labelMedium.copyWith(
                        color: isSel ? n.color : AppColors.textSecondary,
                        fontWeight: isSel ? FontWeight.w700 : FontWeight.w400,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 16),

          // ── Phone number ──
          const Text('Phone number', style: AppTextStyles.labelLarge),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              style: AppTextStyles.bodyMedium,
              decoration: InputDecoration(
                hintText: '+233 XX XXX XXXX',
                hintStyle: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textTertiary),
                prefixIcon: const Icon(Icons.phone_rounded,
                    size: 18, color: AppColors.textSecondary),
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
          ),

          const SizedBox(height: 24),

          PrimaryButton(label: 'Save number', onTap: _submit),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private widgets
// ─────────────────────────────────────────────────────────────────────────────

class _WalletCard extends StatelessWidget {
  final Wallet? wallet;
  const _WalletCard({required this.wallet});

  @override
  Widget build(BuildContext context) {
    final balance = wallet?.balance ?? 0.0;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.darkNavy,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.account_balance_wallet_rounded,
                color: AppColors.primary, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CTSTransport Wallet',
                    style: AppTextStyles.labelLarge
                        .copyWith(color: AppColors.background)),
                const SizedBox(height: 2),
                Text('Available balance',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textOnDarkMuted)),
              ],
            ),
          ),
          wallet == null
              ? Container(
                  width: 80,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                )
              : Text(
                  'GHS ${balance.toStringAsFixed(2)}',
                  style: AppTextStyles.heading3
                      .copyWith(color: AppColors.background),
                ),
        ],
      ),
    );
  }
}

class _MoMoTile extends StatelessWidget {
  final SavedMoMo momo;
  final VoidCallback onSetDefault;
  final VoidCallback onDelete;

  const _MoMoTile({
    required this.momo,
    required this.onSetDefault,
    required this.onDelete,
  });

  Color get _networkColor {
    switch (momo.network) {
      case 'mtn':
        return const Color(0xFFFFCC00);
      case 'vodafone':
        return const Color(0xFFE60000);
      case 'airteltigo':
        return const Color(0xFF0070CD);
      default:
        return AppColors.primary;
    }
  }

  String get _networkLabel {
    switch (momo.network) {
      case 'mtn':
        return 'MTN MoMo';
      case 'vodafone':
        return 'Vodafone Cash';
      case 'airteltigo':
        return 'AirtelTigo Money';
      default:
        return 'Mobile Money';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: momo.isDefault ? AppColors.primary : AppColors.border,
          width: momo.isDefault ? 1.5 : 0.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _networkColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.phone_android_rounded,
                color: _networkColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_networkLabel, style: AppTextStyles.labelLarge),
                Text(momo.phone, style: AppTextStyles.caption),
              ],
            ),
          ),
          if (momo.isDefault)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('Default',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  )),
            )
          else
            GestureDetector(
              onTap: onSetDefault,
              child: Text('Set default',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  )),
            ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: onDelete,
            child: const Icon(Icons.close_rounded,
                color: AppColors.textTertiary, size: 16),
          ),
        ],
      ),
    );
  }
}

class _AddOptionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _AddOptionTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: AppTextStyles.bodyMedium)),
              const Icon(Icons.add_rounded, color: AppColors.primary, size: 20),
            ],
          ),
        ),
      );
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _InfoTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.info.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: AppColors.info, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.labelLarge),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: AppTextStyles.caption.copyWith(height: 1.5)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _HowItWorksCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline_rounded,
                    color: AppColors.primary, size: 18),
                const SizedBox(width: 8),
                Text('How payments work',
                    style: AppTextStyles.labelLarge
                        .copyWith(color: AppColors.primary)),
              ],
            ),
            const SizedBox(height: 12),
            _Step(
              number: '1',
              text:
                  'Top up your CTSTransport Wallet using MoMo or card via Paystack',
            ),
            const SizedBox(height: 8),
            _Step(
              number: '2',
              text:
                  'Your wallet balance is used automatically when you book a ride or order gas',
            ),
            const SizedBox(height: 8),
            _Step(
              number: '3',
              text: 'All transactions are secured and processed by Paystack',
            ),
          ],
        ),
      );
}

class _Step extends StatelessWidget {
  final String number;
  final String text;
  const _Step({required this.number, required this.text});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(number,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  )),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child:
                Text(text, style: AppTextStyles.caption.copyWith(height: 1.5)),
          ),
        ],
      );
}

class _ErrorTile extends StatelessWidget {
  final String message;
  const _ErrorTile({required this.message});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.errorLight,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded,
                color: AppColors.error, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Could not load payment methods',
                  style:
                      AppTextStyles.bodySmall.copyWith(color: AppColors.error)),
            ),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal model
// ─────────────────────────────────────────────────────────────────────────────

class _Network {
  final String key;
  final String label;
  final Color color;
  const _Network({
    required this.key,
    required this.label,
    required this.color,
  });
}
