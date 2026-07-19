// lib/features/profile/presentation/profile_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/routes/app_routes.dart';
import '../../auth/providers/auth_providers.dart';

// ── Tokens ────────────────────────────────────────────────────────────────────
const _kPrimary = Color(0xFF16A34A);
const _kPrimaryDim = Color(0xFFDCFCE7);
const _kBg = Color(0xFFF8FAF9);
const _kSurface = Colors.white;
const _kBorder = Color(0xFFE5E7EB);
const _kBorderLight = Color(0xFFF3F4F6);
const _kError = Color(0xFFDC2626);
const _kErrorLight = Color(0xFFFEE2E2);
const _kTextPrimary = Color(0xFF111827);
const _kTextSecond = Color(0xFF6B7280);
const _kTextTertiary = Color(0xFF9CA3AF);

// ── Providers ─────────────────────────────────────────────────────────────────
final userStreamProvider = StreamProvider.autoDispose<UserData?>((ref) {
  final uid = ref.watch(userIdProvider);
  if (uid == null) return Stream.value(null);
  return FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .snapshots()
      .map((doc) => doc.exists ? UserData.fromFirestore(doc) : null);
});

// ── Screen ────────────────────────────────────────────────────────────────────
class ProfileScreen extends ConsumerWidget {
  final ScrollController scrollController;
  const ProfileScreen({super.key, required this.scrollController});

  static const _menuItems = [
    (
      icon: Icons.edit_rounded,
      label: 'Edit Profile',
      route: AppRoutes.editProfile
    ),
    (
      icon: Icons.location_on_rounded,
      label: 'Saved Places',
      route: AppRoutes.savedPlaces
    ),
    (
      icon: Icons.lock_rounded,
      label: 'Privacy & Security',
      route: AppRoutes.privacySecurity
    ),
    (
      icon: Icons.help_rounded,
      label: 'Help & Support',
      route: AppRoutes.helpSupport
    ),
    (
      icon: Icons.info_rounded,
      label: 'About CTSTransport',
      route: AppRoutes.about
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(userStreamProvider);

    return Scaffold(
      backgroundColor: _kBg,
      body: SingleChildScrollView(
        controller: scrollController,
        physics: const BouncingScrollPhysics(),
        child: Column(
          children: [
            userAsync.when(
              data: (u) => _ProfileHeader(user: u),
              loading: () => const _ProfileHeader(user: null),
              error: (_, __) => const _ProfileHeader(user: null),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _MenuCard(items: _menuItems),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _LogoutButton(
                onTap: () => _confirmLogout(context, ref),
              ),
            ),
            const SizedBox(height: 24),
            const Text('CTSTransport v1.0.0',
                style: TextStyle(fontSize: 11, color: _kTextTertiary)),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  void _confirmLogout(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Log out?',
            style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await ref.read(authNotifierProvider.notifier).signOut();
              } catch (_) {}
              if (context.mounted) {
                Navigator.of(context, rootNavigator: true)
                    .pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
              }
            },
            style: FilledButton.styleFrom(backgroundColor: _kError),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
  }
}

// ── Profile header ────────────────────────────────────────────────────────────
class _ProfileHeader extends StatelessWidget {
  final UserData? user;
  const _ProfileHeader({required this.user});

  String get _displayName {
    if (user?.displayName?.isNotEmpty == true) return user!.displayName!;
    final parts = [user?.firstName, user?.lastName]
        .where((s) => s?.isNotEmpty == true)
        .join(' ');
    return parts.isNotEmpty ? parts : 'Passenger';
  }

  String get _initials {
    final parts = _displayName.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return _displayName.isNotEmpty ? _displayName[0].toUpperCase() : 'P';
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      width: double.infinity,
      color: _kSurface,
      padding: EdgeInsets.fromLTRB(20, top + 24, 20, 28),
      child: Column(
        children: [
          // Avatar
          Stack(
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _kBorder, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.07),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: user?.photoURL?.isNotEmpty == true
                      ? Image.network(
                          user!.photoURL!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _fallback(),
                        )
                      : _fallback(),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onTap: () =>
                      Navigator.pushNamed(context, AppRoutes.editProfile),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _kPrimary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(Icons.camera_alt_rounded,
                        size: 13, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Name
          user == null
              ? _Skeleton(width: 140, height: 18)
              : Text(_displayName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: _kTextPrimary,
                  )),

          const SizedBox(height: 6),

          // Phone / email
          user == null
              ? _Skeleton(width: 110, height: 13)
              : Text(
                  user!.phoneNumber ?? user!.email ?? '',
                  style: const TextStyle(
                    fontSize: 13,
                    color: _kTextSecond,
                  ),
                ),
        ],
      ),
    );
  }

  Widget _fallback() => Container(
        color: _kPrimaryDim,
        child: Center(
          child: Text(_initials,
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: _kPrimary,
              )),
        ),
      );
}

// ── Skeleton ──────────────────────────────────────────────────────────────────
class _Skeleton extends StatelessWidget {
  final double width;
  final double height;
  const _Skeleton({required this.width, required this.height});

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: _kBorder,
          borderRadius: BorderRadius.circular(4),
        ),
      );
}

// ── Menu card ─────────────────────────────────────────────────────────────────
class _MenuCard extends StatelessWidget {
  final List<({IconData icon, String label, String route})> items;
  const _MenuCard({required this.items});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: _kSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _kBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: items.asMap().entries.map((e) {
            final i = e.key;
            final item = e.value;
            final isFirst = i == 0;
            final isLast = i == items.length - 1;
            return Column(
              children: [
                InkWell(
                  onTap: () => Navigator.pushNamed(context, item.route),
                  borderRadius: BorderRadius.only(
                    topLeft: isFirst ? const Radius.circular(16) : Radius.zero,
                    topRight: isFirst ? const Radius.circular(16) : Radius.zero,
                    bottomLeft:
                        isLast ? const Radius.circular(16) : Radius.zero,
                    bottomRight:
                        isLast ? const Radius.circular(16) : Radius.zero,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 13),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: _kPrimaryDim,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(item.icon, size: 18, color: _kPrimary),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(item.label,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: _kTextPrimary,
                              )),
                        ),
                        const Icon(Icons.chevron_right_rounded,
                            color: _kTextTertiary, size: 18),
                      ],
                    ),
                  ),
                ),
                if (!isLast)
                  const Divider(
                    height: 0.5,
                    thickness: 0.5,
                    indent: 66,
                    color: _kBorderLight,
                  ),
              ],
            );
          }).toList(),
        ),
      );
}

// ── Logout button ─────────────────────────────────────────────────────────────
class _LogoutButton extends StatelessWidget {
  final VoidCallback onTap;
  const _LogoutButton({required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _kErrorLight,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _kError.withValues(alpha: 0.2)),
          ),
          child: const Row(
            children: [
              Icon(Icons.logout_rounded, color: _kError, size: 20),
              SizedBox(width: 12),
              Text('Log Out',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _kError,
                  )),
            ],
          ),
        ),
      );
}

// ── Avatar widget — shared ────────────────────────────────────────────────────
class AvatarWidget extends StatelessWidget {
  final String? photoURL;
  final String displayName;
  final double radius;

  const AvatarWidget({
    super.key,
    required this.photoURL,
    required this.displayName,
    this.radius = 40,
  });

  Color get _bgColor {
    const colors = [
      Color(0xFF16A34A),
      Color(0xFF0284C7),
      Color(0xFF7C3AED),
      Color(0xFFDB2777),
      Color(0xFFD97706),
      Color(0xFF0891B2),
    ];
    return colors[
        displayName.codeUnits.fold(0, (a, b) => a + b) % colors.length];
  }

  String get _initials {
    final parts = displayName.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return displayName.isNotEmpty ? displayName[0].toUpperCase() : 'P';
  }

  @override
  Widget build(BuildContext context) {
    if (photoURL?.isNotEmpty == true) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: NetworkImage(photoURL!),
        backgroundColor: _bgColor,
        onBackgroundImageError: (_, __) {},
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: _bgColor,
      child: Text(_initials,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: radius * 0.5,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          )),
    );
  }
}
