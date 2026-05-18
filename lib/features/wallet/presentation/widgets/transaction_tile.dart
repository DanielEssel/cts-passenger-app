import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../domain/entities/transaction.dart';

class TransactionTile extends StatelessWidget {
  final Transaction transaction;
  final VoidCallback? onTap;

  const TransactionTile({
    super.key,
    required this.transaction,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isCredit = transaction.isCredit;
    final iconData = _getIconData(transaction);
    final iconBg = _getIconBackground(transaction);
    final iconColor = _getIconColor(transaction);
    final description = _getDescription(transaction);
    final subtitle = _formatSubtitle(transaction);
    final amount = '${isCredit ? '+' : '-'}GHS ${transaction.amount.toStringAsFixed(2)}';
    final status = transaction.status;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            // Icon
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(iconData, color: iconColor, size: 22),
            ),
            const SizedBox(width: 12),
            
            // Details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          description,
                          style: AppTextStyles.labelLarge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (status != TransactionStatus.completed)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: status == TransactionStatus.pending
                                ? AppColors.warning.withValues(alpha: 0.1)
                                : AppColors.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            status.toString().split('.').last,
                            style: AppTextStyles.caption.copyWith(
                              color: status == TransactionStatus.pending
                                  ? AppColors.warning
                                  : AppColors.error,
                              fontSize: 10,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        isCredit ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 12,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          subtitle,
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            
            // Amount
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  amount,
                  style: AppTextStyles.labelLarge.copyWith(
                    color: isCredit ? AppColors.success : AppColors.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textTertiary,
                  size: 16,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _getIconData(Transaction transaction) {
    if (transaction.isCredit) {
      if (transaction.description.contains('Promo') || 
          transaction.description.contains('Bonus')) {
        return Icons.card_giftcard_rounded;
      }
      return Icons.arrow_upward_rounded;
    }
    
    if (transaction.description.contains('Ride')) {
      return Icons.directions_car_rounded;
    }
    if (transaction.description.contains('Delivery')) {
      return Icons.inventory_2_rounded;
    }
    if (transaction.description.contains('Transfer')) {
      return Icons.swap_horiz_rounded;
    }
    return Icons.two_wheeler_rounded;
  }

  Color _getIconBackground(Transaction transaction) {
    if (transaction.isCredit) {
      return const Color(0xFFDCFCE7);
    }
    
    if (transaction.description.contains('Ride')) {
      return const Color(0xFFFEE2E2);
    }
    if (transaction.description.contains('Delivery')) {
      return const Color(0xFFDBEAFE);
    }
    if (transaction.description.contains('Transfer')) {
      return const Color(0xFFF3E8FF);
    }
    return const Color(0xFFFEE2E2);
  }

  Color _getIconColor(Transaction transaction) {
    if (transaction.isCredit) {
      return const Color(0xFF16A34A);
    }
    
    if (transaction.description.contains('Ride')) {
      return const Color(0xFFDC2626);
    }
    if (transaction.description.contains('Delivery')) {
      return const Color(0xFF1D4ED8);
    }
    if (transaction.description.contains('Transfer')) {
      return const Color(0xFF7C3AED);
    }
    return const Color(0xFFDC2626);
  }

  String _getDescription(Transaction transaction) {
    if (transaction.description.isNotEmpty) {
      return transaction.description;
    }
    
    if (transaction.isCredit) {
      return 'Wallet Top Up';
    }
    return 'Payment';
  }

  String _formatSubtitle(Transaction transaction) {
    final now = DateTime.now();
    final difference = now.difference(transaction.createdAt);
    
    if (difference.inDays == 0) {
      return 'Today, ${_formatTime(transaction.createdAt)}';
    } else if (difference.inDays == 1) {
      return 'Yesterday, ${_formatTime(transaction.createdAt)}';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${transaction.createdAt.day}/${transaction.createdAt.month}/${transaction.createdAt.year}';
    }
  }

  String _formatTime(DateTime date) {
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}