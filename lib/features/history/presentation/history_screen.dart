// lib/features/history/presentation/history_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../../core/widgets/cts_ui.dart';
import '../../../core/theme/cts_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/routes/app_routes.dart';
import '../../../widgets/common/shared_widgets.dart';
import '../../ride/models/book_ride_args.dart';

// ── Model ─────────────────────────────────────────────────────────────────────
enum HistoryItemType { ride, delivery, gas }

class HistoryItem {
  final String id;
  final HistoryItemType type;
  final String status;
  final String origin;
  final String destination;
  final double fare;
  final DateTime? createdAt;
  final String? driverName;
  final String? vehicleType;
  final double? rating;
  final String? cancelReason;
  final String? parcelType;
  final String? cylinderSize;

  /// Ride trips only: what "Rebook" opens booking with (the trip's own
  /// pickup, destination, coordinates and vehicle).
  final BookRideArgs? rebook;

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
    this.rebook,
  });

  bool get isCancelled => status.toLowerCase().contains('cancel');
  bool get isCompleted => status == 'completed' || status == 'delivered';
  bool get isActive => !isCancelled && !isCompleted;

  String get statusLabel => switch (status) {
        'tripAccepted' => 'Accepted',
        'driverArrived' => 'Driver Arrived',
        'tripStarted' => 'In Progress',
        'completed' => 'Completed',
        'delivered' => 'Delivered',
        'cancelledByDriver' => 'Cancelled',
        'cancelledByPassenger' => 'Cancelled',
        'cancelled' => 'Cancelled',
        'searching' => 'Searching',
        _ => status,
      };

  StatusType get statusType => switch (status) {
        'completed' || 'delivered' => StatusType.success,
        'cancelledByDriver' ||
        'cancelledByPassenger' ||
        'cancelled' =>
          StatusType.error,
        'tripStarted' || 'inProgress' => StatusType.primary,
        'tripAccepted' ||
        'driverArrived' ||
        'driverAssigned' =>
          StatusType.info,
        _ => StatusType.warning,
      };

  String get displayDate {
    if (createdAt == null) return '';
    final diff = DateTime.now().difference(createdAt!).inDays;
    final h = createdAt!.hour;
    final m = createdAt!.minute.toString().padLeft(2, '0');
    final amPm = h >= 12 ? 'PM' : 'AM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    final time = '$h12:$m $amPm';
    if (diff == 0) return 'Today, $time';
    if (diff == 1) return 'Yesterday, $time';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${months[createdAt!.month - 1]} ${createdAt!.day}, $time';
  }

  factory HistoryItem.fromTrip(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return HistoryItem(
      id: doc.id,
      type: HistoryItemType.ride,
      status: d['status'] as String? ?? '',
      origin: d['pickupAddress'] as String? ?? '—',
      destination: d['dropoffAddress'] as String? ?? '—',
      fare: (d['actualFare'] as num?)?.toDouble() ??
          (d['estimatedFare'] as num?)?.toDouble() ??
          0,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      driverName: d['driverName'] as String?,
      vehicleType: d['serviceType'] as String?,
      rating: (d['passengerRating'] as num?)?.toDouble(),
      cancelReason: d['cancellationReason'] as String?,
      rebook: rebookArgsFromTrip(d),
    );
  }

  factory HistoryItem.fromDelivery(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return HistoryItem(
      id: doc.id,
      type: HistoryItemType.delivery,
      status: d['status'] as String? ?? '',
      origin: d['pickupAddress'] as String? ?? '—',
      destination: d['dropoffAddress'] as String? ?? '—',
      fare: (d['actualFare'] as num?)?.toDouble() ??
          (d['estimatedFare'] as num?)?.toDouble() ??
          0,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      driverName: d['driverName'] as String?,
      parcelType: d['parcelType'] as String?,
      rating: (d['passengerRating'] as num?)?.toDouble(),
      cancelReason: d['cancellationReason'] as String?,
    );
  }

  factory HistoryItem.fromGasOrder(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return HistoryItem(
      id: doc.id,
      type: HistoryItemType.gas,
      status: d['status'] as String? ?? '',
      origin: d['pickupAddress'] as String? ?? '—',
      destination: d['deliveryAddress'] as String? ?? '—',
      fare: (d['totalPrice'] as num?)?.toDouble() ?? 0,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      cylinderSize: d['cylinderSize'] as String?,
      cancelReason: d['cancellationReason'] as String?,
    );
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────
final historyProvider =
    FutureProvider.autoDispose<List<HistoryItem>>((ref) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return [];
  final db = FirebaseFirestore.instance;

  final results = await Future.wait([
    db
        .collection('trips')
        .where('passengerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .get(),
    db
        .collection('deliveries')
        .where('passengerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(30)
        .get(),
    db
        .collection('gas_orders')
        .where('passengerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(30)
        .get(),
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
    (label: 'All', icon: Icons.apps_rounded),
    (label: 'Rides', icon: Icons.directions_car_rounded),
    (label: 'Deliveries', icon: Icons.inventory_2_rounded),
    (label: 'Gas', icon: Icons.local_fire_department_rounded),
    (label: 'Cancelled', icon: Icons.cancel_rounded),
  ];

  List<HistoryItem> _applyFilter(List<HistoryItem> items) =>
      switch (_filterIndex) {
        1 => items
            .where((i) => i.type == HistoryItemType.ride && !i.isCancelled)
            .toList(),
        2 => items
            .where((i) => i.type == HistoryItemType.delivery && !i.isCancelled)
            .toList(),
        3 => items
            .where((i) => i.type == HistoryItemType.gas && !i.isCancelled)
            .toList(),
        4 => items.where((i) => i.isCancelled).toList(),
        _ => items,
      };

  Map<String, dynamic> _stats(List<HistoryItem> items) {
    final completed = items.where((i) => i.isCompleted).toList();
    final totalSpent = completed.fold(0.0, (s, i) => s + i.fare);
    return {
      'total': items.length,
      'completed': completed.length,
      'spent': totalSpent,
    };
  }

  // Items arrive newest first; keep that order and split by calendar day.
  List<(String, List<HistoryItem>)> _groupByDay(List<HistoryItem> items) {
    final groups = <(String, List<HistoryItem>)>[];
    for (final item in items) {
      final key = _dayLabel(item.createdAt);
      if (groups.isEmpty || groups.last.$1 != key) {
        groups.add((key, [item]));
      } else {
        groups.last.$2.add(item);
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(historyProvider);

    return Scaffold(
      backgroundColor: CtsTheme.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            CtsPageTitle(
              'My Trips',
              trailing: IconButton(
                icon: const Icon(Icons.refresh_rounded,
                    color: CtsTheme.textSecondary),
                onPressed: () => ref.refresh(historyProvider.future),
                tooltip: 'Refresh',
              ),
            ),
            _buildFilterChips(),
            const SizedBox(height: 4),
            Expanded(
              child: historyAsync.when(
                loading: () => _buildSkeleton(),
                error: (e, _) {
                  debugPrint('History load error: $e');
                  return _buildError('Check your connection and try again.');
                },
                data: (items) {
                  final filtered = _applyFilter(items);
                  final stats = _stats(items);
                  final groups = _groupByDay(filtered);
                  return RefreshIndicator(
                    color: CtsTheme.primary,
                    onRefresh: () => ref.refresh(historyProvider.future),
                    child: filtered.isEmpty
                        ? _buildEmpty(hasAny: items.isNotEmpty)
                        : CustomScrollView(
                            controller: widget.scrollController,
                            physics: const AlwaysScrollableScrollPhysics(
                                parent: BouncingScrollPhysics()),
                            slivers: [
                              if (_filterIndex == 0)
                                SliverToBoxAdapter(
                                    child: _SummaryCard(stats: stats)),
                              for (final (day, trips) in groups) ...[
                                SliverToBoxAdapter(child: CtsGroupLabel(day)),
                                SliverPadding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: ctsGutter),
                                  sliver: SliverList.separated(
                                    itemCount: trips.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 10),
                                    itemBuilder: (_, i) =>
                                        _TripCard(item: trips[i]),
                                  ),
                                ),
                              ],
                              const SliverToBoxAdapter(
                                  child: SizedBox(height: 28)),
                            ],
                          ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Filter chips ──────────────────────────────────────────────────────────
  Widget _buildFilterChips() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: ctsGutter),
        child: Row(
          children: List.generate(_filters.length, (i) {
            final f = _filters[i];
            return Padding(
              padding: EdgeInsets.only(right: i < _filters.length - 1 ? 8 : 0),
              child: CtsFilterChip(
                label: f.label,
                icon: f.icon,
                selected: _filterIndex == i,
                onTap: () => setState(() => _filterIndex = i),
              ),
            );
          }),
        ),
      );

  // ── States ────────────────────────────────────────────────────────────────
  Widget _buildEmpty({required bool hasAny}) => LayoutBuilder(
        builder: (_, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: hasAny
                  ? CtsEmptyState(
                      icon: _filters[_filterIndex].icon,
                      title:
                          'No ${_filters[_filterIndex].label.toLowerCase()} trips',
                      message: 'Nothing in this filter yet.',
                      actionLabel: 'Show all trips',
                      onAction: () => setState(() => _filterIndex = 0),
                    )
                  : const CtsEmptyState(
                      icon: Icons.receipt_long_rounded,
                      title: 'No trips yet',
                      message: 'Your completed trips will appear here',
                    ),
            ),
          ),
        ),
      );

  Widget _buildSkeleton() => Semantics(
        label: 'Loading trips',
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(ctsGutter, 22, ctsGutter, 24),
          itemCount: 3,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, __) => const _SkeletonCard(),
        ),
      );

  Widget _buildError(String message) => LayoutBuilder(
        builder: (_, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: CtsEmptyState(
                icon: Icons.cloud_off_rounded,
                title: 'Could not load trips',
                message: message,
                actionLabel: 'Try again',
                onAction: () => ref.refresh(historyProvider.future),
              ),
            ),
          ),
        ),
      );
}

String _ghs(double v) => 'GHS ${ctsMoney(v)}';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

// "Today", "Yesterday", "Wed 16 Oct" (year added when not this year).
String _dayLabel(DateTime? d) {
  if (d == null) return 'Earlier';
  final now = DateTime.now();
  final day = DateTime(d.year, d.month, d.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  final year = d.year == now.year ? '' : ' ${d.year}';
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}$year';
}

String _time(DateTime? d) {
  if (d == null) return '';
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} '
      '${d.hour >= 12 ? 'PM' : 'AM'}';
}

CtsTone _statusTone(StatusType t) => switch (t) {
      StatusType.success => CtsTone.success,
      StatusType.error => CtsTone.error,
      StatusType.primary => CtsTone.info,
      StatusType.info => CtsTone.info,
      StatusType.warning => CtsTone.warning,
    };

// ── Service identity (cards and the detail sheet) ────────────────────────────
// Taxi, Okada and Pragya share the ride colour but keep their own shape.
IconData _serviceIcon(HistoryItem item) {
  final vehicle = (item.vehicleType ?? '').toLowerCase();
  return switch (item.type) {
    HistoryItemType.ride => vehicle.contains('okada')
        ? Icons.two_wheeler_rounded
        : vehicle.contains('pragya')
            ? Icons.electric_rickshaw_rounded
            : vehicle.contains('taxi')
                ? Icons.local_taxi_rounded
                : Icons.directions_car_rounded,
    HistoryItemType.delivery => Icons.inventory_2_rounded,
    HistoryItemType.gas => Icons.local_fire_department_rounded,
  };
}

CtsTone _serviceTone(HistoryItem item) => switch (item.type) {
      HistoryItemType.ride => CtsTone.brand,
      HistoryItemType.delivery => CtsTone.delivery,
      HistoryItemType.gas => CtsTone.gas,
    };

String _serviceLabel(HistoryItem item) {
  final vt = item.vehicleType;
  final pt = item.parcelType;
  final cs = item.cylinderSize;
  return switch (item.type) {
    HistoryItemType.ride => vt?.isNotEmpty == true
        ? '${vt![0].toUpperCase()}${vt.substring(1)}'
        : 'Ride',
    HistoryItemType.delivery =>
      pt?.isNotEmpty == true ? '$pt Delivery' : 'Delivery',
    HistoryItemType.gas => cs?.isNotEmpty == true ? '$cs Gas' : 'Gas Order',
  };
}

// ── Summary ───────────────────────────────────────────────────────────────────
// What has been spent on completed trips, with the trip counts beside it.
class _SummaryCard extends StatelessWidget {
  final Map<String, dynamic> stats;
  const _SummaryCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    final spent = stats['spent'] as double;
    final total = stats['total'] as int;
    final completed = stats['completed'] as int;

    final amount = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Spent on completed trips', style: CtsText.caption),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(_ghs(spent),
              style: CtsText.priceLarge.copyWith(fontSize: 26)),
        ),
      ],
    );
    Widget count(String value, String label) => Semantics(
          label: '$value $label',
          excludeSemantics: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: CtsText.price),
              Text(label, style: CtsText.caption),
            ],
          ),
        );
    final counts = Wrap(
      spacing: 20,
      runSpacing: 8,
      children: [
        count('$total', total == 1 ? 'trip' : 'trips'),
        count('$completed', 'completed'),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(ctsGutter, 12, ctsGutter, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          color: CtsTheme.surface,
          borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
          border: Border.all(color: CtsTheme.border),
        ),
        child: ctsLargeText(context)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [amount, const SizedBox(height: 14), counts],
              )
            : Row(
                children: [
                  Expanded(child: amount),
                  Container(
                    width: 1,
                    height: 40,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    color: CtsTheme.borderLight,
                  ),
                  counts,
                ],
              ),
      ),
    );
  }
}

// ── Loading card ──────────────────────────────────────────────────────────────
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: CtsTheme.surface,
          borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
          border: Border.all(color: CtsTheme.border),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CtsSkeleton(width: 44, height: 44, radius: 13),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CtsSkeleton(width: 110),
                    SizedBox(height: 8),
                    CtsSkeleton(width: 80, height: 11),
                  ],
                ),
              ),
              CtsSkeleton(width: 70),
            ]),
            SizedBox(height: 18),
            CtsSkeleton(height: 12),
            SizedBox(height: 14),
            CtsSkeleton(width: 200, height: 12),
          ],
        ),
      );
}

// ── Trip card ─────────────────────────────────────────────────────────────────
class _TripCard extends StatelessWidget {
  final HistoryItem item;
  const _TripCard({required this.item});

  IconData get _icon => _serviceIcon(item);
  CtsTone get _tone => _serviceTone(item);
  String get _typeLabel => _serviceLabel(item);

  void _rebook(BuildContext context) => Navigator.pushNamed(
        context,
        AppRoutes.bookRide,
        arguments: (item.rebook ?? const BookRideArgs()).toMap(),
      );

  @override
  Widget build(BuildContext context) {
    final canRebook = item.type == HistoryItemType.ride && item.isCompleted;
    final large = ctsLargeText(context);
    final meta = [
      _time(item.createdAt),
      if (item.driverName?.isNotEmpty == true) item.driverName!,
    ].where((s) => s.isNotEmpty).join(' · ');

    final fare = Text(_ghs(item.fare),
        textAlign: TextAlign.right,
        style: CtsText.price.copyWith(
          fontSize: 16,
          color: item.isCancelled ? CtsTheme.textSecondary : null,
        ));
    final pill =
        CtsStatusPill(item.statusLabel, tone: _statusTone(item.statusType));
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_typeLabel,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: CtsText.cardTitle.copyWith(fontWeight: FontWeight.w700)),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(meta, style: CtsText.caption),
        ],
      ],
    );
    final tile = CtsIconTile(_icon, tone: _tone, size: 44);

    final hasReason = item.cancelReason?.isNotEmpty == true;
    final hasRating = item.rating != null;
    final hasFooter = hasReason || hasRating || canRebook;

    return Material(
      color: CtsTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
        side: const BorderSide(color: CtsTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showDetail(context),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, hasFooter ? 6 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: service and time on the left, fare and status right
              if (large) ...[
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  tile,
                  const SizedBox(width: 12),
                  Expanded(child: title),
                ]),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [fare, pill],
                ),
              ] else
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  tile,
                  const SizedBox(width: 12),
                  Expanded(child: title),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [fare, const SizedBox(height: 6), pill],
                  ),
                ]),

              const SizedBox(height: 14),
              _Route(
                  origin: item.origin,
                  destination: item.destination,
                  maxLines: large ? 3 : 1),

              // Footer: reason or rating, and Rebook for finished rides
              if (hasFooter) ...[
                const SizedBox(height: 10),
                const Divider(height: 1, color: CtsTheme.borderLight),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      if (hasReason)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 1),
                                child: Icon(Icons.info_outline_rounded,
                                    size: 15, color: CtsTheme.textTertiary),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(item.cancelReason!,
                                    style: CtsText.caption,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ],
                          ),
                        )
                      else if (hasRating)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: _Stars(rating: item.rating!),
                        )
                      else
                        const SizedBox(height: 48),
                      if (canRebook)
                        TextButton.icon(
                          onPressed: () => _rebook(context),
                          icon: const Icon(Icons.replay_rounded, size: 17),
                          label: const Text('Rebook'),
                          style: TextButton.styleFrom(
                            foregroundColor: CtsTheme.primaryDeep,
                            backgroundColor: CtsTheme.primaryTint,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            shape: const StadiumBorder(),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CtsTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(CtsTheme.radiusXl))),
      builder: (_) => _DetailSheet(item: item),
    );
  }
}

class _Stars extends StatelessWidget {
  final double rating;
  const _Stars({required this.rating});

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Rated ${rating.toStringAsFixed(1)} out of 5',
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 1; i <= 5; i++)
              Icon(
                rating >= i - 0.25
                    ? Icons.star_rounded
                    : rating >= i - 0.75
                        ? Icons.star_half_rounded
                        : Icons.star_outline_rounded,
                size: 16,
                color: CtsTheme.warningFill,
              ),
            const SizedBox(width: 6),
            Text(rating.toStringAsFixed(1),
                style: CtsText.caption.copyWith(
                    color: CtsTheme.textSecondary,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

// ── Route: pickup ring, rail, drop-off dot ────────────────────────────────────
class _Route extends StatelessWidget {
  final String origin;
  final String destination;
  final int maxLines;
  const _Route(
      {required this.origin, required this.destination, this.maxLines = 1});

  Widget _stop(String label, String text, {required bool start}) => Semantics(
        label: '$label: $text',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(),
                style: CtsText.caption
                    .copyWith(fontSize: 12, letterSpacing: 0.4, height: 1.2)),
            const SizedBox(height: 1),
            Text(text,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: CtsText.bodySmall.copyWith(
                    color: CtsTheme.textPrimary,
                    fontWeight: start ? FontWeight.w600 : FontWeight.w500)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: CtsTheme.background,
          borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Rail: ring at the top, dot at the bottom, line between
              SizedBox(
                width: 12,
                child: Column(
                  children: [
                    const SizedBox(height: 4),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: CtsTheme.surface,
                        border: Border.all(color: CtsTheme.primary, width: 2),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        width: 2,
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        color: CtsTheme.mintBorder,
                      ),
                    ),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: CtsTheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _stop('From', origin, start: true),
                    const SizedBox(height: 10),
                    _stop('To', destination, start: false),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

// ── Detail sheet ──────────────────────────────────────────────────────────────
// Same service identity, status colours and route rail as the card, with
// full addresses and every stored detail.
class _DetailSheet extends StatelessWidget {
  final HistoryItem item;
  const _DetailSheet({required this.item});

  @override
  Widget build(BuildContext context) {
    final large = ctsLargeText(context);
    final pill =
        CtsStatusPill(item.statusLabel, tone: _statusTone(item.statusType));
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(_serviceLabel(item), style: CtsText.title3),
        ),
        if (item.displayDate.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(item.displayDate, style: CtsText.bodySmall),
        ],
      ],
    );
    final details = <Widget>[
      if (item.driverName?.isNotEmpty == true)
        CtsDetailRow('Driver', item.driverName!),
      if (item.vehicleType?.isNotEmpty == true)
        CtsDetailRow('Service', item.vehicleType!),
      if (item.cylinderSize?.isNotEmpty == true)
        CtsDetailRow('Cylinder', item.cylinderSize!),
      if (item.parcelType?.isNotEmpty == true)
        CtsDetailRow('Parcel', item.parcelType!),
      if (item.cancelReason?.isNotEmpty == true)
        CtsDetailRow('Reason', item.cancelReason!),
    ];

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        ctsGutter + 4,
        12,
        ctsGutter + 4,
        MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: CtsTheme.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Header: service, when, status
          if (large) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: CtsIconTile(_serviceIcon(item),
                  tone: _serviceTone(item), size: 48),
            ),
            const SizedBox(height: 12),
            title,
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: pill),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CtsIconTile(_serviceIcon(item),
                    tone: _serviceTone(item), size: 48),
                const SizedBox(width: 14),
                Expanded(child: title),
                const SizedBox(width: 12),
                Padding(padding: const EdgeInsets.only(top: 3), child: pill),
              ],
            ),
          const SizedBox(height: 20),

          // Route with full addresses
          _Route(
              origin: item.origin, destination: item.destination, maxLines: 4),

          if (details.isNotEmpty) ...[
            const SizedBox(height: 14),
            CtsDetailCard(rows: details),
          ],

          // Total
          const SizedBox(height: 14),
          Semantics(
            label: 'Total: ${_ghs(item.fare)}',
            excludeSemantics: true,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: BoxDecoration(
                color: CtsTheme.primaryTint,
                borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
                border: Border.all(color: CtsTheme.mintBorder),
              ),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 4,
                children: [
                  const Text('Total', style: CtsText.cardTitle),
                  Text(_ghs(item.fare),
                      style: CtsText.priceLarge.copyWith(fontSize: 24)),
                ],
              ),
            ),
          ),

          if (item.type == HistoryItemType.ride && item.isCompleted) ...[
            const SizedBox(height: 18),
            CtsPrimaryButton(
              label: 'Rebook this trip',
              icon: Icons.replay_rounded,
              onPressed: () {
                // The sheet's context goes away with it: take the navigator
                // first.
                final navigator = Navigator.of(context);
                navigator.pop();
                navigator.pushNamed(AppRoutes.bookRide,
                    arguments: (item.rebook ?? const BookRideArgs()).toMap());
              },
            ),
          ],
        ],
      ),
    );
  }
}
