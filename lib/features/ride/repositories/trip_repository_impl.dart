// lib/features/ride/data/repositories/trip_repository_impl.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dartz/dartz.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/errors/failures.dart';
import '../../domain/entities/service_type.dart';
import '../../domain/entities/trip_request.dart';
import '../../domain/repositories/trip_repository.dart';
import '../../../payment/domain/entities/payment_type.dart';
import '../dtos/trip_request_dto.dart';
import '../sources/trip_remote_source.dart';

class TripRepositoryImpl implements TripRepository {
  const TripRepositoryImpl(this._remoteSource);

  final TripRemoteSource _remoteSource;

  // ── Create ───────────────────────────────────────────────────────────────

  @override
  Future<Either<Failure, String>> createTrip({
    required String passengerId,
    required ServiceType serviceType,
    required double pickupLat,
    required double pickupLng,
    required double dropoffLat,
    required double dropoffLng,
    required String pickupAddress,
    required String dropoffAddress,
    required double estimatedFare,
    required double distanceKm,
    required int estimatedDurationMin,
    required PaymentType paymentType,
  }) async {
    try {
      // Build a minimal domain entity just to leverage the DTO serializer.
      // The entity is not stored — only the resulting map is written.
      final draftTrip = TripRequest(
        id: '',   // will be assigned by Firestore
        passengerId: passengerId,
        serviceType: serviceType,
        status: TripStatus.searching,
        pickupLatLng: LatLng(pickupLat, pickupLng),
        dropoffLatLng: LatLng(dropoffLat, dropoffLng),
        pickupAddress: pickupAddress,
        dropoffAddress: dropoffAddress,
        createdAt: DateTime.now(), // replaced by serverTimestamp in map
        estimatedFare: estimatedFare,
        distanceKm: distanceKm,
        estimatedDurationMin: estimatedDurationMin,
        paymentType: paymentType,
        metadata: const {},
      );

      final tripId = await _remoteSource.createTrip(
        TripRequestDto.toCreateMap(draftTrip),
      );

      return Right(tripId);
    } on FirebaseException catch (e) {
      return Left(FirestoreFailure(
        message: e.message ?? 'Firestore write failed',
        code: e.code,
      ));
    } on Failure catch (f) {
      return Left(f);
    } catch (e) {
      return Left(FirestoreFailure(message: e.toString()));
    }
  }

  // ── Watch single trip ─────────────────────────────────────────────────────

  @override
  Stream<Either<Failure, TripRequest>> watchTrip(String tripId) =>
      _remoteSource
          .watchTrip(tripId)
          .map<Either<Failure, TripRequest>>((doc) {
        try {
          return Right(TripRequestDto.fromFirestore(doc));
        } on FirestoreDtoException catch (e) {
          return Left(FirestoreFailure(message: e.message));
        } catch (e) {
          return Left(FirestoreFailure(message: e.toString()));
        }
      }).handleError(
        (Object e) => Left(
          FirestoreFailure(
            message: e is FirebaseException
                ? (e.message ?? 'Stream error')
                : e.toString(),
          ),
        ),
      );

  // ── Watch active trip ─────────────────────────────────────────────────────

  @override
  Stream<Either<Failure, TripRequest?>> watchActiveTrip(
    String passengerId,
  ) =>
      _remoteSource
          .watchActiveTrip(passengerId)
          .map<Either<Failure, TripRequest?>>((snapshot) {
        try {
          if (snapshot.docs.isEmpty) return const Right(null);
          return Right(TripRequestDto.fromFirestore(snapshot.docs.first));
        } on FirestoreDtoException catch (e) {
          return Left(FirestoreFailure(message: e.message));
        }
      }).handleError(
        (Object e) => Left(FirestoreFailure(message: e.toString())),
      );

  // ── Cancel ───────────────────────────────────────────────────────────────

  @override
  Future<Either<Failure, Unit>> cancelTrip({
    required String tripId,
    required String passengerId,
    required String reason,
  }) async {
    try {
      await _remoteSource.cancelTrip(
        tripId: tripId,
        passengerId: passengerId,
        reason: reason,
      );
      return constRight(unit);
    } on Failure catch (f) {
      return Left(f);
    } on FirebaseException catch (e) {
      return Left(FirestoreFailure(
        message: e.message ?? 'Cancel failed',
        code: e.code,
      ));
    } catch (e) {
      return Left(FirestoreFailure(message: e.toString()));
    }
  }

  // ── Fetch once ───────────────────────────────────────────────────────────

  @override
  Future<Either<Failure, TripRequest>> fetchTrip(String tripId) async {
    try {
      final doc = await _remoteSource.fetchTrip(tripId);
      return Right(TripRequestDto.fromFirestore(doc));
    } on NotFoundFailure catch (f) {
      return Left(f);
    } on FirestoreDtoException catch (e) {
      return Left(FirestoreFailure(message: e.message));
    } on FirebaseException catch (e) {
      return Left(FirestoreFailure(
        message: e.message ?? 'Fetch failed',
        code: e.code,
      ));
    }
  }
}