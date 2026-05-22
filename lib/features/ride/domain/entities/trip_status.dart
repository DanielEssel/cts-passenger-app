// lib/features/ride/domain/entities/trip_status.dart

/// Canonical trip lifecycle. Only 6 active states + 3 terminal states.
/// This replaces the old 9-value enum that had overlapping semantics.
///
/// Migration map (old → new):
///   searching    → searching    (unchanged)
///   pending      → accepted     (driver assigned)
///   tripAccepted → accepted     (duplicate — collapsed)
///   tripStarted  → inProgress   (duplicate — collapsed)
///   driverArrived→ driverArrived (unchanged)
///   inProgress   → inProgress   (unchanged)
///   completed    → completed    (unchanged)
///   cancelled    → cancelled    (unchanged)
///   noDrivers    → noDrivers    (unchanged)
enum TripStatus {
  searching,
  accepted,
  driverArrived,
  inProgress,
  completed,
  cancelled,
  noDrivers;

  // ── State machine ─────────────────────────────────────────────────────────
  // Only the driver app can write accepted/driverArrived/inProgress/completed.
  // Only the passenger app can write cancelled (from their side).
  // Firestore Security Rules enforce the ownership — this is the Dart-layer guard.

  Set<TripStatus> get allowedTransitions => switch (this) {
        TripStatus.searching     => {accepted, noDrivers, cancelled},
        TripStatus.accepted      => {driverArrived, cancelled},
        TripStatus.driverArrived => {inProgress, cancelled},
        TripStatus.inProgress    => {completed, cancelled},
        TripStatus.completed     => {},   // terminal — no transitions allowed
        TripStatus.cancelled     => {},   // terminal
        TripStatus.noDrivers     => {},   // terminal
      };

  bool canTransitionTo(TripStatus next) =>
      allowedTransitions.contains(next);

  /// True once a trip can never be modified again.
  bool get isTerminal =>
      this == completed || this == cancelled || this == noDrivers;

  /// True if a driver has been assigned and the trip is live.
  bool get isLive =>
      this == accepted || this == driverArrived || this == inProgress;

  // ── Display strings ───────────────────────────────────────────────────────

  String get passengerLabel => switch (this) {
        searching     => 'Finding your driver...',
        accepted      => 'Driver on the way',
        driverArrived => 'Driver has arrived',
        inProgress    => 'On your trip',
        completed     => 'Trip completed',
        cancelled     => 'Trip cancelled',
        noDrivers     => 'No drivers available',
      };

  String get driverLabel => switch (this) {
        searching     => 'New trip request',
        accepted      => 'Head to pickup',
        driverArrived => 'Waiting for passenger',
        inProgress    => 'Trip in progress',
        completed     => 'Trip completed',
        cancelled     => 'Trip cancelled',
        noDrivers     => 'Request expired',
      };

  // ── Safe parsing from Firestore string ───────────────────────────────────
  // Lives here (not in DTO) because parsing a known enum is domain logic.

  static TripStatus fromString(String? value) {
    if (value == null) return searching;

    // Handle legacy values from old enum
    const legacyMap = {
      'pending': 'accepted',
      'tripAccepted': 'accepted',
      'tripStarted': 'inProgress',
    };

    final normalized = legacyMap[value] ?? value;

    return TripStatus.values.firstWhere(
      (e) => e.name == normalized,
      orElse: () => searching,
    );
  }
}