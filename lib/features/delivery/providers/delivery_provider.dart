// lib/features/delivery/providers/delivery_providers.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/pricing_service.dart';
import '../models/delivery_request.dart';
import '../../delivery/repositories/delivery_repositories.dart';

final deliveryRepositoryProvider = Provider<DeliveryRepository>(
  (ref) => DeliveryRepository(FirebaseFirestore.instance),
);

/// Loads the admin-configured prices into PricingService. Completes with
/// false when they could not be read, so no price is built from defaults.
final deliveryPricingLoaderProvider = Provider<Future<bool> Function()>(
  (ref) => () async {
    await PricingService.instance.fetch();
    return PricingService.instance.hasLoadedSettings;
  },
);

// Stream a single delivery by ID
final deliveryStreamProvider =
    StreamProvider.autoDispose.family<DeliveryRequest?, String>((ref, id) {
  return ref.read(deliveryRepositoryProvider).watchDelivery(id);
});