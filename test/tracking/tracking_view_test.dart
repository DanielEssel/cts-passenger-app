// The passenger's view of a Ride, Delivery or Gas order comes only from the
// stored status, with honest handling of ended and unknown statuses.

import 'package:cts_transport_app/features/tracking/domain/tracking_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ride', () {
    test('every live status has a plain headline and the right step', () {
      final expected = {
        'searching': 0,
        'tripAccepted': 1,
        'driverArrived': 2,
        'tripStarted': 3,
      };
      expected.forEach((status, step) {
        final v = rideTrackingView(status);
        expect(v.stepIndex, step, reason: status);
        expect(v.headline, isNotEmpty);
        expect(v.steps, rideSteps);
      });
      expect(rideTrackingView('tripAccepted').headline,
          'Your driver is on the way');
      expect(rideTrackingView('driverArrived').youNeedTo, isNotNull);
      expect(rideTrackingView('tripStarted').youNeedTo, isNull);
    });

    test('completed marks every step done', () {
      final v = rideTrackingView('completed');
      expect(v.phase, TrackingPhase.completed);
      expect(v.stepIndex, rideSteps.length);
      expect(v.canCancel, isFalse);
    });

    test('ended statuses offer no tracking or cancel', () {
      for (final s in [
        'cancelledByPassenger',
        'cancelledByDriver',
        'noDriversAvailable',
        'expired',
        'cancelled',
      ]) {
        final v = rideTrackingView(s);
        expect(v.phase, TrackingPhase.ended, reason: s);
        expect(v.canCancel, isFalse, reason: s);
        expect(v.tracksDriver, isFalse, reason: s);
        expect(v.detail, contains('returned automatically'), reason: s);
      }
    });

    test('unknown or missing status is never shown as finding a driver', () {
      for (final s in ['somethingNew', null, '']) {
        final v = rideTrackingView(s);
        expect(v.phase, TrackingPhase.unknown);
        expect(v.headline, isNot(contains('Finding')));
        expect(v.canCancel, isFalse);
      }
    });

    test('a flagged ride is under review with nothing to do', () {
      final v = rideTrackingView('flagged');
      expect(v.phase, TrackingPhase.review);
      expect(v.canCancel, isFalse);
    });

    test('cancel is offered exactly where it was before', () {
      for (final s in passengerCancellableRideStatuses) {
        expect(rideTrackingView(s).canCancel, isTrue, reason: s);
      }
    });

    test('map heads to pickup, then to the drop-off', () {
      expect(rideTrackingView('tripAccepted').heading, TrackingHeading.pickup);
      expect(rideTrackingView('driverArrived').heading, TrackingHeading.pickup);
      expect(rideTrackingView('tripStarted').heading, TrackingHeading.dropoff);
      expect(rideTrackingView('searching').tracksDriver, isFalse);
    });
  });

  group('passenger ride cancellation', () {
    String? refusal(String? status,
            {bool exists = true, String? owner = 'p1', String uid = 'p1'}) =>
        passengerRideCancelRefusal(
          exists: exists,
          currentStatus: status,
          tripPassengerId: owner,
          passengerUid: uid,
        );

    test('allowed while the ride is in progress', () {
      for (final s in passengerCancellableRideStatuses) {
        expect(refusal(s), isNull, reason: s);
      }
    });

    test('never overwrites a completed or already-ended ride', () {
      for (final s in [
        'completed',
        'cancelledByDriver',
        'noDriversAvailable',
        'expired',
        'flagged',
        'unknownStatus',
      ]) {
        expect(refusal(s), isNotNull, reason: s);
      }
      expect(refusal('completed'), contains('completed'));
    });

    test('a repeated cancel is accepted without a second write', () {
      expect(refusal('cancelledByPassenger'), isNull);
    });

    test('only the passenger who owns the ride', () {
      expect(refusal('tripAccepted', owner: 'other'), isNotNull);
      expect(refusal('tripAccepted', uid: ''), isNotNull);
      expect(refusal('tripAccepted', exists: false), isNotNull);
    });
  });

  group('delivery', () {
    test('steps follow the real parcel workflow', () {
      final expected = {
        'pending': 0,
        'driverAssigned': 1,
        'pickupEnroute': 1,
        'arrivedAtPickup': 1,
        'packagePicked': 2,
        'deliveryEnroute': 2,
        'arrivedAtDropoff': 2,
        'completed': 4,
      };
      expected.forEach((status, step) {
        expect(deliveryTrackingView(status).stepIndex, step, reason: status);
      });
    });

    test('the passenger is told when to hand over the parcel', () {
      expect(deliveryTrackingView('arrivedAtPickup').youNeedTo,
          contains('Hand the parcel'));
    });

    test('code reminders only when the delivery has a code', () {
      expect(deliveryTrackingView('deliveryEnroute').youNeedTo, isNull);
      expect(deliveryTrackingView('deliveryEnroute', hasOtp: true).youNeedTo,
          contains('code'));
    });

    test('heads to pickup, then the drop-off', () {
      expect(deliveryTrackingView('pickupEnroute').heading,
          TrackingHeading.pickup);
      expect(deliveryTrackingView('deliveryEnroute').heading,
          TrackingHeading.dropoff);
    });

    test('cancelled variants end; unknown is not "pending"', () {
      for (final s in [
        'cancelled',
        'cancelledByDriver',
        'cancelledByPassenger'
      ]) {
        expect(deliveryTrackingView(s).phase, TrackingPhase.ended, reason: s);
      }
      expect(deliveryTrackingView('mystery').phase, TrackingPhase.unknown);
    });

    test('no cancel from delivery tracking (unchanged)', () {
      for (final s in ['pending', 'driverAssigned', 'deliveryEnroute']) {
        expect(deliveryTrackingView(s).canCancel, isFalse, reason: s);
      }
    });
  });

  group('gas', () {
    test('drop-off orders show three steps, never refill steps', () {
      final v = gasTrackingView('driverEnRoute', refillType: 'exchangeEmpty');
      expect(v.steps, gasDropOffSteps);
      expect(v.steps, isNot(contains('Refilling')));
      expect(
          gasTrackingView('driverArrived', refillType: 'newCylinder').stepIndex,
          1);
      expect(
          gasTrackingView('delivered', refillType: 'newCylinder').stepIndex, 3);
    });

    test('round-trip orders follow collect → refill → return', () {
      final expected = {
        'pendingApproval': 0,
        'driverAssigned': 1,
        'driverEnRoute': 1,
        'driverArrived': 1,
        'pickedUp': 2,
        'atStation': 2,
        'refilling': 2,
        'returning': 3,
        'delivered': 5,
      };
      expected.forEach((status, step) {
        expect(gasTrackingView(status, refillType: 'pickupAndReturn').stepIndex,
            step,
            reason: status);
      });
    });

    test('the refill leg has no route: no station coordinates exist', () {
      for (final s in ['pickedUp', 'atStation', 'refilling']) {
        expect(gasTrackingView(s, refillType: 'pickupAndReturn').heading,
            TrackingHeading.none,
            reason: s);
      }
      expect(
          gasTrackingView('returning', refillType: 'pickupAndReturn').heading,
          TrackingHeading.customer);
    });

    test('round-trip statuses on a drop-off order are not guessed', () {
      for (final s in ['pickedUp', 'atStation', 'refilling', 'returning']) {
        expect(gasTrackingView(s, refillType: 'exchangeEmpty').phase,
            TrackingPhase.unknown,
            reason: s);
      }
    });

    test('cancel only while waiting for a driver (unchanged)', () {
      expect(gasTrackingView('pendingApproval', refillType: 'x').canCancel,
          isTrue);
      for (final s in ['driverAssigned', 'driverEnRoute', 'driverArrived']) {
        expect(gasTrackingView(s, refillType: 'x').canCancel, isFalse,
            reason: s);
      }
    });

    test('cancelled and failed end; never-written statuses are unknown', () {
      expect(gasTrackingView('cancelled', refillType: 'x').phase,
          TrackingPhase.ended);
      expect(gasTrackingView('failed', refillType: 'x').phase,
          TrackingPhase.ended);
      for (final s in ['confirmed', 'outForDelivery', 'weird']) {
        expect(gasTrackingView(s, refillType: 'x').phase, TrackingPhase.unknown,
            reason: s);
      }
    });
  });

  group('driver location freshness', () {
    final now = DateTime(2026, 10, 13, 12);

    test('no position is unavailable, never live', () {
      expect(locationFreshness(hasLocation: false, updatedAt: now, now: now),
          LocationFreshness.unavailable);
    });

    test('recent updates are live, old or untimed ones stale', () {
      expect(
          locationFreshness(
              hasLocation: true,
              updatedAt: now.subtract(const Duration(seconds: 30)),
              now: now),
          LocationFreshness.live);
      expect(
          locationFreshness(
              hasLocation: true,
              updatedAt: now.subtract(const Duration(minutes: 5)),
              now: now),
          LocationFreshness.stale);
      expect(locationFreshness(hasLocation: true, updatedAt: null, now: now),
          LocationFreshness.stale);
    });

    test('stale wording says how old', () {
      expect(lastUpdatedLabel(now.subtract(const Duration(minutes: 4)), now),
          'Updated 4 min ago');
      expect(lastUpdatedLabel(null, now), 'Last known location');
    });
  });
}
