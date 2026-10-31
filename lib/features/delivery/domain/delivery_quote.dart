// lib/features/delivery/domain/delivery_quote.dart
//
// The Delivery price is the server's (functions/delivery_quotes.js
// quoteDelivery): it measures the road route itself and prices it from the
// approved rate card, stores an immutable quote and returns it. The app shows
// that quote, holds exactly its total and writes its id on the order; the
// server refuses an order whose fare, route or parcel differ from the quote.
// Nothing here measures a route or computes a payable amount.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One server quote (amounts in GHS as the server returns them).
class ServerDeliveryQuote {
  final String quoteId;
  final String vehicleType;
  final double distanceKm;
  final int? durationMinutes;
  final double baseFare;
  final double distanceCharge;
  final double weightSurcharge;
  final double fragileSurcharge;
  final double helperSurcharge;
  final double minimumFare;
  final bool minimumApplied;
  final double total;
  final DateTime expiresAt;

  const ServerDeliveryQuote({
    required this.quoteId,
    required this.vehicleType,
    required this.distanceKm,
    this.durationMinutes,
    required this.baseFare,
    required this.distanceCharge,
    required this.weightSurcharge,
    required this.fragileSurcharge,
    required this.helperSurcharge,
    required this.minimumFare,
    required this.minimumApplied,
    required this.total,
    required this.expiresAt,
  });

  /// Parses the callable's result; throws FormatException on a bad shape.
  factory ServerDeliveryQuote.fromMap(Map<String, dynamic> m) {
    double n(String k) {
      final v = m[k];
      if (v is num && v.isFinite) return v.toDouble();
      throw FormatException('quote field $k missing');
    }

    final id = m['quoteId'];
    final vehicle = m['vehicleType'];
    final expires = m['expiresAtMillis'];
    if (id is! String || id.isEmpty || vehicle is! String || expires is! num) {
      throw const FormatException('quote identity missing');
    }
    return ServerDeliveryQuote(
      quoteId: id,
      vehicleType: vehicle,
      distanceKm: n('distanceKm'),
      durationMinutes: (m['durationMinutes'] as num?)?.toInt(),
      baseFare: n('baseFare'),
      distanceCharge: n('distanceCharge'),
      weightSurcharge: n('weightSurcharge'),
      fragileSurcharge: n('fragileSurcharge'),
      helperSurcharge: n('helperSurcharge'),
      minimumFare: n('minimumFare'),
      minimumApplied: m['minimumApplied'] == true,
      total: n('total'),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expires.toInt()),
    );
  }

  /// Base fare plus the per-km charge.
  double get distanceFare => baseFare + distanceCharge;

  /// True when the quote expires within [margin] of [now].
  bool expiresSoon(DateTime now,
          {Duration margin = const Duration(minutes: 1)}) =>
      !now.add(margin).isBefore(expiresAt);
}

/// Why no quote could be produced, with a message for the customer.
class DeliveryQuoteException implements Exception {
  final String reason;
  final String message;
  const DeliveryQuoteException(this.reason, this.message);

  @override
  String toString() => message;
}

/// Asks the server for a quote.
class DeliveryQuoteService {
  const DeliveryQuoteService();

  Future<ServerDeliveryQuote> quote({
    required GeoPoint pickup,
    required GeoPoint dropoff,
    required String vehicleType,
    required String weightTier,
    required bool isFragile,
    required bool requiresHelpers,
  }) async {
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west2')
          .httpsCallable('quoteDelivery')
          .call({
        'pickup': {
          'latitude': pickup.latitude,
          'longitude': pickup.longitude,
        },
        'dropoff': {
          'latitude': dropoff.latitude,
          'longitude': dropoff.longitude,
        },
        'vehicleType': vehicleType,
        'weightTier': weightTier,
        'isFragile': isFragile,
        'requiresHelpers': requiresHelpers,
      });
      return ServerDeliveryQuote.fromMap(
          Map<String, dynamic>.from(result.data as Map));
    } on FirebaseFunctionsException catch (e) {
      final details = e.details;
      final reason = details is Map ? details['reason'] as String? : null;
      throw DeliveryQuoteException(
          reason ?? e.code,
          e.message ??
              'We couldn\'t price this delivery right now. Please try again.');
    } on FormatException {
      throw const DeliveryQuoteException('bad_quote',
          'We couldn\'t price this delivery right now. Please try again.');
    }
  }
}

final deliveryQuoteServiceProvider =
    Provider<DeliveryQuoteService>((ref) => const DeliveryQuoteService());

/// The server quotes for the vehicles offered for one parcel and route.
class DeliveryQuote {
  /// Quote per vehicle key ('Okada' / 'Aboboya' / 'Mini Truck').
  final Map<String, ServerDeliveryQuote> fares;

  const DeliveryQuote({required this.fares});

  double get distanceKm => fares.isEmpty ? 0 : fares.values.first.distanceKm;
}
