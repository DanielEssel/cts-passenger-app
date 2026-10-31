// Gas supplier ordering: values as the server returns them
// (functions/gas_supplier_orders.js, gas_supplier_fulfilment.js). Prices
// and totals are never computed here: they are shown as the server quoted.
import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

/// Order types a supplier order can be paid for. pickupAndReturn needs a
/// pickup leg the fulfilment does not support yet, so it is not offered.
const supplierOrderTypes = ['exchangeEmpty', 'newCylinder', 'commercialBulk'];

const cylinderSizes = ['kg3', 'kg6', 'kg12_5', 'kg14_5', 'kg19', 'kg45'];

/// One order type and cylinder size that can be ordered at an address.
typedef GasOffer = ({String orderType, String cylinderSize});

/// The server's `offered` list, keeping only types and sizes the app orders,
/// in the app's order.
List<GasOffer> parseOffered(Object? raw) {
  final out = <GasOffer>[];
  for (final o in raw is List ? raw : const []) {
    if (o is! Map) continue;
    final t = o['orderType'], s = o['cylinderSize'];
    if (supplierOrderTypes.contains(t) && cylinderSizes.contains(s)) out.add((orderType: t as String, cylinderSize: s as String));
  }
  int rank(GasOffer o) => supplierOrderTypes.indexOf(o.orderType) * cylinderSizes.length + cylinderSizes.indexOf(o.cylinderSize);
  out.sort((a, b) => rank(a) - rank(b));
  return out;
}

/// The order types offered, in the app's order.
List<String> offeredTypes(List<GasOffer> offered) => [for (final t in supplierOrderTypes) if (offered.any((o) => o.orderType == t)) t];

/// The sizes offered for [orderType], in the app's order.
List<String> offeredSizes(List<GasOffer> offered, String orderType) =>
    [for (final s in cylinderSizes) if (offered.any((o) => o.orderType == orderType && o.cylinderSize == s)) s];

/// What to select at an address: the current type and size when still
/// offered, else the current type with its first offered size, else the
/// first offered type and size; null when nothing is offered there.
GasOffer? selectionFor(List<GasOffer> offered, {required String orderType, required String cylinderSize}) {
  if (offered.isEmpty) return null;
  final type = offeredTypes(offered).contains(orderType) ? orderType : offeredTypes(offered).first;
  final sizes = offeredSizes(offered, type);
  return (orderType: type, cylinderSize: sizes.contains(cylinderSize) ? cylinderSize : sizes.first);
}

const _labels = {
  'exchangeEmpty': 'Exchange empty cylinder',
  'newCylinder': 'New cylinder',
  'commercialBulk': 'Commercial bulk',
  'kg3': '3 kg', 'kg6': '6 kg', 'kg12_5': '12.5 kg', 'kg14_5': '14.5 kg', 'kg19': '19 kg', 'kg45': '45 kg',
};

String gasLabel(String v) => _labels[v] ?? v;

/// Status names the backend writes, with what the passenger sees.
const supplierOrderStatusLabels = {
  'awaiting_payment': 'Waiting for your payment',
  'pendingApproval': 'Paid · waiting for the supplier',
  'confirmed': 'Supplier confirmed · finding a driver',
  'driverAssigned': 'Driver on the way to the station',
  'atStation': 'Driver at the station',
  'outForDelivery': 'On the way to you',
  'delivered': 'Delivered',
  'cancelled': 'Cancelled',
};

String supplierOrderStatusLabel(String status) => supplierOrderStatusLabels[status] ?? status;

/// The status label for an order delivered in [deliveryMode] (set when the
/// supplier accepts): a confirmed order is only "finding a driver" when a
/// CTSGo driver (or the supplier's linked rider) is still to be found.
String supplierOrderStatusLabelFor(String status, String? deliveryMode) => status != 'confirmed'
    ? supplierOrderStatusLabel(status)
    : switch (deliveryMode) {
        'supplier_rider' => 'Supplier confirmed · preparing your order',
        'linked_rider' => "Supplier confirmed · assigning the supplier's rider",
        _ => supplierOrderStatusLabel(status),
      };

/// Why an order was cancelled, for the passenger. Supplier and admin reasons
/// are their own words; the server's own reasons are codes.
String supplierCancelReasonLabel(String reason) => switch (reason) {
      'supplier_no_response' => 'The supplier did not respond in time.',
      _ => reason,
    };

/// The passenger may cancel until a driver is assigned (PASSENGER_CANCELLABLE).
bool passengerCanCancel(String status) => const ['awaiting_payment', 'pendingApproval', 'confirmed'].contains(status);

/// The code is shown once a driver is bringing the order.
bool showCompletionCode(String status) => const ['driverAssigned', 'atStation', 'outForDelivery'].contains(status);

/// Lifecycle steps for the tracking screen.
const supplierOrderSteps = ['pendingApproval', 'confirmed', 'driverAssigned', 'atStation', 'outForDelivery', 'delivered'];

/// The steps an order goes through: the supplier's own rider skips the CTSGo
/// driver's steps (deliveryMode "supplier_rider", set when the supplier accepts).
List<String> supplierOrderStepsFor(String? deliveryMode) => deliveryMode == 'supplier_rider'
    ? const ['pendingApproval', 'confirmed', 'outForDelivery', 'delivered']
    : supplierOrderSteps;

double? _num(Object? v) => v is num ? v.toDouble() : null;

class GasSupplierOption {
  final String supplierId, supplierName, stationId, stationName, productId, brand;
  final double? price, distanceKm;
  const GasSupplierOption({required this.supplierId, required this.supplierName, required this.stationId, required this.stationName,
    required this.productId, required this.brand, this.price, this.distanceKm});

  factory GasSupplierOption.fromMap(Map<String, dynamic> m) => GasSupplierOption(
        supplierId: '${m['supplierId']}', supplierName: '${m['supplierName'] ?? ''}',
        stationId: '${m['stationId']}', stationName: '${m['stationName'] ?? ''}',
        productId: '${m['productId']}', brand: '${m['brand'] ?? ''}',
        price: _num(m['price'] ?? m['unitPrice']), distanceKm: _num(m['distanceKm']),
      );
}

int? _int(Object? v) => v is num ? v.toInt() : null;

/// The server's delivery estimate (gas_supplier_orders.js computeEta), in
/// whole minutes from payment: the supplier's answer time, preparation,
/// refilling where the order needs it, and the measured driving time.
class GasSupplierEta {
  final int minutes, driveMinutes;
  const GasSupplierEta({required this.minutes, required this.driveMinutes});

  /// Null when the server sent no usable estimate: none is guessed here.
  static GasSupplierEta? fromMap(Object? v) {
    if (v is! Map) return null;
    final minutes = _int(v['minutes']), drive = _int(v['driveMinutes']);
    return minutes == null || drive == null ? null : GasSupplierEta(minutes: minutes, driveMinutes: drive);
  }
}

/// "45 min" or "1 h 05 min".
String gasDurationLabel(int minutes) =>
    minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')} min';

class GasSupplierQuote {
  final String quoteId;
  final DateTime expiresAt;
  final double unitPrice, productAmount, handlingFee, deliveryFee, total;
  final int quantity;

  /// The road route the delivery fee was priced on, from the supplier's station.
  final double? routeDistanceKm;
  final GasSupplierEta? eta;

  /// What the server priced (selection in the quote response).
  final String? supplierName, stationName, brand, orderType, cylinderSize;
  const GasSupplierQuote({required this.quoteId, required this.expiresAt, required this.unitPrice, required this.quantity,
    required this.productAmount, required this.handlingFee, required this.deliveryFee, required this.total,
    this.routeDistanceKm, this.eta, this.supplierName, this.stationName, this.brand, this.orderType, this.cylinderSize});

  factory GasSupplierQuote.fromMap(Map<String, dynamic> m) {
    final p = Map<String, dynamic>.from(m['pricing'] as Map);
    final s = m['selection'] is Map ? Map<String, dynamic>.from(m['selection'] as Map) : const <String, dynamic>{};
    final meters = _num(p['routeDistanceMeters']);
    return GasSupplierQuote(
      quoteId: '${m['quoteId']}',
      expiresAt: DateTime.fromMillisecondsSinceEpoch((m['expiresAt'] as num).toInt()),
      unitPrice: _num(p['unitPrice']) ?? 0, quantity: (p['quantity'] as num?)?.toInt() ?? 0,
      productAmount: _num(p['productAmount']) ?? 0, handlingFee: _num(p['handlingFee']) ?? 0,
      deliveryFee: _num(p['deliveryFee']) ?? 0, total: _num(p['total']) ?? 0,
      routeDistanceKm: meters == null ? null : meters / 1000,
      eta: GasSupplierEta.fromMap(p['eta']),
      supplierName: s['supplierName'] as String?, stationName: s['stationName'] as String?, brand: s['brand'] as String?,
      orderType: s['orderType'] as String?, cylinderSize: s['cylinderSize'] as String?,
    );
  }

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);
}

class GasSupplierOrderView {
  final String id, status;
  final double? total, deliveryFee, routeDistanceKm;
  final String? completionCode, cancelReason, deliveryMode;
  final String? orderType, cylinderSize, brand;
  final int? quantity;

  /// Payment time + the quoted ETA (gas_supplier_fulfilment.js pay); null
  /// before payment or for an order quoted without an ETA.
  final DateTime? estimatedDeliveryAt;
  final bool refundPending;

  /// payment.status as the server records it: "held" (paid, in escrow),
  /// "captured" (delivered) or "refunded"; null when never paid.
  final String? paymentStatus;

  /// The server could not finish the refund on its own (refundReview set):
  /// CTSGo support reviews it.
  final bool refundReview;
  final String? deliveryAddress;
  const GasSupplierOrderView({required this.id, required this.status, this.total, this.completionCode, this.cancelReason, this.deliveryMode,
    this.refundPending = false, this.deliveryFee, this.routeDistanceKm, this.orderType, this.cylinderSize, this.brand, this.quantity,
    this.estimatedDeliveryAt, this.paymentStatus, this.refundReview = false, this.deliveryAddress});

  factory GasSupplierOrderView.fromMap(String id, Map<String, dynamic> m) {
    final p = m['priceSnapshot'] is Map ? Map<String, dynamic>.from(m['priceSnapshot'] as Map) : const <String, dynamic>{};
    final meters = _num(p['routeDistanceMeters']);
    final eta = m['estimatedDeliveryAt'];
    final payment = m['payment'] is Map ? Map<String, dynamic>.from(m['payment'] as Map) : const <String, dynamic>{};
    final review = m['refundReview'];
    return GasSupplierOrderView(
      paymentStatus: payment['status'] as String?,
      refundReview: review is String && review.isNotEmpty,
      deliveryAddress: m['deliveryAddress'] as String?,
      id: id, status: '${m['status']}',
      total: _num(p['total']), deliveryFee: _num(p['deliveryFee']),
      routeDistanceKm: meters == null ? null : meters / 1000,
      orderType: m['orderType'] as String?, cylinderSize: m['cylinderSize'] as String?, brand: p['brand'] as String?,
      quantity: _int(m['quantity']),
      estimatedDeliveryAt: eta is Timestamp ? eta.toDate() : (eta is DateTime ? eta : null),
      completionCode: m['completionCode'] as String?,
      cancelReason: m['cancelReason'] as String?,
      deliveryMode: m['deliveryMode'] as String?,
      refundPending: m['refundPending'] == true,
    );
  }
}

/// The payment line for an order, from its server state only: a refund is
/// "returned" only once payment.status is "refunded", and "paid" only once
/// the server holds or has captured the payment.
String supplierPaymentNote(GasSupplierOrderView o) {
  final total = o.total == null ? null : 'GH₵${o.total!.toStringAsFixed(2)}';
  if (o.status == 'cancelled') {
    if (o.paymentStatus == null) return 'Nothing was charged for this order.';
    if (o.paymentStatus == 'refunded') return '${total ?? 'Your payment'} has been returned to your wallet.';
    if (o.refundReview) return 'Your refund is being reviewed by CTSGo support. You do not need to do anything.';
    return 'Your refund is being processed.';
  }
  if (total == null) return '';
  if (o.status == 'delivered') return o.paymentStatus == 'captured' ? 'Paid $total from your wallet' : 'Total $total';
  return o.paymentStatus == 'held' ? 'Total $total · paid from your wallet' : 'Total $total · not paid yet';
}

/// A refused or failed server call, with a message for the passenger.
class GasSupplierFailure implements Exception {
  final String code;
  final String? reason;
  final String message;
  const GasSupplierFailure(this.code, this.reason, this.message);
  @override
  String toString() => 'GasSupplierFailure($code, $reason)';
}

const _reasonMessages = {
  'gas_supplier_fulfilment_disabled': 'Ordering from Gas suppliers is not available yet.',
  'quote_expired': 'This price has expired. Please get a new price.',
  'quote_stale': 'The price has changed. Please get a new price.',
  'price_changed': 'The price has changed. Please get a new price.',
  'product_unavailable': 'This product is no longer available. Please choose another.',
  'supplier_not_approved': 'This supplier is not available right now.',
  'supplier_orders_disabled': 'This supplier is not taking orders right now.',
  'station_not_verified': 'This station is not available right now.',
  'station_not_found': 'This station is not available right now.',
  'station_location_invalid': 'This station is not available right now.',
  'escrow_amount_mismatch': 'The payment did not match the order total. Nothing was charged.',
  'order_type_not_supported': 'This order type cannot be fulfilled yet.',
  'cannot_cancel': 'This order can no longer be cancelled.',
  'outside_service_area': 'No supplier delivers to this location.',
  // The delivery fee is priced on the road route measured by the server; if
  // it cannot be measured or the rates are unusable there is no price.
  'routing_timeout': _noRoute,
  'routing_failed': _noRoute,
  'route_unavailable': 'We couldn\'t find a road route to this location. Please check the address.',
  'route_distance_invalid': _noRoute,
  // The delivery time comes from the same measured route: no route time, no price.
  'route_duration_invalid': _noRoute,
  'routing_not_configured': _noPrice,
  'pricing_unavailable': _noPrice,
  'eta_config_invalid': _noPrice,
  'supplier_riders_not_supported': 'This supplier is not taking orders right now.',
  'invalid_location': 'Please choose a valid delivery address.',
  'invalid_address': 'Please choose a valid delivery address.',
  'quote_not_open': 'This price can no longer be used. Please get a new price.',
  // No approved CTSGo commission terms: the server takes no supplier order.
  'commission_terms_missing': _notTaking,
  'commission_terms_inactive': _notTaking,
  'commission_terms_unapproved': _notTaking,
};
const _notTaking = 'Gas supplier orders are not available right now.';
const _noRoute = 'We couldn\'t measure the delivery route. Please try again.';
const _noPrice = 'Gas prices are unavailable right now. Please try again later.';

/// The message for a server refusal reason, or the server's own message.
String gasSupplierMessage(String? reason, String fallback) => _reasonMessages[reason] ?? fallback;
