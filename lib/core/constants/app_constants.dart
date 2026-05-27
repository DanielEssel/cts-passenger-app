// CREATE NEW FILE: lib/core/constants/app_constants.dart

class AppConstants {
  // API Keys
  static const String googleMapsApiKey = 'AIzaSyAFqi7QoQAL5oOPlV6P4ZTNQT4IeRKCbeU';
  
  // App Settings
  static const double defaultMapZoom = 14.0;
  static const double pickupZoom = 16.0;
  
  // Timeouts (in seconds)
  static const int driverSearchTimeout = 45;
  static const int otpTimeout = 60;
  static const int requestTimeout = 30;
  
  // Pricing — now managed via Firestore settings/platform
  // Use PricingService.instance instead
  @Deprecated('Use PricingService.instance instead')
  static const double baseDeliveryFee = 5.0;
  @Deprecated('Use PricingService.instance instead')
  static const double perKmDeliveryRate = 1.5;
  @Deprecated('Use PricingService.instance instead')
  static const double minDeliveryFee = 10.0;
  
  // Gas Delivery — prices now managed via Firestore settings/platform
  // Use PricingService.instance.gasDeliveryFee etc instead
  @Deprecated('Use PricingService.instance instead')
  static const double gasDeliveryBaseFee = 30.0;
  @Deprecated('Use PricingService.instance instead')
  static const double gasRefillServiceFee = 10.0;
  
  // Animation Durations
  static const Duration shortAnimation = Duration(milliseconds: 200);
  static const Duration mediumAnimation = Duration(milliseconds: 400);
  static const Duration longAnimation = Duration(milliseconds: 600);
  
  // Cache Keys
  static const String savedAddressesKey = 'saved_addresses';
  static const String recentPlacesKey = 'recent_places';
  static const String userPreferenceKey = 'user_preferences';
  
  // Collections
  static const String usersCollection = 'users';
  static const String tripsCollection = 'trips';
  static const String deliveriesCollection = 'deliveries';
  static const String gasOrdersCollection = 'gas_orders';
  static const String driversCollection = 'drivers';
  static const String walletsCollection = 'wallets';
  static const String transactionsCollection = 'transactions';
  static const String notificationsCollection = 'notifications';
  
  // Error Messages
  static const String networkError = 'Network error. Please check your connection.';
  static const String locationError = 'Unable to get your location. Please enable GPS.';
  static const String permissionDenied = 'Location permission denied. Please grant permission.';
  static const String noDriversAvailable = 'No drivers available in your area. Please try again.';
  static const String bookingFailed = 'Failed to book ride. Please try again.';
  static const String paymentFailed = 'Payment failed. Please try another method.';
}

// Helper extension for string validation
extension StringExtension on String? {
  bool get isNullOrEmpty => this == null || this!.isEmpty;
  bool get isNotNullOrEmpty => !isNullOrEmpty;
}

// Helper extension for date formatting
extension DateTimeExtension on DateTime {
  String formatTime() {
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }
  
  String formatDate() {
    return '$day/${month.toString().padLeft(2, '0')}/$year';
  }
  
  String formatDateTime() {
    return '$formatDate() at $formatTime()';
  }
}