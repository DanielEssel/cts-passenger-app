import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';

class PaymentMethodsScreen extends StatefulWidget {
  const PaymentMethodsScreen({super.key});
  @override
  State<PaymentMethodsScreen> createState() => _PaymentMethodsScreenState();
}

class _PaymentMethodsScreenState extends State<PaymentMethodsScreen> {
  int _defaultIndex = 0;

  final List<_PayMethod> _methods = [
    const _PayMethod(
        type: 'wallet',
        label: 'CTSRide Wallet',
        sub: 'Balance: GHS 250.50',
        icon: Icons.account_balance_wallet_rounded,
        color: AppColors.primary),
    const _PayMethod(
        type: 'momo',
        label: 'MTN Mobile Money',
        sub: '+233 24 123 4567',
        icon: Icons.phone_android_rounded,
        color: Color(0xFFFFCC00)),
    const _PayMethod(
        type: 'card',
        label: 'Visa •••• 4321',
        sub: 'Expires 08/27',
        icon: Icons.credit_card_rounded,
        color: Color(0xFF1A1F71)),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const CTSRideAppBar(title: 'Payment Methods'),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Wallet balance card
            _buildWalletCard(),
            const SizedBox(height: 20),

            const Text('Saved methods', style: AppTextStyles.heading4),
            const SizedBox(height: 10),

            ..._methods.asMap().entries.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _PayMethodTile(
                    method: e.value,
                    isDefault: _defaultIndex == e.key,
                    onSetDefault: () => setState(() => _defaultIndex = e.key),
                    onRemove: e.value.type == 'wallet'
                        ? null
                        : () => setState(() => _methods.removeAt(e.key)),
                  ),
                )),

            const SizedBox(height: 8),

            // Add new method buttons
            _buildAddOption(
              icon: Icons.phone_android_rounded,
              label: 'Add Mobile Money',
              color: const Color(0xFFFFCC00),
              onTap: () => _showAddSheet('momo'),
            ),
            const SizedBox(height: 10),
            _buildAddOption(
              icon: Icons.credit_card_rounded,
              label: 'Add Debit / Credit Card',
              color: AppColors.info,
              onTap: () => _showAddSheet('card'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildWalletCard() {
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
                Text('CTSRide Wallet',
                    style: AppTextStyles.labelLarge
                        .copyWith(color: AppColors.background)),
                const SizedBox(height: 2),
                Text('Available balance',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textOnDarkMuted)),
              ],
            ),
          ),
          Text('GHS 250.50',
              style:
                  AppTextStyles.heading3.copyWith(color: AppColors.background)),
        ],
      ),
    );
  }

  Widget _buildAddOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border, style: BorderStyle.solid),
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

  void _showAddSheet(String type) {
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
            Text(type == 'momo' ? 'Add Mobile Money' : 'Add Card',
                style: AppTextStyles.heading3),
            const SizedBox(height: 16),
            if (type == 'momo') ...[
              const _SheetLabel('Mobile number'),
              const SizedBox(height: 8),
              const _SheetInput(
                  hint: '+233 — phone number',
                  keyboardType: TextInputType.phone),
              const SizedBox(height: 12),
              const _SheetLabel('Network'),
              const SizedBox(height: 8),
              Row(
                children: ['MTN', 'Vodafone', 'AirtelTigo']
                    .map((n) => Expanded(
                            child: Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(n,
                              style: AppTextStyles.labelMedium,
                              textAlign: TextAlign.center),
                        )))
                    .toList(),
              ),
            ] else ...[
              const _SheetLabel('Card number'),
              const SizedBox(height: 8),
              const _SheetInput(
                  hint: '0000  0000  0000  0000',
                  keyboardType: TextInputType.number),
              const SizedBox(height: 12),
              const Row(children: [
                Expanded(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SheetLabel('Expiry'),
                    SizedBox(height: 8),
                    _SheetInput(
                        hint: 'MM / YY', keyboardType: TextInputType.number),
                  ],
                )),
                SizedBox(width: 12),
                Expanded(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SheetLabel('CVV'),
                    SizedBox(height: 8),
                    _SheetInput(
                        hint: '•••', keyboardType: TextInputType.number),
                  ],
                )),
              ]),
              const SizedBox(height: 12),
              const _SheetLabel('Name on card'),
              const SizedBox(height: 8),
              const _SheetInput(hint: 'Full name'),
            ],
            const SizedBox(height: 20),
            PrimaryButton(
                label: 'Add payment method',
                onTap: () => Navigator.pop(context)),
          ],
        ),
      ),
    );
  }
}

class _PayMethod {
  final String type, label, sub;
  final IconData icon;
  final Color color;
  const _PayMethod(
      {required this.type,
      required this.label,
      required this.sub,
      required this.icon,
      required this.color});
}

class _PayMethodTile extends StatelessWidget {
  final _PayMethod method;
  final bool isDefault;
  final VoidCallback onSetDefault;
  final VoidCallback? onRemove;
  const _PayMethodTile(
      {required this.method,
      required this.isDefault,
      required this.onSetDefault,
      this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: isDefault ? AppColors.primary : AppColors.border,
            width: isDefault ? 1.5 : 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: method.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(method.icon, color: method.color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(method.label, style: AppTextStyles.labelLarge),
                Text(method.sub, style: AppTextStyles.caption),
              ],
            ),
          ),
          if (isDefault)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('Default',
                  style: AppTextStyles.caption.copyWith(
                      color: AppColors.primary, fontWeight: FontWeight.w600)),
            )
          else
            GestureDetector(
              onTap: onSetDefault,
              child: Text('Set default',
                  style: AppTextStyles.caption.copyWith(
                      color: AppColors.primary, fontWeight: FontWeight.w600)),
            ),
          if (onRemove != null) ...[
            const SizedBox(width: 10),
            GestureDetector(
              onTap: onRemove,
              child: const Icon(Icons.close_rounded,
                  color: AppColors.textTertiary, size: 16),
            ),
          ],
        ],
      ),
    );
  }
}

class _SheetLabel extends StatelessWidget {
  final String text;
  const _SheetLabel(this.text);
  @override
  Widget build(BuildContext context) =>
      Text(text, style: AppTextStyles.labelLarge);
}

class _SheetInput extends StatelessWidget {
  final String hint;
  final TextInputType? keyboardType;
  const _SheetInput({required this.hint, this.keyboardType});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: TextField(
        keyboardType: keyboardType,
        style: AppTextStyles.bodyMedium,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:
              AppTextStyles.bodySmall.copyWith(color: AppColors.textTertiary),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }
}
