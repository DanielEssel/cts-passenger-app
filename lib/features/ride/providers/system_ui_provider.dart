
import 'package:flutter/services.dart';

/// Call once on screen mount to configure the overlay style.
void applyRideBookingOverlayStyle() {
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
  ));
}