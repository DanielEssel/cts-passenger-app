import 'package:flutter/material.dart';
import '../../payment/models/payment_method.dart';

class PaymentMethodService {
  static final List<PaymentMethod> availableMethods = [
    PaymentMethod(
      type: PaymentType.wallet, 
      name: 'CTS Wallet', 
      icon: Icons.account_balance_wallet_rounded, 
      subtitle: 'Balance: ', 
      isRecommended: true
    ),
    PaymentMethod(
      type: PaymentType.momo,   
      name: 'Mobile Money', 
      icon: Icons.phone_android_rounded, 
      subtitle: 'MTN MoMo'
    ),
    PaymentMethod(
      type: PaymentType.cash,   
      name: 'Cash',         
      icon: Icons.money_rounded,          
      subtitle: 'Pay driver directly'
    ),
    PaymentMethod(
      type: PaymentType.card,   
      name: 'Card',         
      icon: Icons.credit_card_rounded,    
      subtitle: '•••• 4242'
    ),
  ];

  static bool isWalletSufficient(double amount, double balance) => balance >= amount;
  
  static String getFormattedBalance(double balance) => 'GHS ${balance.toStringAsFixed(2)}';
  
  // Helper method to get PaymentMethod by type
  static PaymentMethod getPaymentMethodByType(PaymentType type) {
    return availableMethods.firstWhere(
      (method) => method.type == type,
      orElse: () => availableMethods.first, // Default to first method if not found
    );
  }
  
  // Helper method to validate if payment method is available
  static bool isPaymentMethodAvailable(PaymentType type) {
    return availableMethods.any((method) => method.type == type);
  }
  
  // Get recommended payment method
  static PaymentMethod? getRecommendedPaymentMethod() {
    try {
      return availableMethods.firstWhere((method) => method.isRecommended);
    } catch (e) {
      return null;
    }
  }
  
  // Get wallet balance (you can connect this to actual wallet service)
  static Future<double> getWalletBalance() async {
    // TODO: Implement actual wallet balance fetching
    // This could come from a provider, service, or API
    return 250.50; // Placeholder value
  }
  
  // Check if wallet has sufficient balance for a fare
  static Future<bool> hasSufficientWalletBalance(double fare) async {
    final balance = await getWalletBalance();
    return isWalletSufficient(fare, balance);
  }
}