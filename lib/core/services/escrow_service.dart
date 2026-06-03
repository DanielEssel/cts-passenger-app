// lib/core/services/escrow_service.dart
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

class EscrowResult {
  final bool   success;
  final String? escrowId;
  final String? error;
  final double? currentBalance;
  final double? shortfall;
  const EscrowResult({required this.success, this.escrowId, this.error, this.currentBalance, this.shortfall});
}

class EscrowService {
  EscrowService._();
  static final instance = EscrowService._();
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');

  Future<EscrowResult> holdBalance({required double amount, required String serviceType, required String referenceType}) async {
    try {
      final result = await _functions.httpsCallable('holdBalance').call({'amount': amount, 'serviceType': serviceType, 'referenceType': referenceType});
      final raw  = result.data;
      final data = Map<String, dynamic>.from(raw as Map);
      if (data['success'] == true) return EscrowResult(success: true, escrowId: data['escrowId']?.toString());
      return EscrowResult(success: false, error: 'Hold failed');
    } on FirebaseFunctionsException catch (e) {
      final details = e.details != null ? Map<String, dynamic>.from(e.details as Map) : null;
      return EscrowResult(success: false, error: e.message ?? 'Payment hold failed', currentBalance: (details?['currentBalance'] as num?)?.toDouble(), shortfall: (details?['shortfall'] as num?)?.toDouble());
    } catch (e) {
      return EscrowResult(success: false, error: e.toString());
    }
  }

  Future<bool> attachToOrder({required String escrowId, required String referenceId, required String referenceType}) async {
    try {
      await _functions.httpsCallable('attachEscrowToOrder').call({'escrowId': escrowId, 'referenceId': referenceId, 'referenceType': referenceType});
      return true;
    } catch (e) {
      debugPrint('attachEscrowToOrder error: $e');
      return false;
    }
  }
}
