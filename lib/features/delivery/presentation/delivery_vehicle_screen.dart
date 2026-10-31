import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../../core/services/escrow_service.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/theme/cts_theme.dart';
import '../../../core/widgets/cts_booking.dart';
import '../../../core/widgets/cts_ui.dart';
import '../../home/widgets/service_tile.dart';
import '../../ride/models/service_type.dart';
import 'delivery_matching_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../domain/delivery_quote.dart';
import '../models/delivery_request.dart';
import '../../delivery/providers/delivery_provider.dart';
import '../../../core/services/pricing_service.dart';
import 'package:flutter/services.dart';

class DeliveryVehicleScreen extends ConsumerStatefulWidget {
  final String pickup;
  final GeoPoint pickupGeoPoint; // ← NEW
  final String dropoff;
  final GeoPoint dropoffGeoPoint; // ← NEW
  final String weightTier;
  final String weightRange;
  final List<String> eligibleVehicles;
  final String parcelType;
  final bool isFragile;
  final bool requiresHelpers;
  final bool hasPhoto;
  final String receiverPhone;
  final String receiverName; // ← NEW
  final String notes;
  final String? photoUrl;

  const DeliveryVehicleScreen({
    super.key,
    required this.pickup,
    required this.pickupGeoPoint,
    required this.dropoff,
    required this.dropoffGeoPoint,
    required this.weightTier,
    required this.weightRange,
    required this.eligibleVehicles,
    required this.parcelType,
    required this.isFragile,
    required this.requiresHelpers,
    required this.hasPhoto,
    required this.receiverPhone,
    required this.receiverName,
    required this.notes,
    this.photoUrl,
  });

  @override
  ConsumerState<DeliveryVehicleScreen> createState() =>
      _DeliveryVehicleScreenState();
}

class _DeliveryVehicleScreenState extends ConsumerState<DeliveryVehicleScreen> {
  int _selectedVehicleIndex = 0;

  Widget _buildPaymentSelector() {
    Widget option(String value, IconData icon, String label, String sub) {
      final selected = _paymentMethod == value;
      return Expanded(
        child: CtsSelectableCard(
          selected: selected,
          semanticLabel: '$label, $sub',
          showCheck: false,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          onTap: () => setState(() => _paymentMethod = value),
          child: Row(children: [
            Icon(icon,
                size: 18,
                color:
                    selected ? CtsTheme.primaryDeep : CtsTheme.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: CtsTheme.textPrimary,
                      )),
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: CtsTheme.textSecondary)),
                ],
              ),
            ),
          ]),
        ),
      );
    }

    return Row(children: [
      option('wallet', Icons.account_balance_wallet_rounded, 'Wallet',
          'Pay from balance'),
      const SizedBox(width: 10),
      option('cash', Icons.payments_rounded, 'Cash', 'Pay driver directly'),
    ]);
  }

  @override
  void initState() {
    super.initState();
    _startQuote();
  }

  @override
  void didUpdateWidget(DeliveryVehicleScreen old) {
    super.didUpdateWidget(old);
    final routeChanged = old.pickupGeoPoint != widget.pickupGeoPoint ||
        old.dropoffGeoPoint != widget.dropoffGeoPoint;
    final parcelChanged = old.weightTier != widget.weightTier ||
        old.isFragile != widget.isFragile ||
        old.requiresHelpers != widget.requiresHelpers ||
        !listEquals(old.eligibleVehicles, widget.eligibleVehicles);
    if (routeChanged || parcelChanged) {
      _selectedVehicleIndex = 0;
      _startQuote(); // build() follows didUpdateWidget
    }
  }

  // The price is the server's quote (functions/delivery_quotes.js): it
  // measures the road route and prices it from the approved rates. Until it
  // answers — or if it cannot (no route, prices unavailable) — nothing is
  // priced or charged; there is no local or straight-line estimate. Each
  // request carries a sequence number so an older answer that arrives late
  // can never replace a newer quote.
  int _quoteSeq = 0;
  DeliveryQuote? _quote;
  bool _quoteFailed = false;
  String? _quoteError;

  bool get _calculatingDistance => _quote == null && !_quoteFailed;
  double get _distanceKm => _quote?.distanceKm ?? 0;

  void _startQuote() {
    _quote = null;
    _quoteFailed = false;
    _quoteError = null;
    unawaited(_fetchQuote(++_quoteSeq));
  }

  /// Server quotes for every offered vehicle, for the current inputs.
  Future<DeliveryQuote> _requestQuotes() async {
    final service = ref.read(deliveryQuoteServiceProvider);
    final entries = await Future.wait(_vehicles.map((v) async {
      final key = v['key'] as String;
      return MapEntry(
          key,
          await service.quote(
            pickup: widget.pickupGeoPoint,
            dropoff: widget.dropoffGeoPoint,
            vehicleType: key,
            weightTier: widget.weightTier,
            isFragile: widget.isFragile,
            requiresHelpers: widget.requiresHelpers,
          ));
    }));
    return DeliveryQuote(fares: Map.fromEntries(entries));
  }

  Future<void> _fetchQuote(int seq) async {
    // The surcharge labels in the chips read the configured prices; the
    // payable amount never does.
    unawaited(() async {
      try {
        await ref.read(deliveryPricingLoaderProvider)();
      } catch (_) {}
    }());
    DeliveryQuote? quote;
    String? error;
    try {
      quote = await _requestQuotes();
    } on DeliveryQuoteException catch (e) {
      error = e.message;
    } catch (_) {
      error = null;
    }
    if (!mounted || seq != _quoteSeq) return; // superseded
    setState(() {
      _quote = quote;
      _quoteFailed = quote == null;
      _quoteError = error;
    });
  }

  void _retryQuote() => setState(_startQuote);

  // Display metadata only — pricing comes from PricingService, not these.
  final List<Map<String, dynamic>> _allVehicles = [
    {
      'key': 'Okada',
      'icon': Icons.two_wheeler_rounded,
      'name': 'Okada',
      'desc': 'Fast · small parcels only',
      'capacity': '0–5 kg',
    },
    {
      'key': 'Aboboya',
      'icon': Icons.electric_rickshaw_rounded,
      'name': 'Aboboya',
      'desc': 'Tricycle · medium loads',
      'capacity': '5–100 kg',
    },
    {
      'key': 'Mini Truck',
      'icon': Icons.local_shipping_rounded,
      'name': 'Mini Truck',
      'desc': 'Bulk goods · furniture · materials',
      'capacity': '100 kg+',
    },
  ];

  List<Map<String, dynamic>> get _vehicles => _allVehicles
      .where((v) => widget.eligibleVehicles.contains(v['key']))
      .toList();

  Map<String, dynamic> get _selected => _vehicles[_selectedVehicleIndex];

  // The selected vehicle's server quote: base + per-km, weight, fragile and
  // helper surcharges, minimum fare. The same figure is shown, held in escrow
  // and stored on the order (which the server checks against the quote).
  ServerDeliveryQuote get _selectedFare =>
      _quote!.fares[_selected['key'] as String]!;

  double get _totalFare => _selectedFare.total;

  // Step 2 of 2: what is being sent, the vehicles that can carry it with
  // their fares (from PricingService), payment, and the total. The action
  // stays disabled until the route is measured, so no price is shown or
  // charged before it is known.
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: ctsBrandOverlay,
      child: Scaffold(
        backgroundColor: CtsTheme.canvas,
        body: Column(
          children: [
            const CtsStatusBarStrip(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  const CtsBrandHeader(
                    eyebrow: 'Step 2 of 2 · Vehicle & price',
                    title: 'Choose a vehicle',
                    subtitle: 'Check your delivery, pick a vehicle and '
                        'confirm the price.',
                    icon: Icons.local_shipping_rounded,
                  ),
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: ctsGutter),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        CtsFormSection(
                          number: '1',
                          title: 'Your delivery',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildRouteSummary(),
                              const SizedBox(height: 12),
                              _buildInfoChips(),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        CtsFormSection(
                          number: '2',
                          title: 'Vehicle',
                          caption:
                              'For ${widget.weightTier.toLowerCase()} parcels (${widget.weightRange})',
                          child: Column(
                            children: [
                              for (final e in _vehicles.asMap().entries) ...[
                                if (e.key > 0) const SizedBox(height: 8),
                                _VehicleCard(
                                  vehicle: e.value,
                                  isSelected: _selectedVehicleIndex == e.key,
                                  fare: _quote
                                      ?.fares[e.value['key'] as String]?.total,
                                  unavailable: _quoteFailed,
                                  approximate: false,
                                  onTap: () => setState(() {
                                    _selectedVehicleIndex = e.key;
                                  }),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        CtsFormSection(
                          number: '3',
                          title: 'Payment',
                          child: _buildPaymentSelector(),
                        ),
                        const SizedBox(height: 16),
                        _buildFareBreakdown(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            CtsBookingBar(
              hint: _calculatingDistance
                  ? 'Measuring your route to price the delivery…'
                  : _quoteFailed
                      ? (_quoteError ??
                          'We couldn\'t price this delivery right now. '
                              'Check your connection and try again.')
                      : null,
              action: _quoteFailed
                  ? CtsPrimaryButton(
                      label: 'Try again',
                      icon: Icons.refresh_rounded,
                      onPressed: _retryQuote,
                    )
                  : CtsPrimaryButton(
                      label: _calculatingDistance
                          ? 'Calculating fare…'
                          : 'Find a delivery driver',
                      trailingText: _quote == null
                          ? null
                          : 'GHS ${_totalFare.toStringAsFixed(2)}',
                      icon: Icons.local_shipping_rounded,
                      loading: _isCreating,
                      onPressed: _quote == null || _isCreating
                          ? null
                          : _confirmDelivery,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteSummary() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: CtsTheme.mint,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CtsTheme.mintBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RouteRow(caption: 'Pickup', label: widget.pickup, filled: false),
          const Padding(
            padding: EdgeInsets.only(left: 5, top: 2, bottom: 2),
            child: SizedBox(
              height: 12,
              child: VerticalDivider(
                  width: 2, thickness: 2, color: CtsTheme.mintBorder),
            ),
          ),
          _RouteRow(caption: 'Drop-off', label: widget.dropoff, filled: true),
          const Divider(height: 22, color: CtsTheme.mintBorder),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _StatPill(
                  icon: Icons.straighten_rounded,
                  label: _calculatingDistance
                      ? 'Measuring route…'
                      : _quoteFailed
                          ? 'Route not measured'
                          : '${_distanceKm.toStringAsFixed(1)} km'),
              _StatPill(icon: Icons.scale_rounded, label: widget.weightRange),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChips() {
    final pricing = PricingService.instance;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Chip(label: widget.parcelType, icon: Icons.inventory_2_rounded),
        _Chip(label: widget.weightTier, icon: Icons.scale_rounded),
        if (widget.isFragile)
          _Chip(
              label:
                  'Fragile +GHS ${pricing.deliveryFragileSurcharge.toStringAsFixed(0)}',
              icon: Icons.wine_bar_rounded),
        if (widget.requiresHelpers)
          _Chip(
              label:
                  'Helpers +GHS ${pricing.deliveryHelperSurcharge.toStringAsFixed(0)}',
              icon: Icons.people_rounded),
        if (widget.hasPhoto)
          const _Chip(
              label: 'Photo attached', icon: Icons.photo_camera_rounded),
      ],
    );
  }

  Widget _buildFareBreakdown() {
    if (_calculatingDistance) {
      return const CtsPriceSummary(
        lines: [],
        totalLabel: 'Total estimate',
        total: null,
        pendingText: 'Measuring route…',
        note: 'The price appears once your route is measured.',
      );
    }
    if (_quoteFailed) {
      return const CtsPriceSummary(
        lines: [],
        totalLabel: 'Total estimate',
        total: null,
        pendingText: 'Price unavailable',
        note: 'We couldn\'t price this route, so no price is shown and '
            'nothing can be charged. Try again to continue.',
      );
    }
    // Every amount below is a component of the server's quote, so the lines
    // add up to exactly what is charged.
    final f = _selectedFare;
    final km = '${_distanceKm.toStringAsFixed(1)} km';
    final components = f.distanceFare +
        f.weightSurcharge +
        f.fragileSurcharge +
        f.helperSurcharge;
    final minimumTopUp = f.minimumApplied ? f.total - components : 0.0;

    return CtsPriceSummary(
      lines: [
        CtsPriceLine('Distance fare ($km by road)',
            'GHS ${f.distanceFare.toStringAsFixed(2)}'),
        if (f.weightSurcharge > 0)
          CtsPriceLine('${widget.weightTier} package',
              '+GHS ${f.weightSurcharge.toStringAsFixed(2)}'),
        if (f.fragileSurcharge > 0)
          CtsPriceLine('Fragile handling',
              '+GHS ${f.fragileSurcharge.toStringAsFixed(2)}'),
        if (f.helperSurcharge > 0)
          CtsPriceLine('Loading helpers',
              '+GHS ${f.helperSurcharge.toStringAsFixed(2)}'),
        if (minimumTopUp > 0)
          CtsPriceLine('Minimum fare top-up',
              '+GHS ${minimumTopUp.toStringAsFixed(2)}'),
      ],
      totalLabel: 'Total',
      total: 'GHS ${_totalFare.toStringAsFixed(2)}',
      note: [
        if (f.minimumApplied)
          'Short trip: the ${_selected['name']} minimum fare of '
              'GHS ${f.minimumFare.toStringAsFixed(2)} applies.',
        'This is the price you pay for this booking.',
      ].join(' '),
    );
  }

  bool _isCreating = false;

  String _paymentMethod = 'wallet'; // 'wallet' | 'cash'

  Future<void> _confirmDelivery() async {
    if (_isCreating) return; // re-entry guard
    if (_quote == null) return; // never charge without a current quote
    final uid = ref.read(deliveryCurrentUidProvider)();
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please sign in again to place this delivery.'),
      ));
      return;
    }

    HapticFeedback.mediumImpact(); // instant tactile feedback
    setState(() => _isCreating = true); // immediate loading state

    // ── Step 0: a current quote ───────────────────────────────────────────
    // The server accepts the order only on an unexpired quote at its total.
    // A quote about to expire is replaced first; if its price differs, the
    // customer sees old → new and goes on only if they agree.
    if (_selectedFare.expiresSoon(DateTime.now())) {
      final shown = _totalFare;
      final seq = ++_quoteSeq;
      DeliveryQuote? fresh;
      try {
        fresh = await _requestQuotes();
      } on DeliveryQuoteException catch (e) {
        if (mounted) {
          setState(() => _isCreating = false);
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(e.message)));
        }
        return;
      } catch (_) {
        if (mounted) setState(() => _isCreating = false);
        return;
      }
      if (!mounted || seq != _quoteSeq) return;
      setState(() => _quote = fresh);
      if (_totalFare != shown) {
        final agreed = await ref.read(deliveryPriceChangeConfirmProvider)(
            context, shown, _totalFare);
        if (agreed != true || !mounted) {
          if (mounted) setState(() => _isCreating = false);
          return;
        }
      }
    }
    final quote = _selectedFare;

    // ── Step 1: Hold funds (wallet only — cash is collected by the driver) ──
    String? escrowId;
    if (_paymentMethod == 'wallet') {
      final escrowResult = await EscrowService.instance.holdBalance(
        amount: quote.total,
        serviceType: 'delivery',
        referenceType: 'delivery',
      );
      if (!escrowResult.success) {
        if (mounted) {
          setState(() => _isCreating = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(escrowResult.shortfall != null
                ? 'Need GHS ${escrowResult.shortfall!.toStringAsFixed(2)} more. Top up your wallet.'
                : escrowResult.error ?? 'Payment hold failed.'),
            backgroundColor: const Color(0xFFDC2626),
            action: SnackBarAction(
              label: 'Top Up',
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .pushNamed('/wallet'),
            ),
          ));
        }
        return;
      }
      escrowId = escrowResult.escrowId!;
    }
    // ─────────────────────────────────────────────────────────────────────

    try {
      final request = DeliveryRequest(
        id: '',
        passengerId: uid,
        status: DeliveryStatus.pending,
        pickupLocation: widget.pickupGeoPoint,
        dropoffLocation: widget.dropoffGeoPoint,
        pickupAddress: widget.pickup,
        photoUrl: widget.photoUrl,
        dropoffAddress: widget.dropoff,
        parcelType: widget.parcelType,
        weightTier: widget.weightTier,
        weightRange: widget.weightRange,
        isFragile: widget.isFragile,
        requiresHelpers: widget.requiresHelpers,
        notes: widget.notes.isEmpty ? null : widget.notes,
        vehicleType: _selected['name'],
        receiverPhone:
            widget.receiverPhone.isEmpty ? null : widget.receiverPhone,
        receiverName: widget.receiverName.isEmpty ? null : widget.receiverName,
        // Exactly the quote's total, for its route and parcel (the server
        // refuses anything else).
        estimatedFare: quote.total,
        deliveryQuoteId: quote.quoteId,
        createdAt: DateTime.now(),
        paymentMethod: _paymentMethod,
      );

      final repo = ref.read(deliveryRepositoryProvider);
      final deliveryId = await repo.createDelivery(request);
      // ── Step 2: Attach escrow (wallet bookings only) ──────────────────────
      if (escrowId != null) {
        await EscrowService.instance.attachToOrder(
          escrowId: escrowId,
          referenceId: deliveryId,
          referenceType: 'delivery',
        );
        // Save escrowId to delivery document for CF cancellation refund
        await FirebaseFirestore.instance
            .collection('deliveries')
            .doc(deliveryId)
            .update({'escrowId': escrowId});
      }

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => DeliveryMatchingScreen(
            deliveryId: deliveryId,
            vehicleName: _selected['name'],
            dropoff: widget.dropoff,
            fare: 'GHS ${quote.total.toStringAsFixed(2)}',
          ),
        ),
      );
    } catch (e) {
      // Rollback escrow if delivery creation failed
      if (escrowId != null) {
        try {
          final fns = FirebaseFunctions.instanceFor(region: 'europe-west2');
          await fns.httpsCallable('refundEscrowOnError').call({
            'escrowId': escrowId,
            'reason': 'order_creation_failed',
          });
        } catch (_) {}
      }
      debugPrint('Delivery creation failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text(
            'We couldn\'t place your delivery. Check your connection and try again.'),
        backgroundColor: AppColors.error,
      ));
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }
}

// ─── Vehicle Card ─────────────────────────────────────────────────────────────
/// The signed-in customer's uid, or null. Overridable in tests.
final deliveryCurrentUidProvider = Provider<String? Function()>(
    (ref) => () => FirebaseAuth.instance.currentUser?.uid);

/// Asks the customer to accept a delivery price that changed from [was] to
/// [now] since it was shown; true to go on at [now]. Overridable in tests.
final deliveryPriceChangeConfirmProvider = Provider<
    Future<bool?> Function(BuildContext context, double was, double now)>(
  (ref) => (context, was, now) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delivery price updated'),
          content: Text('The price for this delivery is now '
              'GHS ${now.toStringAsFixed(2)} (was GHS ${was.toStringAsFixed(2)}).'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Book for GHS ${now.toStringAsFixed(2)}')),
          ],
        ),
      ),
);

class _VehicleCard extends StatelessWidget {
  final Map<String, dynamic> vehicle;
  final bool isSelected;
  final double? fare; // null until the route and prices are both loaded
  final bool unavailable; // prices failed to load
  final bool approximate; // priced from straight-line distance
  final VoidCallback onTap;

  const _VehicleCard({
    required this.vehicle,
    required this.isSelected,
    required this.fare,
    required this.unavailable,
    required this.approximate,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fareText = fare != null
        ? '${approximate ? '~' : ''}GHS ${fare!.toStringAsFixed(2)}'
        : unavailable
            ? 'Unavailable'
            : 'Calculating…';
    final fareCaption = approximate ? 'Approximate' : 'Estimate';
    return CtsSelectableCard(
      selected: isSelected,
      showCheck: false,
      semanticLabel:
          '${vehicle['name']}, ${vehicle['desc']}, ${vehicle['capacity']}, $fareText ${fareCaption.toLowerCase()}',
      padding: const EdgeInsets.all(10),
      onTap: onTap,
      child: Row(
        children: [
          _VehicleThumb(vehicle: vehicle, isSelected: isSelected),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(vehicle['name'],
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: CtsTheme.textPrimary,
                    )),
                Text(vehicle['desc'],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: CtsTheme.textSecondary)),
                const SizedBox(height: 2),
                Text('Carries ${vehicle['capacity']}',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: CtsTheme.textTertiary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 104),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(fareText,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: fare == null ? 12.5 : 15.5,
                        fontWeight: FontWeight.w800,
                        color: fare == null
                            ? CtsTheme.textSecondary
                            : CtsTheme.textPrimary,
                      )),
                ),
                Text(fareCaption,
                    style: const TextStyle(
                        fontSize: 12, color: CtsTheme.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Okada has a real photo; Aboboya and Mini Truck have none yet, so they get
/// an icon tile of the same size rather than a photo of a different vehicle.
class _VehicleThumb extends StatelessWidget {
  final Map<String, dynamic> vehicle;
  final bool isSelected;
  const _VehicleThumb({required this.vehicle, required this.isSelected});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 64,
          height: 54,
          child: vehicle['key'] == 'Okada'
              ? const ServiceImage(
                  service: ServiceType.okada, aspectRatio: 64 / 54)
              : ColoredBox(
                  color: isSelected ? CtsTheme.surface : CtsTheme.surfaceAlt,
                  child: Icon(vehicle['icon'] as IconData,
                      size: 26,
                      color: isSelected
                          ? CtsTheme.primaryDeep
                          : CtsTheme.textSecondary),
                ),
        ),
      );
}

// ─── Small shared widgets ─────────────────────────────────────────────────────
class _RouteRow extends StatelessWidget {
  final String caption;
  final String label;
  final bool filled;
  const _RouteRow(
      {required this.caption, required this.label, required this.filled});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 3),
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: filled ? CtsTheme.primary : CtsTheme.surface,
            shape: BoxShape.circle,
            border: Border.all(color: CtsTheme.primary, width: 2.5),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(caption,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: CtsTheme.textSecondary)),
              Text(label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: CtsTheme.textPrimary,
                  )),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String label;
  const _StatPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: CtsTheme.textSecondary),
        const SizedBox(width: 5),
        Flexible(
          child: Text(label,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: CtsTheme.textPrimary,
              )),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final IconData icon;
  const _Chip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: CtsTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: CtsTheme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: CtsTheme.textSecondary),
          const SizedBox(width: 5),
          Flexible(
            child: Text(label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: CtsTheme.textPrimary,
                )),
          ),
        ],
      ),
    );
  }
}
