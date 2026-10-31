// lib/features/ride/services/last_vehicle_store.dart
//
// The passenger's last selected ride vehicle, kept on this device with
// SharedPreferences (as onboarding is) so a saved-place shortcut can reuse
// it. Only Taxi, Okada and Pragyia are stored or returned; anything else,
// or a storage failure, reads as "no vehicle".

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_ride_args.dart';
import '../models/service_type.dart';

class LastVehicleStore {
  static const key = 'last_ride_vehicle';

  Future<ServiceType?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return BookRideArgs.rideServiceNamed(prefs.getString(key));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(ServiceType service) async {
    if (!BookRideArgs.rideServices.contains(service)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, service.name);
    } catch (_) {/* a preference, not a requirement */}
  }
}

final lastVehicleStoreProvider = Provider<LastVehicleStore>((_) => LastVehicleStore());
