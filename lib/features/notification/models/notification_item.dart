import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';

class NotificationItem {
  final String              id;
  final String              type;
  final String              title;
  final String              body;
  final String?             route;
  final Map<String, dynamic> metadata;
  final bool                isRead;
  final DateTime?           createdAt;

  const NotificationItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.route,
    required this.metadata,
    required this.isRead,
    this.createdAt,
  });

  factory NotificationItem.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return NotificationItem(
      id:        doc.id,
      type:      d['type']  as String? ?? 'system',
      title:     d['title'] as String? ?? '',
      body:      d['body']  as String? ?? '',
      route:     d['route'] as String?,
      metadata:  Map<String, dynamic>.from(d['metadata'] as Map? ?? {}),
      isRead:    d['isRead'] as bool? ?? false,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  // ── Visual config per type ──────────────────────────────────────────────

  IconData get icon => switch (type) {
    'ride'     => Icons.directions_car_rounded,
    'gas'      => Icons.local_fire_department_rounded,
    'delivery' => Icons.inventory_2_rounded,
    'wallet'   => Icons.account_balance_wallet_rounded,
    'promo'    => Icons.local_offer_rounded,
    'security' => Icons.security_rounded,
    _          => Icons.notifications_rounded,
  };

  Color get iconColor => switch (type) {
    'ride'     => AppColors.primary,
    'gas'      => const Color(0xFFFF7A35),
    'delivery' => AppColors.info,
    'wallet'   => AppColors.success,
    'promo'    => const Color(0xFF9333EA),
    'security' => AppColors.textSecondary,
    _          => AppColors.primary,
  };

  Color get iconBg => switch (type) {
    'ride'     => AppColors.primaryDim,
    'gas'      => const Color(0xFFFFF1EC),
    'delivery' => AppColors.infoLight,
    'wallet'   => AppColors.successLight,
    'promo'    => const Color(0xFFF3E8FF),
    'security' => AppColors.surfaceAlt,
    _          => AppColors.primaryDim,
  };

  String get timeAgo {
    if (createdAt == null) return '';
    final diff = DateTime.now().difference(createdAt!);
    if (diff.inMinutes < 1)  return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24)   return '${diff.inHours}h ago';
    if (diff.inDays == 1)    return 'Yesterday';
    if (diff.inDays < 7)     return '${diff.inDays}d ago';
    return '${createdAt!.day}/${createdAt!.month}/${createdAt!.year}';
  }

  String get groupKey {
    if (createdAt == null) return 'Earlier';
    final diff = DateTime.now().difference(createdAt!).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7)  return 'This week';
    return 'Earlier';
  }
}