// lib/features/ride/domain/use_cases/create_trip_use_case.dart

import 'package:dartz/dartz.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/errors/failures.dart';
import '../entities/service_type.dart';
import '../repositories/trip_repository.dart';
import '../../payment/domain/entities/payment_type.dart';

/// Single-responsibility use case. Validates inputs then delegates to repo.
/// This is the ONLY place business validation for trip creation lives.
class CreateTripUseCase {
  const CreateTripUseCase(this._repository);

  final TripRepository _repository;

  Future<Either<Failure, String>> call(CreateTripParams params) async {
    // ── Domain validation (pure Dart, zero I/O) ──────────────────────────
    if (params.passengerId.isEmpty) {
      return const Left(AuthFailure(message: 'Passenger not authenticated'));
    }

    if (params.estimatedFare <= 0) {
      return const Left(
        FirestoreFailure(message: 'Estimated fare must be greater than zero'),
      );
    }

    if (params.distanceKm < 0.1) {
      return const Left(
        FirestoreFailure(message: 'Trip distance is too short'),
      );
    }

    // ── Delegate to repository ────────────────────────────────────────────
    return _repository.createTrip(
      passengerId: params.passengerId,
      serviceType: params.serviceType,
      pickupLat: params.pickupLatLng.latitude,
      pickupLng: params.pickupLatLng.longitude,
      dropoffLat: params.dropoffLatLng.latitude,
      dropoffLng: params.dropoffLatLng.longitude,
      pickupAddress: params.pickupAddress,
      dropoffAddress: params.dropoffAddress,
      estimatedFare: params.estimatedFare,
      distanceKm: params.distanceKm,
      estimatedDurationMin: params.estimatedDurationMin,
      paymentType: params.paymentType,
    );
  }
}

/// Typed params object — never pass raw positional arguments into use cases.
class CreateTripParams {
  const CreateTripParams({
    required this.passengerId,
    required this.serviceType,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.estimatedFare,
    required this.distanceKm,
    required this.estimatedDurationMin,
    required this.paymentType,
  });

  final String passengerId;
  final ServiceType serviceType;
  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String pickupAddress;
  final String dropoffAddress;
  final double estimatedFare;
  final double distanceKm;
  final int estimatedDurationMin;
  final PaymentType paymentType;
}