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
  DateTime? _lastFetched;
  static const _cacheDuration = Duration(minutes: 10);

  // ── Defaults (fallback if Firestore unreachable) ───────────────────────────
  static const _defaults = {
    'platformFeePercent': 15.0,
    'okada': {
      'baseFare': 3.0,
      'perKmRate': 1.5,
      'perMinRate': 0.2,
      'minimumFare': 5.0,
      'cancellationFee': 2.0,
      'surgeMultiplier': 1.5,
      'surgeEnabled': false,
    },
    'pragyia': {
      'baseFare': 4.0,
      'perKmRate': 2.0,
      'perMinRate': 0.25,
      'minimumFare': 8.0,
      'cancellationFee': 2.5,
      'surgeMultiplier': 1.5,
      'surgeEnabled': false,
    },
    'taxi': {
      'baseFare': 5.0,
      'perKmRate': 2.5,
      'perMinRate': 0.3,
      'minimumFare': 10.0,
      'cancellationFee': 3.0,
      'surgeMultiplier': 1.5,
      'surgeEnabled': false,
    },
    'delivery': {
      'okada': {'baseFare': 5.0, 'perKmRate': 2.5, 'minimumFare': 10.0},
      'aboboya': {'baseFare': 15.0, 'perKmRate': 4.0, 'minimumFare': 20.0},
      'miniTruck': {'baseFare': 40.0, 'perKmRate': 7.0, 'minimumFare': 50.0},
      'weightSurchargeSmall': 0.0,
      'weightSurchargeMedium': 5.0,
      'weightSurchargeLarge': 15.0,
      'fragileItemSurcharge': 5.0,
      'helperSurcharge': 10.0,
      'cancellationFee': 3.0,
    },
    'gas': {
      // ── Legacy keys (kept for back-compat; not read by the new calculator) ──
      'cylinder3kg': 48.0,
      'cylinder6kg': 96.0,
      'cylinder12kg': 195.0,
      'cylinder14kg': 228.0,
      'cylinder19kg': 300.0,
      'cylinder45kg': 710.0,
      // ── Refill prices (gas only) — Exchange, Pickup & Return ──
      'refill3kg': 40.0,
      'refill6kg': 75.0,
      'refill12kg': 150.0,
      'refill14kg': 177.0,
      'refill19kg': 230.0,
      'refill45kg': 540.0,
      // ── Full cylinder (hardware + first fill) — New Cylinder ──
      'full3kg': 180.0,
      'full6kg': 280.0,
      'full12kg': 480.0,
      'full14kg': 520.0,
      'full19kg': 620.0,
      'full45kg': 1150.0,
      // ── Fees ──
      'deliveryFee': 15.0,
      'roundTripFee': 30.0,
      'commercialRate': 1.0,
      'baseFare': 8.0,
      'perKm': 2.0,
      'minDeliveryFee': 12.0,
      'minimumOrder': 1,
    },
    'rideEnabled': true,
    'deliveryEnabled': true,
    'gasEnabled': true,
    'maintenanceMode': false,
    'minWithdrawalAmount': 10.0,
    'maxWithdrawalAmount': 5000.0,
    'withdrawalProcessingDays': 1,
  };

  // ── Fetch & cache ──────────────────────────────────────────────────────────
  Future<void> fetch({bool force = false}) async {
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
        _settings = snap.data() as Map<String, dynamic>;
        _lastFetched = now;
        debugPrint('✅ PricingService: settings loaded from Firestore');
      }
    } catch (e) {
      debugPrint(_settings.isEmpty
          ? '⚠️ PricingService: settings unavailable, display uses defaults ($e)'
          : '⚠️ PricingService: settings refresh failed, keeping loaded ones ($e)');
    }
  }

  /// Reads `settings/platform` from the server only — never the offline
  /// cache or the built-in defaults — before money is held or an order is
  /// created. True when the server's settings are now loaded; false when
  /// the read failed (offline, denied) or the document is missing or empty.
  /// On false the loaded settings are kept for display only.
  Future<bool> fetchFromServer() async {
    try {
      final reader = debugServerReader ??
          () async => (await FirebaseFirestore.instance
                  .doc(_doc)
                  .get(const GetOptions(source: Source.server)))
              .data();
      final data = await reader();
      if (data == null || data.isEmpty) {
        debugPrint('⚠️ PricingService: $_doc is missing or empty');
        return false;
      }
      _settings = Map<String, dynamic>.from(data);
      _lastFetched = DateTime.now();
      return true;
    } catch (e) {
      debugPrint('⚠️ PricingService: current prices unavailable ($e)');
      return false;
    }
  }

  /// Test hook: replaces the server read in [fetchFromServer] (null restores
  /// it). Returns the document's data, null when it does not exist, or throws.
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function()? debugServerReader;

  /// True once `settings/platform` has been read (from the server or the
  /// offline cache). False means every price comes from the built-in
  /// defaults, which may not match what the admin panel configured.
  bool get hasLoadedSettings => _settings.isNotEmpty;

  /// Test hook: replaces the cached settings (null clears them).
  @visibleForTesting
  void debugSetSettings(Map<String, dynamic>? settings) {
    _settings = settings ?? {};
    _lastFetched = settings == null ? null : DateTime.now();
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

  double _getDouble(List<String> path) => configAmount(_get(path)) ?? 0.0;

  /// A configured amount as functions/gas_pricing.js reads it: a finite,
  /// non-negative number or a numeric string ("50", "7.5"); null otherwise.
  @visibleForTesting
  static double? configAmount(Object? v) {
    if (v is num) return v.isFinite && v >= 0 ? v.toDouble() : null;
    if (v is String && RegExp(r'^\s*\d+(\.\d+)?\s*$').hasMatch(v)) {
      return double.parse(v.trim());
    }
    return null;
  }

  /// The settings keys a legacy Gas price is made from.
  static const gasPriceKeys = [
    'refill3kg', 'refill6kg', 'refill12kg', 'refill14kg', 'refill19kg', 'refill45kg',
    'full3kg', 'full6kg', 'full12kg', 'full14kg', 'full19kg', 'full45kg',
    'baseFare', 'perKm', 'minDeliveryFee', 'roundTripFee', 'commercialRate',
  ];

  /// Why Gas cannot be priced from the loaded settings, or null. The server
  /// (gas_pricing.js) refuses the same configurations, so the app does not
  /// offer an order it would cancel: a present but malformed amount (text,
  /// negative), a zero product price or commercial rate, a `gas` entry that
  /// is not a map, or a platform fee outside 0–100. Missing keys use the
  /// built-in prices on both sides.
  String? get gasPricingProblem {
    final gas = _settings['gas'];
    if (gas != null && gas is! Map) return 'gas_config_invalid';
    for (final k in gasPriceKeys) {
      final raw = gas is Map ? gas[k] : null;
      if (raw == null) continue;
      final v = configAmount(raw);
      if (v == null) return 'gas_config_invalid';
      final mustBePositive = k.startsWith('refill') || k.startsWith('full') || k == 'commercialRate';
      if (mustBePositive && v <= 0) return 'gas_config_invalid';
    }
    final fee = _settings['platformFeePercent'];
    if (fee != null) {
      final v = configAmount(fee);
      if (v == null || v > 100) return 'platform_fee_invalid';
    }
    return null;
  }
  bool _getBool(List<String> path) => (_get(path) as bool?) ?? true;

  // ── Platform ───────────────────────────────────────────────────────────────
  double get platformFeePercent => _getDouble(['platformFeePercent']);
  double get platformFeeDecimal => platformFeePercent / 100;

  // ── Service toggles ────────────────────────────────────────────────────────
  bool get rideEnabled => _getBool(['rideEnabled']);
  bool get deliveryEnabled => _getBool(['deliveryEnabled']);
  bool get gasEnabled => _getBool(['gasEnabled']);
  bool get maintenanceMode => _getBool(['maintenanceMode']);

  // ── Okada ──────────────────────────────────────────────────────────────────
  double get okadaBaseFare => _getDouble(['okada', 'baseFare']);
  double get okadaPerKmRate => _getDouble(['okada', 'perKmRate']);
  double get okadaPerMinRate => _getDouble(['okada', 'perMinRate']);
  double get okadaMinFare => _getDouble(['okada', 'minimumFare']);
  double get okadaCancelFee => _getDouble(['okada', 'cancellationFee']);
  double get okadaSurgeMultiplier => _getDouble(['okada', 'surgeMultiplier']);
  bool get okadaSurgeEnabled => _getBool(['okada', 'surgeEnabled']);

  // ── Taxi ───────────────────────────────────────────────────────────────────
  double get taxiBaseFare => _getDouble(['taxi', 'baseFare']);
  double get taxiPerKmRate => _getDouble(['taxi', 'perKmRate']);
  double get taxiPerMinRate => _getDouble(['taxi', 'perMinRate']);
  double get taxiMinFare => _getDouble(['taxi', 'minimumFare']);
  double get taxiCancelFee => _getDouble(['taxi', 'cancellationFee']);
  double get taxiSurgeMultiplier => _getDouble(['taxi', 'surgeMultiplier']);
  bool get taxiSurgeEnabled => _getBool(['taxi', 'surgeEnabled']);

  // ── Delivery ───────────────────────────────────────────────────────────────
  double get deliveryBaseFare => _getDouble(['delivery', 'okada', 'baseFare']);
  double get deliveryPerKmRate => _getDouble(['delivery', 'okada', 'perKmRate']);
  double get deliveryMinFare => _getDouble(['delivery', 'okada', 'minimumFare']);
  double get deliveryCancelFee => _getDouble(['delivery', 'cancellationFee']);
  double get deliveryWeightSmall =>
      _getDouble(['delivery', 'weightSurchargeSmall']);
  double get deliveryWeightMedium =>
      _getDouble(['delivery', 'weightSurchargeMedium']);
  double get deliveryWeightLarge =>
      _getDouble(['delivery', 'weightSurchargeLarge']);
  double get deliveryFragileSurcharge =>
      _getDouble(['delivery', 'fragileItemSurcharge']);

  double get deliveryHelperSurcharge => _getDouble(['delivery', 'helperSurcharge']);

  // Per-vehicle delivery rates ('Okada' / 'Aboboya' / 'Mini Truck')
  double _deliveryVehicleBase(String v) => switch (v.toLowerCase().replaceAll(' ', '')) {
        'aboboya' => _getDouble(['delivery', 'aboboya', 'baseFare']),
        'minitruck' => _getDouble(['delivery', 'miniTruck', 'baseFare']),
        _ => _getDouble(['delivery', 'okada', 'baseFare']),
      };
  double _deliveryVehiclePerKm(String v) => switch (v.toLowerCase().replaceAll(' ', '')) {
        'aboboya' => _getDouble(['delivery', 'aboboya', 'perKmRate']),
        'minitruck' => _getDouble(['delivery', 'miniTruck', 'perKmRate']),
        _ => _getDouble(['delivery', 'okada', 'perKmRate']),
      };
  double _deliveryVehicleMinFare(String v) => switch (v.toLowerCase().replaceAll(' ', '')) {
        'aboboya' => _getDouble(['delivery', 'aboboya', 'minimumFare']),
        'minitruck' => _getDouble(['delivery', 'miniTruck', 'minimumFare']),
        _ => _getDouble(['delivery', 'okada', 'minimumFare']),
      };

  // ── Gas ────────────────────────────────────────────────────────────────────
  double get gasCylinder3kg => _getDouble(['gas', 'cylinder3kg']);
  double get gasCylinder6kg => _getDouble(['gas', 'cylinder6kg']);
  double get gasCylinder12kg => _getDouble(['gas', 'cylinder12kg']);
  double get gasCylinder14kg => _getDouble(['gas', 'cylinder14kg']);
  double get gasCylinder19kg => _getDouble(['gas', 'cylinder19kg']);
  double get gasCylinder45kg => _getDouble(['gas', 'cylinder45kg']);
  double get gasDeliveryFee => _getDouble(['gas', 'deliveryFee']);

  // ── Refill prices (gas only) — Exchange, Pickup & Return ──
  double get gasRefill3kg => _getDouble(['gas', 'refill3kg']);
  double get gasRefill6kg => _getDouble(['gas', 'refill6kg']);
  double get gasRefill12kg => _getDouble(['gas', 'refill12kg']);
  double get gasRefill14kg => _getDouble(['gas', 'refill14kg']);
  double get gasRefill19kg => _getDouble(['gas', 'refill19kg']);
  double get gasRefill45kg => _getDouble(['gas', 'refill45kg']);

  // ── Full cylinder prices (hardware + first fill) — New Cylinder ──
  double get gasFull3kg => _getDouble(['gas', 'full3kg']);
  double get gasFull6kg => _getDouble(['gas', 'full6kg']);
  double get gasFull12kg => _getDouble(['gas', 'full12kg']);
  double get gasFull14kg => _getDouble(['gas', 'full14kg']);
  double get gasFull19kg => _getDouble(['gas', 'full19kg']);
  double get gasFull45kg => _getDouble(['gas', 'full45kg']);

  // ── Gas fees ──
  double get gasRoundTripFee => _getDouble(['gas', 'roundTripFee']);
  double get gasBaseFare       => _getDouble(['gas', 'baseFare']);
  double get gasPerKm          => _getDouble(['gas', 'perKm']);
  double get gasMinDeliveryFee => _getDouble(['gas', 'minDeliveryFee']);

  double get gasCommercialRate {
    final r = _getDouble(['gas', 'commercialRate']);
    // Never zero-out bulk pricing (gasPricingProblem blocks ordering then).
    return r > 0 ? r : 1.0;
  }

  // ── Fare calculators ───────────────────────────────────────────────────────
  double calculateRideFare(String serviceType, double distanceKm,
      {double waitingMinutes = 0}) {
    final isOkada = serviceType.toLowerCase() == 'okada';
    final base = isOkada ? okadaBaseFare : taxiBaseFare;
    final perKm = isOkada ? okadaPerKmRate : taxiPerKmRate;
    final perMin = isOkada ? okadaPerMinRate : taxiPerMinRate;
    final minFare = isOkada ? okadaMinFare : taxiMinFare;
    final surge = isOkada
        ? (okadaSurgeEnabled ? okadaSurgeMultiplier : 1.0)
        : (taxiSurgeEnabled ? taxiSurgeMultiplier : 1.0);

    final fare =
        (base + (perKm * distanceKm) + (perMin * waitingMinutes)) * surge;
    return fare < minFare ? minFare : double.parse(fare.toStringAsFixed(2));
  }

  double calculateDeliveryFare(
    double distanceKm, {
    required String vehicleType,
    String weightTier = 'small',
    bool isFragile = false,
    bool requiresHelpers = false,
  }) =>
      deliveryFareBreakdown(
        distanceKm,
        vehicleType: vehicleType,
        weightTier: weightTier,
        isFragile: isFragile,
        requiresHelpers: requiresHelpers,
      ).total;

  /// The components behind [calculateDeliveryFare], so the UI can itemise
  /// the fare and say when the vehicle's minimum fare applied.
  DeliveryFareBreakdown deliveryFareBreakdown(
    double distanceKm, {
    required String vehicleType,
    String weightTier = 'small',
    bool isFragile = false,
    bool requiresHelpers = false,
  }) {
    final base = _deliveryVehicleBase(vehicleType);
    final perKm = _deliveryVehiclePerKm(vehicleType);
    final minFare = _deliveryVehicleMinFare(vehicleType);
    final weightSurcharge = switch (weightTier.toLowerCase()) {
      'medium' => deliveryWeightMedium,
      'large' => deliveryWeightLarge,
      _ => deliveryWeightSmall,
    };
    final fragile = isFragile ? deliveryFragileSurcharge : 0.0;
    final helpers = requiresHelpers ? deliveryHelperSurcharge : 0.0;
    final fare = base + (perKm * distanceKm) + weightSurcharge + fragile + helpers;
    return DeliveryFareBreakdown(
      baseFare: base,
      distanceCharge: perKm * distanceKm,
      weightSurcharge: weightSurcharge,
      fragileSurcharge: fragile,
      helperSurcharge: helpers,
      minimumFare: minFare,
      minimumApplied: fare < minFare,
      total: fare < minFare ? minFare : double.parse(fare.toStringAsFixed(2)),
    );
  }

  double calculateGasFare(String cylinderSize, int quantity) {
    final unitPrice = switch (
        cylinderSize.toLowerCase().replaceAll(' ', '').replaceAll('.', '')) {
      '3kg' => gasCylinder3kg,
      '6kg' => gasCylinder6kg,
      '125kg' => gasCylinder12kg,
      '12kg' => gasCylinder12kg,
      '145kg' => gasCylinder14kg,
      '14kg' => gasCylinder14kg,
      '19kg' => gasCylinder19kg,
      '45kg' => gasCylinder45kg,
      _ => gasCylinder6kg,
    };
    return double.parse(
        ((unitPrice * quantity) + gasDeliveryFee).toStringAsFixed(2));
  }

  /// Get price for a specific cylinder size by weight
  double gasPriceForWeight(double weightKg) {
    if (weightKg <= 3) return gasCylinder3kg;
    if (weightKg <= 6) return gasCylinder6kg;
    if (weightKg <= 13) return gasCylinder12kg;
    if (weightKg <= 15) return gasCylinder14kg;
    if (weightKg <= 19) return gasCylinder19kg;
    return gasCylinder45kg;
  }
}

/// One delivery fare, itemised. [total] is what is charged: the sum of the
/// components (rounded), or [minimumFare] when the sum falls below it.
class DeliveryFareBreakdown {
  final double baseFare;
  final double distanceCharge;
  final double weightSurcharge;
  final double fragileSurcharge;
  final double helperSurcharge;
  final double minimumFare;
  final bool minimumApplied;
  final double total;

  const DeliveryFareBreakdown({
    required this.baseFare,
    required this.distanceCharge,
    required this.weightSurcharge,
    required this.fragileSurcharge,
    required this.helperSurcharge,
    required this.minimumFare,
    required this.minimumApplied,
    required this.total,
  });

  /// Base fare plus the per-km charge.
  double get distanceFare => baseFare + distanceCharge;
}
