// lib/features/gas/repositories/gas_order_repository.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';

class GasOrderRepository {
  GasOrderRepository(this._db);

  final FirebaseFirestore _db;

  static const String _collection = 'gas_orders';

  CollectionReference<Map<String, dynamic>> get _col =>
    _db.collection(_collection).withConverter<Map<String, dynamic>>(
      fromFirestore: (snap, _) => snap.data()!,
      toFirestore: (data, _) => data,
    );

  // ─────────────────────────────────────────────
  // CREATE
  // ─────────────────────────────────────────────

  /// Writes a new order to Firestore. Returns the new document ID.
  Future<String> createGasOrder(GasRefillRequest order) async {
    try {
      final ref = await _col.add(order.toFirestore());
      return ref.id;
    } on FirebaseException catch (e) {
      throw GasOrderException('Failed to create order: ${e.message}',
          code: e.code);
    }
  }

  // ─────────────────────────────────────────────
  // READ
  // ─────────────────────────────────────────────
Future<GasRefillRequest?> getOrderById(String orderId) async {
  try {
    final doc = await _col.doc(orderId).get();
    if (!doc.exists || doc.data() == null) return null;
    return GasRefillRequest.fromFirestore(doc);
  } on FirebaseException catch (e) {
    throw GasOrderException('Failed to fetch order: ${e.message}',
        code: e.code);
  }
}

Stream<GasRefillRequest?> watchOrder(String orderId) {
  return _col.doc(orderId).snapshots().map((doc) {
    if (!doc.exists || doc.data() == null) return null;
    return GasRefillRequest.fromFirestore(doc);
  });
}

  /// Real-time stream of all orders for a passenger, newest first.
  Stream<List<GasRefillRequest>> watchUserOrders(String passengerId) {
    return _col
        .where('passengerId', isEqualTo: passengerId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) => GasRefillRequest.fromFirestore(
                doc as DocumentSnapshot<Map<String, dynamic>>))
            .toList());
  }

  Future<List<GasRefillRequest>> getUserOrders(String passengerId) async {
    try {
      final snap = await _col
          .where('passengerId', isEqualTo: passengerId)
          .orderBy('createdAt', descending: true)
          .get();
      return snap.docs
          .map((doc) => GasRefillRequest.fromFirestore(
              doc as DocumentSnapshot<Map<String, dynamic>>))
          .toList();
    } on FirebaseException catch (e) {
      throw GasOrderException('Failed to fetch orders: ${e.message}',
          code: e.code);
    }
  }

  // ─────────────────────────────────────────────
  // UPDATE
  // ─────────────────────────────────────────────

  Future<void> updateOrderStatus(
    String orderId,
    GasOrderStatus newStatus, {
    Map<String, dynamic>? additionalFields,
  }) async {
    try {
      final data = <String, dynamic>{
        'status': newStatus.firestoreValue,
        ...?additionalFields,
      };

      switch (newStatus) {
        case GasOrderStatus.pickedUp:
          data['pickupCompletedAt'] = FieldValue.serverTimestamp();
        case GasOrderStatus.delivered:
          data['deliveredAt'] = FieldValue.serverTimestamp();
        case GasOrderStatus.cancelled:
          data['cancelledAt'] = FieldValue.serverTimestamp();
        case GasOrderStatus.refilling:
          data['refillCompletedAt'] = FieldValue.serverTimestamp();
        default:
          break;
      }

      await _col.doc(orderId).update(data);
    } on FirebaseException catch (e) {
      throw GasOrderException('Failed to update status: ${e.message}',
          code: e.code);
    }
  }

  Future<void> cancelOrder(String orderId, {String? reason}) async {
    try {
      await _col.doc(orderId).update({
        'status': GasOrderStatus.cancelled.firestoreValue,
        'cancelledAt': FieldValue.serverTimestamp(),
        if (reason != null) 'metadata.cancellationReason': reason,
      });
    } on FirebaseException catch (e) {
      throw GasOrderException('Failed to cancel order: ${e.message}',
          code: e.code);
    }
  }

  Future<void> rateOrder(String orderId, double rating) async {
    try {
      await _col.doc(orderId).update({'passengerRating': rating});
    } on FirebaseException catch (e) {
      throw GasOrderException('Failed to rate order: ${e.message}',
          code: e.code);
    }
  }
}

// ─────────────────────────────────────────────
// Custom exception
// ─────────────────────────────────────────────

class GasOrderException implements Exception {
  final String message;
  final String? code;

  const GasOrderException(this.message, {this.code});

  @override
  String toString() => 'GasOrderException($code): $message';
}