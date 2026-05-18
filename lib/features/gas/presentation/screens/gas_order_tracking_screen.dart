// lib/features/gas/presentation/screens/gas_order_tracking_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cts_transport_app/core/theme/app_theme.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/gas/providers/gas_order_providers.dart';

class GasOrderTrackingScreen extends ConsumerStatefulWidget {
  final String orderId;
  
  const GasOrderTrackingScreen({super.key, required this.orderId});

  @override
  ConsumerState<GasOrderTrackingScreen> createState() => _GasOrderTrackingScreenState();
}

class _GasOrderTrackingScreenState extends ConsumerState<GasOrderTrackingScreen> {
  GoogleMapController? _mapController;
  
  @override
  Widget build(BuildContext context) {
    final orderStream = ref.watch(gasOrderStreamProvider(widget.orderId));
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Track Order'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: orderStream.when(
        data: (order) {
          if (order == null) {
            return const Center(child: Text('Order not found'));
          }
          return _buildTrackingContent(order);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
      ),
    );
  }
  
  Widget _buildTrackingContent(GasRefillRequest order) {
    final progress = order.status.progressValue;
    
    return Column(
      children: [
        // Map
        Expanded(
          flex: 2,
          child: GoogleMap(
            onMapCreated: (controller) => _mapController = controller,
            initialCameraPosition: CameraPosition(
              target: LatLng(order.pickupLocation.latitude, order.pickupLocation.longitude),
              zoom: 14,
            ),
            markers: _buildMarkers(order),
          ),
        ),
        
        // Status Card
        Container(
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          ),
          child: Column(
            children: [
              // Progress indicator
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          order.status.passengerDisplayName,
                          style: AppTheme.titleMedium.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${(progress * 100).toInt()}%',
                          style: AppTheme.bodyMedium.copyWith(color: AppTheme.primaryColor),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.grey[800],
                      valueColor: const AlwaysStoppedAnimation(AppTheme.primaryColor),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
              ),
              
              // Order details
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    _infoRow('Order ID', order.id.substring(0, 8)),
                    _infoRow('Type', order.refillType.displayName),
                    _infoRow('Cylinder', '${order.cylinderSize.displayName} (${order.quantity}x)'),
                    _infoRow('Total', '₵${order.totalPrice.toStringAsFixed(2)}'),
                  ],
                ),
              ),
              
              const SizedBox(height: 24),
              
              // Support button
              Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _contactSupport(),
                        icon: const Icon(Icons.support_agent),
                        label: const Text('Contact Support'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          side: BorderSide(color: Colors.grey[700]!),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
  
 Set<Marker> _buildMarkers(GasRefillRequest order) {
  final pickup = Marker(
    markerId: const MarkerId('pickup'),
    position: LatLng(order.pickupLocation.latitude, order.pickupLocation.longitude),
    icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
  );

  final delivery = Marker(
    markerId: const MarkerId('delivery'),
    position: LatLng(order.deliveryLocation.latitude, order.deliveryLocation.longitude),
    icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
  );

  return {pickup, delivery};
}
  
  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: AppTheme.bodyMedium.copyWith(color: Colors.grey)),
            Text(value, style: AppTheme.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      );
  
  void _contactSupport() {
    // Implement support contact
  }
}