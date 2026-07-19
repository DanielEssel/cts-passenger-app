import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';

class PromotionsScreen extends StatefulWidget {
  const PromotionsScreen({super.key});
  @override
  State<PromotionsScreen> createState() => _PromotionsScreenState();
}

class _PromotionsScreenState extends State<PromotionsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final TextEditingController _codeCtrl = TextEditingController();

  final List<_Promo> _active = [
    const _Promo(
        code: 'RIDE20',
        title: '20% off next 3 rides',
        desc: 'Valid on Taxi and Okada bookings',
        expiry: 'Expires Apr 14',
        color: AppColors.primary,
        icon: Icons.directions_car_rounded),
    const _Promo(
        code: 'DELIVER10',
        title: 'GHS 10 off delivery',
        desc: 'Valid on any delivery order over GHS 25',
        expiry: 'Expires Apr 20',
        color: AppColors.info,
        icon: Icons.inventory_2_rounded),
  ];

  final List<_Promo> _used = [
    const _Promo(
        code: 'WELCOME15',
        title: '15% off first ride',
        desc: 'Welcome offer — used',
        expiry: 'Expired Mar 1',
        color: AppColors.textTertiary,
        icon: Icons.celebration_rounded,
        isUsed: true),
  ];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const CTSTransportAppBar(title: 'Promotions & Referrals'),
      body: Column(
        children: [
          // Promo code entry
          _buildCodeEntry(),
          // Tabs
          Container(
            color: AppColors.surface,
            child: TabBar(
              controller: _tab,
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.textSecondary,
              indicatorColor: AppColors.primary,
              indicatorWeight: 2,
              tabs: const [Tab(text: 'Active'), Tab(text: 'Used')],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _buildPromoList(_active),
                _buildPromoList(_used),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeEntry() {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Have a promo code?', style: AppTextStyles.heading4),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: TextField(
                    controller: _codeCtrl,
                    textCapitalization: TextCapitalization.characters,
                    style: AppTextStyles.bodyMedium.copyWith(
                        fontWeight: FontWeight.w600, letterSpacing: 1),
                    decoration: const InputDecoration(
                      hintText: 'Enter code',
                      hintStyle: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          color: AppColors.textTertiary,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0),
                      border: InputBorder.none,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _applyCode,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('Apply', style: AppTextStyles.buttonSmall),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Referral card
          _buildReferralCard(),
        ],
      ),
    );
  }

  Widget _buildReferralCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.darkNavy, AppColors.deepBlue],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.people_rounded,
              color: AppColors.background, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Invite friends, earn GHS 5',
                    style: AppTextStyles.labelLarge
                        .copyWith(color: AppColors.background)),
                const SizedBox(height: 2),
                Text('They get GHS 5 off their first ride too',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textOnDarkMuted)),
              ],
            ),
          ),
          GestureDetector(
            onTap: _shareReferral,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('Share', style: AppTextStyles.buttonSmall),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPromoList(List<_Promo> promos) {
    if (promos.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.local_offer_rounded,
                size: 48, color: AppColors.textTertiary),
            SizedBox(height: 12),
            Text('No promotions here', style: AppTextStyles.heading4),
            SizedBox(height: 6),
            Text('Enter a code above to add one',
                style: AppTextStyles.bodySmall),
          ],
        ),
      );
    }
    return ListView.separated(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: promos.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _PromoTile(promo: promos[i]),
    );
  }

  void _applyCode() {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            code == 'TESTCODE' ? 'Promo applied!' : 'Invalid or expired code'),
        duration: const Duration(seconds: 2),
      ),
    );
    _codeCtrl.clear();
  }

  void _shareReferral() {
    Clipboard.setData(
        const ClipboardData(text: 'https://ctsride.app/ref/JOHN123'));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Referral link copied to clipboard'),
          duration: Duration(seconds: 2)),
    );
  }
}

class _Promo {
  final String code, title, desc, expiry;
  final Color color;
  final IconData icon;
  final bool isUsed;
  const _Promo(
      {required this.code,
      required this.title,
      required this.desc,
      required this.expiry,
      required this.color,
      required this.icon,
      this.isUsed = false});
}

class _PromoTile extends StatelessWidget {
  final _Promo promo;
  const _PromoTile({required this.promo});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: promo.isUsed ? 0.5 : 1.0,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: promo.color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(promo.icon, color: promo.color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(promo.title, style: AppTextStyles.labelLarge),
                  const SizedBox(height: 2),
                  Text(promo.desc, style: AppTextStyles.caption),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Text(promo.code,
                            style: AppTextStyles.caption.copyWith(
                                fontWeight: FontWeight.w700,
                                fontFamily: 'monospace')),
                      ),
                      const SizedBox(width: 8),
                      Text(promo.expiry, style: AppTextStyles.caption),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
