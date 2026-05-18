// lib/core/startup/route_destination.dart

/// Holds a named route and an optional typed argument.
/// Used by [StartupResolver] so the splash screen can call
/// Navigator.pushReplacementNamed with arguments in one shot.
class RouteDestination {
  final String  route;
  final Object? arguments;

  const RouteDestination(this.route, {this.arguments});
}