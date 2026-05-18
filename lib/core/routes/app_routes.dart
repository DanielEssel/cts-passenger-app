class AppRoutes {
  // ── Auth flow ────────────────────────────────────────────────────────────
  static const String splash = '/';
  static const String onboarding = '/onboarding';
  static const String login = '/login';
  static const String signup = '/signup';
  static const String otpVerification = '/otp-verification';

  // ── Main app shell ───────────────────────────────────────────────────────
  static const String shell = '/shell';

  // ── Ride flow ────────────────────────────────────────────────────────────
  static const String bookRide = '/book-ride';
  static const String deliveryVehicle = '/delivery-vehicle'; // Add this
  static const String deliveryMatching = '/delivery-matching'; // Add this
  static const String gasOrder = '/gas-order'; // Add this
  static const String gasTracking = '/gas-tracking'; // Add this
  static const String delivery = '/delivery';
  static const String notifications = '/notifications';
  static const String rideTracking = '/ride-tracking';

  // ── Profile sub-screens ──────────────────────────────────────────────────
  static const String editProfile = '/edit-profile';
  static const String savedPlaces = '/saved-places';
  static const String paymentMethods = '/payment-methods';
  static const String promotions = '/promotions';
  static const String privacySecurity = '/privacy-security';
  static const String helpSupport = '/help-support';
  static const String about = '/about';

  // ── Wallet sub-screens ───────────────────────────────────────────────────
  static const String transactionDetail = '/transaction-detail';

  static const tripHistory = '/trip-history';

  static const String destinationSearch = '/destinationSearch';
  static const String profile = '/profile';
}
