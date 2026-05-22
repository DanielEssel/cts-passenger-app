// lib/features/delivery/repositories/delivery_repository.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/delivery_request.dart';

class DeliveryRepository {
  final FirebaseFirestore _db;
  DeliveryRepository(this._db);

  static const String _col = 'deliveries';

  // ── Create ──────────────────────────────────────────────────────────────
  Future<String> createDelivery(DeliveryRequest request) async {
    final ref = await _db.collection(_col).add(request.toFirestore());
    return ref.id;
  }

  // ── Stream single ────────────────────────────────────────────────────────
  Stream<DeliveryRequest?> watchDelivery(String id) =>
      _db.collection(_col).doc(id).snapshots().map((doc) =>
          doc.exists ? DeliveryRequest.fromFirestore(doc) : null);

  // ── Cancel ───────────────────────────────────────────────────────────────
  Future<void> cancelDelivery(String id, {String? reason}) =>
      _db.collection(_col).doc(id).update({
        'status':      DeliveryStatus.cancelled.firestoreValue,
        'cancelledAt': FieldValue.serverTimestamp(),
        if (reason != null) 'cancelReason': reason,
      });

  // ── Rate ─────────────────────────────────────────────────────────────────
  Future<void> rateDelivery(String id, double rating) =>
      _db.collection(_col).doc(id).update({'passengerRating': rating});
}