// Order Gas from an approved supplier: order type and cylinder → delivery
// address → supplier options → server price (product, handling, delivery)
// → confirm and pay from wallet → tracking. Reached from the Gas entry
// (gas_entry_screen.dart) only when the server reports supplier ordering
// is available.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/routes/app_routes.dart';
import '../../../core/theme/cts_theme.dart';
import '../../../core/widgets/cts_booking.dart';
import '../../../core/widgets/cts_photo_header.dart';
import '../../../core/widgets/cts_ui.dart';
import '../../gas/presentation/widgets/address_picker_sheet.dart';
import '../../gas/presentation/widgets/gas_booking_widgets.dart';
import '../data/gas_supplier_repository.dart';
import '../domain/gas_supplier_models.dart';
import 'gas_supplier_tracking_screen.dart';
import '../../../core/utils/cedi_format.dart';

String _ghs(double v) => formatCedis(v);

/// A chosen delivery address.
typedef DeliveryPoint = ({String address, double latitude, double longitude});

/// Lets the passenger choose where to deliver; the app's address picker, a fake in tests.
typedef PickDeliveryPoint = Future<DeliveryPoint?> Function(BuildContext context);

Future<DeliveryPoint?> pickWithAddressSheet(BuildContext context) async {
  final r = await showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const AddressPickerSheet(),
  );
  if (r == null) return null;
  final geo = r['location'] as GeoPoint;
  return (address: r['address'] as String, latitude: geo.latitude, longitude: geo.longitude);
}

class GasSupplierOrderScreen extends StatefulWidget {
  /// A delivery address already chosen, if any; otherwise the passenger picks one here.
  final DeliveryPoint? initialDelivery;
  final GasSupplierRepository? repository;
  final PickDeliveryPoint pickDelivery;
  const GasSupplierOrderScreen({super.key, this.initialDelivery, this.repository, this.pickDelivery = pickWithAddressSheet});

  @override
  State<GasSupplierOrderScreen> createState() => _GasSupplierOrderScreenState();
}

class _GasSupplierOrderScreenState extends State<GasSupplierOrderScreen> {
  late final GasSupplierRepository repo = widget.repository ?? GasSupplierRepository();
  bool? available;
  late DeliveryPoint? delivery = widget.initialDelivery;
  String orderType = supplierOrderTypes.first;
  String size = 'kg12_5';
  int quantity = 1;
  List<GasSupplierOption>? options;
  GasSupplierOption? chosen;
  GasSupplierQuote? quote;
  List<GasSupplierOrderView> active = const [];
  String? error;
  bool busy = false;
  Timer? _tick;

  /// What can be ordered at the chosen address (the server's word); null
  /// before an address, while asking, or when the server cannot say, in
  /// which case every type and size stays selectable.
  List<GasOffer>? offered;

  @override
  void initState() {
    super.initState();
    repo.orderingAvailable().then((v) { if (mounted) setState(() => available = v); });
    repo.activeOrders().then((v) { if (mounted) setState(() => active = v); });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted && quote != null) setState(() {}); });
    final d = delivery;
    if (d != null) _loadOffered(d);
  }

  /// Asks what is orderable at [d] and selects a type and size that is.
  Future<void> _loadOffered(DeliveryPoint d) async {
    setState(() => offered = null);
    List<GasOffer>? list;
    try {
      list = await repo.offeredAt(latitude: d.latitude, longitude: d.longitude);
    } catch (_) {
      list = null; // keep the full choice; finding suppliers still says what exists
    }
    if (!mounted || delivery != d) return; // the address changed meanwhile
    setState(() {
      offered = list;
      final sel = list == null ? null : selectionFor(list, orderType: orderType, cylinderSize: size);
      if (sel != null && (sel.orderType != orderType || sel.cylinderSize != size)) {
        orderType = sel.orderType;
        size = sel.cylinderSize;
        _inputs++; options = null; chosen = null; quote = null;
      }
    });
  }

  void _selectType(String t) {
    orderType = t;
    final o = offered;
    if (o != null) {
      final sizes = offeredSizes(o, t);
      if (sizes.isNotEmpty && !sizes.contains(size)) size = sizes.first;
    }
    _reset();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() { busy = true; error = null; });
    try {
      await f();
    } on GasSupplierFailure catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Bumped by every change to what is ordered or where: a price requested
  /// before the change is never shown (or paid) after it.
  int _inputs = 0;

  /// The option whose price is being fetched, for its loading indicator.
  GasSupplierOption? pricing;

  /// Any change to what is ordered or where invalidates the options and the price.
  void _reset() => setState(() { _inputs++; options = null; chosen = null; quote = null; error = null; });

  void _setQuantity(int q) => setState(() { _inputs++; quantity = q; quote = null; });

  Future<void> _chooseAddress() async {
    final p = await widget.pickDelivery(context);
    if (p == null || !mounted) return;
    delivery = p;
    _reset();
    _loadOffered(p);
  }

  Future<void> _quote(GasSupplierOption o) {
    final asked = _inputs;
    setState(() { pricing = o; quote = null; });
    return _run(() async {
      try {
        final d = delivery!;
        final q = await repo.quote(o, quantity: quantity, latitude: d.latitude, longitude: d.longitude, address: d.address);
        if (!mounted || asked != _inputs) return; // the order or address changed meanwhile
        setState(() { chosen = o; quote = q; });
      } finally {
        if (mounted) setState(() => pricing = null);
      }
    });
  }

  // ─────────────────────────────────────────────
  // BUILD
  //
  // The Gas look of the passenger app (gas_order_screen.dart): a compact
  // header with the cylinder photo and progress that never scrolls, then,
  // scrolling on their own, stepped white sections —
  // where to deliver (it decides what is offered), what to order, and the
  // suppliers with the server's price — and a pinned bar holding the one
  // next action and any error. Content is capped at [_maxWidth] so tablets
  // and landscape keep a readable column.
  // ─────────────────────────────────────────────

  static const double _maxWidth = 640;

  /// Large text (accessibility sizes): rows stack and grids use fewer columns.
  bool get _largeText => MediaQuery.textScalerOf(context).scale(10) >= 14;

  /// Where the passenger is: address → gas → supplier → pay.
  int get _step => delivery == null ? 0 : options == null ? 1 : quote == null ? 2 : 3;

  @override
  Widget build(BuildContext context) {
    final d = delivery;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: ctsBrandOverlay,
      child: Scaffold(
        backgroundColor: CtsTheme.canvas,
        body: Column(children: [
          const CtsStatusBarStrip(),
          // Permanent header; only the content below scrolls.
          CtsPhotoHeader(
            maxContentWidth: _maxWidth,
            image: 'assets/images/services/gas.jpeg',
            imageAspectRatio: 1,
            // The cylinder stands a little right of the photo's centre.
            imageAlignment: const Alignment(0.1, 0),
            eyebrow: 'Cooking gas · Suppliers',
            title: 'Order gas',
            subtitle: 'From an approved supplier near you, delivered.',
            trailing: CtsHeaderIconButton(
              icon: Icons.support_agent_rounded,
              label: 'Help and support',
              onTap: () => Navigator.of(context, rootNavigator: true).pushNamed(AppRoutes.helpSupport),
            ),
            footer: CtsHeaderProgress(steps: const ['Address', 'Gas', 'Supplier', 'Pay'], current: _step),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _maxWidth),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(ctsGutter, 20, ctsGutter, 24),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (available == null)
                          const _StateCard(
                            icon: Icons.local_fire_department_rounded,
                            title: 'Checking supplier ordering…',
                            body: 'This takes a moment.',
                            loading: true,
                          )
                        else if (available == false)
                          const _StateCard(
                            icon: Icons.storefront_rounded,
                            title: 'Not available yet',
                            bodyWidget: Text('Ordering from Gas suppliers is not available yet.',
                                key: Key('gs-unavailable'), style: CtsText.bodySmall),
                          )
                        else ...[
                          if (active.isNotEmpty) ...[
                            const GasGroupLabel('In progress', caption: 'Tap an order to track it'),
                            for (final o in active) ...[
                              GasSupplierActiveOrderCard(order: o, repository: repo),
                              const SizedBox(height: 10),
                            ],
                            const SizedBox(height: 8),
                          ],
                          _addressSection(d),
                          const SizedBox(height: 18),
                          _needSection(),
                          const SizedBox(height: 18),
                          _supplierSection(d),
                        ],
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          ),
          if (available == true) _actionBar(d),
        ]),
      ),
    );
  }

  // ── 1 · Address ─────────────────────────────

  Widget _addressSection(DeliveryPoint? d) {
    final has = d != null;
    return GasSection(
      step: 1,
      icon: Icons.location_on_rounded,
      title: 'Deliver to',
      caption: 'Your address decides which gas and suppliers are available',
      child: Semantics(
        button: true,
        enabled: !busy,
        label: has ? 'Delivery address, ${d.address}. Change' : 'Choose a delivery address',
        excludeSemantics: true,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: has ? CtsTheme.primaryTint : GasPalette.idleFill,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: has ? GasPalette.green : Colors.transparent, width: 1.5),
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('gs-address'),
              onTap: busy ? null : _chooseAddress,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: has ? GasPalette.green : CtsTheme.surface,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(has ? Icons.location_on_rounded : Icons.add_location_alt_rounded,
                        size: 22, color: has ? Colors.white : GasPalette.greenDeep),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(has ? 'Delivering to' : 'Where should we deliver?',
                          style: CtsText.caption.copyWith(
                              fontSize: 12.5, fontWeight: FontWeight.w700, color: GasPalette.greenDeep)),
                      const SizedBox(height: 2),
                      Text(d?.address ?? 'Choose a delivery address',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: CtsText.cardTitle.copyWith(
                            fontWeight: has ? FontWeight.w700 : FontWeight.w500,
                            color: has ? CtsTheme.textPrimary : CtsTheme.textTertiary,
                          )),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  _Pill(text: has ? 'Change' : 'Choose', filled: !has),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 2 · What you need ───────────────────────

  static IconData _typeIcon(String t) => switch (t) {
        'exchangeEmpty' => Icons.swap_horiz_rounded,
        'newCylinder' => Icons.add_circle_outline_rounded,
        'commercialBulk' => Icons.business_rounded,
        _ => Icons.propane_tank_rounded,
      };

  static String _typeDescription(String t) => switch (t) {
        'exchangeEmpty' => 'Swap your empty cylinder for a full one',
        'newCylinder' => 'Buy a new, filled cylinder',
        'commercialBulk' => 'Several cylinders for a business',
        _ => '',
      };

  // The tank icon grows with the cylinder, so sizes read at a glance.
  static double _tankSize(String s) => switch (s) {
        'kg3' => 16, 'kg6' => 19, 'kg12_5' => 23, 'kg14_5' => 25, 'kg19' => 28, _ => 31,
      };

  Widget _needSection() {
    final types = offered == null ? supplierOrderTypes : offeredTypes(offered!);
    final sizes = offered == null ? cylinderSizes : offeredSizes(offered!, orderType);
    return GasSection(
      step: 2,
      icon: Icons.propane_tank_rounded,
      title: 'What you need',
      caption: offered == null ? 'Choose the service, size and quantity' : 'What suppliers offer at this address',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const GasGroupLabel('Service'),
        // Once the address is known, only what can be ordered there is offered.
        for (final t in types) ...[
          _TileChip(
            chipKey: Key('gs-type-$t'),
            selected: orderType == t,
            onSelected: busy ? null : () => _selectType(t),
            radius: 20,
            builder: (selected, enabled) => _TypeTile(
              icon: _typeIcon(t),
              title: gasLabel(t),
              description: _typeDescription(t),
              selected: selected,
            ),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 8),
        const GasGroupLabel('Cylinder size'),
        LayoutBuilder(builder: (_, c) {
          const gap = 8.0;
          final cols = _largeText ? 2 : 3;
          final w = (c.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(spacing: gap, runSpacing: gap, children: [
            for (final sz in sizes)
              SizedBox(
                width: w,
                child: _TileChip(
                  chipKey: Key('gs-size-$sz'),
                  selected: size == sz,
                  onSelected: busy ? null : () { size = sz; _reset(); },
                  radius: 18,
                  builder: (selected, enabled) => _SizeTile(label: gasLabel(sz), iconSize: _tankSize(sz), selected: selected),
                ),
              ),
          ]);
        }),
        if (offered != null && offered!.isEmpty) ...[
          const SizedBox(height: 12),
          const _Notice(
            icon: Icons.wrong_location_rounded,
            child: Text('No supplier delivers Gas to this address right now. Try another address.',
                key: Key('gs-none-here')),
          ),
        ],
        const SizedBox(height: 18),
        _quantityRow(),
      ]),
    );
  }

  Widget _quantityRow() {
    final labels = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Quantity', style: CtsText.cardTitle.copyWith(fontWeight: FontWeight.w800, color: GasPalette.forest)),
      Text('Up to 20 cylinders', style: CtsText.caption.copyWith(color: CtsTheme.textSecondary)),
    ]);
    final stepper = Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: CtsTheme.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: CtsTheme.cardShadow,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _StepBtn(
                icon: Icons.remove,
                label: 'Fewer cylinders',
                onTap: busy || quantity <= 1 ? null : () => _setQuantity(quantity - 1),
              ),
              SizedBox(
                width: 40,
                child: Text('$quantity',
                    key: const Key('gs-qty'),
                    textAlign: TextAlign.center,
                    style: CtsText.price.copyWith(fontSize: 20, fontWeight: FontWeight.w800, color: CtsTheme.textPrimary)),
              ),
              _StepBtn(
                icon: Icons.add,
                label: 'More cylinders',
                onTap: busy || quantity >= 20 ? null : () => _setQuantity(quantity + 1),
              ),
            ]),
          );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(color: GasPalette.mint, borderRadius: BorderRadius.circular(18)),
      // Large text: the stepper goes under the labels, so neither squeezes.
      child: _largeText
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              labels,
              const SizedBox(height: 10),
              Align(alignment: Alignment.centerRight, child: stepper),
            ])
          : Row(children: [Expanded(child: labels), stepper]),
    );
  }

  // ── 3 · Supplier and price ──────────────────

  Widget _supplierSection(DeliveryPoint? d) {
    final list = options;
    return GasSection(
      step: 3,
      icon: Icons.storefront_rounded,
      title: 'Supplier and price',
      caption: list == null || list.isEmpty ? 'Approved suppliers that deliver to you' : 'Tap a supplier to get your price',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (list == null)
          _Notice(
            icon: Icons.search_rounded,
            tone: _NoticeTone.neutral,
            child: Text(d == null
                ? 'Set your address first. Suppliers near it appear here.'
                : 'Search below to see the suppliers that deliver this to you.'),
          )
        else if (list.isEmpty)
          const _Notice(
            icon: Icons.storefront_rounded,
            child: Text('No supplier delivers this to your location right now.', key: Key('gs-none')),
          ),
        for (final o in list ?? const <GasSupplierOption>[]) ...[
          _optionCard(o),
          const SizedBox(height: 10),
        ],
        if (pricing != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: Row(children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: GasPalette.greenDeep)),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Measuring the delivery route and getting a price…',
                    key: const Key('gs-pricing-note'), style: CtsText.bodySmall.copyWith(color: CtsTheme.textPrimary)),
              ),
            ]),
          ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: quote == null ? const SizedBox.shrink() : _quoteCard(quote!),
        ),
      ]),
    );
  }

  Widget _optionCard(GasSupplierOption o) {
    final chosenHere = chosen == o;
    final loading = pricing == o;
    final enabled = !busy;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: enabled || loading || chosenHere ? 1 : 0.55,
      child: GasOptionSurface(
        selected: chosenHere,
        semanticLabel: '${o.supplierName}, ${o.stationName}, ${o.brand}'
            '${o.price != null ? ', ${_ghs(o.price!)} each' : ''}',
        onTap: enabled ? () => _quote(o) : null,
        padding: const EdgeInsets.all(14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: chosenHere ? GasPalette.green : CtsTheme.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.storefront_rounded, size: 22, color: chosenHere ? Colors.white : GasPalette.greenDeep),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(o.supplierName,
                  style: CtsText.cardTitle.copyWith(fontSize: 15.5, fontWeight: FontWeight.w800, color: CtsTheme.textPrimary)),
              const SizedBox(height: 2),
              Text('${o.stationName} · ${o.brand}', style: CtsText.bodySmall),
              // Price and distance wrap under the name, so large text never
              // squeezes the supplier's name. The list's distance is
              // straight-line (for choosing); the price is on the road
              // route the server measures.
              if (o.price != null || o.distanceKm != null) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (o.price != null)
                    Text.rich(TextSpan(children: [
                      TextSpan(text: _ghs(o.price!),
                          style: CtsText.price.copyWith(fontSize: 15, fontWeight: FontWeight.w800, color: GasPalette.greenDeep)),
                      TextSpan(text: ' each', style: CtsText.caption.copyWith(color: CtsTheme.textSecondary)),
                    ])),
                  if (o.distanceKm != null)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.near_me_rounded, size: 13, color: CtsTheme.textSecondary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text('${o.distanceKm!.toStringAsFixed(1)} km away (straight line)',
                            style: CtsText.caption.copyWith(fontWeight: FontWeight.w600, color: CtsTheme.textSecondary)),
                      ),
                    ]),
                ]),
              ],
            ]),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 24,
            height: 44,
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: GasPalette.greenDeep, key: Key('gs-pricing')))
                  : chosenHere
                      ? const GasCheckBadge(selected: true)
                      : const Icon(Icons.chevron_right_rounded, color: CtsTheme.textTertiary),
            ),
          ),
        ]),
      ),
    );
  }

  /// The server's quote as a receipt: what was priced, the lines, the total,
  /// the delivery estimate and how long the price is held. Paying is in the
  /// action bar.
  Widget _quoteCard(GasSupplierQuote q) {
    final now = DateTime.now();
    final expired = q.isExpired(now);
    final left = q.expiresAt.difference(now);
    const muted = CtsTheme.onForestMuted;
    // With large text, each amount sits under its label instead of beside it.
    final stacked = _largeText;
    Widget row(String k, String v) => stacked
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(k, style: CtsText.bodySmall.copyWith(fontSize: 14, color: muted)),
              Text(v, textAlign: TextAlign.end, style: CtsText.price.copyWith(fontSize: 14.5, color: Colors.white)),
            ]),
          )
        : Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: Text(k, style: CtsText.bodySmall.copyWith(fontSize: 14, color: muted))),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.topRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(v, style: CtsText.price.copyWith(fontSize: 14.5, color: Colors.white)),
                ),
              ),
            ),
          ]),
        );
    return Container(
      key: ValueKey(q.quoteId),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: CtsTheme.forestGradient,
        borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
        boxShadow: GasPalette.selectedGlow,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Everything here is the server's quote, including what it priced.
        Text('YOUR PRICE', style: CtsText.overline.copyWith(color: GasPalette.mint, fontSize: 11, letterSpacing: 0.9)),
        const SizedBox(height: 4),
        if (q.supplierName != null)
          Text('${q.supplierName}${q.stationName != null ? ' · ${q.stationName}' : ''}',
              key: const Key('gs-quote-supplier'),
              style: CtsText.cardTitle.copyWith(fontWeight: FontWeight.w800, color: Colors.white)),
        if (q.cylinderSize != null && q.orderType != null)
          Text('${gasLabel(q.cylinderSize!)} · ${gasLabel(q.orderType!)}${q.brand != null ? ' · ${q.brand}' : ''}',
              key: const Key('gs-quote-product'), style: CtsText.bodySmall.copyWith(color: muted)),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: _HoldPill(
            text: expired
                ? 'This price has expired.'
                : 'Price held for ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
            expired: expired,
          ),
        ),
        const SizedBox(height: 14),
        row('${q.quantity} × ${_ghs(q.unitPrice)}', _ghs(q.productAmount)),
        if (q.handlingFee > 0) row('Handling', _ghs(q.handlingFee)),
        row(q.routeDistanceKm != null ? 'Delivery · ${q.routeDistanceKm!.toStringAsFixed(1)} km by road' : 'Delivery',
            _ghs(q.deliveryFee)),
        Divider(height: 22, color: Colors.white.withValues(alpha: 0.18)),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            flex: 1,
            child: Text('Total',
                style: CtsText.cardTitle.copyWith(fontSize: 15.5, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.bottomRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(_ghs(q.total), style: CtsText.priceLarge.copyWith(fontSize: 26, color: Colors.white)),
              ),
            ),
          ),
        ]),
        if (q.eta != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.schedule_rounded, size: 18, color: GasPalette.mint),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    'Estimated delivery: about ${gasDurationLabel(q.eta!.minutes)} after payment '
                    '(${gasDurationLabel(q.eta!.driveMinutes)} on the road, plus the supplier confirming and preparing your order)',
                    key: const Key('gs-eta'),
                    style: CtsText.bodySmall.copyWith(color: Colors.white, height: 1.4)),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.account_balance_wallet_rounded, size: 16, color: muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                'Paid from your CTSGo wallet. The supplier confirms after payment; if they decline, it is returned to your wallet.',
                style: CtsText.bodySmall.copyWith(fontSize: 13, color: muted)),
          ),
        ]),
      ]),
    );
  }

  // ── Action bar ──────────────────────────────

  /// What is still needed before the next action, or null.
  String? _hint(DeliveryPoint? d) {
    if (error != null) return null;
    if (d == null) return 'Set your delivery address to see suppliers.';
    if (offered != null && offered!.isEmpty) return 'Choose another address to see suppliers.';
    if (options != null && options!.isNotEmpty && quote == null && pricing == null) return 'Choose a supplier to get your price.';
    return null;
  }

  static final ButtonStyle _primaryStyle = FilledButton.styleFrom(
    backgroundColor: GasPalette.greenDeep,
    foregroundColor: Colors.white,
    disabledBackgroundColor: CtsTheme.surfaceAlt,
    disabledForegroundColor: CtsTheme.textDisabled,
    minimumSize: const Size.fromHeight(CtsTheme.buttonHeight),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CtsTheme.radiusMd)),
    textStyle: CtsText.button,
    elevation: 0,
  );

  Widget _busyLabel(String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: CtsTheme.textSecondary)),
        const SizedBox(width: 10),
        Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
      ]);

  Widget _actionBar(DeliveryPoint? d) {
    final q = quote;
    final Widget button;
    if (q != null) {
      final expired = q.isExpired(DateTime.now());
      button = FilledButton(
        key: const Key('gs-pay'),
        style: _primaryStyle,
        onPressed: busy
            ? null
            : expired
                ? () => _quote(chosen!)
                : () => _run(() async {
                      final orderId = await repo.placeAndPay(q);
                      if (!mounted) return;
                      // Paid and verified by the server (placeAndPay): the order
                      // screen gives way to the order's own screen, which starts
                      // in processing and tracks only once a driver accepts.
                      Navigator.of(context).pushReplacement(MaterialPageRoute(
                          builder: (_) => GasSupplierTrackingScreen(
                              orderId: orderId,
                              repository: repo,
                              supplier: q.supplierName == null
                                  ? null
                                  : '${q.supplierName}${q.stationName != null ? ' · ${q.stationName}' : ''}')));
                    }),
        child: busy && !expired
            ? _busyLabel('Paying…')
            : Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(expired ? Icons.refresh_rounded : Icons.account_balance_wallet_rounded, size: 19),
                const SizedBox(width: 8),
                // The receipt above says it is paid from the CTSGo wallet.
                Flexible(
                  child: Text(expired ? 'Get a new price' : 'Confirm and pay ${_ghs(q.total)}',
                      textAlign: TextAlign.center),
                ),
              ]),
      );
    } else {
      final finding = busy && pricing == null;
      button = FilledButton(
        key: const Key('gs-find'),
        style: _primaryStyle,
        onPressed: busy || d == null || (offered != null && offered!.isEmpty)
            ? null
            : () => _run(() async {
                  final list = await repo.options(orderType: orderType, cylinderSize: size, latitude: d.latitude, longitude: d.longitude);
                  setState(() { options = list; chosen = null; quote = null; });
                }),
        child: finding
            ? _busyLabel('Finding suppliers…')
            : Row(mainAxisSize: MainAxisSize.min, children: [
                if (d != null) ...[const Icon(Icons.search_rounded, size: 19), const SizedBox(width: 8)],
                Flexible(child: Text(d == null ? 'Choose an address first' : 'Find suppliers', textAlign: TextAlign.center)),
              ]),
      );
    }
    final hint = _hint(d);
    return CtsBookingBar(
      // The hint is drawn in the action's centred column (below), so it
      // lines up with the button on tablets.
      action: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth - ctsGutter * 2),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (hint != null) ...[
              Semantics(
                liveRegion: true,
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.info_outline_rounded, size: 18, color: CtsTheme.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(hint,
                        style: CtsText.bodySmall.copyWith(color: CtsTheme.textPrimary, fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
              const SizedBox(height: 10),
            ],
            if (error != null) ...[
              Semantics(
                liveRegion: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: CtsTheme.errorTint,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: CtsTheme.errorBorder),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.error_outline_rounded, size: 18, color: CtsTheme.errorDeep),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(error!,
                          key: const Key('gs-error'),
                          style: CtsText.bodySmall.copyWith(color: CtsTheme.errorDeep, fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 10),
            ],
            button,
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// PRIVATE WIDGETS
// ─────────────────────────────────────────────

/// A ChoiceChip drawn as a full tile: the chip keeps its selection
/// semantics and tap handling, the tile ([builder]) draws every state.
class _TileChip extends StatelessWidget {
  /// Given to the ChoiceChip itself.
  final Key chipKey;
  final bool selected;
  final VoidCallback? onSelected;
  final double radius;
  final Widget Function(bool selected, bool enabled) builder;

  const _TileChip({required this.chipKey, required this.selected, required this.onSelected, required this.radius, required this.builder});

  @override
  Widget build(BuildContext context) {
    final enabled = onSelected != null;
    return LayoutBuilder(
      builder: (context, c) => ChoiceChip(
        key: chipKey,
        selected: selected,
        onSelected: enabled ? (_) { HapticFeedback.selectionClick(); onSelected!(); } : null,
        showCheckmark: false,
        padding: EdgeInsets.zero,
        labelPadding: EdgeInsets.zero,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        clipBehavior: Clip.antiAlias,
        color: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: Colors.transparent,
        selectedColor: Colors.transparent,
        disabledColor: Colors.transparent,
        shadowColor: Colors.transparent,
        selectedShadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        pressElevation: 0,
        label: SizedBox(
          width: c.maxWidth,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: enabled || selected ? 1 : 0.55,
            child: builder(selected, enabled),
          ),
        ),
      ),
    );
  }
}

class _TypeTile extends StatelessWidget {
  final IconData icon;
  final String title, description;
  final bool selected;
  const _TypeTile({required this.icon, required this.title, required this.description, required this.selected});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: selected ? GasPalette.selectedGradient : null,
          color: selected ? null : GasPalette.idleFill,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: selected ? Colors.white.withValues(alpha: 0.14) : CtsTheme.surface,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, size: 23, color: selected ? GasPalette.mint : GasPalette.greenDeep),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // A chip label is one faded line by default; tiles wrap.
              Text(title,
                  softWrap: true,
                  overflow: TextOverflow.visible,
                  maxLines: 3,
                  style: CtsText.cardTitle.copyWith(
                      fontSize: 15.5, fontWeight: FontWeight.w800, color: selected ? Colors.white : CtsTheme.textPrimary)),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(description,
                    softWrap: true,
                    overflow: TextOverflow.visible,
                    maxLines: 4,
                    style: CtsText.bodySmall.copyWith(
                        fontSize: 13.5, height: 1.3, color: selected ? GasPalette.mint : CtsTheme.textSecondary)),
              ],
            ]),
          ),
          const SizedBox(width: 10),
          GasCheckBadge(selected: selected, onDark: selected),
        ]),
      );
}

class _SizeTile extends StatelessWidget {
  final String label;
  final double iconSize;
  final bool selected;
  const _SizeTile({required this.label, required this.iconSize, required this.selected});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
        decoration: BoxDecoration(
          color: selected ? CtsTheme.primaryTint : GasPalette.idleFill,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? GasPalette.green : Colors.transparent, width: 1.5),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 32,
              height: 32,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Icon(Icons.propane_tank_rounded,
                    size: iconSize, color: selected ? GasPalette.greenDeep : CtsTheme.textTertiary),
              ),
            ),
            const Spacer(),
            if (selected) const Icon(Icons.check_circle_rounded, size: 18, color: GasPalette.green),
          ]),
          const SizedBox(height: 8),
          // A size is short: scaled to fit rather than cut ("14…") at large text.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(label,
                maxLines: 1,
                softWrap: false,
                style: CtsText.cardTitle.copyWith(
                    fontSize: 15, fontWeight: FontWeight.w800, color: selected ? GasPalette.forest : CtsTheme.textPrimary)),
          ),
        ]),
      );
}

class _StepBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _StepBtn({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onTap != null,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          color: onTap != null ? GasPalette.green : CtsTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap == null ? null : () { HapticFeedback.selectionClick(); onTap!(); },
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, size: 20, color: onTap != null ? Colors.white : CtsTheme.textDisabled),
            ),
          ),
        ),
      );
}

class _Pill extends StatelessWidget {
  final String text;
  final bool filled;
  const _Pill({required this.text, required this.filled});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: filled ? GasPalette.greenDeep : CtsTheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: CtsText.label.copyWith(fontWeight: FontWeight.w800, color: filled ? Colors.white : GasPalette.greenDeep)),
      );
}

/// How long the quoted price is held, on the forest receipt.
class _HoldPill extends StatelessWidget {
  final String text;
  final bool expired;
  const _HoldPill({required this.text, required this.expired});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: expired ? CtsTheme.warningTint : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(expired ? Icons.timer_off_rounded : Icons.timer_rounded,
              size: 14, color: expired ? CtsTheme.warning : GasPalette.mint),
          const SizedBox(width: 5),
          Flexible(
            child: Text(text,
                style: CtsText.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: expired ? CtsTheme.warning : Colors.white,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ]),
      );
}

enum _NoticeTone { warning, neutral }

/// A short inline message inside a section.
class _Notice extends StatelessWidget {
  final IconData icon;
  final Widget child;
  final _NoticeTone tone;
  const _Notice({required this.icon, required this.child, this.tone = _NoticeTone.warning});

  @override
  Widget build(BuildContext context) {
    final warn = tone == _NoticeTone.warning;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: warn ? CtsTheme.warningTint : GasPalette.idleFill,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: warn ? CtsTheme.warning : GasPalette.greenDeep),
        const SizedBox(width: 10),
        Expanded(
          child: DefaultTextStyle.merge(
            style: CtsText.bodySmall.copyWith(color: warn ? const Color(0xFF7C3A06) : CtsTheme.textPrimary, height: 1.4),
            child: child,
          ),
        ),
      ]),
    );
  }
}

/// A whole-screen state (checking, unavailable) as a section card.
class _StateCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final Widget? bodyWidget;
  final bool loading;
  const _StateCard({required this.icon, required this.title, this.body, this.bodyWidget, this.loading = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
        decoration: BoxDecoration(
          color: CtsTheme.surface,
          borderRadius: BorderRadius.circular(22),
          boxShadow: GasPalette.sectionShadow,
        ),
        child: Column(children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: GasPalette.mint, borderRadius: BorderRadius.circular(18)),
            child: loading
                ? const Padding(
                    padding: EdgeInsets.all(17),
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: GasPalette.greenDeep))
                : Icon(icon, size: 26, color: GasPalette.greenDeep),
          ),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: CtsText.section.copyWith(fontSize: 17.5, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          DefaultTextStyle.merge(
            textAlign: TextAlign.center,
            style: CtsText.bodySmall,
            child: bodyWidget ?? Text(body ?? ''),
          ),
        ]),
      );
}

/// One of the passenger's supplier orders still in progress; opens its tracking
/// (where it can be cancelled while that is still allowed).
class GasSupplierActiveOrderCard extends StatelessWidget {
  final GasSupplierOrderView order;
  final GasSupplierRepository repository;
  const GasSupplierActiveOrderCard({super.key, required this.order, required this.repository});

  @override
  Widget build(BuildContext context) => Material(
        key: Key('gs-active-${order.id}'),
        color: CtsTheme.surface,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => GasSupplierTrackingScreen(orderId: order.id, repository: repository))),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: CtsTheme.mintBorder),
            ),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: GasPalette.mint, borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.local_fire_department_rounded, size: 22, color: GasPalette.greenDeep),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(supplierOrderStatusLabel(order.status),
                      style: CtsText.cardTitle.copyWith(fontWeight: FontWeight.w800, color: CtsTheme.textPrimary)),
                  const SizedBox(height: 2),
                  Text('Order ${order.id}${order.total != null ? ' · ${_ghs(order.total!)}' : ''}', style: CtsText.bodySmall),
                ]),
              ),
              const SizedBox(width: 8),
              const _Pill(text: 'Track', filled: true),
            ]),
          ),
        ),
      );
}
