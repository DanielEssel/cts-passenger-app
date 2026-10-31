// Order Gas from an approved supplier: order type and cylinder → delivery
// address → supplier options → server price (product, handling, delivery)
// → confirm and pay from wallet → tracking. Reached from the Gas entry
// (gas_entry_screen.dart) only when the server reports supplier ordering
// is available.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../gas/presentation/widgets/address_picker_sheet.dart';
import '../data/gas_supplier_repository.dart';
import '../domain/gas_supplier_models.dart';
import 'gas_supplier_tracking_screen.dart';

String _ghs(double v) => 'GH₵${v.toStringAsFixed(2)}';

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

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = delivery;
    return Scaffold(
      appBar: AppBar(title: const Text('Order Gas')),
      body: available == null
          ? const Center(child: CircularProgressIndicator())
          : available == false
              ? const Padding(padding: EdgeInsets.all(24), child: Text('Ordering from Gas suppliers is not available yet.', key: Key('gs-unavailable')))
              : ListView(padding: const EdgeInsets.all(16), children: [
                  for (final o in active) GasSupplierActiveOrderCard(order: o, repository: repo),
                  if (active.isNotEmpty) const SizedBox(height: 16),
                  Text('1 · What you need', style: t.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  // Once the address is known, only what can be ordered there is offered.
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final o in offered == null ? supplierOrderTypes : offeredTypes(offered!))
                      ChoiceChip(key: Key('gs-type-$o'), label: Text(gasLabel(o)), selected: orderType == o, onSelected: busy ? null : (_) => _selectType(o)),
                  ]),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final s in offered == null ? cylinderSizes : offeredSizes(offered!, orderType))
                      ChoiceChip(key: Key('gs-size-$s'), label: Text(gasLabel(s)), selected: size == s, onSelected: busy ? null : (_) { size = s; _reset(); }),
                  ]),
                  if (offered != null && offered!.isEmpty)
                    const Padding(padding: EdgeInsets.only(top: 8),
                        child: Text('No supplier delivers Gas to this address right now. Try another address.', key: Key('gs-none-here'))),
                  const SizedBox(height: 12),
                  Row(children: [
                    const Text('Quantity'),
                    IconButton(onPressed: busy || quantity <= 1 ? null : () => _setQuantity(quantity - 1), icon: const Icon(Icons.remove)),
                    Text('$quantity', key: const Key('gs-qty')),
                    IconButton(onPressed: busy || quantity >= 20 ? null : () => _setQuantity(quantity + 1), icon: const Icon(Icons.add)),
                  ]),
                  const SizedBox(height: 16),
                  Text('2 · Deliver to', style: t.textTheme.titleMedium),
                  Card(
                    child: ListTile(
                      key: const Key('gs-address'),
                      leading: const Icon(Icons.location_on_outlined),
                      title: Text(d?.address ?? 'Choose a delivery address'),
                      trailing: Text(d == null ? 'Choose' : 'Change'),
                      onTap: busy ? null : _chooseAddress,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('3 · Supplier and price', style: t.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const Key('gs-find'),
                    onPressed: busy || d == null || (offered != null && offered!.isEmpty) ? null : () => _run(() async {
                      final list = await repo.options(orderType: orderType, cylinderSize: size, latitude: d.latitude, longitude: d.longitude);
                      setState(() { options = list; chosen = null; quote = null; });
                    }),
                    child: Text(d == null ? 'Choose an address first' : 'Find suppliers'),
                  ),
                  if (options != null && options!.isEmpty) const Padding(padding: EdgeInsets.only(top: 16), child: Text('No supplier delivers this to your location right now.', key: Key('gs-none'))),
                  for (final o in options ?? const <GasSupplierOption>[])
                    Card(
                      child: ListTile(
                        title: Text(o.supplierName),
                        // The list's distance is straight-line (for choosing); the
                        // price is on the road route the server measures.
                        subtitle: Text('${o.stationName} · ${o.brand}${o.distanceKm != null ? ' · ${o.distanceKm!.toStringAsFixed(1)} km away (straight line)' : ''}'),
                        trailing: pricing == o
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, key: Key('gs-pricing')))
                            : chosen == o ? const Icon(Icons.check_circle) : (o.price != null ? Text('${_ghs(o.price!)} each') : null),
                        onTap: busy ? null : () => _quote(o),
                      ),
                    ),
                  if (pricing != null)
                    const Padding(padding: EdgeInsets.only(top: 12), child: Text('Measuring the delivery route and getting a price…', key: Key('gs-pricing-note'))),
                  if (quote != null) _quoteCard(t, quote!),
                  if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, key: const Key('gs-error'), style: TextStyle(color: t.colorScheme.error))),
                ]),
    );
  }

  Widget _quoteCard(ThemeData t, GasSupplierQuote q) {
    final now = DateTime.now();
    final expired = q.isExpired(now);
    final left = q.expiresAt.difference(now);
    Widget row(String k, String v, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [Expanded(child: Text(k)), Text(v, style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null)]),
        );
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Everything here is the server's quote, including what it priced.
          if (q.supplierName != null)
            Text('${q.supplierName}${q.stationName != null ? ' · ${q.stationName}' : ''}', key: const Key('gs-quote-supplier'), style: t.textTheme.titleSmall),
          if (q.cylinderSize != null && q.orderType != null)
            Text('${gasLabel(q.cylinderSize!)} · ${gasLabel(q.orderType!)}${q.brand != null ? ' · ${q.brand}' : ''}', key: const Key('gs-quote-product')),
          const SizedBox(height: 8),
          row('${q.quantity} × ${_ghs(q.unitPrice)}', _ghs(q.productAmount)),
          if (q.handlingFee > 0) row('Handling', _ghs(q.handlingFee)),
          row(q.routeDistanceKm != null ? 'Delivery · ${q.routeDistanceKm!.toStringAsFixed(1)} km by road' : 'Delivery', _ghs(q.deliveryFee)),
          const Divider(),
          row('Total', _ghs(q.total), bold: true),
          const SizedBox(height: 8),
          if (q.eta != null)
            Text('Estimated delivery: about ${gasDurationLabel(q.eta!.minutes)} after payment '
                '(${gasDurationLabel(q.eta!.driveMinutes)} on the road, plus the supplier confirming and preparing your order)',
                key: const Key('gs-eta'), style: t.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Text(expired ? 'This price has expired.' : 'Price held for ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}', style: t.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text('Paid from your CTSGo wallet. The supplier confirms after payment; if they decline, it is returned to your wallet.', style: t.textTheme.bodySmall),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('gs-pay'),
            onPressed: busy
                ? null
                : expired
                    ? () => _quote(chosen!)
                    : () => _run(() async {
                          final orderId = await repo.placeAndPay(q);
                          if (!mounted) return;
                          Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => GasSupplierTrackingScreen(orderId: orderId, repository: repo)));
                        }),
            child: Text(expired ? 'Get a new price' : 'Confirm and pay ${_ghs(q.total)} from wallet'),
          ),
        ]),
      ),
    );
  }
}

/// One of the passenger's supplier orders still in progress; opens its tracking
/// (where it can be cancelled while that is still allowed).
class GasSupplierActiveOrderCard extends StatelessWidget {
  final GasSupplierOrderView order;
  final GasSupplierRepository repository;
  const GasSupplierActiveOrderCard({super.key, required this.order, required this.repository});

  @override
  Widget build(BuildContext context) => Card(
        key: Key('gs-active-${order.id}'),
        child: ListTile(
          leading: const Icon(Icons.local_fire_department_outlined),
          title: Text(supplierOrderStatusLabel(order.status)),
          subtitle: Text('Order ${order.id}${order.total != null ? ' · ${_ghs(order.total!)}' : ''}'),
          trailing: const Text('Track'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GasSupplierTrackingScreen(orderId: order.id, repository: repository))),
        ),
      );
}
