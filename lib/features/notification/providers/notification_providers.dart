import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/notification_item.dart';

// ── Stream of all notifications ───────────────────────────────────────────────

final notificationsStreamProvider =
    StreamProvider.autoDispose<List<NotificationItem>>((ref) {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return Stream.value([]);

  return FirebaseFirestore.instance
      .collection('notifications')
      .doc(uid)
      .collection('items')
      .orderBy('createdAt', descending: true)
      .limit(50)
      .snapshots()
      .map((snap) =>
          snap.docs.map(NotificationItem.fromFirestore).toList());
});

// ── Unread count — used for bottom nav badge ──────────────────────────────────

final unreadNotifCountProvider = StreamProvider.autoDispose<int>((ref) {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return Stream.value(0);

  return FirebaseFirestore.instance
      .collection('notifications')
      .doc(uid)
      .collection('items')
      .where('isRead', isEqualTo: false)
      .snapshots()
      .map((snap) => snap.docs.length);
});

// ── Actions ───────────────────────────────────────────────────────────────────

Future<void> markNotificationRead(String uid, String notifId) async {
  await FirebaseFirestore.instance
      .collection('notifications')
      .doc(uid)
      .collection('items')
      .doc(notifId)
      .update({'isRead': true});
}

Future<void> markAllNotificationsRead(
    String uid, List<NotificationItem> items) async {
  final unread = items.where((n) => !n.isRead).toList();
  if (unread.isEmpty) return;

  final batch = FirebaseFirestore.instance.batch();
  for (final n in unread) {
    final ref = FirebaseFirestore.instance
        .collection('notifications')
        .doc(uid)
        .collection('items')
        .doc(n.id);
    batch.update(ref, {'isRead': true});
  }
  await batch.commit();
}

Future<void> deleteNotification(String uid, String notifId) async {
  await FirebaseFirestore.instance
      .collection('notifications')
      .doc(uid)
      .collection('items')
      .doc(notifId)
      .delete();
}