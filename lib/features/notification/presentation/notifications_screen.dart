// lib/features/notifications/presentation/notifications_screen.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/core/theme/cts_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/routes/deep_link.dart';
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
        error:   (e, _) {
          debugPrint('Notifications load error: $e');
          return const _ErrorState(
              message: 'Check your connection and try again.');
        },
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

    final canPop = Navigator.of(context).canPop();
    return AppBar(
      backgroundColor:  AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      // Same back control as the other account screens.
      automaticallyImplyLeading: false,
      leadingWidth: canPop ? 64 : null,
      leading: canPop
          ? const Padding(
              padding: EdgeInsets.only(left: 16),
              child: Center(child: CtsBackButton()),
            )
          : null,
      title: Row(
        children: [
          const Flexible(
            child: Text('Notifications',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CtsText.title3),
          ),
          if (unread > 0) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: CtsTheme.vivid,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$unread',
                semanticsLabel: '$unread unread',
                style: CtsText.caption.copyWith(
                  color:      CtsTheme.onVivid,
                  fontWeight: FontWeight.w800,
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
            child: const Text('Mark all read'),
          ),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(0.5),
        child: Divider(height: 0.5, thickness: 0.5, color: CtsTheme.border),
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
    if (route == AppRoutes.shell) {
      Navigator.pushNamedAndRemoveUntil(
          context, AppRoutes.shell, (_) => false);
      return;
    }

    // Parsed like a push tap (ids from the route's query, else the stored
    // metadata) and opened on the root navigator, as push taps are: it knows
    // every tracking route and shows "Route not found" for anything else.
    final link = DeepLink.parse(route, metadata: item.metadata);
    if (link == null) return;
    final requiredId = _requiredIds[link.path];
    if (requiredId != null && link.arguments?[requiredId] == null) return;
    Navigator.of(context, rootNavigator: true)
        .pushNamed(link.path, arguments: link.arguments);
  }

  static const _requiredIds = {
    AppRoutes.rideTracking: 'tripId',
    AppRoutes.tripComplete: 'tripId',
    AppRoutes.gasTracking: 'orderId',
    AppRoutes.deliveryTracking: 'deliveryId',
  };
}

// ─────────────────────────────────────────────
// Empty & error states
// ─────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Center(
        child: SingleChildScrollView(
          child: CtsEmptyState(
            icon: Icons.notifications_none_rounded,
            title: 'All caught up!',
            message:
                "No notifications yet.\nWe'll let you know when something happens.",
          ),
        ),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  const _ErrorState({required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          child: CtsEmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load notifications',
            message: message,
          ),
        ),
      );
}
