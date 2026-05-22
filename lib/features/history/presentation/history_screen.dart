// lib/features/history/presentation/history_screen.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../widgets/common/shared_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

enum HistoryItemType { ride, delivery, gas }

class HistoryItem {
  final String          id;
  final HistoryItemType type;
  final String          status;
  final String          origin;
  final String          destination;
  final double          fare;
  final DateTime?       createdAt;
  final String?         driverName;
  final String?         vehicleType;
  final double?         rating;
  final String?         cancelReason;
  final String?         parcelType;
  final String?         cylinderSize;

  const HistoryItem({
    required this.id,
    required this.type,
    required this.status,
    required this.origin,
    required this.destination,
    required this.fare,
    this.createdAt,
    this.driverName,
    this.vehicleType,
    this.rating,
    this.cancelReason,
    this.parcelType,
    this.cylinderSize,
  });

  bool get isCancelled  => status == 'cancelled';
  bool get isCompleted  =>
      status == 'completed' || status == 'delivered';

  String get displayDate {
    if (createdAt == null) return '';
    final diff = DateTime.now().difference(createdAt!).inDays;
    final time =
        '${createdAt!.hour}:${createdAt!.minute.toString().padLeft(2, '0')}';
    if (diff == 0) return 'Today, $time';
    if (diff == 1) return 'Yesterday, $time';
    return '${_months[createdAt!.month - 1]} ${createdAt!.day}, $time';
  }

  static const _months = [
    'Jan','Feb','Mar','Apr','May','Jun',
    'Jul','Aug','Sep','Oct','Nov','Dec',
  ];

  // ── Firestore factories ──────────────────────────────────────────────────

  factory HistoryItem.fromTrip(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return HistoryItem(
      id:           doc.id,
      type:         HistoryItemType.ride,
      status:       d['status']         as String? ?? '',
      origin:       d['pickupAddress']  as String? ?? '—',
      destination:  d['dropoffAddress'] as String? ?? '—',
      fare:         (d['actualFare']    as num?)?.toDouble() ??
                    (d['estimatedFare'] as num?)?.toDouble() ?? 0,
      createdAt:    (d['createdAt'] as Timestamp?)?.toDate(),
      driverName:   d['metadata']?['driverName'] as String?,
      vehicleType:  d['serviceType']    as String?,
      rating:       (d['passengerRating'] as num?)?.toDouble(),
      cancelReason: d['cancelReason']   as String?,
    );
  }

  factory HistoryItem.fromDelivery(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return HistoryItem(
      id:          doc.id,
      type:        HistoryItemType.delivery,
      status:      d['status']          as String? ?? '',
      origin:      d['pickupAddress']   as String? ?? '—',
      destination: d['dropoffAddress']  as String? ?? '—',
      fare:        (d['actualFare']     as num?)?.toDouble() ??
                   (d['estimatedFare']  as num?)?.toDouble() ?? 0,
      createdAt:   (d['createdAt'] as Timestamp?)?.toDate(),
      driverName:  d['driverName']      as String?,
      parcelType:  d['parcelType']      as String?,
      rating:      (d['passengerRating'] as num?)?.toDouble(),
      cancelReason: d['cancelReason']   as String?,
    );
  }

  factory HistoryItem.fromGasOrder(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return HistoryItem(
      id:           doc.id,
      type:         HistoryItemType.gas,
      status:       d['status']        as String? ?? '',
      origin:       d['pickupAddress'] as String? ?? '—',
      destination:  d['deliveryAddress'] as String? ?? '—',
      fare:         (d['totalPrice']   as num?)?.toDouble() ?? 0,
      createdAt:    (d['createdAt'] as Timestamp?)?.toDate(),
      cylinderSize: d['cylinderSize']  as String?,
      cancelReason: d['cancelReason']  as String?,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider — fetches all three collections in parallel
// ─────────────────────────────────────────────────────────────────────────────

final historyProvider =
    FutureProvider.autoDispose<List<HistoryItem>>((ref) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return [];

  final db = FirebaseFirestore.instance;

  final results = await Future.wait([
    db.collection('trips')
        .where('passengerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .get(),
    db.collection('deliveries')
        .where('passengerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .get(),
    db.collection('gas_orders')
        .where('passengerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .get(),
  ]);

  final items = <HistoryItem>[
    ...results[0].docs.map(HistoryItem.fromTrip),
    ...results[1].docs.map(HistoryItem.fromDelivery),
    ...results[2].docs.map(HistoryItem.fromGasOrder),
  ];

  // Sort all items by date descending
  items.sort((a, b) {
    if (a.createdAt == null && b.createdAt == null) return 0;
    if (a.createdAt == null) return 1;
    if (b.createdAt == null) return -1;
    return b.createdAt!.compareTo(a.createdAt!);
  });

  return items;
});

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class HistoryScreen extends ConsumerStatefulWidget {
  final ScrollController scrollController;

  const HistoryScreen({super.key, required this.scrollController});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  int _selectedFilter = 0;

  static const _filters = ['All', 'Rides', 'Deliveries', 'Gas', 'Cancelled'];

  List<HistoryItem> _applyFilter(List<HistoryItem> items) {
    switch (_selectedFilter) {
      case 1: return items.where((i) =>
          i.type == HistoryItemType.ride && !i.isCancelled).toList();
      case 2: return items.where((i) =>
          i.type == HistoryItemType.delivery).toList();
      case 3: return items.where((i) =>
          i.type == HistoryItemType.gas).toList();
      case 4: return items.where((i) => i.isCancelled).toList();
      default: return items;
    }
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(historyProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(historyAsync.value ?? []),
      body: Column(
        children: [
          _buildFilterRow(),
          Expanded(
            child: historyAsync.when(
              loading: () => _buildSkeleton(),
              error:   (e, _) => _buildError(e.toString()),
              data:    (items) {
                final filtered = _applyFilter(items);
                return filtered.isEmpty
                    ? _buildEmpty()
                    : RefreshIndicator(
                        color:     AppColors.primary,
                        onRefresh: () =>
                            ref.refresh(historyProvider.future),
                        child: ListView.separated(
                          controller: widget.scrollController,
                          physics:
                              const AlwaysScrollableScrollPhysics(
                                  parent: BouncingScrollPhysics()),
                          padding: const EdgeInsets.all(16),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, i) =>
                              _TripCard(item: filtered[i]),
                        ),
                      );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── App bar ─────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar(List<HistoryItem> items) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight + 0.5),
      child: AppBar(
        backgroundColor:  AppColors.surface,
        elevation:        0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        title: const Text('My Trips', style: AppTextStyles.heading3),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: GestureDetector(
              onTap: () => _showFilterSheet(items),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.tune_rounded,
                        size: 14, color: AppColors.textSecondary),
                    SizedBox(width: 4),
                    Text('Filter',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textSecondary,
                        )),
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
    );
  }

  // ── Filter chips ─────────────────────────────────────────────────────────

  Widget _buildFilterRow() => ColoredBox(
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
                      right: i < _filters.length - 1 ? 8 : 0),
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _selectedFilter = i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 7),
                      decoration: BoxDecoration(
                        color: isActive
                            ? AppColors.primary
                            : AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isActive
                              ? AppColors.primary
                              : AppColors.border,
                        ),
                      ),
                      child: Text(
                        _filters[i],
                        style: AppTextStyles.labelMedium.copyWith(
                          color: isActive
                              ? AppColors.background
                              : AppColors.textSecondary,
                          fontWeight: isActive
                              ? FontWeight.w600
                              : FontWeight.w400,
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

  // ── Filter sheet ──────────────────────────────────────────────────────────

  void _showFilterSheet(List<HistoryItem> items) {
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
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Filter trips', style: AppTextStyles.heading3),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: List.generate(_filters.length, (i) {
                final isActive = _selectedFilter == i;
                return GestureDetector(
                  onTap: () {
                    setState(() => _selectedFilter = i);
                    Navigator.pop(context);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppColors.primary
                          : AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isActive
                            ? AppColors.primary
                            : AppColors.border,
                      ),
                    ),
                    child: Text(_filters[i],
                        style: AppTextStyles.labelMedium.copyWith(
                          color: isActive
                              ? AppColors.background
                              : AppColors.textSecondary,
                        )),
                  ),
                );
              }),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ── States ────────────────────────────────────────────────────────────────

  Widget _buildEmpty() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72, height: 72,
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.history_rounded,
                  size: 34, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 16),
            const Text('No trips found',
                style: AppTextStyles.heading4),
            const SizedBox(height: 6),
            const Text('Your completed trips will appear here',
                style: AppTextStyles.bodySmall),
          ],
        ),
      );

  Widget _buildSkeleton() => ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: 4,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, __) => Container(
          height: 140,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      );

  Widget _buildError(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColors.textTertiary),
              const SizedBox(height: 12),
              const Text('Could not load trips',
                  style: AppTextStyles.heading4),
              const SizedBox(height: 6),
              Text(message,
                  style: AppTextStyles.caption,
                  textAlign: TextAlign.center),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => ref.refresh(historyProvider.future),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('Retry',
                      style: AppTextStyles.button),
                ),
              ),
            ],
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Trip card
// ─────────────────────────────────────────────────────────────────────────────

class _TripCard extends StatelessWidget {
  final HistoryItem item;
  const _TripCard({required this.item});

  IconData get _icon => switch (item.type) {
        HistoryItemType.ride     => Icons.directions_car_rounded,
        HistoryItemType.delivery => Icons.inventory_2_rounded,
        HistoryItemType.gas      => Icons.local_fire_department_rounded,
      };

  Color get _iconColor => switch (item.type) {
        HistoryItemType.ride     => AppColors.primary,
        HistoryItemType.delivery => AppColors.info,
        HistoryItemType.gas      => const Color(0xFFFF7A35),
      };

  String get _typeLabel => switch (item.type) {
        HistoryItemType.ride     => item.vehicleType ?? 'Ride',
        HistoryItemType.delivery => 'Delivery',
        HistoryItemType.gas      => 'Gas Order',
      };

  @override
  Widget build(BuildContext context) {
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
          // ── Header ──
          Row(
            children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: _iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_icon, color: _iconColor, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.driverName != null
                          ? '$_typeLabel · ${item.driverName}'
                          : _typeLabel,
                      style: AppTextStyles.labelLarge,
                    ),
                    Text(item.displayDate,
                        style: AppTextStyles.caption),
                  ],
                ),
              ),
              StatusBadge(
                label: item.isCancelled
                    ? 'Cancelled'
                    : item.type == HistoryItemType.gas
                        ? 'Delivered'
                        : item.type == HistoryItemType.delivery
                            ? 'Delivered'
                            : 'Completed',
                type: item.isCancelled
                    ? StatusType.error
                    : StatusType.success,
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── Route ──
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                _RouteStop(label: item.origin, isOrigin: true),
                const Padding(
                  padding:
                      EdgeInsets.only(left: 3, top: 3, bottom: 3),
                  child: SizedBox(
                      width: 1.5,
                      height: 12,
                      child: ColoredBox(color: AppColors.border)),
                ),
                _RouteStop(
                    label: item.destination, isOrigin: false),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── Footer ──
          Row(
            children: [
              if (item.rating != null) ...[
                const Icon(Icons.star_rounded,
                    color: AppColors.warning, size: 14),
                const SizedBox(width: 4),
                Text(item.rating!.toStringAsFixed(1),
                    style: AppTextStyles.caption
                        .copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
              ],
              if (item.cancelReason != null)
                Expanded(
                  child: Text(item.cancelReason!,
                      style: AppTextStyles.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                )
              else if (item.parcelType != null)
                Text(item.parcelType!,
                    style: AppTextStyles.caption)
              else if (item.cylinderSize != null)
                Text(item.cylinderSize!,
                    style: AppTextStyles.caption)
              else
                const Spacer(),
              const Spacer(),
              // Rebook — only for rides
              if (item.type == HistoryItemType.ride &&
                  !item.isCancelled) ...[
                GestureDetector(
                  onTap: () => Navigator.pushNamed(
                    context,
                    AppRoutes.bookRide,
                    arguments: {
                      'pickupAddress':  item.origin,
                      'dropoffAddress': item.destination,
                    },
                  ),
                  child: Text('Rebook',
                      style: AppTextStyles.caption.copyWith(
                        color:      AppColors.primary,
                        fontWeight: FontWeight.w600,
                      )),
                ),
                const SizedBox(width: 12),
              ],
              Text(
                '₵${item.fare.toStringAsFixed(2)}',
                style: AppTextStyles.amountSmall
                    .copyWith(fontSize: 14),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Route stop widget
// ─────────────────────────────────────────────────────────────────────────────

class _RouteStop extends StatelessWidget {
  final String label;
  final bool   isOrigin;
  const _RouteStop({required this.label, required this.isOrigin});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              color: isOrigin
                  ? AppColors.success
                  : AppColors.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: isOrigin
                  ? AppTextStyles.labelMedium
                      .copyWith(color: AppColors.textPrimary)
                  : AppTextStyles.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
}