// The Gas service entry (AppRoutes.gasOrder). When the server reports
// supplier ordering is on (settings/gas_supplier_fulfilment, via
// gasSupplierOrderingStatus), Gas is ordered from an approved supplier so
// the supplier portal and admin see the same order. Otherwise, including
// when the check fails, the existing Gas screen opens unchanged, unless the
// passenger still has supplier orders in progress: switching ordering off
// must not hide them, so they are listed (each can still be tracked and,
// where allowed, cancelled and refunded) with the existing Gas screen a tap away.
import 'package:flutter/material.dart';

import '../../gas/presentation/screens/gas_order_screen.dart';
import '../data/gas_supplier_repository.dart';
import '../domain/gas_supplier_models.dart';
import 'gas_supplier_order_screen.dart';

class GasEntryScreen extends StatefulWidget {
  final GasSupplierRepository? repository;

  /// The screen when supplier ordering is off; the existing Gas screen by default.
  final WidgetBuilder? legacyBuilder;
  final WidgetBuilder? supplierBuilder;
  const GasEntryScreen({super.key, this.repository, this.legacyBuilder, this.supplierBuilder});

  @override
  State<GasEntryScreen> createState() => _GasEntryScreenState();
}

class _GasEntryScreenState extends State<GasEntryScreen> {
  late final GasSupplierRepository repo = widget.repository ?? GasSupplierRepository();
  bool? supplierOrdering;
  List<GasSupplierOrderView> active = const [];

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final on = await repo.orderingAvailable();
    // Only needed while off; activeOrders() shows nothing on any failure.
    final mine = on ? const <GasSupplierOrderView>[] : await repo.activeOrders();
    if (mounted) setState(() { supplierOrdering = on; active = mine; });
  }

  Widget _legacy(BuildContext context) => widget.legacyBuilder?.call(context) ?? const GasOrderScreen();

  @override
  Widget build(BuildContext context) {
    final on = supplierOrdering;
    if (on == null) return const Scaffold(body: Center(child: CircularProgressIndicator(key: Key('gas-entry-checking'))));
    if (on) return widget.supplierBuilder?.call(context) ?? GasSupplierOrderScreen(repository: repo);
    if (active.isEmpty) return _legacy(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Gas')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Your supplier orders in progress', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final o in active) GasSupplierActiveOrderCard(order: o, repository: repo),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('gas-entry-order-gas'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: _legacy)),
          child: const Text('Order Gas'),
        ),
      ]),
    );
  }
}
