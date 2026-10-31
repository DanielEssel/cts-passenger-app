// Gas supplier ordering over the server's callables. The server prices,
// verifies payment and decides every transition; this only sends ids,
// choices and the passenger's location.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/services/escrow_service.dart';
import '../domain/gas_supplier_models.dart';

/// One callable invocation; Firebase in the app, a fake in tests.
typedef GasSupplierCall = Future<Map<String, dynamic>> Function(String name, Map<String, dynamic> data);

/// Holds wallet funds (escrow.js holdBalance); returns the escrow id.
typedef HoldFunds = Future<String> Function(double amount);

Future<Map<String, dynamic>> firebaseGasSupplierCall(String name, Map<String, dynamic> data) async {
  try {
    final r = await FirebaseFunctions.instanceFor(region: 'europe-west2').httpsCallable(name).call(data);
    return r.data == null ? <String, dynamic>{} : Map<String, dynamic>.from(r.data as Map);
  } on FirebaseFunctionsException catch (e) {
    final details = e.details is Map ? Map<String, dynamic>.from(e.details as Map) : const <String, dynamic>{};
    final reason = details['reason'] as String?;
    throw GasSupplierFailure(e.code, reason, gasSupplierMessage(reason, e.message ?? 'Something went wrong. Please try again.'));
  }
}

Future<String> escrowHold(double amount) async {
  final r = await EscrowService.instance.holdBalance(amount: amount, serviceType: 'gas', referenceType: 'gas_supplier_order');
  if (!r.success || r.escrowId == null) {
    throw GasSupplierFailure('failed-precondition', 'hold_failed', r.error ?? 'Your wallet payment could not be held.');
  }
  return r.escrowId!;
}

enum _HoldReturn { returned, boundToOrder, unknown }

/// Live view of one order; Firestore in the app, a fake in tests.
typedef WatchOrder = Stream<GasSupplierOrderView?> Function(String orderId);

/// The signed-in passenger's orders still in progress; Firestore in the app, a fake in tests.
typedef ActiveOrders = Future<List<GasSupplierOrderView>> Function();

class GasSupplierRepository {
  final GasSupplierCall call;
  final HoldFunds hold;
  final WatchOrder? _watch;
  final ActiveOrders? _active;

  GasSupplierRepository({GasSupplierCall? call, HoldFunds? hold, WatchOrder? watch, ActiveOrders? activeOrders})
      : call = call ?? firebaseGasSupplierCall,
        hold = hold ?? escrowHold,
        _watch = watch,
        _active = activeOrders;

  /// Whether supplier ordering is switched on (settings/gas_supplier_fulfilment).
  /// Any failure, including the callable not being deployed, counts as off.
  Future<bool> orderingAvailable() async {
    try {
      final r = await call('gasSupplierOrderingStatus', const {}).timeout(const Duration(seconds: 8));
      return r['enabled'] == true;
    } catch (_) {
      return false;
    }
  }

  /// The order types and sizes the server says can be ordered at this
  /// address now (listGasSupplierOptions with a location only), limited to
  /// those the app orders; null when the server cannot say (an older
  /// backend), so the caller keeps its full choice.
  Future<List<GasOffer>?> offeredAt({required double latitude, required double longitude}) async {
    try {
      final r = await call('listGasSupplierOptions', {'location': {'latitude': latitude, 'longitude': longitude}});
      return r.containsKey('offered') ? parseOffered(r['offered']) : null;
    } on GasSupplierFailure catch (e) {
      // An older backend refuses a request without a type and size.
      if (e.code == 'invalid-argument' && e.reason != 'invalid_location') return null;
      rethrow;
    }
  }

  Future<List<GasSupplierOption>> options({required String orderType, required String cylinderSize, required double latitude, required double longitude}) async {
    final r = await call('listGasSupplierOptions', {
      'orderType': orderType, 'cylinderSize': cylinderSize, 'location': {'latitude': latitude, 'longitude': longitude},
    });
    return [for (final o in (r['options'] as List? ?? const [])) GasSupplierOption.fromMap(Map<String, dynamic>.from(o as Map))];
  }

  Future<GasSupplierQuote> quote(GasSupplierOption o, {required int quantity, required double latitude, required double longitude, String? address}) async {
    final r = await call('quoteGasSupplierOrder', {
      'supplierId': o.supplierId, 'stationId': o.stationId, 'productId': o.productId, 'quantity': quantity,
      'location': {'latitude': latitude, 'longitude': longitude}, if (address != null && address.isNotEmpty) 'address': address,
    });
    return GasSupplierQuote.fromMap(r);
  }

  /// Creates the order from the quote (idempotent: the quote id is the order id),
  /// holds exactly the server's total, and has the server verify and attach it.
  /// If the server refuses the payment, the hold is returned at once.
  ///
  /// Safe to repeat after a lost response or a second tap: an order the
  /// server reports as already past payment is not held for again, a
  /// transport failure retries the (idempotent) payment with the same hold,
  /// and a hold the server already bound to the order is never refunded
  /// (refundEscrowOnError refuses it), which is how a paid order is told
  /// apart from a refused one.
  Future<String> placeAndPay(GasSupplierQuote q) async {
    // Never hold money for a flow that is switched off.
    if (!await orderingAvailable()) {
      throw GasSupplierFailure('unavailable', 'gas_supplier_fulfilment_disabled', gasSupplierMessage('gas_supplier_fulfilment_disabled', ''));
    }
    final created = await call('createGasSupplierOrder', {'quoteId': q.quoteId});
    final orderId = '${created['orderId']}';
    // A repeat for an order that is already paid (or cancelled): show it, hold nothing.
    final status = created['status'];
    if (status is String && status != 'awaiting_payment') return orderId;
    final total = (created['total'] as num).toDouble();
    final escrowId = await hold(total);
    final pay = {'orderId': orderId, 'escrowId': escrowId};
    try {
      try {
        await call('payGasSupplierOrder', pay);
      } catch (e) {
        if (!_transportFailure(e)) rethrow;
        await call('payGasSupplierOrder', pay);
      }
    } catch (e) {
      final refund = await _returnHold(escrowId);
      // The order was paid meanwhile (by this hold, or an earlier one).
      final reason = e is GasSupplierFailure ? e.reason : null;
      if (refund == _HoldReturn.boundToOrder || const ['order_not_awaiting_payment', 'order_already_paid'].contains(reason)) {
        return orderId;
      }
      rethrow;
    }
    return orderId;
  }

  /// Failures where the server may have run the call (a server refusal
  /// always carries a reason): the payment is retried with the same hold,
  /// which the server treats as already paid.
  static bool _transportFailure(Object e) =>
      e is! GasSupplierFailure ||
      (e.reason == null && const ['unavailable', 'deadline-exceeded', 'internal', 'unknown', 'aborted'].contains(e.code));

  Future<_HoldReturn> _returnHold(String escrowId) async {
    try {
      await call('refundEscrowOnError', {'escrowId': escrowId, 'reason': 'gas_supplier_payment_refused'});
      return _HoldReturn.returned;
    } on GasSupplierFailure catch (e) {
      // refundEscrowOnError refuses a hold that is attached to an order.
      return e.code == 'failed-precondition' ? _HoldReturn.boundToOrder : _HoldReturn.unknown;
    } catch (_) {
      // The stale-hold sweep returns an unattached hold later.
      return _HoldReturn.unknown;
    }
  }

  Future<void> cancel(String orderId) => call('cancelGasSupplierOrder', {'orderId': orderId});

  /// The passenger's own order (rules: the passenger may read it).
  Stream<GasSupplierOrderView?> watch(String orderId) {
    final injected = _watch;
    if (injected != null) return injected(orderId);
    return FirebaseFirestore.instance.collection('gas_supplier_orders').doc(orderId).snapshots()
        .map((s) => s.exists ? GasSupplierOrderView.fromMap(s.id, s.data()!) : null);
  }

  /// The passenger's paid orders that are not finished yet, so they can be
  /// tracked again after leaving the tracking screen. Equality filters only
  /// (no composite index); the rules allow a passenger to read their own.
  /// Any failure shows nothing rather than blocking ordering.
  Future<List<GasSupplierOrderView>> activeOrders() async {
    final injected = _active;
    try {
      if (injected != null) return await injected();
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return const [];
      final snap = await FirebaseFirestore.instance.collection('gas_supplier_orders')
          .where('passengerId', isEqualTo: uid)
          .where('status', whereIn: supplierOrderSteps.where((s) => s != 'delivered').toList())
          .get();
      return [for (final d in snap.docs) GasSupplierOrderView.fromMap(d.id, d.data())];
    } catch (_) {
      return const [];
    }
  }
}
