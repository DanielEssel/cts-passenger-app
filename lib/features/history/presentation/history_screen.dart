// lib/features/history/presentation/history_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/routes/app_routes.dart';
import '../../../widgets/common/shared_widgets.dart';

// ── Model ─────────────────────────────────────────────────────────────────────
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

  bool get isCancelled => status.toLowerCase().contains('cancel');
  bool get isCompleted => status == 'completed' || status == 'delivered';
  bool get isActive    => !isCancelled && !isCompleted;

  String get statusLabel => switch (status) {
    'tripAccepted'         => 'Accepted',
    'driverArrived'        => 'Driver Arrived',
    'tripStarted'          => 'In Progress',
    'completed'            => 'Completed',
    'delivered'            => 'Delivered',
    'cancelledByDriver'    => 'Cancelled',
    'cancelledByPassenger' => 'Cancelled',
    'cancelled'            => 'Cancelled',
    'searching'            => 'Searching',
    _                      => status,
  };

  StatusType get statusType => switch (status) {
    'completed' || 'delivered'                              => StatusType.success,
    'cancelledByDriver' || 'cancelledByPassenger' ||
    'cancelled'                                             => StatusType.error,
    'tripStarted' || 'inProgress'                           => StatusType.primary,
    'tripAccepted' || 'driverArrived' || 'driverAssigned'   => StatusType.info,
    _                                                       => StatusType.warning,
  };

  String get displayDate {
    if (createdAt == null) return '';
    final diff = DateTime.now().difference(createdAt!).inDays;
    final h    = createdAt!.hour;
    final m    = createdAt!.minute.toString().padLeft(2, '0');
    final amPm = h >= 12 ? 'PM' : 'AM';
    final h12  = h % 12 == 0 ? 12 : h % 12;
    final time = '$h12:$m $amPm';
    if (diff == 0) return 'Today, $time';
    if (diff == 1) return 'Yesterday, $time';
    const months = ['Jan','Feb','Mar','Apr','May','Jun',
                    'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[createdAt!.month - 1]} ${createdAt!.day}, $time';
  }

  factory HistoryItem.fromTrip(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return HistoryItem(
      id:           doc.id,
      type:         HistoryItemType.ride,
      status:       d['status']             as String? ?? '',
      origin:       d['pickupAddress']      as String? ?? '—',
      destination:  d['dropoffAddress']     as String? ?? '—',
      fare:         (d['actualFare']        as num?)?.toDouble() ??
                    (d['estimatedFare']     as num?)?.toDouble() ?? 0,
      createdAt:    (d['createdAt']   as Timestamp?)?.toDate(),
      driverName:   d['driverName']         as String?,
      vehicleType:  d['serviceType']        as String?,
      rating:       (d['passengerRating']   as num?)?.toDouble(),
      cancelReason: d['cancellationReason'] as String?,
    );
  }

  factory HistoryItem.fromDelivery(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return HistoryItem(
      id:           doc.id,
      type:         HistoryItemType.delivery,
      status:       d['status']             as String? ?? '',
      origin:       d['pickupAddress']      as String? ?? '—',
      destination:  d['dropoffAddress']     as String? ?? '—',
      fare:         (d['actualFare']        as num?)?.toDouble() ??
                    (d['estimatedFare']     as num?)?.toDouble() ?? 0,
      createdAt:    (d['createdAt']   as Timestamp?)?.toDate(),
      driverName:   d['driverName']         as String?,
      parcelType:   d['parcelType']         as String?,
      rating:       (d['passengerRating']   as num?)?.toDouble(),
      cancelReason: d['cancellationReason'] as String?,
    );
  }

  factory HistoryItem.fromGasOrder(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return HistoryItem(
      id:           doc.id,
      type:         HistoryItemType.gas,
      status:       d['status']             as String? ?? '',
      origin:       d['pickupAddress']      as String? ?? '—',
      destination:  d['deliveryAddress']    as String? ?? '—',
      fare:         (d['totalPrice']        as num?)?.toDouble() ?? 0,
      createdAt:    (d['createdAt']   as Timestamp?)?.toDate(),
      cylinderSize: d['cylinderSize']       as String?,
      cancelReason: d['cancellationReason'] as String?,
    );
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────
final historyProvider = FutureProvider.autoDispose<List<HistoryItem>>((ref) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return [];
  final db = FirebaseFirestore.instance;

  final results = await Future.wait([
    db.collection('trips')
        .where('passengerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(50).get(),
    db.collection('deliveries')
        .where('passengerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(30).get(),
    db.collection('gas_orders')
        .where('passengerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(30).get(),
  ]);

  final items = <HistoryItem>[
    ...results[0].docs.map(HistoryItem.fromTrip),
    ...results[1].docs.map(HistoryItem.fromDelivery),
    ...results[2].docs.map(HistoryItem.fromGasOrder),
  ]..sort((a, b) {
    if (a.createdAt == null) return 1;
    if (b.createdAt == null) return -1;
    return b.createdAt!.compareTo(a.createdAt!);
  });

  return items;
});

// ── Screen ────────────────────────────────────────────────────────────────────
class HistoryScreen extends ConsumerStatefulWidget {
  final ScrollController scrollController;
  const HistoryScreen({super.key, required this.scrollController});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  int _filterIndex = 0;

  static const _filters = [
    (label: 'All',        icon: Icons.apps_rounded),
    (label: 'Rides',      icon: Icons.directions_car_rounded),
    (label: 'Deliveries', icon: Icons.inventory_2_rounded),
    (label: 'Gas',        icon: Icons.local_fire_department_rounded),
    (label: 'Cancelled',  icon: Icons.cancel_rounded),
  ];

  List<HistoryItem> _applyFilter(List<HistoryItem> items) => switch (_filterIndex) {
    1 => items.where((i) => i.type == HistoryItemType.ride     && !i.isCancelled).toList(),
    2 => items.where((i) => i.type == HistoryItemType.delivery && !i.isCancelled).toList(),
    3 => items.where((i) => i.type == HistoryItemType.gas      && !i.isCancelled).toList(),
    4 => items.where((i) => i.isCancelled).toList(),
    _ => items,
  };

  Map<String, dynamic> _stats(List<HistoryItem> items) {
    final completed  = items.where((i) => i.isCompleted).toList();
    final totalSpent = completed.fold(0.0, (s, i) => s + i.fare);
    return {
      'total':     items.length,
      'completed': completed.length,
      'spent':     totalSpent,
    };
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(historyProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildFilterChips(),
          Expanded(
            child: historyAsync.when(
              loading: () => _buildSkeleton(),
              error:   (e, _) => _buildError(e.toString()),
              data: (items) {
                final filtered = _applyFilter(items);
                final stats    = _stats(items);
                return RefreshIndicator(
                  color:     AppColors.primary,
                  onRefresh: () => ref.refresh(historyProvider.future),
                  child: filtered.isEmpty
                      ? _buildEmpty()
                      : CustomScrollView(
                          controller: widget.scrollController,
                          physics: const AlwaysScrollableScrollPhysics(
                              parent: BouncingScrollPhysics()),
                          slivers: [
                            if (_filterIndex == 0)
                              SliverToBoxAdapter(
                                  child: _StatsStrip(stats: stats)),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                              sliver: SliverList.separated(
                                itemCount:        filtered.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (_, i) =>
                                    _TripCard(item: filtered[i]),
                              ),
                            ),
                          ],
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── App bar ───────────────────────────────────────────────────────────────
  PreferredSizeWidget _buildAppBar() => PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight + 0.5),
        child: AppBar(
          backgroundColor:           AppColors.surface,
          elevation:                 0,
          surfaceTintColor:          Colors.transparent,
          automaticallyImplyLeading: false,
          title: const Text('My Trips',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize:   18,
                color:      AppColors.textPrimary,
              )),
          actions: [
            IconButton(
              icon:      const Icon(Icons.refresh_rounded,
                  color: AppColors.textSecondary),
              onPressed: () => ref.refresh(historyProvider.future),
              tooltip:   'Refresh',
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

  // ── Filter chips ──────────────────────────────────────────────────────────
  Widget _buildFilterChips() => ColoredBox(
        color: AppColors.surface,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics:         const BouncingScrollPhysics(),
                child: Row(
                  children: List.generate(_filters.length, (i) {
                    final isActive = _filterIndex == i;
                    final f        = _filters[i];
                    return Padding(
                      padding: EdgeInsets.only(
                          right: i < _filters.length - 1 ? 8 : 0),
                      child: GestureDetector(
                        onTap: () => setState(() => _filterIndex = i),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            color: isActive
                                ? AppColors.primary : AppColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isActive
                                  ? AppColors.primary : AppColors.border,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(f.icon, size: 13,
                                  color: isActive
                                      ? Colors.white
                                      : AppColors.textSecondary),
                              const SizedBox(width: 5),
                              Text(f.label,
                                  style: TextStyle(
                                    fontSize:   12,
                                    fontWeight: isActive
                                        ? FontWeight.w700 : FontWeight.w400,
                                    color: isActive
                                        ? Colors.white
                                        : AppColors.textSecondary,
                                  )),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
            const ColoredBox(
              color: AppColors.borderLight,
              child: SizedBox(height: 0.5, width: double.infinity),
            ),
          ],
        ),
      );

  // ── States ────────────────────────────────────────────────────────────────
  Widget _buildEmpty() => LayoutBuilder(
        builder: (_, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width:  72, height: 72,
                    decoration: BoxDecoration(
                      color:        AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(Icons.receipt_long_rounded,
                        size: 34, color: AppColors.textTertiary),
                  ),
                  const SizedBox(height: 16),
                  const Text('No trips yet',
                      style: TextStyle(
                        fontSize:   17,
                        fontWeight: FontWeight.w700,
                        color:      AppColors.textPrimary,
                      )),
                  const SizedBox(height: 6),
                  const Text('Your completed trips will appear here',
                      style: TextStyle(
                          fontSize: 13,
                          color:    AppColors.textSecondary)),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _buildSkeleton() => ListView.separated(
        padding:          const EdgeInsets.all(16),
        itemCount:        5,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder:      (_, __) => _ShimmerCard(),
      );

  Widget _buildError(String message) => LayoutBuilder(
        builder: (_, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width:  72, height: 72,
                      decoration: BoxDecoration(
                        color:        AppColors.errorLight,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.cloud_off_rounded,
                          size: 32, color: AppColors.error),
                    ),
                    const SizedBox(height: 16),
                    const Text('Could not load trips',
                        style: TextStyle(
                          fontSize:   17,
                          fontWeight: FontWeight.w700,
                          color:      AppColors.textPrimary,
                        )),
                    const SizedBox(height: 8),
                    Text(message,
                        style: const TextStyle(
                            fontSize: 12,
                            color:    AppColors.textSecondary),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () => ref.refresh(historyProvider.future),
                      icon:      const Icon(Icons.refresh_rounded),
                      label:     const Text('Try Again'),
                      style:     FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

// ── Stats strip ───────────────────────────────────────────────────────────────
class _StatsStrip extends StatelessWidget {
  final Map<String, dynamic> stats;
  const _StatsStrip({required this.stats});

  @override
  Widget build(BuildContext context) => Container(
        margin:  const EdgeInsets.fromLTRB(16, 16, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.primary, AppColors.primaryDark],
            begin:  Alignment.topLeft,
            end:    Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color:      AppColors.primary.withValues(alpha: 0.25),
              blurRadius: 12,
              offset:     const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(child: _StatItem('Total', '${stats['total']}')),
            Container(width: 1, height: 36,
                color: Colors.white.withValues(alpha: 0.2)),
            Expanded(child: _StatItem('Completed', '${stats['completed']}')),
            Container(width: 1, height: 36,
                color: Colors.white.withValues(alpha: 0.2)),
            Expanded(child: _StatItem('Spent',
                'GH₵${(stats['spent'] as double).toStringAsFixed(0)}')),
          ],
        ),
      );
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  const _StatItem(this.label, this.value);

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value,
              style: const TextStyle(
                fontSize:   18,
                fontWeight: FontWeight.w800,
                color:      Colors.white,
              )),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  fontSize: 10, color: Colors.white70)),
        ],
      );
}

// ── Shimmer card ──────────────────────────────────────────────────────────────
class _ShimmerCard extends StatefulWidget {
  @override
  State<_ShimmerCard> createState() => _ShimmerCardState();
}

class _ShimmerCardState extends State<_ShimmerCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _anim = Tween<double>(begin: -1, end: 2).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _anim,
        builder: (_, __) => Container(
          height:  140,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color:        AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border:       Border.all(color: AppColors.border),
          ),
          child: ShaderMask(
            shaderCallback: (bounds) => LinearGradient(
              begin:  Alignment.centerLeft,
              end:    Alignment.centerRight,
              colors: const [
                Color(0xFFEEEEEE),
                Color(0xFFF5F5F5),
                Color(0xFFEEEEEE),
              ],
              stops: [
                (_anim.value - 0.3).clamp(0.0, 1.0),
                _anim.value.clamp(0.0, 1.0),
                (_anim.value + 0.3).clamp(0.0, 1.0),
              ],
            ).createShader(bounds),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(width: 38, height: 38,
                      decoration: BoxDecoration(
                        color:        Colors.white,
                        borderRadius: BorderRadius.circular(10))),
                  const SizedBox(width: 10),
                  Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Container(width: 120, height: 13, color: Colors.white),
                    const SizedBox(height: 5),
                    Container(width: 80,  height: 10, color: Colors.white),
                  ]),
                ]),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity, height: 60,
                  decoration: BoxDecoration(
                    color:        Colors.white,
                    borderRadius: BorderRadius.circular(10))),
              ],
            ),
          ),
        ),
      );
}

// ── Trip card ─────────────────────────────────────────────────────────────────
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
    HistoryItemType.delivery => const Color(0xFF0284C7),
    HistoryItemType.gas      => const Color(0xFFEA580C),
  };

  Color get _iconBg => switch (item.type) {
    HistoryItemType.ride     => AppColors.primaryDim,
    HistoryItemType.delivery => const Color(0xFFE0F2FE),
    HistoryItemType.gas      => const Color(0xFFFFF7ED),
  };

  String get _typeLabel {
    final vt = item.vehicleType;
    final pt = item.parcelType;
    final cs = item.cylinderSize;
    return switch (item.type) {
      HistoryItemType.ride     => vt?.isNotEmpty == true
          ? '${vt![0].toUpperCase()}${vt.substring(1)}' : 'Ride',
      HistoryItemType.delivery => pt?.isNotEmpty == true
          ? '$pt Delivery' : 'Delivery',
      HistoryItemType.gas      => cs?.isNotEmpty == true
          ? '$cs Gas' : 'Gas Order',
    };
  }

  @override
  Widget build(BuildContext context) => Material(
        color:        AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap:        () => _showDetail(context),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border:       Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(children: [
                  Container(
                    width:  40, height: 40,
                    decoration: BoxDecoration(
                      color:        _iconBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(_icon, color: _iconColor, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.driverName?.isNotEmpty == true
                              ? '$_typeLabel · ${item.driverName}'
                              : _typeLabel,
                          style: const TextStyle(
                            fontSize:   13,
                            fontWeight: FontWeight.w700,
                            color:      AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(item.displayDate,
                            style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.textTertiary)),
                      ],
                    ),
                  ),
                  StatusBadge(label: item.statusLabel, type: item.statusType),
                ]),

                const SizedBox(height: 12),

                // Route
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color:        AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(children: [
                    _RouteStop(label: item.origin,      isOrigin: true),
                    Padding(
                      padding: const EdgeInsets.only(left: 3),
                      child: Container(
                          width: 1.5, height: 14,
                          color: AppColors.border),
                    ),
                    _RouteStop(label: item.destination, isOrigin: false),
                  ]),
                ),

                const SizedBox(height: 12),

                // Footer
                Row(children: [
                  if (item.rating != null) ...[
                    const Icon(Icons.star_rounded,
                        color: AppColors.warning, size: 14),
                    const SizedBox(width: 3),
                    Text(item.rating!.toStringAsFixed(1),
                        style: const TextStyle(
                          fontSize:   11,
                          fontWeight: FontWeight.w600,
                          color:      AppColors.textSecondary,
                        )),
                    const SizedBox(width: 10),
                  ],
                  if (item.cancelReason?.isNotEmpty == true)
                    Expanded(
                      child: Text(item.cancelReason!,
                          style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textTertiary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    )
                  else
                    const Spacer(),

                  if (item.type == HistoryItemType.ride && item.isCompleted) ...[
                    GestureDetector(
                      onTap: () => Navigator.pushNamed(
                        context, AppRoutes.bookRide,
                        arguments: {
                          'pickupAddress':  item.origin,
                          'dropoffAddress': item.destination,
                        },
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color:        AppColors.primaryDim,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('Rebook',
                            style: TextStyle(
                              fontSize:   11,
                              fontWeight: FontWeight.w700,
                              color:      AppColors.primary,
                            )),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],

                  Text(
                    'GH₵ ${item.fare.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize:   15,
                      fontWeight: FontWeight.w800,
                      color:      AppColors.textPrimary,
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      );

  void _showDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context:            context,
      backgroundColor:    AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _DetailSheet(item: item),
    );
  }
}

// ── Route stop ────────────────────────────────────────────────────────────────
class _RouteStop extends StatelessWidget {
  final String label;
  final bool   isOrigin;
  const _RouteStop({required this.label, required this.isOrigin});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width:  8, height: 8,
            decoration: BoxDecoration(
              color: isOrigin ? AppColors.primary : AppColors.error,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: TextStyle(
                  fontSize:   12,
                  fontWeight: isOrigin ? FontWeight.w600 : FontWeight.w400,
                  color:      isOrigin
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      );
}

// ── Detail sheet ──────────────────────────────────────────────────────────────
class _DetailSheet extends StatelessWidget {
  final HistoryItem item;
  const _DetailSheet({required this.item});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
          24, 12, 24,
          MediaQuery.of(context).padding.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color:        AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),

            Container(
              width:  64, height: 64,
              decoration: BoxDecoration(
                color: item.isCompleted
                    ? AppColors.primaryDim
                    : item.isCancelled
                        ? AppColors.errorLight
                        : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                item.isCompleted
                    ? Icons.check_circle_rounded
                    : item.isCancelled
                        ? Icons.cancel_rounded
                        : Icons.pending_rounded,
                color: item.isCompleted
                    ? AppColors.primary
                    : item.isCancelled
                        ? AppColors.error
                        : AppColors.textSecondary,
                size: 32,
              ),
            ),
            const SizedBox(height: 12),

            StatusBadge(label: item.statusLabel, type: item.statusType),
            const SizedBox(height: 4),
            Text(item.displayDate,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textTertiary)),
            const SizedBox(height: 20),

            _DetailRow('From', item.origin),
            _DetailRow('To',   item.destination),
            if (item.driverName?.isNotEmpty  == true) _DetailRow('Driver',   item.driverName!),
            if (item.vehicleType?.isNotEmpty == true) _DetailRow('Service',  item.vehicleType!),
            if (item.cylinderSize?.isNotEmpty == true) _DetailRow('Cylinder', item.cylinderSize!),
            if (item.parcelType?.isNotEmpty  == true) _DetailRow('Parcel',   item.parcelType!),
            if (item.cancelReason?.isNotEmpty == true) _DetailRow('Reason',   item.cancelReason!),

            const Divider(height: 24, color: AppColors.border),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Total',
                    style: TextStyle(
                      fontSize:   15,
                      fontWeight: FontWeight.w700,
                      color:      AppColors.textPrimary,
                    )),
                Text('GH₵ ${item.fare.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize:   18,
                      fontWeight: FontWeight.w900,
                      color:      AppColors.primary,
                    )),
              ],
            ),

            if (item.type == HistoryItemType.ride && item.isCompleted) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.pushNamed(context, AppRoutes.bookRide,
                        arguments: {
                          'pickupAddress':  item.origin,
                          'dropoffAddress': item.destination,
                        });
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Rebook This Trip',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize:   15,
                      )),
                ),
              ),
            ],
          ],
        ),
      );
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textTertiary)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                    fontSize:   13,
                    fontWeight: FontWeight.w600,
                    color:      AppColors.textPrimary,
                  )),
            ),
          ],
        ),
      );
}
