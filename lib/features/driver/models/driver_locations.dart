import 'package:cloud_firestore/cloud_firestore.dart';

class DriverLocation {
  final String driverId;
  final GeoPoint location;
  final bool isOnline;
  final List<String> availableFor;
  final double heading;
  final DateTime updatedAt;

  DriverLocation({
    required this.driverId,
    required this.location,
    required this.isOnline,
    required this.availableFor,
    required this.heading,
    required this.updatedAt,
  });

  factory DriverLocation.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    return DriverLocation(
      driverId: doc.id,
      location: data['location'] as GeoPoint,
      isOnline: data['isOnline'] ?? false,
      availableFor: List<String>.from(data['availableFor'] ?? []),
      heading: (data['heading'] ?? 0).toDouble(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'location': location,
      'isOnline': isOnline,
      'availableFor': availableFor,
      'heading': heading,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}