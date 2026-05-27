// features/ride/screens/trip_complete_screen.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../widgets/common/shared_widgets.dart';

class TripCompleteScreen extends StatefulWidget {
  final String tripId; // ✅ required to save rating against the trip
  final String driverId; // ✅ required to update driver's rating aggregate
  final String driverName;
  final String destination;
  final String fare;
  final String rideType;

  const TripCompleteScreen({
    super.key,
    required this.tripId,
    required this.driverId,
    required this.driverName,
    required this.destination,
    required this.fare,
    required this.rideType,
  });

  @override
  State<TripCompleteScreen> createState() => _TripCompleteScreenState();
}

class _TripCompleteScreenState extends State<TripCompleteScreen>
    with SingleTickerProviderStateMixin {
  int _selectedStars = 0;
  int _selectedTip = -1; // index into _tipOptions; -1 = none
  final TextEditingController _feedbackController = TextEditingController();
  bool _isSubmitting = false;

  static const List<int> _tipOptions = [2, 5, 10];

  final List<String> _positiveTags = [
    'Great driver',
    'Very punctual',
    'Clean vehicle',
    'Safe driving',
    'Friendly',
  ];
  final List<String> _selectedTags = [];

  late final AnimationController _checkController;
  late final Animation<double> _checkScale;

  // ✅ Safe initials — identical pattern to RideTrackingScreen
  String get _initials {
    final parts = widget.driverName.trim().split(' ');
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  @override
  void initState() {
    super.initState();
    _checkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _checkScale = CurvedAnimation(
      parent: _checkController,
      curve: Curves.elasticOut,
    );
    _checkController.forward();
  }

  @override
  void dispose() {
    _checkController.dispose();
    _feedbackController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Submit
  // ---------------------------------------------------------------------------

  Future<void> _submitRating() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);

    try {
      final db = FirebaseFirestore.instance;
      final batch = db.batch();

      final hasRating = _selectedStars > 0;
      final hasTip = _selectedTip >= 0;

      if (hasRating) {
        batch.update(db.collection('trips').doc(widget.tripId), {
          'passengerRating': _selectedStars,
          'passengerTip': hasTip ? _tipOptions[_selectedTip] : 0,
          'passengerTags': _selectedTags,
          'passengerFeedback': _feedbackController.text.trim(),
          'ratedAt': FieldValue.serverTimestamp(),
        });

        batch.update(db.collection('drivers').doc(widget.driverId), {
          'ratingTotal': FieldValue.increment(_selectedStars),
          'ratingCount': FieldValue.increment(1),
        });
      }

      if (hasTip) {
        batch.set(db.collection('tip_transactions').doc(), {
          'tripId': widget.tripId,
          'driverId': widget.driverId,
          'amount': _tipOptions[_selectedTip],
          'currency': 'GHS',
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      if (hasRating || hasTip) await batch.commit();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save your rating. You can rate later.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
        _goHome();
      }
    }
  }

  void _goHome() {
  Navigator.of(context, rootNavigator: true).pushNamedAndRemoveUntil(
    AppRoutes.shell,
    (route) => false,
  );
}

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const SizedBox(height: 16),
              _AnimatedCheckmark(animation: _checkScale),
              const SizedBox(height: 16),
              const Text('Trip completed!', style: AppTextStyles.heading2),
              const SizedBox(height: 4),
              const Text('Hope you had a great ride',
                  style: AppTextStyles.bodySmall),
              const SizedBox(height: 24),
              _FareCard(
                initials: _initials,
                driverName: widget.driverName,
                rideType: widget.rideType,
                fare: widget.fare,
                destination: widget.destination,
              ),
              const SizedBox(height: 20),
              _RatingSection(
                driverName: widget.driverName,
                selectedStars: _selectedStars,
                onStarTap: (stars) => setState(() => _selectedStars = stars),
              ),
              const SizedBox(height: 16),
              if (_selectedStars > 0) ...[
                _TagsSection(
                  tags: _positiveTags,
                  selectedTags: _selectedTags,
                  onTagToggle: (tag) => setState(() {
                    _selectedTags.contains(tag)
                        ? _selectedTags.remove(tag)
                        : _selectedTags.add(tag);
                  }),
                ),
                const SizedBox(height: 16),
              ],
              _TipSection(
                tipOptions: _tipOptions,
                selectedTip: _selectedTip,
                onTipTap: (i) =>
                    setState(() => _selectedTip = _selectedTip == i ? -1 : i),
              ),
              const SizedBox(height: 16),
              _FeedbackField(controller: _feedbackController),
              const SizedBox(height: 24),
              PrimaryButton(
                label: _isSubmitting
                    ? 'Submitting…'
                    : _selectedStars == 0
                        ? 'Skip & go home'
                        : 'Submit rating',
                onTap: _isSubmitting
                    ? null
                    : _selectedStars == 0
                        ? () =>
                            _goHome() // ← explicit lambda, uniform VoidCallback
                        : () =>
                            _submitRating(), // ← explicit lambda, Future discarded cleanly
              ),
              if (!_isSubmitting && _selectedStars == 0) ...[
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: _goHome,
                  child: Text(
                    'Rate later',
                    style: AppTextStyles.bodySmall
                        .copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Sub-widgets — all purely presentational
// =============================================================================

class _AnimatedCheckmark extends StatelessWidget {
  final Animation<double> animation;
  const _AnimatedCheckmark({required this.animation});

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: animation,
      child: Container(
        width: 80,
        height: 80,
        decoration: const BoxDecoration(
          color: AppColors.success,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.check_rounded,
          color: AppColors.background,
          size: 40,
        ),
      ),
    );
  }
}

class _FareCard extends StatelessWidget {
  final String initials;
  final String driverName;
  final String rideType;
  final String fare;
  final String destination;

  const _FareCard({
    required this.initials,
    required this.driverName,
    required this.rideType,
    required this.fare,
    required this.destination,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.darkNavy,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.primary,
                child: Text(
                  initials,
                  style: AppTextStyles.labelMedium
                      .copyWith(color: AppColors.background),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      driverName,
                      style: AppTextStyles.labelLarge
                          .copyWith(color: AppColors.background),
                    ),
                    Text(
                      rideType,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textOnDarkMuted),
                    ),
                  ],
                ),
              ),
              Text(
                fare,
                style: AppTextStyles.heading3
                    .copyWith(color: AppColors.background),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(height: 0.5, color: Colors.white.withValues(alpha: 0.15)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Destination',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textOnDarkMuted),
                    ),
                    Text(
                      destination,
                      style: AppTextStyles.bodySmall
                          .copyWith(color: AppColors.textOnDarkMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Payment',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textOnDarkMuted),
              ),
              Row(
                children: [
                  const Icon(Icons.account_balance_wallet_rounded,
                      color: AppColors.success, size: 13),
                  const SizedBox(width: 4),
                  Text(
                    'CTSRide Wallet',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.success),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RatingSection extends StatelessWidget {
  final String driverName;
  final int selectedStars;
  final ValueChanged<int> onStarTap;

  const _RatingSection({
    required this.driverName,
    required this.selectedStars,
    required this.onStarTap,
  });

  String _ratingLabel(int stars) => switch (stars) {
        1 => 'Poor experience',
        2 => 'Below average',
        3 => 'It was okay',
        4 => 'Good ride!',
        5 => 'Excellent! 🎉',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Text(
            'How was your ride with $driverName?',
            style: AppTextStyles.heading4,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) {
              final filled = i < selectedStars;
              return GestureDetector(
                onTap: () => onStarTap(i + 1),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      filled ? Icons.star_rounded : Icons.star_outline_rounded,
                      key: ValueKey('$i-$filled'),
                      color:
                          filled ? AppColors.warning : AppColors.textTertiary,
                      size: 40,
                    ),
                  ),
                ),
              );
            }),
          ),
          if (selectedStars > 0) ...[
            const SizedBox(height: 10),
            Text(
              _ratingLabel(selectedStars),
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TagsSection extends StatelessWidget {
  final List<String> tags;
  final List<String> selectedTags;
  final ValueChanged<String> onTagToggle;

  const _TagsSection({
    required this.tags,
    required this.selectedTags,
    required this.onTagToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('What went well?', style: AppTextStyles.heading4),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: tags.map((tag) {
              final isSelected = selectedTags.contains(tag);
              return GestureDetector(
                onTap: () => onTagToggle(tag),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppColors.primary.withValues(alpha: 0.1)
                        : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected ? AppColors.primary : AppColors.border,
                      width: isSelected ? 1.5 : 0.5,
                    ),
                  ),
                  child: Text(
                    tag,
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isSelected
                          ? AppColors.primary
                          : AppColors.textSecondary,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _TipSection extends StatelessWidget {
  final List<int> tipOptions;
  final int selectedTip;
  final ValueChanged<int> onTipTap;

  const _TipSection({
    required this.tipOptions,
    required this.selectedTip,
    required this.onTipTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Add a tip?', style: AppTextStyles.heading4),
          const SizedBox(height: 4),
          Text(
            '100% goes directly to your driver',
            style: AppTextStyles.caption.copyWith(color: AppColors.success),
          ),
          const SizedBox(height: 12),
          Row(
            children: List.generate(tipOptions.length, (i) {
              final isSelected = selectedTip == i;
              return Expanded(
                child: Padding(
                  padding:
                      EdgeInsets.only(right: i < tipOptions.length - 1 ? 8 : 0),
                  child: GestureDetector(
                    onTap: () => onTipTap(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color:
                              isSelected ? AppColors.primary : AppColors.border,
                        ),
                      ),
                      child: Text(
                        'GHS ${tipOptions[i]}',
                        style: AppTextStyles.labelLarge.copyWith(
                          color: isSelected
                              ? AppColors.background
                              : AppColors.textPrimary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _FeedbackField extends StatelessWidget {
  final TextEditingController controller;
  const _FeedbackField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: TextField(
        controller: controller,
        maxLines: 3,
        style: AppTextStyles.bodyMedium,
        decoration: const InputDecoration(
          hintText: 'Any additional comments? (optional)',
          hintStyle: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            color: AppColors.textTertiary,
          ),
          border: InputBorder.none,
          contentPadding: EdgeInsets.all(16),
        ),
      ),
    );
  }
}
