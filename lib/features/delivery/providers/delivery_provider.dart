// lib/features/delivery/providers/delivery_providers.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/delivery_request.dart';
import '../../delivery/repositories/delivery_repositories.dart';

final deliveryRepositoryProvider = Provider<DeliveryRepository>(
  (ref) => DeliveryRepository(FirebaseFirestore.instance),
);

// Stream a single delivery by ID
final deliveryStreamProvider =
    StreamProvider.autoDispose.family<DeliveryRequest?, String>((ref, id) {
  return ref.read(deliveryRepositoryProvider).watchDelivery(id);
});