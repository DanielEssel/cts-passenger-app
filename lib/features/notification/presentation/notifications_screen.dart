// lib/features/notifications/presentation/notifications_screen.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../models/notification_item.dart';
import '../providers/notification_providers.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifAsync = ref.watch(notificationsStreamProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(context, ref, notifAsync.value ?? []),
      body: notifAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => _ErrorState(message: e.toString()),
        data:    (items) => items.isEmpty
            ? const _EmptyState()
            : _NotifList(items: items),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    WidgetRef ref,
    List<NotificationItem> items,
  ) {
    final unread = items.where((n) => !n.isRead).length;

    return AppBar(
      backgroundColor:  AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      title: Row(
        children: [
          Text('Notifications', style: AppTextStyles.heading4),
          if (unread > 0) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$unread',
                style: AppTextStyles.captionSmall.copyWith(
                  color:      Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (unread > 0)
          TextButton(
            onPressed: () async {
              final uid = FirebaseAuth.instance.currentUser?.uid;
              if (uid == null) return;
              await markAllNotificationsRead(uid, items);
            },
            child: Text(
              'Mark all read',
              style: AppTextStyles.caption.copyWith(
                color:      AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(0.5),
        child: Divider(height: 0.5, thickness: 0.5),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Notification list with grouping
// ─────────────────────────────────────────────

class _NotifList extends StatelessWidget {
  final List<NotificationItem> items;
  const _NotifList({required this.items});

  Map<String, List<NotificationItem>> get _grouped {
    final map = <String, List<NotificationItem>>{};
    const order = ['Today', 'Yesterday', 'This week', 'Earlier'];
    for (final key in order) {
      final group = items.where((n) => n.groupKey == key).toList();
      if (group.isNotEmpty) map[key] = group;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _grouped;
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final entry in grouped.entries) ...[
          _GroupHeader(label: entry.key),
          for (final item in entry.value)
            _NotifTile(item: item),
        ],
        const SizedBox(height: 32),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// Group header
// ─────────────────────────────────────────────

class _GroupHeader extends StatelessWidget {
  final String label;
  const _GroupHeader({required this.label});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(
          label.toUpperCase(),
          style: AppTextStyles.captionSmall.copyWith(
            color:         AppColors.textTertiary,
            fontWeight:    FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      );
}

// ─────────────────────────────────────────────
// Notification tile
// ─────────────────────────────────────────────

class _NotifTile extends ConsumerWidget {
  final NotificationItem item;
  const _NotifTile({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key:       ValueKey(item.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding:   const EdgeInsets.only(right: 20),
        color:     AppColors.error,
        child:     const Icon(Icons.delete_rounded,
            color: Colors.white, size: 22),
      ),
      onDismissed: (_) async {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          await deleteNotification(uid, item.id);
        }
      },
      child: InkWell(
        onTap: () => _handleTap(context),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          color: item.isRead
              ? AppColors.surface
              : AppColors.primary.withValues(alpha: 0.04),
          padding: const EdgeInsets.symmetric(
              horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Icon ──
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color:         item.iconBg,
                  borderRadius:  BorderRadius.circular(13),
                ),
                child: Icon(item.icon,
                    color: item.iconColor, size: 21),
              ),
              const SizedBox(width: 12),

              // ── Content ──
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: AppTextStyles.labelLarge.copyWith(
                        fontWeight: item.isRead
                            ? FontWeight.w500
                            : FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.body,
                      style: AppTextStyles.caption.copyWith(
                        color:  item.isRead
                            ? AppColors.textTertiary
                            : AppColors.textSecondary,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),

              // ── Time + unread dot ──
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    item.timeAgo,
                    style: AppTextStyles.captionSmall.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (!item.isRead)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleTap(BuildContext context) async {
    // Mark as read
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && !item.isRead) {
      await markNotificationRead(uid, item.id);
    }

    // Navigate to route
    if (!context.mounted || item.route == null) return;
    _navigateToRoute(context, item.route!, item);
  }

  void _navigateToRoute(
    BuildContext context,
    String route,
    NotificationItem item,
  ) {
    // Parse route and navigate with correct arguments
    if (route.contains('ride-tracking')) {
      final tripId = item.metadata['tripId'] as String?;
      if (tripId != null) {
        Navigator.pushNamed(context, '/ride-tracking',
            arguments: tripId);
      }
      return;
    }

    if (route.contains('gas-tracking')) {
      final orderId = item.metadata['orderId'] as String?;
      if (orderId != null) {
        Navigator.pushNamed(context, '/gas-tracking',
            arguments: {'orderId': orderId});
      }
      return;
    }

    if (route.contains('delivery-tracking')) {
      final deliveryId = item.metadata['deliveryId'] as String?;
      if (deliveryId != null) {
        Navigator.pushNamed(context, '/delivery-tracking',
            arguments: {'deliveryId': deliveryId});
      }
      return;
    }

    if (route.contains('trip-complete')) {
      final tripId = item.metadata['tripId'] as String?;
      if (tripId != null) {
        Navigator.pushNamed(context, '/trip-complete',
            arguments: {'tripId': tripId});
      }
      return;
    }

    if (route == '/shell') {
      Navigator.pushNamedAndRemoveUntil(
          context, '/shell', (_) => false);
      return;
    }

    // Fallback — push the raw route
    Navigator.pushNamed(context, route);
  }
}

// ─────────────────────────────────────────────
// Empty & error states
// ─────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.notifications_off_rounded,
                size: 34,
                color: AppColors.textTertiary,
              ),
            ),
            const SizedBox(height: 16),
            const Text('All caught up!',
                style: AppTextStyles.heading4),
            const SizedBox(height: 6),
            Text(
              'No notifications yet.\nWe\'ll let you know when something happens.',
              style: AppTextStyles.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  const _ErrorState({required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColors.textTertiary),
              const SizedBox(height: 12),
              const Text('Could not load notifications',
                  style: AppTextStyles.heading4),
              const SizedBox(height: 6),
              Text(message,
                  style: AppTextStyles.caption,
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}