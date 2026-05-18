import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final List<_NotifGroup> _groups = [
    _NotifGroup(
      label: 'Today',
      items: [
        _NotifItem(
          icon: Icons.directions_car_rounded,
          iconColor: AppColors.primary,
          iconBg: const Color(0xFFFFF1EC),
          title: 'Driver arrived 🚗',
          body: 'Ahmed K. is waiting at your pickup location on Osu.',
          time: '2m ago',
          isRead: false,
        ),
        _NotifItem(
          icon: Icons.card_giftcard_rounded,
          iconColor: const Color(0xFF9333EA),
          iconBg: const Color(0xFFF3E8FF),
          title: 'Promo unlocked 🎉',
          body: "You've earned 20% off your next 3 rides this week!",
          time: '1h ago',
          isRead: false,
        ),
        _NotifItem(
          icon: Icons.inventory_2_rounded,
          iconColor: AppColors.info,
          iconBg: AppColors.infoLight,
          title: 'Delivery confirmed 📦',
          body: 'Your parcel to East Legon has been picked up by Kofi M.',
          time: '3h ago',
          isRead: false,
        ),
      ],
    ),
    _NotifGroup(
      label: 'Yesterday',
      items: [
        _NotifItem(
          icon: Icons.check_circle_rounded,
          iconColor: AppColors.success,
          iconBg: AppColors.successLight,
          title: 'Ride completed ✓',
          body: 'Your trip to Accra Mall was GHS 18.00. Rate your driver.',
          time: '1d ago',
          isRead: true,
        ),
        _NotifItem(
          icon: Icons.account_balance_wallet_rounded,
          iconColor: AppColors.success,
          iconBg: AppColors.successLight,
          title: 'Top up successful 💳',
          body: 'GHS 100.00 has been added to your CTSRide wallet.',
          time: '1d ago',
          isRead: true,
        ),
        _NotifItem(
          icon: Icons.people_rounded,
          iconColor: AppColors.warning,
          iconBg: AppColors.warningLight,
          title: 'Referral bonus 🎁',
          body: 'Your friend Ama joined CTSRide! GHS 5 added to your wallet.',
          time: '2d ago',
          isRead: true,
        ),
      ],
    ),
    _NotifGroup(
      label: 'Earlier',
      items: [
        _NotifItem(
          icon: Icons.local_offer_rounded,
          iconColor: AppColors.primary,
          iconBg: const Color(0xFFFFF1EC),
          title: 'Weekend special 🌟',
          body: 'Get 15% off all Okada rides this Saturday and Sunday.',
          time: '3d ago',
          isRead: true,
        ),
        _NotifItem(
          icon: Icons.security_rounded,
          iconColor: AppColors.textSecondary,
          iconBg: AppColors.surfaceAlt,
          title: 'New login detected',
          body: 'We noticed a new sign-in to your account from Accra.',
          time: '4d ago',
          isRead: true,
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final unreadCount =
        _groups.expand((g) => g.items).where((i) => !i.isRead).length;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: CTSRideAppBar(
        title: 'Notifications',
        actions: [
          if (unreadCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: GestureDetector(
                onTap: _markAllRead,
                child: Text(
                  'Mark all read',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: unreadCount == 0 &&
              _groups.every((g) => g.items.every((i) => i.isRead))
          ? _buildEmpty()
          : ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: _groups.map((group) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _GroupHeader(label: group.label),
                    ...group.items.map((item) => _NotifTile(
                          item: item,
                          onTap: () => setState(() => item.isRead = true),
                          onDismiss: () =>
                              setState(() => group.items.remove(item)),
                        )),
                  ],
                );
              }).toList(),
            ),
    );
  }

  void _markAllRead() {
    setState(() {
      for (final group in _groups) {
        for (final item in group.items) {
          item.isRead = true;
        }
      }
    });
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.notifications_off_rounded,
              size: 56, color: AppColors.textTertiary),
          SizedBox(height: 12),
          Text('All caught up!', style: AppTextStyles.heading4),
          SizedBox(height: 6),
          Text('No new notifications', style: AppTextStyles.bodySmall),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  const _GroupHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        label,
        style: AppTextStyles.caption.copyWith(
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _NotifTile extends StatelessWidget {
  final _NotifItem item;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  const _NotifTile({
    required this.item,
    required this.onTap,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey(item.title + item.time),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: AppColors.error,
        child: const Icon(Icons.delete_rounded,
            color: AppColors.background, size: 22),
      ),
      onDismissed: (_) => onDismiss(),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          color:
              item.isRead ? AppColors.surface : AppColors.primary.withValues(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Icon
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: item.iconBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(item.icon, color: item.iconColor, size: 20),
              ),
              const SizedBox(width: 12),
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: AppTextStyles.labelLarge.copyWith(
                        fontWeight:
                            item.isRead ? FontWeight.w500 : FontWeight.w700,
                        color: item.isRead
                            ? AppColors.textSecondary
                            : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.body,
                      style: AppTextStyles.caption.copyWith(
                        color: item.isRead
                            ? AppColors.textTertiary
                            : AppColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Time + unread dot
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(item.time, style: AppTextStyles.caption),
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
}

class _NotifGroup {
  final String label;
  final List<_NotifItem> items;
  _NotifGroup({required this.label, required this.items});
}

class _NotifItem {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String body;
  final String time;
  bool isRead;

  _NotifItem({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.body,
    required this.time,
    required this.isRead,
  });
}
