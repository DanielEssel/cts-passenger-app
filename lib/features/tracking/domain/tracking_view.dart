// lib/features/tracking/domain/tracking_view.dart
//
// What the passenger sees on a Ride, Delivery or Gas tracking screen,
// decided only from the order's stored status (the authoritative state):
//
//   • one plain headline ("Your driver is on the way") and a short detail
//   • whether the passenger needs to do anything right now
//   • named progress steps for that service's real workflow
//   • which actions are allowed (cancel only where it already was)
//
// Statuses this app does not recognise are shown as unknown, never as
// "finding a driver". Pure, so it can be tested without Firebase.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Broad state of the order, used to pick the screen layout.
enum TrackingPhase {
  /// Waiting for a driver to accept.
  searching,

  /// A driver is assigned and the job is under way.
  active,

  /// Finished successfully.
  completed,

  /// Cancelled, failed or closed without a driver. Nothing more happens.
  ended,

  /// Held by CTSGo support (rides only).
  review,

  /// A status this app version does not recognise.
  unknown,
}

/// Where the driver is heading, for the map route and camera.
enum TrackingHeading { none, pickup, dropoff, customer }

class TrackingView {
  final TrackingPhase phase;
  final IconData icon;
  final String headline;
  final String detail;

  /// What the passenger should do now, or null when nothing is needed.
  final String? youNeedTo;

  final List<String> steps;

  /// Index of the current step; equals steps.length when all are done and
  /// -1 when progress does not apply (ended / unknown).
  final int stepIndex;

  final TrackingHeading heading;

  /// A driver has been assigned (show driver details and contact).
  final bool hasDriver;

  /// The passenger may cancel from this screen (unchanged rules).
  final bool canCancel;

  const TrackingView({
    required this.phase,
    required this.icon,
    required this.headline,
    required this.detail,
    this.youNeedTo,
    this.steps = const [],
    this.stepIndex = -1,
    this.heading = TrackingHeading.none,
    this.hasDriver = false,
    this.canCancel = false,
  });

  bool get isOver =>
      phase == TrackingPhase.completed || phase == TrackingPhase.ended;

  /// Live driver location is only meaningful while a driver is on the job.
  bool get tracksDriver => phase == TrackingPhase.active && hasDriver;
}

const _nothingNeeded = null;

TrackingView _unknown(String? raw, String noun) => TrackingView(
      phase: TrackingPhase.unknown,
      icon: Icons.help_outline_rounded,
      headline: "We can't show this $noun's progress",
      detail: 'Its status ("${raw ?? 'none'}") is not recognised by this '
          'version of the app. Please update the app or contact support. '
          'Nothing has been changed.',
    );

// ── Ride ────────────────────────────────────────────────────────────────────

const rideSteps = [
  'Finding driver',
  'Driver coming',
  'Pickup',
  'On your way',
  'Arrived',
];

/// Statuses from which the passenger may cancel a ride (unchanged: the
/// tracking screen offered cancel for every in-progress ride).
const passengerCancellableRideStatuses = {
  'searching',
  'tripAccepted',
  'driverArrived',
  'tripStarted',
  'inProgress',
};

TrackingView rideTrackingView(String? status) {
  TrackingView active(int step, IconData icon, String headline, String detail,
          {String? youNeedTo,
          TrackingHeading heading = TrackingHeading.none}) =>
      TrackingView(
        phase: TrackingPhase.active,
        icon: icon,
        headline: headline,
        detail: detail,
        youNeedTo: youNeedTo,
        steps: rideSteps,
        stepIndex: step,
        heading: heading,
        hasDriver: true,
        canCancel: true,
      );
  const refund = 'Any amount held from your wallet for this ride is '
      'returned automatically.';

  return switch (status) {
    'searching' => const TrackingView(
        phase: TrackingPhase.searching,
        icon: Icons.search_rounded,
        headline: 'Finding your driver',
        detail: "We're asking nearby drivers. This usually takes a minute "
            'or two.',
        steps: rideSteps,
        stepIndex: 0,
        canCancel: true,
      ),
    'tripAccepted' => active(
        1,
        Icons.directions_car_rounded,
        'Your driver is on the way',
        'Your driver is heading to your pickup point.',
        youNeedTo: 'Be ready at your pickup point.',
        heading: TrackingHeading.pickup,
      ),
    'driverArrived' => active(
        2,
        Icons.place_rounded,
        'Your driver has arrived',
        'Your driver is waiting at your pickup point.',
        youNeedTo: "Go to your driver. Check the driver's name and vehicle "
            'before you get in.',
        heading: TrackingHeading.pickup,
      ),
    'tripStarted' || 'inProgress' => active(
        3,
        Icons.route_rounded,
        'Your ride is in progress',
        "You're on your way to your destination.",
        youNeedTo: _nothingNeeded,
        heading: TrackingHeading.dropoff,
      ),
    'completed' => const TrackingView(
        phase: TrackingPhase.completed,
        icon: Icons.flag_rounded,
        headline: "You've arrived",
        detail: 'Your driver has marked this ride as complete.',
        steps: rideSteps,
        stepIndex: 5,
        hasDriver: true,
      ),
    'cancelledByPassenger' => const TrackingView(
        phase: TrackingPhase.ended,
        icon: Icons.cancel_rounded,
        headline: 'You cancelled this ride',
        detail: refund,
      ),
    'cancelledByDriver' => const TrackingView(
        phase: TrackingPhase.ended,
        icon: Icons.cancel_rounded,
        headline: 'Your driver cancelled',
        detail: '$refund You can book another ride.',
      ),
    'noDriversAvailable' || 'expired' => const TrackingView(
        phase: TrackingPhase.ended,
        icon: Icons.event_busy_rounded,
        headline: 'No driver was found',
        detail: '$refund Please try booking again.',
      ),
    'cancelled' => const TrackingView(
        phase: TrackingPhase.ended,
        icon: Icons.cancel_rounded,
        headline: 'This ride was cancelled',
        detail: refund,
      ),
    'flagged' => const TrackingView(
        phase: TrackingPhase.review,
        icon: Icons.policy_rounded,
        headline: 'Your ride is being reviewed',
        detail: 'CTSGo support is reviewing this trip. You don\'t need to do '
            'anything right now; we will contact you if needed.',
        hasDriver: true,
      ),
    _ => _unknown(status, 'ride'),
  };
}

/// Why the passenger may not cancel the ride, or null when they may.
/// Re-checked in a transaction so a ride that has just completed or been
/// cancelled is never overwritten.
String? passengerRideCancelRefusal({
  required bool exists,
  required String? currentStatus,
  required String? tripPassengerId,
  required String passengerUid,
}) {
  if (!exists) return 'This ride no longer exists.';
  if (passengerUid.isEmpty || tripPassengerId != passengerUid) {
    return 'This ride is not linked to your account.';
  }
  if (currentStatus == 'cancelledByPassenger') return null; // already done
  if (!passengerCancellableRideStatuses.contains(currentStatus)) {
    return switch (currentStatus) {
      'completed' => 'This ride has already been completed.',
      'cancelledByDriver' => 'Your driver has already cancelled this ride.',
      _ => 'This ride can no longer be cancelled.',
    };
  }
  return null;
}

class TrackingActionException implements Exception {
  final String message;
  const TrackingActionException(this.message);
  @override
  String toString() => message;
}

/// Cancels the ride as the passenger, writing the same fields as before,
/// only if it is still cancellable. Throws [TrackingActionException] with a
/// message for the passenger otherwise. Cancelling twice is a no-op.
Future<void> cancelRideAsPassenger(
  FirebaseFirestore db, {
  required String tripId,
  required String passengerUid,
}) async {
  final ref = db.collection('trips').doc(tripId);
  await db.runTransaction((tx) async {
    final snap = await tx.get(ref);
    final data = snap.data();
    final current = data?['status'] as String?;
    final refusal = passengerRideCancelRefusal(
      exists: snap.exists,
      currentStatus: current,
      tripPassengerId: data?['passengerId'] as String?,
      passengerUid: passengerUid,
    );
    if (refusal != null) throw TrackingActionException(refusal);
    if (current == 'cancelledByPassenger') return;
    tx.update(ref, {
      'status': 'cancelledByPassenger',
      'cancelledAt': FieldValue.serverTimestamp(),
    });
  });
}

// ── Delivery ────────────────────────────────────────────────────────────────

const deliverySteps = [
  'Finding driver',
  'Collecting',
  'On the way',
  'Delivered',
];

TrackingView deliveryTrackingView(String? status, {bool hasOtp = false}) {
  TrackingView active(int step, IconData icon, String headline, String detail,
          {String? youNeedTo,
          TrackingHeading heading = TrackingHeading.none}) =>
      TrackingView(
        phase: TrackingPhase.active,
        icon: icon,
        headline: headline,
        detail: detail,
        youNeedTo: youNeedTo,
        steps: deliverySteps,
        stepIndex: step,
        heading: heading,
        hasDriver: true,
      );
  final shareCode = hasOtp
      ? 'Make sure the receiver has the delivery code. The driver needs it '
          'to finish the delivery.'
      : null;
  const refund = 'Any amount held from your wallet for this delivery is '
      'returned automatically.';

  return switch (status) {
    'pending' => const TrackingView(
        phase: TrackingPhase.searching,
        icon: Icons.search_rounded,
        headline: 'Finding a delivery driver',
        detail: "We're asking nearby drivers. You'll see their details here "
            'once one accepts.',
        steps: deliverySteps,
        stepIndex: 0,
      ),
    'driverAssigned' => active(
        1,
        Icons.person_pin_circle_rounded,
        'A driver has accepted your delivery',
        'They will head to the pickup point shortly.',
        youNeedTo: 'Have the parcel ready at the pickup point.',
        heading: TrackingHeading.pickup,
      ),
    'pickupEnroute' => active(
        1,
        Icons.directions_rounded,
        'Your driver is coming to collect the parcel',
        'They are on the way to the pickup point.',
        youNeedTo: 'Have the parcel ready at the pickup point.',
        heading: TrackingHeading.pickup,
      ),
    'arrivedAtPickup' => active(
        1,
        Icons.place_rounded,
        'Your driver is at the pickup point',
        'They are ready to collect the parcel.',
        youNeedTo: 'Hand the parcel to the driver.',
        heading: TrackingHeading.pickup,
      ),
    'packagePicked' => active(
        2,
        Icons.inventory_2_rounded,
        'Your parcel has been collected',
        'The driver will set off for the drop-off shortly.',
        youNeedTo: shareCode,
        heading: TrackingHeading.dropoff,
      ),
    'deliveryEnroute' => active(
        2,
        Icons.local_shipping_rounded,
        'Your parcel is on its way',
        'The driver is heading to the drop-off.',
        youNeedTo: shareCode,
        heading: TrackingHeading.dropoff,
      ),
    'arrivedAtDropoff' => active(
        2,
        Icons.place_rounded,
        'Your driver is at the drop-off',
        'They are handing the parcel to the receiver.',
        youNeedTo: hasOtp
            ? 'The receiver must give the driver the 4-digit delivery code.'
            : null,
        heading: TrackingHeading.dropoff,
      ),
    'completed' => const TrackingView(
        phase: TrackingPhase.completed,
        icon: Icons.check_circle_rounded,
        headline: 'Your parcel was delivered',
        detail: 'The driver has completed this delivery.',
        steps: deliverySteps,
        stepIndex: 4,
        hasDriver: true,
      ),
    'cancelled' ||
    'cancelledByDriver' ||
    'cancelledByPassenger' =>
      const TrackingView(
        phase: TrackingPhase.ended,
        icon: Icons.cancel_rounded,
        headline: 'This delivery was cancelled',
        detail: refund,
      ),
    _ => _unknown(status, 'delivery'),
  };
}

// ── Gas ─────────────────────────────────────────────────────────────────────

const gasDropOffSteps = ['Finding driver', 'Driver coming', 'Delivered'];
const gasRoundTripSteps = [
  'Finding driver',
  'Collecting',
  'Refilling',
  'Returning',
  'Delivered',
];

/// [refillType] is the stored value: `pickupAndReturn` is the round trip
/// (collect → refill station → return); every other type is a drop-off.
TrackingView gasTrackingView(
  String? status, {
  required String refillType,
  bool hasOtp = false,
}) {
  final roundTrip = refillType == 'pickupAndReturn';
  final steps = roundTrip ? gasRoundTripSteps : gasDropOffSteps;
  TrackingView active(int step, IconData icon, String headline, String detail,
          {String? youNeedTo,
          TrackingHeading heading = TrackingHeading.none}) =>
      TrackingView(
        phase: TrackingPhase.active,
        icon: icon,
        headline: headline,
        detail: detail,
        youNeedTo: youNeedTo,
        steps: steps,
        stepIndex: step,
        heading: heading,
        hasDriver: true,
      );
  final codeOnHandover =
      hasOtp ? 'Give the driver your 4-digit code when you receive it.' : null;
  final emptyReady = roundTrip || refillType == 'exchangeEmpty'
      ? 'Have your empty cylinder ready.'
      : null;
  const refund = 'Any amount held from your wallet for this order is '
      'returned automatically.';

  return switch (status) {
    'pendingApproval' => TrackingView(
        phase: TrackingPhase.searching,
        icon: Icons.search_rounded,
        headline: 'Finding a driver for your gas',
        detail: "We're asking nearby drivers. You can cancel until one "
            'accepts.',
        steps: steps,
        stepIndex: 0,
        canCancel: true,
      ),
    'driverAssigned' => active(
        1,
        Icons.person_pin_circle_rounded,
        'A driver has accepted your order',
        roundTrip
            ? 'They will come to collect your cylinder shortly.'
            : 'They will bring your gas to you shortly.',
        youNeedTo: emptyReady,
        heading: TrackingHeading.customer,
      ),
    'driverEnRoute' => active(
        1,
        Icons.directions_rounded,
        'Your driver is on the way',
        roundTrip
            ? 'They are coming to collect your cylinder.'
            : 'They are bringing your gas to you.',
        youNeedTo: emptyReady,
        heading: TrackingHeading.customer,
      ),
    'driverArrived' when roundTrip => active(
        1,
        Icons.place_rounded,
        'Your driver has arrived',
        'They are here to collect your cylinder for refilling.',
        youNeedTo: 'Hand over your empty cylinder.',
        heading: TrackingHeading.customer,
      ),
    'driverArrived' => active(
        1,
        Icons.place_rounded,
        'Your driver has arrived',
        'They are here with your gas.',
        youNeedTo: codeOnHandover ?? 'Meet your driver to receive your gas.',
        heading: TrackingHeading.customer,
      ),
    // The refill leg: no station location is stored, so no route is shown.
    'pickedUp' when roundTrip => active(
        2,
        Icons.propane_tank_rounded,
        'Your cylinder has been collected',
        'The driver is taking it to a refill station.',
      ),
    'atStation' when roundTrip => active(
        2,
        Icons.local_gas_station_rounded,
        'Your cylinder is at the refill station',
        'It will be refilled shortly.',
      ),
    'refilling' when roundTrip => active(
        2,
        Icons.local_fire_department_rounded,
        'Your cylinder is being refilled',
        'The driver will bring it back to you when it is full.',
      ),
    'returning' when roundTrip => active(
        3,
        Icons.u_turn_left_rounded,
        'Your gas is on its way back',
        'The driver is returning your refilled cylinder.',
        youNeedTo: hasOtp ? 'Have your 4-digit code ready.' : null,
        heading: TrackingHeading.customer,
      ),
    'delivered' => TrackingView(
        phase: TrackingPhase.completed,
        icon: Icons.check_circle_rounded,
        headline: 'Your gas was delivered',
        detail: 'The driver has completed this order.',
        steps: steps,
        stepIndex: steps.length,
        hasDriver: true,
      ),
    'cancelled' => const TrackingView(
        phase: TrackingPhase.ended,
        icon: Icons.cancel_rounded,
        headline: 'This order was cancelled',
        detail: refund,
      ),
    'failed' => const TrackingView(
        phase: TrackingPhase.ended,
        icon: Icons.error_outline_rounded,
        headline: "This order couldn't be completed",
        detail: refund,
      ),
    _ => _unknown(status, 'order'),
  };
}

// ── Driver location freshness ───────────────────────────────────────────────

/// How current the driver's position on the map is.
enum LocationFreshness {
  /// No usable position yet.
  unavailable,

  /// Updated within [liveWindow].
  live,

  /// Older than [liveWindow] (or with no update time recorded).
  stale,
}

const liveWindow = Duration(seconds: 90);

LocationFreshness locationFreshness({
  required bool hasLocation,
  required DateTime? updatedAt,
  required DateTime now,
}) {
  if (!hasLocation) return LocationFreshness.unavailable;
  if (updatedAt == null) return LocationFreshness.stale;
  return now.difference(updatedAt) <= liveWindow
      ? LocationFreshness.live
      : LocationFreshness.stale;
}

/// "Updated 4 min ago" style wording for a stale position.
String lastUpdatedLabel(DateTime? updatedAt, DateTime now) {
  if (updatedAt == null) return 'Last known location';
  final age = now.difference(updatedAt);
  if (age.inMinutes < 1) return 'Updated just now';
  if (age.inMinutes < 60) return 'Updated ${age.inMinutes} min ago';
  final hours = age.inHours;
  return 'Updated $hours hour${hours == 1 ? '' : 's'} ago';
}

/// The time the Driver App last wrote the driver's position on a job
/// document (`lastLocationUpdate`, or the older `driverLocationUpdatedAt`).
DateTime? readDriverLocationTime(Map<String, dynamic> data) {
  for (final key in ['lastLocationUpdate', 'driverLocationUpdatedAt']) {
    final v = data[key];
    if (v is Timestamp) return v.toDate();
  }
  return null;
}
