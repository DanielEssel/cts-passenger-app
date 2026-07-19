// lib/features/delivery/domain/delivery_form_validator.dart
//
// Pure Dart — NO Flutter imports. Every rule here is unit-testable in
// isolation. The delivery screen holds all UI/state; this file holds all
// judgement about what counts as valid.
//
// Design notes:
//  • Field validators return `null` when valid, else a user-facing message.
//  • `firstError` is the single gate the screen's submit button reads — it
//    returns the first blocking problem (or null when the form may proceed),
//    so the button hint and the button-enabled state come from one source.

import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

class DeliveryFormValidator {
  DeliveryFormValidator._();

  // ── Receiver phone (Ghana MTN / Telecel / AirtelTigo) ──────────────────
  // Valid NCA mobile prefixes as of 2026. Accepts either 0XXXXXXXXX or
  // +233XXXXXXXXX input; both normalize to the 10-digit 0-leading form.
  static const _ghanaMobilePrefixes = {
    '020', '023', '024', '025', '026', '027', '028', // and MTN/AT range
    '050', '053', '054', '055', '056', '057', '059',
  };

  /// Returns null when valid, else a message. Phone is REQUIRED.
  static String? receiverPhone(String raw) {
    final local = normalizePhone(raw);
    if (local.isEmpty) return 'Receiver phone is required';
    if (local.length != 10 || !local.startsWith('0')) {
      return 'Enter a valid 10-digit Ghana number';
    }
    if (!_ghanaMobilePrefixes.contains(local.substring(0, 3))) {
      return "That doesn't look like a Ghana mobile number";
    }
    return null;
  }

  /// Normalizes any Ghana input to 0XXXXXXXXX. Non-digits stripped;
  /// a 233-prefixed 12-digit number becomes 0-leading.
  static String normalizePhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('233') && digits.length == 12) {
      return '0${digits.substring(3)}';
    }
    return digits;
  }

  // ── Receiver name (optional — but must be a name if provided) ───────────
  static String? receiverName(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return null; // optional field
    if (v.length < 2) return 'Name is too short';
    if (RegExp(r'^[\d\s+.\-]+$').hasMatch(v)) {
      return 'Enter a name, not a number';
    }
    return null;
  }

  // ── Delivery notes ──────────────────────────────────────────────────────
  static const notesMaxLength = 200;

  static String? notes(String raw) {
    if (raw.trim().length > notesMaxLength) {
      return 'Keep notes under $notesMaxLength characters';
    }
    return null;
  }

  // ── Route sanity (haversine) ────────────────────────────────────────────
  static const minRouteKm = 0.2; // 200m — catches same-Plus-Code / same-building bookings
  static const maxRouteKm = 100.0; // beyond this isn't a city delivery

  static double distanceKm(GeoPoint a, GeoPoint b) {
    const earthKm = 6371.0;
    final dLat = _rad(b.latitude - a.latitude);
    final dLng = _rad(b.longitude - a.longitude);
    final h = pow(sin(dLat / 2), 2) +
        cos(_rad(a.latitude)) * cos(_rad(b.latitude)) * pow(sin(dLng / 2), 2);
    return 2 * earthKm * atan2(sqrt(h), sqrt(1 - h));
  }

  static double _rad(double deg) => deg * pi / 180;

  /// Null when the route is sane; else a message.
  static String? route(GeoPoint? pickup, GeoPoint? dropoff) {
    if (pickup == null) return 'Pickup location not set';
    if (dropoff == null) return 'Select a drop-off address';
    final km = distanceKm(pickup, dropoff);
    if (km < minRouteKm) return 'Pickup and drop-off are the same place';
    if (km > maxRouteKm) {
      return 'Route is ${km.toStringAsFixed(0)} km — too far for delivery';
    }
    return null;
  }

  /// True when a candidate drop-off is effectively the same spot as pickup.
  /// Used for immediate feedback the moment a suggestion is tapped, before
  /// the user ever reaches the submit gate. `route` remains the backstop.
  static bool isSameAsPickup(GeoPoint? pickup, GeoPoint candidate) {
    if (pickup == null) return false;
    return distanceKm(pickup, candidate) < minRouteKm;
  }

  // ── Cross-field: loading helpers vs weight tier ─────────────────────────
  // Helpers ride on Aboboya / Mini Truck. The Small tier is Okada-only, so
  // "requires helpers" is meaningless (and shouldn't be billed) there.
  static bool helpersAllowedForTier(List<String> tierVehicles) =>
      tierVehicles.any((v) => v == 'Aboboya' || v == 'Mini Truck');

  // ── Aggregate gate ──────────────────────────────────────────────────────
  // Returns the first blocking error, or null when the form may proceed.
  // Order matters: it drives the button hint, so earlier = higher priority.
  static String? firstError({
    required GeoPoint? pickup,
    required GeoPoint? dropoff,
    required int selectedWeight,
    required String phone,
    required String name,
    required String noteText,
    required bool uploadingPhoto,
  }) {
    if (pickup == null) return 'Set your pickup location';
    if (dropoff == null) return 'Select a drop-off address';

    final routeErr = route(pickup, dropoff);
    if (routeErr != null) return routeErr;

    if (selectedWeight < 0) return 'Select a weight tier';

    final phoneErr = receiverPhone(phone);
    if (phoneErr != null) return phoneErr;

    final nameErr = receiverName(name);
    if (nameErr != null) return nameErr;

    final noteErr = notes(noteText);
    if (noteErr != null) return noteErr;

    if (uploadingPhoto) return 'Wait for the photo upload to finish';

    return null;
  }
}