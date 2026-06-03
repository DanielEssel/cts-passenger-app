// lib/core/services/pricing_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Fetches platform pricing from Firestore settings/platform
/// Falls back to hardcoded defaults if Firestore is unavailable
class PricingService {
  PricingService._();
  static final PricingService instance = PricingService._();

  static const _doc = 'settings/platform';

  // ── Cached settings ────────────────────────────────────────────────────────
  Map<String, dynamic> _settings = {};
  DateTime?            _lastFetched;
  static const _cacheDuration = Duration(minutes: 10);

  // ── Defaults (fallback if Firestore unreachable) ───────────────────────────
  static const _defaults = {
    'platformFeePercent':  15.0,

    'okada': {
      'baseFare':        3.0,
      'perKmRate':       1.5,
      'perMinRate':      0.2,
      'minimumFare':     5.0,
      'cancellationFee': 2.0,
      'surgeMultiplier': 1.5,
      'surgeEnabled':    false,
    },
    'taxi': {
      'baseFare':        5.0,
      'perKmRate':       2.5,
      'perMinRate':      0.3,
      'minimumFare':     10.0,
      'cancellationFee': 3.0,
      'surgeMultiplier': 1.5,
      'surgeEnabled':    false,
    },
    'delivery': {
      'baseFare':               8.0,
      'perKmRate':              2.0,
      'minimumFare':            10.0,
      'cancellationFee':        3.0,
      'weightSurchargeSmall':   0.0,
      'weightSurchargeMedium':  5.0,
      'weightSurchargeLarge':   15.0,
      'fragileItemSurcharge':   5.0,
    },
    'gas': {
      'cylinder3kg':    48.0,
      'cylinder6kg':    96.0,
      'cylinder12kg':   195.0,
      'cylinder14kg':   228.0,
      'cylinder19kg':   300.0,
      'cylinder45kg':   710.0,
      'deliveryFee':    10.0,
      'minimumOrder':   1,
    },

    'rideEnabled':     true,
    'deliveryEnabled': true,
    'gasEnabled':      true,
    'maintenanceMode': false,

    'minWithdrawalAmount':      10.0,
    'maxWithdrawalAmount':      5000.0,
    'withdrawalProcessingDays': 1,
  };

  // ── Fetch & cache ──────────────────────────────────────────────────────────
  Future<void> fetch({ bool force = false }) async {
    final now = DateTime.now();
    if (!force &&
        _lastFetched != null &&
        now.difference(_lastFetched!) < _cacheDuration &&
        _settings.isNotEmpty) {
      return;
    }

    try {
      final snap = await FirebaseFirestore.instance
          .doc(_doc)
          .get(const GetOptions(source: Source.serverAndCache));
      if (snap.exists) {
        _settings    = snap.data() as Map<String, dynamic>;
        _lastFetched = now;
        debugPrint('✅ PricingService: settings loaded from Firestore');
      }
    } catch (e) {
      debugPrint('⚠️ PricingService: using defaults ($e)');
    }
  }

  // ── Generic getter with fallback ───────────────────────────────────────────
  dynamic _get(List<String> path) {
    dynamic obj = _settings.isEmpty ? _defaults : _settings;
    for (final key in path) {
      if (obj is Map) {
        obj = obj[key] ?? _getDefault(path);
      } else {
        return _getDefault(path);
      }
    }
    return obj ?? _getDefault(path);
  }

  dynamic _getDefault(List<String> path) {
    dynamic obj = _defaults;
    for (final key in path) {
      if (obj is Map) {
        obj = obj[key];
      } else {
        return null;
      }
    }
    return obj;
  }

  double _getDouble(List<String> path) => (_get(path) as num?)?.toDouble() ?? 0.0;
  bool   _getBool(List<String> path)   => (_get(path) as bool?) ?? true;

  // ── Platform ───────────────────────────────────────────────────────────────
  double get platformFeePercent  => _getDouble(['platformFeePercent']);
  double get platformFeeDecimal  => platformFeePercent / 100;

  // ── Service toggles ────────────────────────────────────────────────────────
  bool get rideEnabled        => _getBool(['rideEnabled']);
  bool get deliveryEnabled    => _getBool(['deliveryEnabled']);
  bool get gasEnabled         => _getBool(['gasEnabled']);
  bool get maintenanceMode    => _getBool(['maintenanceMode']);

  // ── Okada ──────────────────────────────────────────────────────────────────
  double get okadaBaseFare        => _getDouble(['okada', 'baseFare']);
  double get okadaPerKmRate       => _getDouble(['okada', 'perKmRate']);
  double get okadaPerMinRate      => _getDouble(['okada', 'perMinRate']);
  double get okadaMinFare         => _getDouble(['okada', 'minimumFare']);
  double get okadaCancelFee       => _getDouble(['okada', 'cancellationFee']);
  double get okadaSurgeMultiplier => _getDouble(['okada', 'surgeMultiplier']);
  bool   get okadaSurgeEnabled    => _getBool(['okada', 'surgeEnabled']);

  // ── Taxi ───────────────────────────────────────────────────────────────────
  double get taxiBaseFare        => _getDouble(['taxi', 'baseFare']);
  double get taxiPerKmRate       => _getDouble(['taxi', 'perKmRate']);
  double get taxiPerMinRate      => _getDouble(['taxi', 'perMinRate']);
  double get taxiMinFare         => _getDouble(['taxi', 'minimumFare']);
  double get taxiCancelFee       => _getDouble(['taxi', 'cancellationFee']);
  double get taxiSurgeMultiplier => _getDouble(['taxi', 'surgeMultiplier']);
  bool   get taxiSurgeEnabled    => _getBool(['taxi', 'surgeEnabled']);

  // ── Delivery ───────────────────────────────────────────────────────────────
  double get deliveryBaseFare             => _getDouble(['delivery', 'baseFare']);
  double get deliveryPerKmRate            => _getDouble(['delivery', 'perKmRate']);
  double get deliveryMinFare              => _getDouble(['delivery', 'minimumFare']);
  double get deliveryCancelFee            => _getDouble(['delivery', 'cancellationFee']);
  double get deliveryWeightSmall          => _getDouble(['delivery', 'weightSurchargeSmall']);
  double get deliveryWeightMedium         => _getDouble(['delivery', 'weightSurchargeMedium']);
  double get deliveryWeightLarge          => _getDouble(['delivery', 'weightSurchargeLarge']);
  double get deliveryFragileSurcharge     => _getDouble(['delivery', 'fragileItemSurcharge']);

  // ── Gas ────────────────────────────────────────────────────────────────────
  double get gasCylinder3kg  => _getDouble(['gas', 'cylinder3kg']);
  double get gasCylinder6kg  => _getDouble(['gas', 'cylinder6kg']);
  double get gasCylinder12kg => _getDouble(['gas', 'cylinder12kg']);
  double get gasCylinder14kg => _getDouble(['gas', 'cylinder14kg']);
  double get gasCylinder19kg => _getDouble(['gas', 'cylinder19kg']);
  double get gasCylinder45kg => _getDouble(['gas', 'cylinder45kg']);
  double get gasDeliveryFee  => _getDouble(['gas', 'deliveryFee']);

  // ── Fare calculators ───────────────────────────────────────────────────────
  double calculateRideFare(String serviceType, double distanceKm, { double waitingMinutes = 0 }) {
    final isOkada = serviceType.toLowerCase() == 'okada';
    final base    = isOkada ? okadaBaseFare    : taxiBaseFare;
    final perKm   = isOkada ? okadaPerKmRate   : taxiPerKmRate;
    final perMin  = isOkada ? okadaPerMinRate  : taxiPerMinRate;
    final minFare = isOkada ? okadaMinFare     : taxiMinFare;
    final surge   = isOkada
        ? (okadaSurgeEnabled  ? okadaSurgeMultiplier  : 1.0)
        : (taxiSurgeEnabled   ? taxiSurgeMultiplier   : 1.0);

    final fare = (base + (perKm * distanceKm) + (perMin * waitingMinutes)) * surge;
    return fare < minFare ? minFare : double.parse(fare.toStringAsFixed(2));
  }

  double calculateDeliveryFare(double distanceKm, {
    String weightTier  = 'small',
    bool   isFragile   = false,
  }) {
    final weightSurcharge = switch (weightTier.toLowerCase()) {
      'medium' => deliveryWeightMedium,
      'large'  => deliveryWeightLarge,
      _        => deliveryWeightSmall,
    };
    final fragile = isFragile ? deliveryFragileSurcharge : 0.0;
    final fare = deliveryBaseFare + (deliveryPerKmRate * distanceKm) + weightSurcharge + fragile;
    return fare < deliveryMinFare
        ? deliveryMinFare
        : double.parse(fare.toStringAsFixed(2));
  }

  double calculateGasFare(String cylinderSize, int quantity) {
    final unitPrice = switch (cylinderSize.toLowerCase().replaceAll(' ', '').replaceAll('.', '')) {
      '3kg'   => gasCylinder3kg,
      '6kg'   => gasCylinder6kg,
      '125kg' => gasCylinder12kg,
      '12kg'  => gasCylinder12kg,
      '145kg' => gasCylinder14kg,
      '14kg'  => gasCylinder14kg,
      '19kg'  => gasCylinder19kg,
      '45kg'  => gasCylinder45kg,
      _       => gasCylinder6kg,
    };
    return double.parse(
      ((unitPrice * quantity) + gasDeliveryFee).toStringAsFixed(2)
    );
  }

  /// Get price for a specific cylinder size by weight
  double gasPriceForWeight(double weightKg) {
    if (weightKg <= 3)  return gasCylinder3kg;
    if (weightKg <= 6)  return gasCylinder6kg;
    if (weightKg <= 13) return gasCylinder12kg;
    if (weightKg <= 15) return gasCylinder14kg;
    if (weightKg <= 19) return gasCylinder19kg;
    return gasCylinder45kg;
  }
}
