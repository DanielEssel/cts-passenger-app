// C4-B: the passenger's active gas-order query uses the statuses the system
// actually writes, so an order still searching for a driver (pendingApproval)
// and every in-progress step is found, and finished orders are not.

import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Written by: passenger create, acceptGasOrder, Driver App step flow.
  const writtenActive = [
    'pendingApproval',
    'driverAssigned',
    'driverEnRoute',
    'driverArrived',
    'pickedUp',
    'atStation',
    'refilling',
    'returning',
  ];

  test('a pendingApproval order counts as active', () {
    expect(GasOrderStatus.activeStatusNames, contains('pendingApproval'));
    expect(GasOrderStatus.pendingApproval.isActive, isTrue);
  });

  test('every status the apps write for an in-progress order is active', () {
    expect(GasOrderStatus.activeStatusNames, unorderedEquals(writtenActive));
  });

  test('statuses already active before C4 still are (driverAssigned, refilling)', () {
    expect(GasOrderStatus.activeStatusNames, containsAll(['driverAssigned', 'refilling']));
  });

  test('finished and never-written statuses are not active', () {
    for (final s in ['delivered', 'cancelled', 'failed', 'confirmed', 'outForDelivery']) {
      expect(GasOrderStatus.activeStatusNames, isNot(contains(s)), reason: s);
    }
  });

  test('legacy names that nothing writes are gone from the query', () {
    for (final s in ['searchingDriver', 'pickupEnroute', 'cylinderPicked', 'enrouteToStation', 'deliveryEnroute']) {
      expect(GasOrderStatus.activeStatusNames, isNot(contains(s)), reason: s);
    }
  });

  test('the list fits a Firestore whereIn and has no duplicates', () {
    final names = GasOrderStatus.activeStatusNames;
    expect(names.length, lessThanOrEqualTo(30));
    expect(names.toSet().length, names.length);
  });

  test('every active name round-trips through fromFirestore', () {
    for (final n in GasOrderStatus.activeStatusNames) {
      expect(GasOrderStatus.fromFirestore(n).firestoreValue, n);
    }
  });
}
