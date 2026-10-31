// The completion code the receiver gives the rider, for Delivery and Gas
// orders. The server keeps it in order_completion_codes/{collection}_{id}
// (functions/completion_codes.js), readable only by the order's passenger,
// so the assigned driver can no longer read it from the order. Orders made
// by older app versions still carry their own `deliveryOtp`, which is used
// first.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The server-held code for (collection, orderId), or null until it exists.
final completionCodeProvider = StreamProvider.autoDispose
    .family<String?, (String, String)>((ref, key) {
  final (collection, orderId) = key;
  return watchCompletionCode(() => FirebaseFirestore.instance
      .collection('order_completion_codes')
      .doc('${collection}_$orderId')
      .snapshots()
      .map((s) => s.data()?['code'] as String?));
});

/// Waits between listens while the code cannot be read yet: ~2.5 minutes
/// in all, then the listener gives up.
const completionCodeRetryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
  Duration(seconds: 30),
  Duration(seconds: 30),
  Duration(seconds: 60),
];

/// Listens to [listen], listening again after each delay in [retryDelays]
/// when it is denied. The record is written by the order's create trigger
/// (functions/notifications.js) moments after the app creates the order,
/// and the rules can only grant a read of an existing record to its
/// passenger: a listen started before then is denied and Firestore ends it.
/// Any other error, or a denial after the last retry, ends the stream.
Stream<String?> watchCompletionCode(Stream<String?> Function() listen,
    {List<Duration> retryDelays = completionCodeRetryDelays}) async* {
  for (var attempt = 0;; attempt++) {
    try {
      await for (final code in listen()) {
        yield code;
      }
      return;
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied' || attempt >= retryDelays.length) {
        rethrow;
      }
      await Future<void>.delayed(retryDelays[attempt]);
    }
  }
}

/// The code to show: the order's own (older orders) or the server-held one.
String? completionCodeFor(WidgetRef ref, String collection, String orderId,
    String? orderCode) {
  if (orderCode != null && orderCode.isNotEmpty) return orderCode;
  return pickCompletionCode(
      orderCode, ref.watch(completionCodeProvider((collection, orderId))));
}

/// Pure: the order's own code first, else a loaded server-held code.
String? pickCompletionCode(String? orderCode, AsyncValue<String?> held) {
  if (orderCode != null && orderCode.isNotEmpty) return orderCode;
  final code = held.hasValue ? held.value : null;
  return (code != null && code.isNotEmpty) ? code : null;
}
