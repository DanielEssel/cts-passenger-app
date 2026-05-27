
// Route this file to: lib/features/gas/presentation/screens/order_success_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cts_transport_app/core/theme/app_theme.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/gas/providers/gas_order_providers.dart';
import 'package:cts_transport_app/features/gas/presentation/screens/gas_order_tracking_screen.dart';

// =============================================================================
// Root screen — handles stream states
// =============================================================================

class OrderSuccessScreen extends ConsumerWidget {
  final String orderId;

  const OrderSuccessScreen({super.key, required this.orderId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderAsync = ref.watch(gasOrderStreamProvider(orderId));

    // No inner Scaffold here — we are ALREADY a route-level Scaffold.
    return Scaffold(
      body: orderAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorBody(message: e.toString()),
        data: (order) {
          if (order == null) {
            return const _ErrorBody(message: 'Order not found');
          }
          // Key on order.id so _SuccessBody is only remounted when a truly
          // different order arrives — stream updates to the *same* order will
          // not replay the entry animation.
          return _SuccessBody(key: ValueKey(order.id), order: order);
        },
      ),
    );
  }
}

// =============================================================================
// Success body — stateful for the entry animation only
// =============================================================================

class _SuccessBody extends StatefulWidget {
  final GasRefillRequest order;

  const _SuccessBody({super.key, required this.order});

  @override
  State<_SuccessBody> createState() => _SuccessBodyState();
}

class _SuccessBodyState extends State<_SuccessBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scaleAnim =
        CurvedAnimation(parent: _controller, curve: Curves.elasticOut);
    _fadeAnim =
        CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _controller.forward();
    HapticFeedback.mediumImpact();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Returns up to 8 characters of the order ID, uppercased.
  /// Never throws on short IDs.
  String get _shortId {
    final id = widget.order.id;
    return (id.length >= 8 ? id.substring(0, 8) : id).toUpperCase();
  }

  void _copyOrderId(BuildContext context) {
    Clipboard.setData(ClipboardData(text: widget.order.id));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Order ID copied'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _navigateToTracking(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GasOrderTrackingScreen(orderId: widget.order.id),
      ),
    );
  }

  void _goHome(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final order = widget.order;

    // No Scaffold here — already provided by OrderSuccessScreen
    return Container(
      decoration: BoxDecoration(gradient: AppTheme.primaryGradient),
      child: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            children: [
              const SizedBox(height: 40),

              // ── Animated success icon ──────────────────────────────────────
              FadeTransition(
                opacity: _fadeAnim,
                child: ScaleTransition(
                  scale: _scaleAnim,
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      color: Colors.white,
                      size: 72,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              FadeTransition(
                opacity: _fadeAnim,
                child: Column(
                  children: [
                    Text(
                      'Order placed!',
                      style: AppTheme.headlineMedium.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your gas is on its way',
                      style: AppTheme.bodyMedium.copyWith(
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // ── Content card ───────────────────────────────────────────────
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: AppTheme.background,
                  borderRadius: BorderRadius.circular(24),
                ),
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Order ID row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Order ID',
                          style: AppTheme.bodyMedium
                              .copyWith(color: Colors.grey[500]),
                        ),
                        GestureDetector(
                          onTap: () => _copyOrderId(context),
                          child: Row(
                            children: [
                              Text(
                                '#$_shortId',
                                style: AppTheme.bodyMedium.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.primaryColor,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.copy_rounded,
                                  size: 16, color: AppTheme.primaryColor),
                            ],
                          ),
                        ),
                      ],
                    ),

                    Divider(
                        height: 28,
                        color: Colors.grey.withValues(alpha: 0.3)),

                    // ── Status tracker ─────────────────────────────────────
                    _StatusTracker(currentStatus: order.status),

                    Divider(
                        height: 28,
                        color: Colors.grey.withValues(alpha: 0.3)),

                    // ── Order summary ──────────────────────────────────────
                    Text(
                      'Order summary',
                      style: AppTheme.titleMedium
                          .copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    _SummaryRow(
                      icon: Icons.local_fire_department_rounded,
                      label: 'Service',
                      value: order.refillType.displayName,
                    ),
                    const SizedBox(height: 12),
                    _SummaryRow(
                      icon: Icons.propane_tank_rounded,
                      label: 'Cylinder',
                      value:
                          '${order.cylinderSize.displayName} × ${order.quantity}',
                    ),
                    if (order.preferredBrand != null) ...[
                      const SizedBox(height: 12),
                      _SummaryRow(
                        icon: Icons.verified_rounded,
                        label: 'Brand',
                        value: order.preferredBrand!.displayName,
                      ),
                    ],
                    const SizedBox(height: 12),
                    _SummaryRow(
                      icon: Icons.location_on_rounded,
                      label: 'Deliver to',
                      value: order.deliveryAddress,
                    ),

                    Divider(
                        height: 28,
                        color: Colors.grey.withValues(alpha: 0.3)),

                    // ── Price ──────────────────────────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Total paid',
                          style: AppTheme.titleMedium
                              .copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '₵${order.totalPrice.toStringAsFixed(2)}',
                          style: AppTheme.titleLarge.copyWith(
                            color: AppTheme.primaryColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Payment method',
                          style: AppTheme.bodyMedium
                              .copyWith(color: Colors.grey[500]),
                        ),
                        Text(
                          order.paymentMethod.toUpperCase(),
                          style: AppTheme.bodyMedium
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // ── ETA banner ────────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color:
                              AppTheme.primaryColor.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.access_time_rounded,
                              color: AppTheme.primaryColor, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Estimated delivery in '
                              '${order.refillType.estimatedDuration.inMinutes} minutes',
                              style: AppTheme.bodyMedium.copyWith(
                                color: AppTheme.primaryColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ── Actions ────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    // Primary: Track order
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _navigateToTracking(context),
                        icon: const Icon(Icons.location_on_rounded),
                        label: const Text('Track order'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppTheme.primaryColor,
                          padding:
                              const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Secondary: Home
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _goHome(context),
                        icon: const Icon(Icons.home_rounded),
                        label: const Text('Back to home'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.5)),
                          padding:
                              const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Status tracker — canonical, consolidated version
//
// Uses the richer 7-step list with individual icons (from doc 3),
// with the cleaner circle+line renderer. Handles the case where
// currentStatus doesn't match any step gracefully (returns -1 → all pending).
// =============================================================================

class _StatusTracker extends StatelessWidget {
  final GasOrderStatus currentStatus;
  const _StatusTracker({required this.currentStatus});

  // Steps ordered by progression. Each record: (status, icon, label).
  static const _steps = [
    (GasOrderStatus.pendingApproval, Icons.hourglass_top_rounded, 'Finding driver'),
    (GasOrderStatus.driverAssigned, Icons.person_pin_rounded, 'Driver assigned'),
    (GasOrderStatus.driverEnRoute, Icons.directions_bike_rounded, 'Driver en route'),
    (GasOrderStatus.driverArrived, Icons.location_on_rounded, 'Driver arrived'),
    (GasOrderStatus.pickedUp, Icons.propane_tank_rounded, 'Cylinder collected'),
    (GasOrderStatus.refilling, Icons.local_fire_department_rounded, 'Refilling'),
    (GasOrderStatus.delivered, Icons.check_circle_rounded, 'Delivered'),
  ];

  int get _currentIndex =>
      _steps.indexWhere((s) => s.$1 == currentStatus);

  @override
  Widget build(BuildContext context) {
    final currentIndex = _currentIndex; // -1 if unknown status

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row with progress pill
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Order status',
              style: AppTheme.titleMedium
                  .copyWith(fontWeight: FontWeight.bold),
            ),
            if (currentIndex >= 0)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${currentIndex + 1} / ${_steps.length}',
                  style: AppTheme.labelSmall.copyWith(
                    color: AppTheme.primaryColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),

        const SizedBox(height: 8),

        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: currentStatus.progressValue,
            minHeight: 6,
            backgroundColor: Colors.grey.withValues(alpha: 0.15),
            valueColor:
                const AlwaysStoppedAnimation(AppTheme.primaryColor),
          ),
        ),

        const SizedBox(height: 20),

        // Step list
        ...List.generate(_steps.length, (i) {
          final (_, icon, label) = _steps[i];
          final isDone = i < currentIndex;
          final isCurrent = i == currentIndex;
          final isPending = i > currentIndex;
          final isLast = i == _steps.length - 1;

          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Timeline column
                Column(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        gradient: isCurrent ? AppTheme.primaryGradient : null,
                        color: isDone
                            ? AppTheme.primaryColor
                            : isPending
                                ? Colors.grey.withValues(alpha: 0.15)
                                : null,
                        shape: BoxShape.circle,
                        boxShadow: isCurrent
                            ? [
                                BoxShadow(
                                  color: AppTheme.primaryColor
                                      .withValues(alpha: 0.35),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      child: Center(
                        child: isDone
                            ? const Icon(Icons.check_rounded,
                                size: 14, color: Colors.white)
                            : Icon(
                                icon,
                                size: 14,
                                color: isCurrent
                                    ? Colors.white
                                    : Colors.grey[400],
                              ),
                      ),
                    ),
                    if (!isLast)
                      Expanded(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: 2,
                          color: isDone
                              ? AppTheme.primaryColor
                              : Colors.grey.withValues(alpha: 0.2),
                        ),
                      ),
                  ],
                ),

                const SizedBox(width: 14),

                // Label column
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: AppTheme.bodyMedium.copyWith(
                              fontWeight: isCurrent
                                  ? FontWeight.w700
                                  : FontWeight.normal,
                              color: isDone
                                  ? AppTheme.primaryColor
                                  : isCurrent
                                      ? null // default text colour
                                      : Colors.grey[400],
                            ),
                          ),
                        ),
                        if (isCurrent) _NowBadge(),
                        if (isDone)
                          Icon(Icons.check_circle_rounded,
                              size: 16, color: AppTheme.primaryColor),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _NowBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primaryColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(
              color: AppTheme.primaryColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'Now',
            style: AppTheme.labelSmall.copyWith(
              color: AppTheme.primaryColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Shared sub-widgets
// =============================================================================

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _SummaryRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppTheme.primaryColor, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: AppTheme.labelSmall
                      .copyWith(color: Colors.grey[500])),
              const SizedBox(height: 2),
              Text(value, style: AppTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final String message;
  const _ErrorBody({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Colors.red, size: 64),
            const SizedBox(height: 16),
            Text('Something went wrong',
                style: AppTheme.titleLarge
                    .copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style:
                  AppTheme.bodyMedium.copyWith(color: Colors.grey[500]),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: const Text('Go back'),
            ),
          ],
        ),
      ),
    );
  }
}