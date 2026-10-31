// lib/features/profile/presentation/profile_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../core/theme/cts_theme.dart';
import '../../../core/widgets/cts_ui.dart';
import '../../auth/providers/auth_providers.dart';

// ── Tokens (CTSGo design system) ─────────────────────────────────────────────
const _kBg = CtsTheme.background;
const _kSurface = CtsTheme.surface;
const _kBorder = CtsTheme.border;
const _kError = CtsTheme.error;

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

  // Everyday account settings first; privacy, help and app information
  // after. Routes are unchanged.
  static const _account = [
    (
      icon: Icons.person_rounded,
      label: 'Edit Profile',
      sub: 'Name, photo and email',
      route: AppRoutes.editProfile
    ),
    (
      icon: Icons.location_on_rounded,
      label: 'Saved Places',
      sub: 'Home, work and favourite addresses',
      route: AppRoutes.savedPlaces
    ),
  ];

  static const _more = [
    (
      icon: Icons.shield_rounded,
      label: 'Privacy & Security',
      sub: 'Biometrics, permissions and your data',
      route: AppRoutes.privacySecurity
    ),
    (
      icon: Icons.support_agent_rounded,
      label: 'Help & Support',
      sub: 'FAQs, contact us and trip issues',
      route: AppRoutes.helpSupport
    ),
    (
      icon: Icons.info_rounded,
      label: 'About CTSGo',
      sub: 'Version, terms and privacy policy',
      route: AppRoutes.about
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(userStreamProvider);

    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          controller: scrollController,
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const CtsPageTitle('Profile'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: ctsGutter),
                child: userAsync.when(
                  data: (u) => _IdentityCard(user: u, loading: false),
                  loading: () => const _IdentityCard(user: null, loading: true),
                  error: (_, __) =>
                      const _IdentityCard(user: null, loading: false),
                ),
              ),
              const SizedBox(height: 28),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: ctsGutter),
                child: _MenuCard(title: 'Account', items: _account),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: ctsGutter),
                child: _MenuCard(title: 'Privacy and support', items: _more),
              ),
              const SizedBox(height: 32),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: ctsGutter),
                child: _LogoutButton(
                  onTap: () => _confirmLogout(context, ref),
                ),
              ),
              const SizedBox(height: 16),
              const Text('CTSGo v1.0.0',
                  textAlign: TextAlign.center, style: CtsText.caption),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmLogout(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
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
            style: FilledButton.styleFrom(
                backgroundColor: _kError, foregroundColor: Colors.white),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
  }
}

// ── Identity card ─────────────────────────────────────────────────────────────
// Avatar, full name and contact details. The phone number is the one the
// passenger signed in with, marked Verified as on Edit Profile.
class _IdentityCard extends StatelessWidget {
  final UserData? user;
  final bool loading;
  const _IdentityCard({required this.user, required this.loading});

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
    final large = ctsLargeText(context);
    final phone = user?.phoneNumber;
    final email = user?.email;

    final avatar = SizedBox(
      width: 76,
      height: 76,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 72,
            height: 72,
            padding: const EdgeInsets.all(3),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: CtsTheme.appleSoft,
            ),
            child: ClipOval(
              child: user?.photoURL?.isNotEmpty == true
                  ? Image.network(
                      user!.photoURL!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _fallback(),
                    )
                  : loading
                      ? const ColoredBox(color: CtsTheme.surface)
                      : _fallback(),
            ),
          ),
          Positioned(
            right: -10,
            bottom: -10,
            child: Semantics(
              button: true,
              label: 'Edit profile photo',
              excludeSemantics: true,
              onTap: () => Navigator.pushNamed(context, AppRoutes.editProfile),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.editProfile),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: CtsTheme.vivid,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.camera_alt_rounded,
                          size: 14, color: CtsTheme.onVivid),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final details = loading
        ? const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CtsSkeleton(width: 150, height: 20),
              SizedBox(height: 10),
              CtsSkeleton(width: 110, height: 13),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(_displayName,
                    maxLines: large ? null : 3,
                    overflow: large ? null : TextOverflow.ellipsis,
                    style: CtsText.title2),
              ),
              if (phone?.isNotEmpty == true) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(phone!,
                        style: CtsText.bodySmall
                            .copyWith(color: CtsTheme.textPrimary)),
                    const _VerifiedMark(),
                  ],
                ),
              ],
              if (email?.isNotEmpty == true) ...[
                const SizedBox(height: 4),
                // One line: an address split mid-word is hard to read.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(email!, maxLines: 1, style: CtsText.bodySmall),
                ),
              ],
            ],
          );

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(CtsTheme.radiusXl),
        border: Border.all(color: _kBorder),
        boxShadow: CtsTheme.cardShadow,
      ),
      child: large
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [avatar, const SizedBox(height: 16), details],
            )
          : Row(
              children: [
                avatar,
                const SizedBox(width: 18),
                Expanded(child: details),
              ],
            ),
    );
  }

  Widget _fallback() => Container(
        color: CtsTheme.surface,
        child: Center(
          child: Text(_initials,
              style: CtsText.title2.copyWith(
                fontWeight: FontWeight.w800,
                color: CtsTheme.primaryDeep,
              )),
        ),
      );
}

class _VerifiedMark extends StatelessWidget {
  const _VerifiedMark();

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Verified',
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
          decoration: BoxDecoration(
            color: CtsTheme.appleSoft,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.verified_rounded,
                  size: 13, color: CtsTheme.primaryDeep),
              const SizedBox(width: 4),
              Text('Verified',
                  style: CtsText.caption.copyWith(
                      color: CtsTheme.primaryDeep,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      );
}

// ── Menu group ────────────────────────────────────────────────────────────────
class _MenuCard extends StatelessWidget {
  final String title;
  final List<({IconData icon, String label, String sub, String route})> items;
  const _MenuCard({required this.title, required this.items});

  @override
  Widget build(BuildContext context) => CtsListGroup(
        title: title,
        children: [
          for (final item in items)
            CtsListRow(
              icon: item.icon,
              title: item.label,
              subtitle: item.sub,
              onTap: () => Navigator.pushNamed(context, item.route),
            ),
        ],
      );
}

// ── Logout button ─────────────────────────────────────────────────────────────
class _LogoutButton extends StatelessWidget {
  final VoidCallback onTap;
  const _LogoutButton({required this.onTap});

  @override
  Widget build(BuildContext context) => CtsSecondaryButton(
        label: 'Log Out',
        icon: Icons.logout_rounded,
        destructive: true,
        expand: true,
        onPressed: onTap,
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
