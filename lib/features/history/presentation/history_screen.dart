import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';

class HistoryScreen extends StatefulWidget {
  final ScrollController scrollController;

  const HistoryScreen({
    super.key,
    required this.scrollController,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  // _selectedNavIndex removed — PassengerRootShell owns the bottom nav
  int _selectedFilter = 0;

  final List<String> _filters = ['All', 'Rides', 'Deliveries', 'Cancelled'];

  final List<Map<String, dynamic>> _trips = [
    {
      'type': 'ride',
      'status': 'completed',
      'vehicleType': 'Taxi',
      'driverName': 'Ahmed K.',
      'origin': 'Osu, Accra',
      'destination': 'Kotoka Airport',
      'date': 'Today, 8:14 AM',
      'fare': 'GHS 28.00',
      'rating': 4.8,
      'canRebook': true,
    },
    {
      'type': 'delivery',
      'status': 'completed',
      'vehicleType': 'Delivery',
      'driverName': 'Kofi M.',
      'origin': 'Osu Market',
      'destination': 'East Legon, Accra',
      'date': 'Yesterday, 3:40 PM',
      'fare': 'GHS 15.00',
      'parcelType': '📦 Documents',
      'rating': 4.9,
      'canRebook': false,
    },
    {
      'type': 'ride',
      'status': 'cancelled',
      'vehicleType': 'Okada',
      'driverName': 'Kweku A.',
      'origin': 'Labadi Beach',
      'destination': 'Accra Mall',
      'date': 'Mon, 5:00 PM',
      'fare': 'GHS 0.00',
      'cancelReason': 'Driver cancelled',
      'canRebook': true,
    },
    {
      'type': 'ride',
      'status': 'completed',
      'vehicleType': 'Taxi',
      'driverName': 'Ama S.',
      'origin': 'Cantonments',
      'destination': 'Tema Station',
      'date': 'Mon, 9:30 AM',
      'fare': 'GHS 22.00',
      'rating': 5.0,
      'canRebook': true,
    },
    {
      'type': 'delivery',
      'status': 'completed',
      'vehicleType': 'Delivery',
      'driverName': 'Yaw B.',
      'origin': 'Madina',
      'destination': 'Lapaz',
      'date': 'Sun, 1:15 PM',
      'fare': 'GHS 18.00',
      'parcelType': '📱 Electronics',
      'rating': 4.7,
      'canRebook': false,
    },
  ];

  List<Map<String, dynamic>> get _filtered {
    if (_selectedFilter == 0) return _trips;
    if (_selectedFilter == 1) {
      return _trips
          .where((t) => t['type'] == 'ride' && t['status'] != 'cancelled')
          .toList();
    }
    if (_selectedFilter == 2) {
      return _trips.where((t) => t['type'] == 'delivery').toList();
    }
    return _trips.where((t) => t['status'] == 'cancelled').toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight + 0.5),
        child: AppBar(
          backgroundColor: AppColors.surface,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          automaticallyImplyLeading: false,
          title: const Text('My Trips', style: AppTextStyles.heading3),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: GestureDetector(
                onTap: () {},
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.tune_rounded,
                        size: 14,
                        color: AppColors.textSecondary,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Filter',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(0.5),
            child: ColoredBox(
              color: AppColors.border,
              child: SizedBox(height: 0.5, width: double.infinity),
            ),
          ),
        ),
      ),
      // bottomNavigationBar removed — owned by PassengerRootShell
      body: Column(
        children: [
          // ── Filter chips ─────────────────────────────────────────────────
          _buildFilterRow(),

          // ── Trip list ────────────────────────────────────────────────────
          Expanded(
            child: _filtered.isEmpty
                ? _buildEmpty()
                : ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, i) => _TripCard(trip: _filtered[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    return ColoredBox(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: List.generate(_filters.length, (i) {
              final isActive = _selectedFilter == i;
              return Padding(
                padding: EdgeInsets.only(
                  right: i < _filters.length - 1 ? 8 : 0,
                ),
                child: GestureDetector(
                  onTap: () => setState(() => _selectedFilter = i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color:
                          isActive ? AppColors.primary : AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isActive ? AppColors.primary : AppColors.border,
                      ),
                    ),
                    child: Text(
                      _filters[i],
                      style: AppTextStyles.labelMedium.copyWith(
                        color: isActive
                            ? AppColors.background
                            : AppColors.textSecondary,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history_rounded, size: 56, color: AppColors.textTertiary),
          SizedBox(height: 12),
          Text('No trips found', style: AppTextStyles.heading4),
          SizedBox(height: 6),
          Text('Your trips will appear here', style: AppTextStyles.bodySmall),
        ],
      ),
    );
  }
}

// ─── Trip Card ───────────────────────────────────────────────────────────────

class _TripCard extends StatelessWidget {
  final Map<String, dynamic> trip;

  const _TripCard({required this.trip});

  @override
  Widget build(BuildContext context) {
    final isCancelled = trip['status'] == 'cancelled';
    final isDelivery = trip['type'] == 'delivery';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ────────────────────────────────────────────────────────
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  // withOpacity → withValues(alpha:)
                  color: isDelivery
                      ? AppColors.info.withValues(alpha: 0.1)
                      : AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isDelivery
                      ? Icons.inventory_2_rounded
                      : Icons.directions_car_rounded,
                  color: isDelivery ? AppColors.info : AppColors.primary,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${trip['vehicleType']} · ${trip['driverName']}',
                      style: AppTextStyles.labelLarge,
                    ),
                    Text(trip['date'], style: AppTextStyles.caption),
                  ],
                ),
              ),
              StatusBadge(
                label: isCancelled
                    ? 'Cancelled'
                    : isDelivery
                        ? 'Delivered'
                        : 'Completed',
                type: isCancelled ? StatusType.error : StatusType.success,
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── Route ──────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                _RouteStop(label: trip['origin'], isOrigin: true),
                const Padding(
                  padding: EdgeInsets.only(left: 4, top: 3, bottom: 3),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 1.5,
                        height: 14,
                        child: ColoredBox(color: AppColors.border),
                      ),
                    ],
                  ),
                ),
                _RouteStop(label: trip['destination'], isOrigin: false),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── Footer ─────────────────────────────────────────────────────────
          Row(
            children: [
              if (trip['rating'] != null) ...[
                const Icon(Icons.star_rounded,
                    color: AppColors.warning, size: 14),
                const SizedBox(width: 4),
                Text(
                  '${trip['rating']}',
                  style: AppTextStyles.caption
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 10),
              ],
              if (trip['cancelReason'] != null)
                Text(trip['cancelReason'], style: AppTextStyles.caption),
              if (trip['parcelType'] != null)
                Text(trip['parcelType'], style: AppTextStyles.caption),
              const Spacer(),
              if (trip['canRebook'] == true)
                GestureDetector(
                  onTap: () {},
                  child: Text(
                    'Rebook',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              Text(
                trip['fare'],
                style: AppTextStyles.amountSmall.copyWith(fontSize: 14),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Route Stop ──────────────────────────────────────────────────────────────

class _RouteStop extends StatelessWidget {
  final String label;
  final bool isOrigin;

  const _RouteStop({required this.label, required this.isOrigin});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: isOrigin ? AppColors.success : AppColors.primary,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: isOrigin
              ? AppTextStyles.labelMedium.copyWith(color: AppColors.textPrimary)
              : AppTextStyles.bodySmall,
        ),
      ],
    );
  }
}
