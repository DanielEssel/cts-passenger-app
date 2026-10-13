// lib/features/ride/domain/ride_availability.dart
//
// Driver availability for a ride category, shown next to the category but
// never used to block selecting it.
//
// Passengers may not read drivers/{id}. Availability comes from driver_map
// (rounded position and type only, kept by syncDriverMap), the same data as
// the map markers. The backend's search still decides whether a driver is
// found.

enum RideAvailability {
  /// No availability source is configured. Nothing is implied either way.
  notChecked,

  /// A check is in progress.
  checking,

  /// The backend reported at least one eligible driver.
  available,

  /// The backend reported no eligible driver right now.
  unavailable,

  /// A check was attempted and failed.
  checkFailed;

  String get label => switch (this) {
        RideAvailability.notChecked => 'Availability confirmed when you request',
        RideAvailability.checking => 'Checking availability…',
        RideAvailability.available => 'Drivers nearby',
        RideAvailability.unavailable => 'No drivers nearby right now',
        RideAvailability.checkFailed => 'Couldn\'t check availability',
      };
}
