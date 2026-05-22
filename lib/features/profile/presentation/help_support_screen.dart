// lib/features/profile/presentation/screens/help_support_screen.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────────

class HelpSupportScreen extends StatefulWidget {
  const HelpSupportScreen({super.key});

  @override
  State<HelpSupportScreen> createState() => _HelpSupportScreenState();
}

class _HelpSupportScreenState extends State<HelpSupportScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query        = '';
  int?   _expandedFaq;

  static const List<Map<String, String>> _faqs = [
    {
      'q': 'How do I book a ride?',
      'a': 'Tap "Book Ride" on the home screen, enter your destination, choose a vehicle type, and confirm. A nearby driver will be matched to you.',
    },
    {
      'q': 'How is the fare calculated?',
      'a': 'Fares are based on a base fee plus a per-kilometre rate. Delivery fares also factor in the weight tier of your parcel.',
    },
    {
      'q': 'Can I cancel a ride?',
      'a': 'Yes, you can cancel before a driver is assigned for free. After a driver is matched, a small cancellation fee may apply.',
    },
    {
      'q': 'How do I top up my wallet?',
      'a': 'Go to the Wallet tab and tap "Add Money". You can top up via Mobile Money (MTN, Vodafone, AirtelTigo) or a debit/credit card.',
    },
    {
      'q': 'What is Aboboya delivery?',
      'a': 'Aboboya is our tricycle delivery service for medium loads (5–100 kg). Great for market goods, appliances, and bulk items.',
    },
    {
      'q': 'How do I track my delivery?',
      'a': 'After confirming a delivery, track the rider in real time on the delivery tracking screen. You can also share a tracking link with the receiver.',
    },
    {
      'q': "What if my driver doesn't show up?",
      'a': "Call or message your driver directly. If unreachable, cancel the ride and you won't be charged. Contact support for a refund if needed.",
    },
    {
      'q': 'How do referrals work?',
      'a': 'Share your referral link from the Promotions screen. When a friend signs up and takes their first ride, both of you earn GHS 5.',
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
    _searchCtrl.addListener(() => setState(() {
          _query       = _searchCtrl.text;
          _expandedFaq = null; // reset open item on new search
        }));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Contact actions ────────────────────────────────────────────────────────

  Future<void> _launchCall() async {
    final uri = Uri.parse('tel:+233302000000');
    if (!await launchUrl(uri)) {
      _showError('Could not open phone dialler');
    }
  }

  Future<void> _launchWhatsApp() async {
    final uri = Uri.parse(
        'https://wa.me/233302000000?text=Hello%2C%20I%20need%20help%20with%20CTSRide');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _showError('WhatsApp is not installed');
    }
  }

  Future<void> _launchEmail() async {
    final uri = Uri(
      scheme: 'mailto',
      path: 'support@ctstransport.com',
      queryParameters: {'subject': 'CTSRide Support Request'},
    );
    if (!await launchUrl(uri)) {
      _showError('Could not open email app');
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

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
            _buildSearchBar(),
            const SizedBox(height: 20),
            const Text('Contact us', style: AppTextStyles.heading4),
            const SizedBox(height: 10),
            _buildContactRow(),
            const SizedBox(height: 20),
            _buildReportTripTile(),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Frequently asked', style: AppTextStyles.heading4),
                if (_query.isNotEmpty)
                  Text(
                    '${_filtered.length} result${_filtered.length == 1 ? '' : 's'}',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.primary),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _buildFaqList(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ── Search bar ─────────────────────────────────────────────────────────────

  Widget _buildSearchBar() => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: TextField(
          controller: _searchCtrl,
          style: AppTextStyles.bodyMedium,
          decoration: InputDecoration(
            hintText: 'Search help articles…',
            hintStyle: AppTextStyles.bodySmall
                .copyWith(color: AppColors.textTertiary),
            prefixIcon: const Icon(Icons.search_rounded,
                color: AppColors.textSecondary, size: 20),
            suffixIcon: _query.isNotEmpty
                ? GestureDetector(
                    onTap: () {
                      _searchCtrl.clear();
                      setState(() => _query = '');
                    },
                    child: const Icon(Icons.close_rounded,
                        color: AppColors.textSecondary, size: 18),
                  )
                : null,
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          ),
        ),
      );

  // ── Contact row ────────────────────────────────────────────────────────────

  Widget _buildContactRow() => Row(
        children: [
          Expanded(
            child: _ContactCard(
              icon: Icons.chat_rounded,
              label: 'WhatsApp',
              sub: 'Chat with us',
              color: const Color(0xFF25D366),
              onTap: _launchWhatsApp,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ContactCard(
              icon: Icons.phone_rounded,
              label: 'Call us',
              sub: '0302 000 000',
              color: AppColors.success,
              onTap: _launchCall,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ContactCard(
              icon: Icons.email_rounded,
              label: 'Email',
              sub: 'support@cts',
              color: AppColors.info,
              onTap: _launchEmail,
            ),
          ),
        ],
      );

  // ── Report trip tile ───────────────────────────────────────────────────────

  Widget _buildReportTripTile() => GestureDetector(
        onTap: _showReportTripSheet,
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
                    color: AppColors.error, size: 20),
              ),
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
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.textTertiary, size: 18),
            ],
          ),
        ),
      );

  // ── FAQ list ───────────────────────────────────────────────────────────────

  Widget _buildFaqList() {
    if (_filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(Icons.search_off_rounded,
                  color: AppColors.textTertiary, size: 40),
              const SizedBox(height: 12),
              Text('No results for "$_query"',
                  style: AppTextStyles.bodySmall),
            ],
          ),
        ),
      );
    }

    return Column(
      children: _filtered.asMap().entries.map((e) {
        final isOpen = _expandedFaq == e.key;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isOpen ? AppColors.primary : AppColors.border,
              width: isOpen ? 1.5 : 0.5,
            ),
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
                        child: Text(
                          e.value['q']!,
                          style: AppTextStyles.labelLarge.copyWith(
                            color: isOpen
                                ? AppColors.primary
                                : AppColors.textPrimary,
                          ),
                        ),
                      ),
                      AnimatedRotation(
                        turns: isOpen ? 0.5 : 0,
                        duration: const Duration(milliseconds: 220),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: isOpen
                              ? AppColors.primary
                              : AppColors.textTertiary,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ── Animated expand ──
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeInOut,
                child: isOpen
                    ? Padding(
                        padding:
                            const EdgeInsets.fromLTRB(14, 0, 14, 14),
                        child: Text(
                          e.value['a']!,
                          style: AppTextStyles.bodySmall
                              .copyWith(height: 1.6),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ── Report trip sheet ──────────────────────────────────────────────────────

  void _showReportTripSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => _ReportTripSheet(
        onSubmitted: () {
          Navigator.pop(sheetCtx);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(children: [
                Icon(Icons.check_circle_rounded,
                    color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('Report submitted — we\'ll follow up shortly'),
              ]),
              backgroundColor: AppColors.success,
            ),
          );
        },
      ),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.error),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Report trip sheet — extracted StatefulWidget so it manages its own state
// ─────────────────────────────────────────────────────────────────────────────

class _ReportTripSheet extends StatefulWidget {
  final VoidCallback onSubmitted;
  const _ReportTripSheet({required this.onSubmitted});

  @override
  State<_ReportTripSheet> createState() => _ReportTripSheetState();
}

class _ReportTripSheetState extends State<_ReportTripSheet> {
  final TextEditingController _descCtrl = TextEditingController();
  String? _selectedIssue;
  bool    _isSubmitting = false;

  static const _issueTypes = [
    'Overcharged',
    'Driver behaviour',
    'Wrong route',
    'Parcel damaged',
    'Driver no-show',
    'Other',
  ];

  @override
  void dispose() {
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selectedIssue == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select an issue type'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;

      await FirebaseFirestore.instance
          .collection('support_reports')
          .add({
        'userId':      uid,
        'issueType':   _selectedIssue,
        'description': _descCtrl.text.trim(),
        'status':      'open',
        'createdAt':   FieldValue.serverTimestamp(),
      });

      widget.onSubmitted();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to submit: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
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
      child: SingleChildScrollView(
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
            const Text('Report a trip issue',
                style: AppTextStyles.heading3),
            const SizedBox(height: 4),
            const Text(
              'Our team will review your report within 24 hours.',
              style: AppTextStyles.caption,
            ),
            const SizedBox(height: 16),

            // ── Issue type chips ──
            const Text('Issue type', style: AppTextStyles.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _issueTypes.map((t) {
                final isSelected = _selectedIssue == t;
                return GestureDetector(
                  onTap: () =>
                      setState(() => _selectedIssue = t),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary
                          : AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.border,
                      ),
                    ),
                    child: Text(
                      t,
                      style: AppTextStyles.labelMedium.copyWith(
                        color: isSelected
                            ? Colors.white
                            : AppColors.textSecondary,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // ── Description ──
            const Text('Description', style: AppTextStyles.labelLarge),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: TextField(
                controller: _descCtrl,
                maxLines: 4,
                maxLength: 500,
                style: AppTextStyles.bodyMedium,
                decoration: InputDecoration(
                  hintText: 'Describe the issue in detail…',
                  hintStyle: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.textTertiary),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(12),
                  counterStyle: AppTextStyles.caption
                      .copyWith(color: AppColors.textTertiary),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ── Submit ──
            PrimaryButton(
              label: 'Submit report',
              isLoading: _isSubmitting,
              onTap: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Contact card widget
// ─────────────────────────────────────────────────────────────────────────────

class _ContactCard extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final String       sub;
  final Color        color;
  final VoidCallback onTap;

  const _ContactCard({
    required this.icon,
    required this.label,
    required this.sub,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(height: 8),
              Text(label,
                  style: AppTextStyles.labelMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 2),
              Text(
                sub,
                style: AppTextStyles.caption,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
}