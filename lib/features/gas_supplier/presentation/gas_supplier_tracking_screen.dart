// Tracks one Gas supplier order (gas_supplier_orders/{id}, which its
// passenger may read) in the shared Gas tracking experience
// (GasTrackingBody), the same one the original gas_orders flow uses.
// gasSupplierTrackingView decides what is said from the order's server
// state; this screen adapts the rest.
//
// Supplier orders carry no driver name, phone or position a passenger may
// read, so there is no driver card or call action (an info line says a
// driver has accepted) and the map shows the delivery point only. Passengers cannot write these orders,
// so a delivered order is not sent to the driver-rating screen (which
// writes the rating onto the order); it ends on the completed state here.
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/widgets/cts_ui.dart';
import '../../gas/presentation/widgets/gas_tracking_body.dart';
import '../../tracking/domain/tracking_view.dart';
import '../../tracking/widgets/passenger_tracking_panel.dart';
import '../data/gas_supplier_repository.dart';
import '../domain/gas_supplier_models.dart';
import '../domain/gas_supplier_tracking.dart';

class GasSupplierTrackingScreen extends StatefulWidget {
  final String orderId;
  final GasSupplierRepository? repository;
  final Stream<GasSupplierOrderView?>? stream;

  /// Who the order is with, from the server's quote, when opened straight
  /// after payment ("Tema Gas · Tema Station"). Only a fallback: the order's
  /// own server snapshot (supplierSnapshot) is shown first, also when the
  /// order is reopened; orders created before it existed have only this.
  final String? supplier;

  const GasSupplierTrackingScreen({super.key, required this.orderId, this.repository, this.stream, this.supplier});

  @override
  State<GasSupplierTrackingScreen> createState() => _GasSupplierTrackingScreenState();
}

class _GasSupplierTrackingScreenState extends State<GasSupplierTrackingScreen> {
  late final GasSupplierRepository repo = widget.repository ?? GasSupplierRepository();
  late Stream<GasSupplierOrderView?> stream = _open();

  Stream<GasSupplierOrderView?> _open() => widget.stream ?? repo.watch(widget.orderId);

  void _goHome() => Navigator.of(context, rootNavigator: true)
      .pushNamedAndRemoveUntil(AppRoutes.shell, (_) => false);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: StreamBuilder<GasSupplierOrderView?>(
        stream: stream,
        builder: (context, snap) {
          if (snap.hasError) {
            return CtsErrorState(
              title: "Can't load your gas order",
              message: 'Check your connection. Your order is not affected.',
              onRetry: () => setState(() => stream = _open()),
              onBack: () => Navigator.of(context).popUntil((route) => route.isFirst),
            );
          }
          final o = snap.data;
          if (o == null) {
            if (snap.connectionState == ConnectionState.waiting || snap.connectionState == ConnectionState.none) {
              return const Center(child: CircularProgressIndicator());
            }
            return TrackingEndedScreen(
              view: const TrackingView(
                phase: TrackingPhase.ended,
                icon: Icons.search_off_rounded,
                headline: 'Order not found',
                detail: 'This order may have been removed. You can check '
                    'your past orders in History.',
              ),
              onHome: _goHome,
            );
          }
          return GasTrackingBody(data: _data(o));
        },
      ),
    );
  }

  GasTrackingData _data(GasSupplierOrderView o) {
    // The code is the server's, shown once a driver or rider is bringing the order.
    final code = showCompletionCode(o.status) ? o.completionCode : null;
    final view = gasSupplierTrackingView(o, hasCode: (code ?? '').isNotEmpty);
    final note = supplierPaymentNote(o);
    final over = const ['delivered', 'cancelled'].contains(o.status);
    final km = o.routeDistanceKm == null ? '' : ' · ${o.routeDistanceKm!.toStringAsFixed(1)} km by road';
    final product = o.cylinderSize != null && o.orderType != null
        ? '${o.quantity ?? 1} × ${gasLabel(o.cylinderSize!)}'
        : 'Gas order';
    final type = [if (o.orderType != null) gasLabel(o.orderType!), if (o.brand != null) o.brand!].join(' · ');

    return GasTrackingData(
      orderId: o.id,
      view: view,
      statusKey: o.status,
      customer: o.deliveryLatitude == null || o.deliveryLongitude == null
          ? null
          : LatLng(o.deliveryLatitude!, o.deliveryLongitude!),
      // No driver name, phone or position is readable for supplier orders,
      // so no driver card (it would name no one): an info line says a
      // driver has accepted, by the server's driverId.
      showDriverCard: false,
      canContactDriver: false,
      code: code,
      info: [
        if ((o.supplierLabel ?? widget.supplier) != null)
          (icon: Icons.storefront_rounded, label: 'Supplier', value: (o.supplierLabel ?? widget.supplier)!),
        if (view.hasDriver && o.hasDriver && !over)
          (
            icon: Icons.person_pin_circle_rounded,
            label: o.deliveryMode == 'linked_rider' ? 'Rider' : 'Driver',
            value: 'Accepted your order'
          ),
        // The server's estimate (payment time + quoted ETA); never shown once finished.
        if (o.estimatedDeliveryAt != null && !over)
          (
            icon: Icons.schedule_rounded,
            label: 'Estimated delivery',
            value: 'by ${TimeOfDay.fromDateTime(o.estimatedDeliveryAt!).format(context)}'
          ),
        // Payment and refund wording from the order's server state only.
        if (note.isNotEmpty) (icon: Icons.account_balance_wallet_rounded, label: 'Payment', value: note),
        (icon: Icons.tag_rounded, label: 'Order', value: o.id),
      ],
      deliveryAddress: o.deliveryAddress ?? '',
      summary: GasTrackingSummary(
        title: product,
        subtitle: type,
        lines: [
          if (o.productAmount != null) ('Gas', o.productAmount!),
          if ((o.handlingFee ?? 0) > 0) ('Handling', o.handlingFee!),
          if (o.deliveryFee != null) ('Delivery fee$km', o.deliveryFee!),
        ],
        total: o.total,
      ),
      cancel: GasTrackingCancel(
        title: 'Cancel this gas order?',
        message: 'Any payment for it is returned to your wallet.',
        run: () => repo.cancel(o.id),
        errorText: (e) => e is GasSupplierFailure ? e.message : "Couldn't cancel. Check your connection and try again.",
      ),
      completedAction: TrackingAction(label: 'Back to home', icon: Icons.home_rounded, onTap: _goHome),
    );
  }
}
