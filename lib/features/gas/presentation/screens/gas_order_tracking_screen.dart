// lib/features/gas/presentation/screens/gas_order_tracking_screen.dart
//
// The passenger's live gas order screen. What it says and offers comes only
// from the order's stored status and its own fulfilment flow
// (gasTrackingView): a simple drop-off, or Pickup & Return (collect → refill
// station → return). The order stores only the customer's location, so the
// map shows the customer and the driver; no station position is invented.
// Ended, unknown and missing orders get their own screen.
//
// The experience itself is GasTrackingBody, shared with Gas supplier orders;
// this screen adapts a gas_orders document into it.

import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../tracking/data/completion_code_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../../core/constants/app_colors.dart';
import '../../repositories/gas_order_repository.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../ride/presentation/trip_complete_screen.dart';
import '../../../tracking/domain/tracking_view.dart';
import '../../../tracking/widgets/passenger_tracking_panel.dart';
import '../../models/gas_refill_request.dart';
import '../../providers/gas_order_providers.dart';
import '../widgets/gas_tracking_body.dart';
import '../../../../core/utils/cedi_format.dart';

class GasOrderTrackingScreen extends ConsumerWidget {
  final String orderId;

  const GasOrderTrackingScreen({super.key, required this.orderId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderAsync = ref.watch(gasOrderStreamProvider(orderId));

    // Navigate to rating screen when order completes
    ref.listen(gasOrderStreamProvider(orderId), (prev, next) {
      final prevStatus = prev?.value?.status;
      final order = next.value;
      if (order != null &&
          order.status == GasOrderStatus.delivered &&
          prevStatus != GasOrderStatus.delivered) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => TripCompleteScreen(
              tripId: order.id,
              collection: 'gas_orders',
              serviceType: 'gas',
              driverId: order.driverId ?? '',
              driverName: order.driverName ?? 'Your driver',
              destination: order.deliveryAddress,
              fare: formatCedis(order.totalPrice),
              rideType: 'Gas Delivery',
              driverRating: 5.0,
            ),
          ),
        );
      }
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      body: orderAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => CtsErrorState(
          title: "Can't load your gas order",
          message: 'Check your connection. Your order is not affected.',
          onRetry: () => ref.invalidate(gasOrderStreamProvider(orderId)),
          onBack: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
        ),
        data: (order) {
          if (order == null) {
            return TrackingEndedScreen(
              view: const TrackingView(
                phase: TrackingPhase.ended,
                icon: Icons.search_off_rounded,
                headline: 'Order not found',
                detail: 'This order may have been removed. You can check '
                    'your past orders in History.',
              ),
              onHome: () => Navigator.of(context, rootNavigator: true)
                  .pushNamedAndRemoveUntil(AppRoutes.shell, (_) => false),
            );
          }
          return _GasOrderTracking(order: order, orderId: orderId);
        },
      ),
    );
  }
}

class _GasOrderTracking extends ConsumerWidget {
  final GasRefillRequest order;
  final String orderId;

  const _GasOrderTracking({
    required this.order,
    required this.orderId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The receiver's completion code: the order's own (older orders) or the
    // server-held one (completion_code_provider.dart).
    final code =
        completionCodeFor(ref, 'gas_orders', order.id, order.deliveryOtp);
    final view = gasTrackingView(
      order.rawStatus ?? order.status.firestoreValue,
      refillType: order.refillType.firestoreValue,
      hasOtp: (code ?? '').isNotEmpty,
    );
    final station = order.preferredStationAddress?.trim() ?? '';
    final onRefillLeg =
        const {'pickedUp', 'atStation', 'refilling'}.contains(order.rawStatus);
    final gasCost = (order.totalPrice - order.deliveryFee)
        .clamp(0, double.infinity)
        .toDouble();

    return GasTrackingBody(
      data: GasTrackingData(
        orderId: orderId,
        view: view,
        statusKey: order.rawStatus,
        customer: LatLng(
          order.deliveryLocation.latitude,
          order.deliveryLocation.longitude,
        ),
        driver: order.driverLocation == null
            ? null
            : LatLng(order.driverLocation!.latitude,
                order.driverLocation!.longitude),
        driverHeading: order.driverHeading ?? 0,
        driverLocationAt: order.driverLocationAt,
        showDriverCard: view.hasDriver && order.driverId != null,
        driverName: order.driverName,
        driverRating: order.driverRating,
        driverVehicle: order.driverVehicle,
        driverPhone: order.driverPhone,
        code: code,
        info: [
          if (onRefillLeg && station.isNotEmpty)
            (
              icon: Icons.local_gas_station_rounded,
              label: 'Refill station',
              value: station
            ),
        ],
        deliveryAddress: order.deliveryAddress,
        summary: GasTrackingSummary(
          title: '${order.cylinderSize.displayName} × ${order.quantity}',
          subtitle: order.refillType.displayName,
          lines: [('Gas cost', gasCost), ('Delivery fee', order.deliveryFee)],
          total: order.totalPrice,
        ),
        // Cancel is offered only while no driver has accepted
        // (pendingApproval). The repository re-checks that in a
        // transaction; the backend refunds any wallet hold when the order
        // becomes cancelled.
        cancel: GasTrackingCancel(
          title: 'Cancel this gas order?',
          message: 'No driver has accepted it yet. Any amount held from your '
              'wallet for this order is returned.',
          run: () => ref.read(gasOrderRepositoryProvider).cancelPendingOrder(
                orderId,
                reason: 'Cancelled by customer before a driver accepted',
              ),
          errorText: (e) => e is GasOrderException && e.code == 'not-pending'
              ? 'A driver has already accepted this order, so it can no longer be cancelled here.'
              : "Couldn't cancel. Check your connection and try again.",
        ),
      ),
    );
  }
}
