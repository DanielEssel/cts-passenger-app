import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';

class HelpSupportScreen extends StatefulWidget {
  const HelpSupportScreen({super.key});
  @override
  State<HelpSupportScreen> createState() => _HelpSupportScreenState();
}

class _HelpSupportScreenState extends State<HelpSupportScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  int? _expandedFaq;

  final List<Map<String, String>> _faqs = [
    {
      'q': 'How do I book a ride?',
      'a':
          'Tap "Book Ride" on the home screen, enter your destination, choose a vehicle type, and confirm. A nearby driver will be matched to you.'
    },
    {
      'q': 'How is the fare calculated?',
      'a':
          'Fares are based on a base fee plus a per-kilometre rate. Delivery fares also factor in the weight tier of your parcel.'
    },
    {
      'q': 'Can I cancel a ride?',
      'a':
          'Yes, you can cancel before a driver is assigned for free. After a driver is matched, a small cancellation fee may apply.'
    },
    {
      'q': 'How do I top up my wallet?',
      'a':
          'Go to the Wallet tab and tap "Add Money". You can top up via Mobile Money (MTN, Vodafone, AirtelTigo) or a debit/credit card.'
    },
    {
      'q': 'What is Aboboya delivery?',
      'a':
          'Aboboya is our tricycle delivery service for medium loads (5–100 kg). Great for market goods, appliances, and bulk items.'
    },
    {
      'q': 'How do I track my delivery?',
      'a':
          'After confirming a delivery, you can track the rider in real time on the delivery tracking screen. You can also share a tracking link with the receiver.'
    },
    {
      'q': 'What if my driver doesn\'t show up?',
      'a':
          'You can call or message your driver directly. If unreachable, cancel the ride and you won\'t be charged. Contact support for a refund if needed.'
    },
    {
      'q': 'How do referrals work?',
      'a':
          'Share your referral link from the Promotions screen. When a friend signs up and takes their first ride, both of you earn GHS 5.'
    },
  ];

  List<Map<String, String>> get _filtered {
    if (_query.isEmpty) return _faqs;
    final q = _query.toLowerCase();
    return _faqs
        .where((f) =>
            f['q']!.toLowerCase().contains(q) ||
            f['a']!.toLowerCase().contains(q))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const CTSRideAppBar(title: 'Help & Support'),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Search
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: TextField(
                controller: _searchCtrl,
                style: AppTextStyles.bodyMedium,
                decoration: const InputDecoration(
                  hintText: 'Search help articles…',
                  hintStyle: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: AppColors.textTertiary),
                  prefixIcon: Icon(Icons.search_rounded,
                      color: AppColors.textSecondary, size: 20),
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Contact options
            const Text('Contact us', style: AppTextStyles.heading4),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: _ContactCard(
                icon: Icons.chat_rounded,
                label: 'Live chat',
                sub: 'Avg. 2 min reply',
                color: AppColors.primary,
                onTap: () {},
              )),
              const SizedBox(width: 10),
              Expanded(
                  child: _ContactCard(
                icon: Icons.phone_rounded,
                label: 'Call us',
                sub: '0302 000 000',
                color: AppColors.success,
                onTap: () {},
              )),
              const SizedBox(width: 10),
              Expanded(
                  child: _ContactCard(
                icon: Icons.email_rounded,
                label: 'Email',
                sub: 'support@CTSRide',
                color: AppColors.info,
                onTap: () {},
              )),
            ]),
            const SizedBox(height: 20),

            // Report a trip
            GestureDetector(
              onTap: () => _showReportTripSheet(),
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
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: AppColors.error.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.report_problem_rounded,
                            color: AppColors.error, size: 20)),
                    const SizedBox(width: 12),
                    const Expanded(
                        child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Report a trip issue',
                            style: AppTextStyles.labelLarge),
                        Text('Problem with a ride or delivery?',
                            style: AppTextStyles.caption),
                      ],
                    )),
                    const Icon(Icons.chevron_right_rounded,
                        color: AppColors.textTertiary, size: 18),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // FAQ
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Frequently asked', style: AppTextStyles.heading4),
                if (_query.isNotEmpty)
                  Text('${_filtered.length} results',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.primary)),
              ],
            ),
            const SizedBox(height: 10),

            if (_filtered.isEmpty)
              Center(
                  child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('No results for "$_query"',
                    style: AppTextStyles.bodySmall),
              ))
            else
              ..._filtered.asMap().entries.map((e) {
                final isOpen = _expandedFaq == e.key;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: isOpen ? AppColors.primary : AppColors.border,
                        width: isOpen ? 1.5 : 0.5),
                  ),
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: () => setState(
                            () => _expandedFaq = isOpen ? null : e.key),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Expanded(
                                  child: Text(e.value['q']!,
                                      style: AppTextStyles.labelLarge.copyWith(
                                          color: isOpen
                                              ? AppColors.primary
                                              : AppColors.textPrimary))),
                              Icon(
                                  isOpen
                                      ? Icons.keyboard_arrow_up_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                  color: isOpen
                                      ? AppColors.primary
                                      : AppColors.textTertiary,
                                  size: 20),
                            ],
                          ),
                        ),
                      ),
                      if (isOpen)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                          child: Text(e.value['a']!,
                              style: AppTextStyles.bodySmall
                                  .copyWith(height: 1.6)),
                        ),
                    ],
                  ),
                );
              }),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  void _showReportTripSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) {
        final ctrl = TextEditingController();
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
              Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              const Text('Report a trip issue', style: AppTextStyles.heading3),
              const SizedBox(height: 14),
              const Text('Issue type', style: AppTextStyles.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  'Overcharged',
                  'Driver behaviour',
                  'Wrong route',
                  'Parcel damaged',
                  'Driver no-show',
                  'Other',
                ]
                    .map((t) => GestureDetector(
                          onTap: () {},
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceAlt,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Text(t, style: AppTextStyles.labelMedium),
                          ),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 14),
              const Text('Description', style: AppTextStyles.labelLarge),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: TextField(
                  controller: ctrl,
                  maxLines: 4,
                  style: AppTextStyles.bodyMedium,
                  decoration: const InputDecoration(
                    hintText: 'Describe the issue…',
                    hintStyle: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        color: AppColors.textTertiary),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                  label: 'Submit report', onTap: () => Navigator.pop(context)),
            ],
          ),
        );
      },
    );
  }
}

class _ContactCard extends StatelessWidget {
  final IconData icon;
  final String label, sub;
  final Color color;
  final VoidCallback onTap;
  const _ContactCard(
      {required this.icon,
      required this.label,
      required this.sub,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: [
          Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20)),
          const SizedBox(height: 8),
          Text(label,
              style: AppTextStyles.labelMedium, textAlign: TextAlign.center),
          const SizedBox(height: 2),
          Text(sub,
              style: AppTextStyles.caption,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}
