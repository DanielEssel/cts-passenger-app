// lib/app/auth_gate.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/routes/app_routes.dart';
import '../core/startup/passenger_flow_resolver.dart';
import '../core/startup/route_destination.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/signup_screen.dart';
import '../features/auth/presentation/welcome_screen.dart';
import '../features/root/passenger_root_shell.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // ───────────────────────────────────────────────────────────────────
        // Firebase is restoring the session.
        // ───────────────────────────────────────────────────────────────────

        if (snapshot.connectionState ==
            ConnectionState.waiting) {
          return const _LoadingScreen();
        }

        // ───────────────────────────────────────────────────────────────────
        // No Firebase user.
        // ───────────────────────────────────────────────────────────────────

        final user = snapshot.data;

        if (user == null) {
          return const LoginScreen();
        }

        // ───────────────────────────────────────────────────────────────────
        // Firebase user exists.
        //
        // DO NOT automatically open PassengerRootShell.
        //
        // First verify users/{uid}.
        // ───────────────────────────────────────────────────────────────────

        return FutureBuilder<RouteDestination>(
          future: PassengerFlowResolver.resolve(
            user.uid,
          ),
          builder: (context, flowSnapshot) {
            // Still checking Firestore.
            if (flowSnapshot.connectionState ==
                ConnectionState.waiting) {
              return const _LoadingScreen();
            }

            // If we cannot determine the user's CTSGo profile,
            // fail closed instead of allowing access.
            if (flowSnapshot.hasError ||
                !flowSnapshot.hasData) {
              return const LoginScreen();
            }

            final destination =
                flowSnapshot.data!;

            switch (destination.route) {
              case AppRoutes.login:
                return const LoginScreen();

              case AppRoutes.signup:
                return const SignupScreen();

              case AppRoutes.welcome:
                return const WelcomeScreen();

              case AppRoutes.shell:
                return const PassengerRootShell();

              default:
                return const LoginScreen();
            }
          },
        );
      },
    );
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}