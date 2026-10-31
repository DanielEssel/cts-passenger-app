// lib/features/tracking/widgets/arrival_prompt.dart
//
// The "Have you arrived?" question for a completed, unconfirmed ride, and
// what each answer writes. Only the two buttons act: closing the dialog any
// other way (Android Back) writes nothing and leaves the trip as it was.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/cts_theme.dart';

enum ArrivalAnswer { arrived, reportIssue, dismissed }

/// Asks whether the passenger arrived. [message] explains how the fare is
/// paid (see arrivalMessage).
Future<ArrivalAnswer> askArrival(BuildContext context,
    {required String message}) async {
  final answer = await showDialog<ArrivalAnswer>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: CtsTheme.primaryTint,
              borderRadius: BorderRadius.circular(16),
            ),
            child:
                const Icon(Icons.flag_rounded, color: CtsTheme.primary, size: 32),
          ),
          const SizedBox(height: 16),
          const Text('Have you arrived?',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: CtsTheme.textSecondary),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(ctx, ArrivalAnswer.arrived),
              style: FilledButton.styleFrom(
                backgroundColor: CtsTheme.vivid,
                foregroundColor: CtsTheme.onVivid,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Yes, I arrived!',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(ctx, ArrivalAnswer.reportIssue),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: CtsTheme.error),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text("I didn't arrive — Report issue",
                  style: TextStyle(
                    color: CtsTheme.error,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  )),
            ),
          ),
        ],
      ),
    ),
  );
  return answer ?? ArrivalAnswer.dismissed;
}

/// The writes behind each answer, so they can be checked without Firebase.
abstract class ArrivalWriter {
  /// Records the passenger's confirmation; onTripCompleted settles the trip.
  Future<void> confirmArrival(String tripId);

  /// Marks the trip disputed and opens a support ticket.
  Future<void> reportNotArrived(String tripId, {String? userId});
}

class FirestoreArrivalWriter implements ArrivalWriter {
  FirestoreArrivalWriter([FirebaseFirestore? db])
      : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  @override
  Future<void> confirmArrival(String tripId) =>
      _db.collection('trips').doc(tripId).update({
        'passengerConfirmed': true,
        'passengerConfirmedAt': FieldValue.serverTimestamp(),
      });

  @override
  Future<void> reportNotArrived(String tripId, {String? userId}) async {
    await _db.collection('trips').doc(tripId).update({
      'disputed': true,
      'disputedAt': FieldValue.serverTimestamp(),
      'disputeReason': 'Passenger did not confirm arrival',
    });
    await _db.collection('supportTickets').add({
      'userId': userId,
      'userRole': 'passenger',
      'subject': 'Trip dispute — did not arrive at destination',
      'message':
          'Driver marked trip as complete but passenger did not arrive. Trip ID: $tripId',
      'category': 'trip_dispute',
      'priority': 'high',
      'status': 'open',
      'tripId': tripId,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}

/// Applies [answer]: only an explicit button writes anything.
Future<void> applyArrivalAnswer(
  ArrivalAnswer answer,
  ArrivalWriter writer, {
  required String tripId,
  String? userId,
}) async {
  switch (answer) {
    case ArrivalAnswer.arrived:
      await writer.confirmArrival(tripId);
    case ArrivalAnswer.reportIssue:
      await writer.reportNotArrived(tripId, userId: userId);
    case ArrivalAnswer.dismissed:
      break;
  }
}
