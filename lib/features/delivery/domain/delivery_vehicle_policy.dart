// Which vehicles may carry each delivery weight tier.
//
// From the vehicle capacities the app shows (delivery_vehicle_screen.dart):
// Okada 0–5 kg, Aboboya 5–100 kg, Mini Truck 100 kg+. The backend enforces
// the same table (functions/dispatch_policy.js DELIVERY_VEHICLE_TIERS and
// firestore.rules deliveryVehicleMatches): a delivery booked on a vehicle
// outside it is offered to no driver and cannot be claimed. Keep in step.

/// Weight tier label → the vehicle keys that may carry it.
const deliveryTierVehicles = <String, List<String>>{
  'Small': ['Okada'], // 0–5 kg
  'Medium': ['Aboboya'], // 5–20 kg: beyond Okada's 5 kg
  'Large': ['Aboboya'], // 20–100 kg
  'Bulk': ['Mini Truck'], // 100 kg+
};

/// True when [vehicle] may carry a [tier] delivery.
bool deliveryVehicleCarries(String vehicle, String tier) =>
    deliveryTierVehicles[tier]?.contains(vehicle) ?? false;
