import 'package:flutter/widgets.dart';

/// A notification route such as "/ride-tracking?tripId=abc", split into the
/// path the route generators match on and the ids they read from
/// `arguments`. Push taps (foreground, background, launch) and the in-app
/// notification list all go through [parse], so a link means the same thing
/// wherever it is opened.
class DeepLink {
  const DeepLink(this.path, this.arguments);

  final String path;
  final Map<String, dynamic>? arguments;

  static const idKeys = ['tripId', 'rideId', 'deliveryId', 'orderId'];

  /// Ids come from the route's query, then from [metadata] (in-app
  /// notifications store them there). Returns null for an empty route.
  static DeepLink? parse(String? route, {Map<String, dynamic>? metadata}) {
    final raw = route?.trim() ?? '';
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    final path = uri.path.isEmpty ? raw : uri.path;
    final args = <String, dynamic>{};
    for (final key in idKeys) {
      final value = uri.queryParameters[key] ?? metadata?[key];
      if (value is String && value.isNotEmpty) args[key] = value;
    }
    return DeepLink(path, args.isEmpty ? null : args);
  }

  /// The trip a ride route refers to: a String argument, a map's tripId or
  /// rideId, or the route name's own ?tripId= query. Empty when none.
  static String tripIdFrom(RouteSettings settings) {
    final args = settings.arguments;
    if (args is String) return args;
    if (args is Map) {
      final id = args['tripId'] ?? args['rideId'];
      if (id is String && id.isNotEmpty) return id;
    }
    return Uri.tryParse(settings.name ?? '')?.queryParameters['tripId'] ?? '';
  }
}
