// lib/features/tracking/domain/trip_completion.dart
//
// What the passenger sees once a ride's stored status is `completed`. It is
// decided from the server's copy of the trip (never a cached one), so a trip
// that is already confirmed or settled is never offered for confirmation
// again. Confirming only writes passengerConfirmed; onTripCompleted settles
// the trip once (walletProcessed, fixed-ID ledger entries, escrow HELD
// check), so this decides what the passenger is asked, not what is paid.
// Pure, so it can be tested without Firebase.

/// The next step for a ride whose trip document was just read.
enum TripCompletionStep {
  /// Not completed: keep tracking.
  none,

  /// Completed and not yet confirmed, settled or disputed: ask once whether
  /// the passenger arrived.
  askArrival,

  /// Completed and already confirmed or settled: show the trip summary.
  showSummary,

  /// The passenger reported a problem: nothing to confirm while it is
  /// reviewed.
  underReview,
}

TripCompletionStep tripCompletionStep(Map<String, dynamic> trip) {
  if (trip['status'] != 'completed') return TripCompletionStep.none;
  if (trip['disputed'] == true) return TripCompletionStep.underReview;
  final settlement = trip['settlementStatus'];
  final settled = trip['walletProcessed'] == true ||
      settlement == 'completed' ||
      settlement == 'processing';
  final confirmed =
      trip['passengerConfirmed'] == true || trip['autoConfirmed'] == true;
  if (settled || confirmed) return TripCompletionStep.showSummary;
  return TripCompletionStep.askArrival;
}

/// The arrival question's explanation. A cash fare is paid to the driver,
/// not taken from the wallet; any other trip is paid from the amount held in
/// the wallet when it was booked.
String arrivalMessage({required String fare, String? paymentMethod}) =>
    paymentMethod == 'cash'
        ? 'Confirm you reached your destination. This is a cash trip: '
            'pay the driver $fare if you have not already.'
        : 'Confirm you reached your destination. $fare will be paid from '
            'your wallet.';
