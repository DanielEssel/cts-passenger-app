// lib/features/wallet/presentation/widgets/bridge_momo_sheet.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../core/utils/ghana_phone.dart';
import '../providers/wallet_controller.dart';
import '../providers/wallet_providers.dart';

// ── Network data ──────────────────────────────────────────────────────────────

class _MomoNetwork {
  const _MomoNetwork({
    required this.id,
    required this.label,
    required this.color,
    required this.prefixes,
  });
  final String id;
  final String label;
  final Color color;
  final List<String> prefixes;
}

const _networks = [
  _MomoNetwork(
    id: 'MTN',
    label: 'MTN MoMo',
    color: Color(0xFFFFC107),
    prefixes: ['024', '025', '053', '054', '055', '059'],
  ),
  _MomoNetwork(
    id: 'TELECEL',
    label: 'Telecel Cash',
    color: Color(0xFFE53935),
    prefixes: ['020', '050'],
  ),
  _MomoNetwork(
    id: 'AIRTELTIGO',
    label: 'AirtelTigo',
    color: Color(0xFF1565C0),
    prefixes: ['023', '026', '027', '056', '057'],
  ),
];

// ── Public API ────────────────────────────────────────────────────────────────

/// Shows the Bridge MoMo top-up bottom sheet.
/// Returns true if top-up was successful, false if cancelled or failed.
Future<bool> showBridgeMomoSheet(
  BuildContext context, {
  required double amount,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => BridgeMomoSheet(amount: amount),
  );
  return result ?? false;
}

// ── Widget ────────────────────────────────────────────────────────────────────

class BridgeMomoSheet extends ConsumerStatefulWidget {
  const BridgeMomoSheet({super.key, required this.amount});
  final double amount;

  @override
  ConsumerState<BridgeMomoSheet> createState() => _BridgeMomoSheetState();
}

class _BridgeMomoSheetState extends ConsumerState<BridgeMomoSheet> {
  // ── State ──────────────────────────────────────────────────────────────────
  _MomoNetwork? _selectedNetwork;
  final _phoneController = TextEditingController();
  String? _phoneError;

  // Stages: input → pending → success | failed
  _Stage _stage = _Stage.input;
  String? _errorMessage;
  String? _transactionId;
  int _pollCount = 0;
  Timer? _pollTimer;

  static const int _maxPolls = 12; // 12 × 5s = 60s timeout
  static const int _pollIntervalSec = 5;

  @override
  void initState() {
    super.initState();
    // Pre-fill phone from user profile
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final walletState = ref.read(walletProvider);
      walletState.whenData((wallet) {
        // Try to pre-fill — wallet may not have phone
      });
    });
    _phoneController.addListener(_onPhoneChanged);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _phoneController.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _onPhoneChanged() {
    final digits = _phoneController.text.replaceAll(RegExp(r'\D'), '');

    // Auto-detect and pre-select network
    if (digits.length == 10) {
      final detected = detectNetwork(digits);
      if (detected != null && _selectedNetwork == null) {
        setState(() {
          _selectedNetwork = _networks.firstWhere(
            (n) => n.id == detected,
            orElse: () => _networks.first,
          );
        });
      }
      setState(() {
        _phoneError = isValidGhanaPhone(digits)
            ? null
            : 'Enter a valid Ghana mobile number (e.g. 0244000000)';
      });
    } else {
      setState(() => _phoneError = null);
    }
  }

  bool get _canSubmit {
    final digits = _phoneController.text.replaceAll(RegExp(r'\D'), '');
    return _selectedNetwork != null &&
        digits.length == 10 &&
        isValidGhanaPhone(digits) &&
        _stage == _Stage.input;
  }

  // ── Top-up initiation ──────────────────────────────────────────────────────

  Future<void> _initiate() async {
    final phone = _phoneController.text.replaceAll(RegExp(r'\D'), '');

    setState(() {
      _stage = _Stage.pending;
      _errorMessage = null;
      _pollCount = 0;
    });

    HapticFeedback.mediumImpact();

    try {
      final controller = ref.read(walletControllerProvider);
      final txId = await controller.initiateBridgeTopUp(
        amount: widget.amount,
        phone: phone,
        network: _selectedNetwork!.id,
      );

      setState(() => _transactionId = txId);
      _startPolling(txId);
    } catch (e) {
      setState(() {
        _stage = _Stage.failed;
        _errorMessage = _extractError(e);
      });
    }
  }

  // ── Polling ────────────────────────────────────────────────────────────────

  void _startPolling(String txId) {
    _pollTimer = Timer.periodic(
      const Duration(seconds: _pollIntervalSec),
      (_) => _poll(txId),
    );
  }

  Future<void> _poll(String txId) async {
    if (!mounted) {
      _pollTimer?.cancel();
      return;
    }

    _pollCount++;

    if (_pollCount > _maxPolls) {
      _pollTimer?.cancel();
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _errorMessage =
              'Payment timed out. Please check your MoMo and try again.';
        });
      }
      return;
    }

    try {
      final controller = ref.read(walletControllerProvider);
      final status = await controller.checkBridgeTopUpStatus(txId);

      if (!mounted) return;

      if (status.isSuccess) {
        _pollTimer?.cancel();
        // Refresh wallet balance
        await controller.onTopUpSuccess();
        if (mounted) setState(() => _stage = _Stage.success);
      } else if (status.isFailed) {
        _pollTimer?.cancel();
        if (mounted) {
          setState(() {
            _stage = _Stage.failed;
            _errorMessage =
                'Payment was declined or cancelled. Please try again.';
          });
        }
      }
      // Otherwise still pending — keep polling
    } catch (_) {
      // Transient error — keep polling, don't show error yet
    }
  }

  // ── Reset ──────────────────────────────────────────────────────────────────

  void _reset() {
    _pollTimer?.cancel();
    setState(() {
      _stage = _Stage.input;
      _errorMessage = null;
      _transactionId = null;
      _pollCount = 0;
    });
  }

  // ── Error extraction ───────────────────────────────────────────────────────

  String _extractError(dynamic e) {
    final msg = e.toString().replaceFirst('Exception: ', '');
    return msg.isNotEmpty ? msg : 'Something went wrong. Please try again.';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: switch (_stage) {
        _Stage.input => _buildInputStage(),
        _Stage.pending => _buildPendingStage(),
        _Stage.success => _buildSuccessStage(),
        _Stage.failed => _buildFailedStage(),
      },
    );
  }

  // ── Input stage ───────────────────────────────────────────────────────────

  Widget _buildInputStage() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Handle + header
        Center(
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Top Up Wallet', style: AppTextStyles.heading3),
                  const SizedBox(height: 2),
                  Text(
                    'Pay via Mobile Money',
                    style: AppTextStyles.bodySmall
                        .copyWith(color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded),
              iconSize: 20,
              onPressed: () => Navigator.pop(context, false),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // Amount display
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.2),
            ),
          ),
          child: Column(
            children: [
              Text(
                'Amount',
                style: AppTextStyles.caption.copyWith(color: Colors.grey[600]),
              ),
              const SizedBox(height: 4),
              Text(
                'GHS ${widget.amount.toStringAsFixed(2)}',
                style:
                    AppTextStyles.heading2.copyWith(color: AppColors.primary),
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // Network selector
        Text('Select Network', style: AppTextStyles.labelLarge),
        const SizedBox(height: 10),
        Row(
          children: _networks.map((n) {
            final isSelected = _selectedNetwork?.id == n.id;
            return Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _selectedNetwork = n),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? n.color.withValues(alpha: 0.12)
                        : Colors.grey[100],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? n.color : Colors.grey[300]!,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: n.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        n.id,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: isSelected ? n.color : Colors.grey[700],
                          fontWeight:
                              isSelected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),

        const SizedBox(height: 20),

        // Phone number input
        Text('MoMo Number', style: AppTextStyles.labelLarge),
        const SizedBox(height: 8),
        TextField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(10),
          ],
          decoration: InputDecoration(
            hintText: '0244 000 000',
            prefixIcon: const Icon(Icons.phone_outlined, size: 20),
            errorText: _phoneError,
            helperText: _selectedNetwork != null
                ? 'Network detected: ${_selectedNetwork!.label}'
                : 'Starts with ${_networks.map((n) => n.prefixes.first).join(', ')}...',
            helperStyle: AppTextStyles.caption.copyWith(
              color: _selectedNetwork?.color ?? Colors.grey[600],
            ),
            filled: true,
            fillColor: Colors.grey[50],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey[300]!),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: _selectedNetwork?.color ?? AppColors.primary,
                width: 2,
              ),
            ),
          ),
        ),

        const SizedBox(height: 8),

        // Mismatch warning
        if (_selectedNetwork != null && _phoneController.text.length == 10) ...[
          Builder(builder: (ctx) {
            final digits = _phoneController.text.replaceAll(RegExp(r'\D'), '');
            final detected = detectNetwork(digits);
            final mismatch =
                detected != null && detected != _selectedNetwork!.id;
            if (!mismatch) return const SizedBox.shrink();
            return Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange[200]!),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: Colors.orange[700]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This number looks like $detected but you selected ${_selectedNetwork!.id}. '
                      'Please confirm your network.',
                      style: AppTextStyles.caption.copyWith(
                        color: Colors.orange[800],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
        ],

        const SizedBox(height: 8),

        // Security note
        Row(
          children: [
            Icon(Icons.lock_rounded, size: 14, color: Colors.grey[500]),
            const SizedBox(width: 6),
            Text(
              'Secured by Bridge · CTS does not store your MoMo PIN',
              style: AppTextStyles.caption.copyWith(color: Colors.grey[500]),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // Submit button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _canSubmit ? _initiate : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              disabledBackgroundColor: Colors.grey[300],
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(
              'Send Payment Prompt  →',
              style: AppTextStyles.button.copyWith(color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  // ── Pending stage ─────────────────────────────────────────────────────────

  Widget _buildPendingStage() {
    final secondsLeft =
        ((_maxPolls - _pollCount) * _pollIntervalSec).clamp(0, 60);
    final phone = _phoneController.text.replaceAll(RegExp(r'\D'), '');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Spinner
          SizedBox(
            width: 72,
            height: 72,
            child: Stack(
              children: [
                const Center(child: CircularProgressIndicator(strokeWidth: 3)),
                Center(
                  child: Icon(
                    Icons.smartphone_rounded,
                    color: AppColors.primary,
                    size: 32,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Approve on your phone',
            style: AppTextStyles.heading3,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            'A payment prompt of GHS ${widget.amount.toStringAsFixed(2)} '
            'has been sent to ${formatGhanaPhone(phone)}.\n'
            'Open your MoMo app or dial *170# to approve.',
            style: AppTextStyles.bodyMedium.copyWith(color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Text(
            'Waiting… (${secondsLeft}s)',
            style: AppTextStyles.caption.copyWith(color: Colors.grey[500]),
          ),
          const SizedBox(height: 20),
          TextButton(
            onPressed: () {
              _pollTimer?.cancel();
              _reset();
            },
            child: Text(
              'Cancel and try again',
              style: AppTextStyles.bodySmall.copyWith(
                color: Colors.grey[600],
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Success stage ─────────────────────────────────────────────────────────

  Widget _buildSuccessStage() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.green[50],
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.check_circle_rounded,
              color: Colors.green[600],
              size: 40,
            ),
          ),
          const SizedBox(height: 24),
          Text('Wallet Topped Up! 🎉', style: AppTextStyles.heading3),
          const SizedBox(height: 10),
          Text(
            'GHS ${widget.amount.toStringAsFixed(2)} has been added to your CTS wallet.',
            style: AppTextStyles.bodyMedium.copyWith(color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                if (Navigator.canPop(context)) Navigator.pop(context, true);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                'Done',
                style: AppTextStyles.button.copyWith(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Failed stage ──────────────────────────────────────────────────────────

  Widget _buildFailedStage() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.red[50],
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.error_outline_rounded,
                color: Colors.red[600], size: 40),
          ),
          const SizedBox(height: 20),
          Text('Payment Failed', style: AppTextStyles.heading3),
          const SizedBox(height: 10),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _errorMessage!,
                style:
                    AppTextStyles.bodyMedium.copyWith(color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
            ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
  if (Navigator.canPop(context)) Navigator.pop(context, false);
},
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _reset,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Try Again',
                    style: AppTextStyles.button.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _Stage { input, pending, success, failed }
