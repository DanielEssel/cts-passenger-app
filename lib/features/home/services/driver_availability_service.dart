import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../ride/models/service_type.dart';





final driverAvailabilityProvider = Provider((ref) => DriverAvailabilityService());

class DriverAvailabilityService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<int> getNearbyDriversCount(ServiceType service) async {
    final roleMap = {
      ServiceType.taxi: 'driver_hailing',
      ServiceType.okada: 'driver_hailing',
      ServiceType.delivery: 'driver_delivery',
      ServiceType.gas: 'driver_delivery',
    };

    final snapshot = await _firestore
        .collection('drivers')
        .where('isOnline', isEqualTo: true)
        .where('isApproved', isEqualTo: true)
        .where('role', isEqualTo: roleMap[service])
        .get();

    return snapshot.docs.length;
  }

  Future<bool> isDriverAvailable(ServiceType service) async {
    final count = await getNearbyDriversCount(service);
    return count > 0;
  }

  Stream<int> watchNearbyDriversCount(ServiceType service) {
    final roleMap = {
      ServiceType.taxi: 'driver_hailing',
      ServiceType.okada: 'driver_hailing',
      ServiceType.delivery: 'driver_delivery',
      ServiceType.gas: 'driver_delivery',
    };

    return _firestore
        .collection('drivers')
        .where('isOnline', isEqualTo: true)
        .where('isApproved', isEqualTo: true)
        .where('role', isEqualTo: roleMap[service])
        .snapshots()
        .map((snap) => snap.docs.length);
  }
}