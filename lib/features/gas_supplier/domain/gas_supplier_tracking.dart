// A Gas supplier order (gas_supplier_orders, gas_supplier_fulfilment.js) as
// the shared tracking state the Gas tracking experience shows. Pure.
//
// Only genuinely equivalent states are mapped:
//   pendingApproval, confirmed     → searching: no driver yet; the supplier
//                                    decides, then delivery is arranged
//   driverAssigned, atStation      → active, only once the server wrote
//                                    driverId (otherwise still searching)
//   outForDelivery                 → active; the supplier's own rider has no
//                                    driverId and gets no driver card
//   delivered / cancelled          → completed / ended
// The original flow's refilling and returning legs have no supplier
// equivalent and are never used here.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../tracking/domain/tracking_view.dart';
import 'gas_supplier_models.dart';

/// CTSGo driver or linked rider: collected at the supplier's station.
const gasSupplierDriverSteps = ['Supplier', 'Driver', 'At station', 'On the way', 'Delivered'];

/// The supplier's own rider takes it from the station (no CTSGo driver steps).
const gasSupplierOwnRiderSteps = ['Supplier', 'Preparing', 'On the way', 'Delivered'];

TrackingView gasSupplierTrackingView(GasSupplierOrderView o, {bool hasCode = false}) {
  final ownRider = o.deliveryMode == 'supplier_rider';
  final steps = ownRider ? gasSupplierOwnRiderSteps : gasSupplierDriverSteps;
  final canCancel = passengerCanCancel(o.status);
  final emptyReady = o.orderType == 'exchangeEmpty' ? 'Have your empty cylinder ready.' : null;
  final phase = supplierOrderPhase(o);

  TrackingView waiting(int step, IconData icon, String headline, String detail) => TrackingView(
        phase: TrackingPhase.searching,
        icon: icon,
        headline: headline,
        detail: detail,
        steps: steps,
        stepIndex: step,
        canCancel: canCancel,
      );

  TrackingView active(int step, IconData icon, String headline,
          {String? youNeedTo, TrackingHeading heading = TrackingHeading.none}) =>
      TrackingView(
        phase: TrackingPhase.active,
        icon: icon,
        headline: headline,
        detail: supplierOrderGuidance(o),
        youNeedTo: youNeedTo,
        steps: steps,
        stepIndex: step,
        heading: heading,
        // A driver card only for a driver the server recorded.
        hasDriver: o.hasDriver,
        canCancel: canCancel,
      );

  // Delivery still being arranged, also for a driver status the server
  // wrote without a driver: told as the confirmed state, never as tracking.
  TrackingView arranging() {
    final asConfirmed = GasSupplierOrderView(
        id: o.id, status: 'confirmed', deliveryMode: o.deliveryMode, driverReleased: o.driverReleased);
    final headline = switch (o.deliveryMode) {
      'supplier_rider' => 'The supplier is preparing your order',
      'linked_rider' => 'The supplier is assigning a rider',
      _ => o.driverReleased ? 'Finding another driver' : 'Finding a driver',
    };
    return waiting(1, ownRider ? Icons.inventory_2_rounded : Icons.search_rounded, headline,
        supplierOrderGuidance(asConfirmed));
  }

  switch (o.status) {
    case 'awaiting_payment':
      return waiting(0, Icons.payments_rounded, 'Waiting for your payment', supplierOrderGuidance(o));
    case 'pendingApproval':
      return waiting(0, Icons.storefront_rounded, 'Payment confirmed', supplierOrderGuidance(o));
    case 'confirmed':
      return arranging();
    case 'driverAssigned':
      if (phase != GasSupplierPhase.delivering) return arranging();
      return active(2, Icons.person_pin_circle_rounded, 'A driver has accepted your order', youNeedTo: emptyReady);
    case 'atStation':
      if (phase != GasSupplierPhase.delivering) return arranging();
      return active(2, Icons.local_gas_station_rounded, "Your driver is at the supplier's station", youNeedTo: emptyReady);
    case 'outForDelivery':
      return active(ownRider ? 2 : 3, Icons.directions_rounded, 'Your gas is on its way',
          youNeedTo: hasCode
              ? 'Give the ${ownRider ? 'rider' : 'driver'} your 4-digit code when you receive it.'
              : emptyReady,
          heading: TrackingHeading.customer);
    case 'delivered':
      return TrackingView(
        phase: TrackingPhase.completed,
        icon: Icons.check_circle_rounded,
        headline: 'Your gas was delivered',
        detail: supplierPaymentNote(o).isEmpty ? supplierOrderGuidance(o) : supplierPaymentNote(o),
        steps: steps,
        stepIndex: steps.length,
        hasDriver: o.hasDriver,
      );
    case 'cancelled':
      return TrackingView(
        phase: TrackingPhase.ended,
        icon: Icons.cancel_rounded,
        headline: 'This order was cancelled',
        detail: [
          if (o.cancelReason != null) 'Reason: ${supplierCancelReasonLabel(o.cancelReason!)}',
          supplierPaymentNote(o),
        ].where((l) => l.isNotEmpty).join('\n'),
      );
  }
  return TrackingView(
    phase: TrackingPhase.unknown,
    icon: Icons.help_outline_rounded,
    headline: "We can't show this order's progress",
    detail: 'Its status ("${o.status}") is not recognised by this version of the app. '
        'Your order is not affected.',
  );
}

// ── Live driver position (gas_supplier_tracking/{orderId}) ──────────────────
// A separate document (functions/gas_supplier_tracking.js) the passenger may
// read: the assigned driver, the status, and the driver's last position. The
// order itself stays the source of the status and progress shown; this
// document only supplies the position.

/// Statuses in which the assigned driver shares their position (the rules allow it only then).
const gasSupplierTrackingStatuses = {'driverAssigned', 'atStation', 'outForDelivery'};

/// One read of gas_supplier_tracking/{orderId}.
class GasSupplierTrackingFix {
  final String? driverId, status;
  final double? latitude, longitude;
  final double heading;
  final DateTime? at;

  const GasSupplierTrackingFix({this.driverId, this.status, this.latitude, this.longitude, this.heading = 0, this.at});

  factory GasSupplierTrackingFix.fromMap(Map<String, dynamic> m) {
    final loc = m['driverCurrentLocation'];
    final heading = m['driverHeading'];
    final at = m['driverLocationUpdatedAt'] ?? m['lastLocationUpdate'];
    return GasSupplierTrackingFix(
      driverId: m['driverId'] is String && (m['driverId'] as String).isNotEmpty ? m['driverId'] as String : null,
      status: m['status'] as String?,
      latitude: loc is GeoPoint ? loc.latitude : null,
      longitude: loc is GeoPoint ? loc.longitude : null,
      heading: heading is num && heading >= 0 ? heading.toDouble() : 0,
      at: at is Timestamp ? at.toDate() : null,
    );
  }

  bool get hasPosition => latitude != null && longitude != null;
}

/// The driver position to show for [o], or null. Only a position from the
/// driver now on the order (the order's own driverId), while the order is in
/// a driver stage, with a real location: never a released driver's, an ended
/// order's, or a guessed one.
GasSupplierTrackingFix? liveDriverFix(GasSupplierOrderView o, GasSupplierTrackingFix? t) {
  if (t == null || !t.hasPosition) return null;
  if (!gasSupplierTrackingStatuses.contains(o.status) || o.driverId == null) return null;
  if (t.driverId != o.driverId) return null;
  return t;
}
