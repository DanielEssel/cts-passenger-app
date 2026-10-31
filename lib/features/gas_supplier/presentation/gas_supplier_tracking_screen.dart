// Tracks one Gas supplier order from the passenger's own order document.
import 'package:flutter/material.dart';

import '../data/gas_supplier_repository.dart';
import '../domain/gas_supplier_models.dart';

class GasSupplierTrackingScreen extends StatefulWidget {
  final String orderId;
  final GasSupplierRepository? repository;
  final Stream<GasSupplierOrderView?>? stream;
  const GasSupplierTrackingScreen({super.key, required this.orderId, this.repository, this.stream});

  @override
  State<GasSupplierTrackingScreen> createState() => _GasSupplierTrackingScreenState();
}

class _GasSupplierTrackingScreenState extends State<GasSupplierTrackingScreen> {
  late final GasSupplierRepository repo = widget.repository ?? GasSupplierRepository();
  late final Stream<GasSupplierOrderView?> stream = widget.stream ?? repo.watch(widget.orderId);
  String? error;
  bool busy = false;

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Cancel this order?'),
      content: const Text('Any payment for it is returned to your wallet.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep order')),
        FilledButton(key: const Key('gs-cancel-confirm'), onPressed: () => Navigator.pop(c, true), child: const Text('Cancel order'))],
    ));
    if (ok != true) return;
    setState(() { busy = true; error = null; });
    try {
      await repo.cancel(widget.orderId);
    } on GasSupplierFailure catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Your Gas order')),
      body: StreamBuilder<GasSupplierOrderView?>(
        stream: stream,
        builder: (context, snap) {
          final o = snap.data;
          if (o == null) return const Center(child: CircularProgressIndicator());
          final steps = supplierOrderStepsFor(o.deliveryMode);
          final reached = steps.indexOf(o.status);
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text(supplierOrderStatusLabelFor(o.status, o.deliveryMode), key: const Key('gs-status'), style: t.textTheme.titleLarge),
            if (o.cylinderSize != null && o.orderType != null)
              Text('${o.quantity ?? 1} × ${gasLabel(o.cylinderSize!)} · ${gasLabel(o.orderType!)}${o.brand != null ? ' · ${o.brand}' : ''}',
                  key: const Key('gs-track-product')),
            if (o.deliveryAddress != null && o.deliveryAddress!.isNotEmpty) Text('Deliver to ${o.deliveryAddress}', key: const Key('gs-track-address')),
            if (o.deliveryFee != null)
              Text('Delivery GH₵${o.deliveryFee!.toStringAsFixed(2)}${o.routeDistanceKm != null ? ' · ${o.routeDistanceKm!.toStringAsFixed(1)} km by road' : ''}'),
            // Payment and refund wording from the order's server state only (supplierPaymentNote).
            if (supplierPaymentNote(o).isNotEmpty) Text(supplierPaymentNote(o), key: const Key('gs-payment-note')),
            // The server's estimate (payment time + quoted ETA); never shown once finished.
            if (o.estimatedDeliveryAt != null && !const ['delivered', 'cancelled'].contains(o.status))
              Text('Estimated delivery by ${TimeOfDay.fromDateTime(o.estimatedDeliveryAt!).format(context)}', key: const Key('gs-track-eta')),
            Text('Order ${o.id}', key: const Key('gs-order-ref'), style: t.textTheme.bodySmall),
            const SizedBox(height: 16),
            if (o.status != 'cancelled')
              for (var i = 0; i < steps.length; i++)
                ListTile(
                  dense: true,
                  leading: Icon(i <= reached ? Icons.check_circle : Icons.radio_button_unchecked, color: i <= reached ? t.colorScheme.primary : null),
                  title: Text(supplierOrderStatusLabel(steps[i])),
                ),
            if (showCompletionCode(o.status) && o.completionCode != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    const Text('Give this code to the driver when you receive your Gas'),
                    Text(o.completionCode!, key: const Key('gs-code'), style: t.textTheme.displaySmall),
                  ]),
                ),
              ),
            if (o.status == 'cancelled' && o.cancelReason != null) Text('Reason: ${supplierCancelReasonLabel(o.cancelReason!)}'),
            if (passengerCanCancel(o.status))
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: OutlinedButton(key: const Key('gs-cancel'), onPressed: busy ? null : _cancel, child: const Text('Cancel order')),
              ),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: TextStyle(color: t.colorScheme.error))),
          ]);
        },
      ),
    );
  }
}
