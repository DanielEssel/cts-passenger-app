import 'package:cts_transport_app/features/gas/presentation/screens/gas_order_screen.dart';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/routes/app_routes.dart';

// The 4 tab screens
import '../home/presentation/home_screen.dart';
import 'package:cts_transport_app/features/history/presentation/history_screen.dart';
import '../../../features/wallet/presentation/screens/wallet_screen.dart';
import 'package:cts_transport_app/features/profile/presentation/profile_screen.dart';

// Screens for navigation
import 'package:cts_transport_app/features/ride/presentation/book_ride_screen.dart';
import 'package:cts_transport_app/features/delivery/presentation/delivery_screen.dart';
import 'package:cts_transport_app/features/notification/presentation/notifications_screen.dart';
import 'package:cts_transport_app/features/ride_tracking/ride_tracking_screen.dart';

// Import profile-related screens
import 'package:cts_transport_app/features/profile/presentation/edit_profile_screen.dart';
import 'package:cts_transport_app/features/profile/presentation/saved_places_screen.dart';
import 'package:cts_transport_app/features/profile/presentation/payment_methods_screen.dart';
import 'package:cts_transport_app/features/profile/presentation/promotions_screen.dart';
import 'package:cts_transport_app/features/profile/presentation/privacy_security_screen.dart';
import 'package:cts_transport_app/features/profile/presentation/help_support_screen.dart';
import 'package:cts_transport_app/features/profile/presentation/about_screen.dart';
import '../ride/presentation/destination_search_screen.dart';

/// PassengerRootShell is the single widget that owns the bottom navigation bar.
/// It uses an IndexedStack so each tab keeps its scroll position and state
/// when you switch away and come back.
///
/// How to reach it:
///   Navigator.pushNamedAndRemoveUntil(
///     context, AppRoutes.shell, (route) => false,
///   );
///
/// Use pushNamedAndRemoveUntil (not just pushNamed) so the auth screens
/// are fully removed from the back-stack when the user lands on the shell.
class PassengerRootShell extends StatefulWidget {
  const PassengerRootShell({super.key});

  @override
  State<PassengerRootShell> createState() => _PassengerRootShellState();
}

class _PassengerRootShellState extends State<PassengerRootShell> {
  int _currentIndex = 0;

  // One Navigator key per tab — lets each tab have its own navigation stack.
  // e.g. Home can push BookRide internally without affecting the History tab.
  final List<GlobalKey<NavigatorState>> _navKeys = [
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
  ];
  @override
  void dispose() {
    _homeScrollController.dispose();
    _historyScrollController.dispose();
    _walletScrollController.dispose();
    _profileScrollController.dispose();
    super.dispose();
  }

  final _homeScrollController = ScrollController();
  final _historyScrollController = ScrollController();
  final _walletScrollController = ScrollController();
  final _profileScrollController = ScrollController();
  // The root widget for each tab.
  // These are instantiated once and kept alive by IndexedStack.
  late final List<Widget> _tabRoots = [
    HomeScreen(
      onWalletTap: () =>
          setState(() => _currentIndex = 2), // ← switch to wallet tab
    ),
    HistoryScreen(scrollController: _historyScrollController),
    WalletScreen(scrollController: _walletScrollController),
    ProfileScreen(scrollController: _profileScrollController),
  ];

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        final innerNav = _navKeys[_currentIndex].currentState;

        // If current tab has its own navigation stack → pop inside tab
        if (innerNav != null && innerNav.canPop()) {
          innerNav.pop();
          return;
        }

        // Otherwise allow system back (exit app)
        Navigator.of(context).maybePop();
      },
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: List.generate(
            _tabRoots.length,
            (i) => Navigator(
              key: _navKeys[i],
              onGenerateRoute: (settings) => _onGenerateRoute(settings, i),
            ),
          ),
        ),
        bottomNavigationBar: _BottomNavBar(
          currentIndex: _currentIndex,
          onTap: (index) {
            if (index == _currentIndex) {
              // Tapping the already-active tab scrolls it back to the top
              _navKeys[index].currentState?.popUntil((route) => route.isFirst);
            } else {
              setState(() => _currentIndex = index);
            }
          },
        ),
      ),
    );
  }

  Route<dynamic> _onGenerateRoute(RouteSettings settings, int tabIndex) {
    debugPrint('🎯 Generating route: ${settings.name} for tab: $tabIndex');

    switch (settings.name) {
      case '/':
        return MaterialPageRoute(
          builder: (_) => _tabRoots[tabIndex],
          settings: settings,
        );

      // Existing routes
      case AppRoutes.bookRide:
        return MaterialPageRoute(
          builder: (context) => const BookRideScreen(),
          settings: settings,
        );

      case AppRoutes.delivery:
        return MaterialPageRoute(
          builder: (context) => const DeliveryScreen(),
          settings: settings,
        );

      // ADD THIS GAS ORDER ROUTE
      case AppRoutes.gasOrder:
        debugPrint('✅ Navigating to Gas Order Screen');
        return MaterialPageRoute(
          builder: (context) => const GasOrderScreen(),
          settings: settings,
        );

      case AppRoutes.notifications:
        return MaterialPageRoute(
          builder: (context) => const NotificationsScreen(),
          settings: settings,
        );

      case AppRoutes.rideTracking:
        final rideId = settings.arguments as String;
        return MaterialPageRoute(
          builder: (context) => RideTrackingScreen(
            rideId: rideId,
          ),
          settings: settings,
        );

      // Profile menu routes
      case AppRoutes.editProfile:
        return MaterialPageRoute(
          builder: (context) => const EditProfileScreen(),
          settings: settings,
        );

      case AppRoutes.savedPlaces:
        return MaterialPageRoute(
          builder: (context) => const SavedPlacesScreen(),
          settings: settings,
        );

      case AppRoutes.paymentMethods:
        return MaterialPageRoute(
          builder: (context) => const PaymentMethodsScreen(),
          settings: settings,
        );

      case AppRoutes.promotions:
        return MaterialPageRoute(
          builder: (context) => const PromotionsScreen(),
          settings: settings,
        );

      case AppRoutes.privacySecurity:
        return MaterialPageRoute(
          builder: (context) => const PrivacySecurityScreen(),
          settings: settings,
        );

      case AppRoutes.destinationSearch:
        final args = settings.arguments as Map<String, dynamic>?;
        final originAddress = args?['origin'] as String? ?? "Current Location";
        return MaterialPageRoute(
          builder: (_) => DestinationSearchScreen(origin: originAddress),
          settings: settings,
        );

      case AppRoutes.helpSupport:
        return MaterialPageRoute(
          builder: (context) => const HelpSupportScreen(),
          settings: settings,
        );

      case AppRoutes.about:
        return MaterialPageRoute(
          builder: (context) => const AboutScreen(),
          settings: settings,
        );

      default:
        debugPrint('❌ Unknown route: ${settings.name}');
        throw Exception('Unknown route: ${settings.name}');
    }
  }
}

// ─── Bottom Nav Bar ────────────────────────────────────────────────────────

class _BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _BottomNavBar({
    required this.currentIndex,
    required this.onTap,
  });

  static const _items = [
    _NavItem(icon: Icons.home_rounded, label: 'Home'),
    _NavItem(icon: Icons.access_time_rounded, label: 'History'),
    _NavItem(icon: Icons.account_balance_wallet_rounded, label: 'Wallet'),
    _NavItem(icon: Icons.person_rounded, label: 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(
          top: BorderSide(color: AppColors.borderColor, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: List.generate(
              _items.length,
              (i) => _NavTile(
                item: _items[i],
                isActive: currentIndex == i,
                onTap: () => onTap(i),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final _NavItem item;
  final bool isActive;
  final VoidCallback onTap;

  const _NavTile({
    required this.item,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              item.icon,
              size: 22,
              color: isActive
                  ? AppColors.primaryColor
                  : AppColors.textSecondaryColor,
            ),
            const SizedBox(height: 3),
            Text(
              item.label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                color: isActive
                    ? AppColors.primaryColor
                    : AppColors.textSecondaryColor,
              ),
            ),
            const SizedBox(height: 3),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: isActive ? 4 : 0,
              height: isActive ? 4 : 0,
              decoration: BoxDecoration(
                color: AppColors.primaryColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem({required this.icon, required this.label});
}
