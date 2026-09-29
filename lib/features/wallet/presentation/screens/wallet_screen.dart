// lib/features/wallet/presentation/screens/wallet_screen.dart

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../widgets/common/shared_widgets.dart';
import '../providers/wallet_providers.dart';
import 'transaction_detail_screen.dart';
import '../../domain/entities/transaction.dart';
import '../../domain/entities/wallet.dart';
import '../widgets/bridge_momo_sheet.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Derived stats provider — UNCHANGED
// ─────────────────────────────────────────────────────────────────────────────

final _walletStatsProvider = Provider.autoDispose<_WalletStats>((ref) {
  final txList = ref.watch(recentTransactionsStreamProvider).value ?? [];

  int tripCount = 0;
  double totalSpent = 0;
  double totalSaved = 0;

  for (final tx in txList) {
    if (tx.type == TransactionType.debit) {
      totalSpent += tx.amount;
      final cat = tx.metadata?['category'] as String? ?? '';
      final desc = tx.description.toLowerCase();
      if (cat == 'ride' ||
          desc.contains('ride') ||
          desc.contains('taxi') ||
          desc.contains('okada')) {
        tripCount++;
      }
    } else if (tx.type == TransactionType.credit) {
      final desc = tx.description.toLowerCase();
      if (desc.contains('promo') ||
          desc.contains('bonus') ||
          desc.contains('reward') ||
          desc.contains('cashback')) {
        totalSaved += tx.amount;
      }
    }
  }

  return _WalletStats(
    tripCount: tripCount,
    totalSpent: totalSpent,
    totalSaved: totalSaved,
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// Local presentational tokens — layered on top of the app's existing
// AppColors/AppTextStyles. Fold into the shared design system if these
// should become app-wide tokens; scoped to this file for now.
// ─────────────────────────────────────────────────────────────────────────────

class _WalletVisuals {
  static const heroShadeEnd = Color(0xFF0E3B31); // deep teal-green, pairs with AppColors.darkNavy
}

// ─────────────────────────────────────────────────────────────────────────────
// WALLET SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class WalletScreen extends ConsumerStatefulWidget {
  final ScrollController scrollController;

  const WalletScreen({super.key, required this.scrollController});

  @override
  ConsumerState<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends ConsumerState<WalletScreen>
    with SingleTickerProviderStateMixin {
  String _activeFilter = 'All';
  bool _balanceVisible = true;
  final bool _isTopUpLoading = false; // ← FIX 1: loading overlay state (unchanged)

  late final AnimationController _entrance;

  static const _filters = [
    'All',
    'Rides',
    'Deliveries',
    'Gas',
    'Top-ups',
    'Transfers',
  ];

  static const _filterIcons = <String, IconData>{
    'All': Icons.apps_rounded,
    'Rides': Icons.directions_car_rounded,
    'Deliveries': Icons.inventory_2_rounded,
    'Gas': Icons.local_fire_department_rounded,
    'Top-ups': Icons.arrow_upward_rounded,
    'Transfers': Icons.swap_horiz_rounded,
  };

  @override
  void initState() {
    super.initState();
    // Single orchestrated entrance — one choreographed moment on first
    // load rather than per-item scroll/hover animation.
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _entrance.forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final walletAsync = ref.watch(walletStreamProvider);
    final txAsync = ref.watch(recentTransactionsStreamProvider);
    final stats = ref.watch(_walletStatsProvider);

    ref.listen<AsyncValue<Wallet>>(walletStreamProvider, (_, next) {
      next.whenOrNull(error: (e, _) => _showError('Wallet error: $e'));
    });

    final reduceMotion = MediaQuery.of(context).disableAnimations;

    final scrollView = CustomScrollView(
      controller: widget.scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: walletAsync.when(
            data: (w) => _buildBalanceHeader(w),
            loading: () => _buildBalanceHeader(null),
            error: (_, __) => _buildBalanceHeader(null),
          ),
        ),
        SliverToBoxAdapter(child: _buildStatsRow(stats)),
        SliverToBoxAdapter(child: _buildSectionHeader()),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: _buildFilterChips(),
          ),
        ),
        txAsync.when(
          data: (txList) {
            final filtered = _filterTransactions(txList);
            if (filtered.isEmpty) {
              return SliverToBoxAdapter(child: _buildEmptyState());
            }
            final items = _buildFlatItemList(_groupTransactions(filtered));
            return SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => items[i],
                childCount: items.length,
              ),
            );
          },
          loading: () => SliverToBoxAdapter(child: _buildTxSkeleton()),
          error: (e, _) =>
              SliverToBoxAdapter(child: _buildTxError(e.toString())),
        ),
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.of(context).padding.bottom + 32),
        ),
      ],
    );

    final animatedContent = reduceMotion
        ? scrollView
        : FadeTransition(
            opacity: CurvedAnimation(parent: _entrance, curve: Curves.easeOut),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.03),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: _entrance,
                curve: Curves.easeOutCubic,
              )),
              child: scrollView,
            ),
          );

    return Stack(
      children: [
        Scaffold(
          backgroundColor: AppColors.background,
          body: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _refresh,
            child: animatedContent,
          ),
        ),

        // ── FIX 1: Loading overlay while Paystack WebView is open ──
        if (_isTopUpLoading)
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Container(
                color: Colors.black.withValues(alpha: 0.35),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                            color: AppColors.primary),
                        const SizedBox(height: 16),
                        Text('Processing payment...',
                            style: AppTextStyles.labelLarge),
                        const SizedBox(height: 4),
                        Text(
                          'Please do not close the app',
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Hero balance card — the one bold gesture on this screen ──
  Widget _buildBalanceHeader(Wallet? wallet) {
    final balance = wallet?.totalBalance ?? 0.0;

    return ClipRRect(
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(32),
        bottomRight: Radius.circular(32),
      ),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.darkNavy, _WalletVisuals.heroShadeEnd],
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _WeavePatternPainter(
                  color: Colors.white.withValues(alpha: 0.05),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 20,
                left: 22,
                right: 22,
                bottom: 28,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('My Wallet',
                          style: AppTextStyles.heading3
                              .copyWith(color: AppColors.background)),
                      const Spacer(),
                      _AddMoneyButton(onTap: _showTopUpSheet),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Text('Available balance',
                      style: AppTextStyles.bodySmall
                          .copyWith(color: AppColors.textOnDarkMuted)),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 0.12),
                              end: Offset.zero,
                            ).animate(anim),
                            child: child,
                          ),
                        ),
                        child: wallet == null
                            ? _BalanceSkeleton(key: const ValueKey('skeleton'))
                            : _balanceVisible
                                ? Text(
                                    'GHS ${balance.toStringAsFixed(2)}',
                                    key: const ValueKey('visible'),
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 38,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.background,
                                      letterSpacing: -1,
                                      fontFeatures: const [
                                        ui.FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  )
                                : const Text(
                                    'GHS ••••••',
                                    key: ValueKey('hidden'),
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 38,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.background,
                                      letterSpacing: 3,
                                    ),
                                  ),
                      ),
                      const SizedBox(width: 12),
                      _VisibilityToggle(
                        visible: _balanceVisible,
                        onTap: () {
                          HapticFeedback.lightImpact();
                          setState(() => _balanceVisible = !_balanceVisible);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  Row(
                    children: [
                      _ActionBtn(
                          icon: Icons.arrow_upward_rounded,
                          label: 'Top Up',
                          onTap: _showTopUpSheet),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsRow(_WalletStats stats) => ColoredBox(
        color: AppColors.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Row(
            children: [
              _StatChip(
                icon: Icons.route_rounded,
                value: '${stats.tripCount}',
                label: 'Trips',
                color: AppColors.success,
              ),
              _StatsDiv(),
              _StatChip(
                icon: Icons.receipt_long_rounded,
                value: 'GHS ${stats.totalSpent.toStringAsFixed(0)}',
                label: 'Total spent',
                color: AppColors.info,
              ),
              _StatsDiv(),
              _StatChip(
                icon: Icons.savings_rounded,
                value: 'GHS ${stats.totalSaved.toStringAsFixed(0)}',
                label: 'Saved',
                color: AppColors.primary,
              ),
            ],
          ),
        ),
      );

  Widget _buildSectionHeader() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Transactions', style: AppTextStyles.heading4),
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _showFilterSheet,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.tune_rounded,
                          size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Text('Filter',
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _buildFilterChips() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: _filters.map((f) {
            final isActive = _activeFilter == f;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: isActive ? AppColors.primary : AppColors.surface,
                borderRadius: BorderRadius.circular(22),
                child: InkWell(
                  borderRadius: BorderRadius.circular(22),
                  onTap: () => setState(() => _activeFilter = f),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                          color: isActive
                              ? AppColors.primary
                              : AppColors.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _filterIcons[f] ?? Icons.circle,
                          size: 14,
                          color: isActive
                              ? AppColors.background
                              : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(f,
                            style: AppTextStyles.labelMedium.copyWith(
                              color: isActive
                                  ? AppColors.background
                                  : AppColors.textSecondary,
                              fontWeight: isActive
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            )),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      );

  // ── Filtering/grouping logic — UNCHANGED ──

  List<Transaction> _filterTransactions(List<Transaction> all) {
    if (_activeFilter == 'All') return all;
    return all.where((tx) => _categoryLabel(tx) == _activeFilter).toList();
  }

  Map<String, List<Transaction>> _groupTransactions(List<Transaction> list) {
    final map = <String, List<Transaction>>{};
    for (final tx in list) {
      map.putIfAbsent(_dateGroupKey(tx.createdAt), () => []).add(tx);
    }
    return map;
  }

  List<Widget> _buildFlatItemList(Map<String, List<Transaction>> grouped) {
    final widgets = <Widget>[];
    for (final entry in grouped.entries) {
      widgets.add(_groupHeader(entry.key));
      for (final tx in entry.value) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _buildTxTile(tx),
        ));
      }
    }
    return widgets;
  }

  String _categoryLabel(Transaction tx) {
    if (tx.type == TransactionType.credit) return 'Top-ups';
    final cat = (tx.metadata?['category'] as String? ?? '').toLowerCase();
    final desc = tx.description.toLowerCase();
    if (cat == 'gas_order' || desc.contains('gas')) return 'Gas';
    if (cat == 'delivery' || desc.contains('delivery')) return 'Deliveries';
    if (cat == 'transfer' || desc.contains('transfer')) return 'Transfers';
    if (cat == 'ride' ||
        desc.contains('ride') ||
        desc.contains('taxi') ||
        desc.contains('okada')) {
      return 'Rides';
    }
    return 'Rides';
  }

  String _dateGroupKey(DateTime date) {
    final diff = DateTime.now().difference(date).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return 'This Week';
    return 'Earlier';
  }

  Widget _groupHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Row(
          children: [
            Text(label,
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                )),
            const SizedBox(width: 8),
            Expanded(
              child: Container(height: 0.6, color: AppColors.border),
            ),
          ],
        ),
      );

  Widget _buildTxTile(Transaction tx) {
    final isCredit = tx.type == TransactionType.credit;
    final category = _categoryLabel(tx);
    final meta = _txMeta(isCredit, category);

    final txItem = TxItem(
      icon: meta.icon,
      iconBg: meta.bg,
      iconColor: meta.fg,
      label: tx.description,
      sub: _formatDate(tx.createdAt),
      amount: '${isCredit ? '+' : '-'}GHS ${tx.amount.toStringAsFixed(2)}',
      isCredit: isCredit,
      type: category,
      ref: tx.reference,
      fullDate: _formatFullDate(tx.createdAt),
      status: tx.status.toString().split('.').last,
      note: tx.metadata?['note'] as String? ?? '',
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        elevation: 0,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => TransactionDetailScreen(tx: txItem)),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: AppColors.darkNavy.withValues(alpha: 0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                      color: meta.bg, borderRadius: BorderRadius.circular(13)),
                  child: Icon(meta.icon, color: meta.fg, size: 19),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tx.description,
                          style: AppTextStyles.labelLarge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_formatDate(tx.createdAt),
                              style: AppTextStyles.caption),
                          const SizedBox(width: 6),
                          _StatusBadge(status: tx.status.toString()),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${isCredit ? '+' : '-'}GHS ${tx.amount.toStringAsFixed(2)}',
                  style: AppTextStyles.labelLarge.copyWith(
                    color: isCredit ? AppColors.success : AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  _TxMeta _txMeta(bool isCredit, String category) {
    if (isCredit) {
      return _TxMeta(
          icon: Icons.arrow_upward_rounded,
          bg: AppColors.successLight,
          fg: AppColors.success);
    }
    switch (category) {
      case 'Gas':
        return _TxMeta(
            icon: Icons.local_fire_department_rounded,
            bg: const Color(0xFFFEF3C7),
            fg: const Color(0xFFD97706));
      case 'Deliveries':
        return _TxMeta(
            icon: Icons.inventory_2_rounded,
            bg: AppColors.infoLight,
            fg: AppColors.info);
      case 'Transfers':
        return _TxMeta(
            icon: Icons.swap_horiz_rounded,
            bg: const Color(0xFFF3E8FF),
            fg: const Color(0xFF7C3AED));
      default:
        return _TxMeta(
            icon: Icons.directions_car_rounded,
            bg: AppColors.errorLight,
            fg: AppColors.error);
    }
  }

  Widget _buildEmptyState() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 20),
        child: Center(
          child: Column(children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.receipt_long_rounded,
                  size: 34, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 16),
            Text('No transactions yet', style: AppTextStyles.heading4),
            const SizedBox(height: 6),
            Text('Your transaction history will appear here',
                style: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center),
          ]),
        ),
      );

  Widget _buildTxSkeleton() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Column(
          children: List.generate(
            5,
            (_) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      );

  Widget _buildTxError(String message) => Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(children: [
            const Icon(Icons.cloud_off_rounded,
                color: AppColors.textTertiary, size: 40),
            const SizedBox(height: 12),
            Text('Could not load transactions', style: AppTextStyles.heading4),
            const SizedBox(height: 6),
            Text(message,
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Material(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _refresh,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 10),
                  child: Text('Retry',
                      style: AppTextStyles.labelMedium
                          .copyWith(color: AppColors.background)),
                ),
              ),
            ),
          ]),
        ),
      );

  // ─────────────────────────────────────────────
  // Top-up sheet — logic UNCHANGED, visuals refined
  // ─────────────────────────────────────────────

  void _showTopUpSheet() {
    int selectedAmountIndex = -1;
    int selectedMethodIndex = 0;
    final customCtrl = TextEditingController();
    final amounts = [20.0, 50.0, 100.0, 200.0, 500.0];
    final methods = _payMethods();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final resolvedAmount = selectedAmountIndex >= 0
              ? amounts[selectedAmountIndex]
              : double.tryParse(customCtrl.text);
          final canPay = resolvedAmount != null && resolvedAmount > 0;

          return SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 28,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SheetHandle(),
                const SizedBox(height: 16),
                Text('Top up wallet', style: AppTextStyles.heading3),
                const SizedBox(height: 4),
                Text('Powered by Paystack — your details are secure',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 20),
                Text('Select amount', style: AppTextStyles.labelLarge),
                const SizedBox(height: 10),
                SizedBox(
                  height: 46,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: amounts.length,
                    itemBuilder: (_, i) {
                      final isSel = selectedAmountIndex == i;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Material(
                          color: isSel
                              ? AppColors.primary
                              : AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(22),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(22),
                            onTap: () => setLocal(() {
                              selectedAmountIndex = i;
                              customCtrl.clear();
                            }),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                    color: isSel
                                        ? AppColors.primary
                                        : AppColors.border),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isSel) ...[
                                    Icon(Icons.check_rounded,
                                        size: 14,
                                        color: AppColors.background),
                                    const SizedBox(width: 4),
                                  ],
                                  Text(
                                    'GHS ${amounts[i].toInt()}',
                                    style: AppTextStyles.labelMedium.copyWith(
                                      color: isSel
                                          ? AppColors.background
                                          : AppColors.textPrimary,
                                      fontWeight: isSel
                                          ? FontWeight.w700
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: customCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setLocal(() => selectedAmountIndex = -1),
                  style: AppTextStyles.bodyMedium,
                  decoration: InputDecoration(
                    hintText: 'Or enter custom amount',
                    prefixText: 'GHS  ',
                    hintStyle: AppTextStyles.bodySmall
                        .copyWith(color: AppColors.textTertiary),
                    filled: true,
                    fillColor: AppColors.surfaceAlt,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.border)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: AppColors.primary, width: 1.5)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Pay with', style: AppTextStyles.labelLarge),
                const SizedBox(height: 10),
                ...methods.asMap().entries.map((e) {
                  final isSel = selectedMethodIndex == e.key;
                  final m = e.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: isSel
                          ? AppColors.primary.withValues(alpha: 0.06)
                          : AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () =>
                            setLocal(() => selectedMethodIndex = e.key),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSel
                                  ? AppColors.primary
                                  : AppColors.border,
                              width: isSel ? 1.5 : 0.8,
                            ),
                          ),
                          child: Row(children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: m.color.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(m.icon, color: m.color, size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.label,
                                      style: AppTextStyles.labelLarge),
                                  Text(m.sub, style: AppTextStyles.caption),
                                ],
                              ),
                            ),
                            Icon(
                              isSel
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_off_rounded,
                              color: isSel
                                  ? AppColors.primary
                                  : AppColors.textTertiary,
                              size: 18,
                            ),
                          ]),
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 8),
                _SecurityBadge(),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: !canPay
                        ? null
                        : () async {
                            Navigator.pop(ctx);
                            await _processTopUp(
                              resolvedAmount,
                              methods[selectedMethodIndex].value,
                            );
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.background,
                      disabledBackgroundColor:
                          AppColors.primary.withValues(alpha: 0.35),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text(
                      canPay
                          ? 'Pay GHS ${resolvedAmount.toStringAsFixed(2)} via MoMo'
                          : 'Select an amount',
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── FIX 1 + 2: loading state + correct channel mapping — UNCHANGED ──
  Future<void> _processTopUp(double amount, String method) async {
    if (!mounted) return;
    if (Navigator.canPop(context)) Navigator.pop(context);

    if (!mounted) return;
    final success = await showBridgeMomoSheet(context, amount: amount);

    if (success && mounted) {
      await _refresh();
      _showSuccess('GHS ${amount.toStringAsFixed(2)} added to your wallet');
    }
  }

  void _showTransferSheet() => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SheetHandle(),
              const SizedBox(height: 16),
              Text('Transfer to rider', style: AppTextStyles.heading3),
              const SizedBox(height: 4),
              Text('Coming soon',
                  style: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.textSecondary)),
              const SizedBox(height: 20),
              PrimaryButton(
                  label: 'Coming Soon', onTap: () => Navigator.pop(context)),
            ],
          ),
        ),
      );

  void _showFilterSheet() {
    String tempFilter = _activeFilter;
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SheetHandle(),
              const SizedBox(height: 16),
              Text('Filter transactions', style: AppTextStyles.heading3),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _filters.map((f) {
                  final isSel = tempFilter == f;
                  return Material(
                    color:
                        isSel ? AppColors.primary : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => setLocal(() => tempFilter = f),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: isSel
                                  ? AppColors.primary
                                  : AppColors.border),
                        ),
                        child: Text(f,
                            style: AppTextStyles.labelMedium.copyWith(
                              color: isSel
                                  ? AppColors.background
                                  : AppColors.textSecondary,
                            )),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              PrimaryButton(
                label: 'Apply',
                onTap: () {
                  setState(() => _activeFilter = tempFilter);
                  Navigator.pop(ctx);
                },
              ),
              const SizedBox(height: 8),
              Center(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _activeFilter = 'All');
                    Navigator.pop(ctx);
                  },
                  child: Text('Clear filter',
                      style: AppTextStyles.bodySmall
                          .copyWith(color: AppColors.textSecondary)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── FIX 3: correct refresh for StreamProviders — UNCHANGED ──
  Future<void> _refresh() async {
    await ref.read(walletProvider.notifier).refresh();
    ref.invalidate(walletStreamProvider); // ← re-subscribes stream
    ref.invalidate(recentTransactionsStreamProvider); // ← re-subscribes stream
    ref.invalidate(transactionHistoryProvider); // ← busts future cache
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AppColors.error,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(msg)),
      ]),
      backgroundColor: AppColors.success,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  // ── FIX 2: UI labels unchanged, values mapped in _toPaystackChannel — UNCHANGED ──
  List<_PayMethod> _payMethods() => [
        _PayMethod(
          label: 'MTN Mobile Money',
          sub: 'MTN MoMo — 024, 054, 055, 059',
          icon: Icons.phone_android_rounded,
          color: const Color(0xFFFFCC00),
          value: 'MTN',
        ),
        _PayMethod(
          label: 'Telecel Cash',
          sub: 'Telecel — 020, 050',
          icon: Icons.phone_android_rounded,
          color: const Color(0xFFE60000),
          value: 'TELECEL',
        ),
        _PayMethod(
          label: 'AirtelTigo Money',
          sub: 'AirtelTigo — 027, 057, 026, 056',
          icon: Icons.phone_android_rounded,
          color: const Color(0xFF1565C0),
          value: 'AIRTELTIGO',
        ),
      ];

  String _formatDate(DateTime date) {
    final diff = DateTime.now().difference(date).inDays;
    if (diff == 0) {
      return 'Today ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
    }
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return '${date.day}/${date.month}';
    return '${date.day}/${date.month}/${date.year}';
  }

  String _formatFullDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final h = date.hour;
    final m = date.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final hour = h > 12 ? h - 12 : (h == 0 ? 12 : h);
    return '${months[date.month - 1]} ${date.day}, ${date.year} · $hour:$m $period';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MODELS — UNCHANGED
// ─────────────────────────────────────────────────────────────────────────────

class TxItem {
  final IconData icon;
  final Color iconBg, iconColor;
  final String label, sub, amount, type, ref, fullDate, status, note;
  final bool isCredit;

  const TxItem({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.label,
    required this.sub,
    required this.amount,
    required this.isCredit,
    required this.type,
    required this.ref,
    required this.fullDate,
    required this.status,
    required this.note,
  });
}

class _WalletStats {
  final int tripCount;
  final double totalSpent;
  final double totalSaved;
  const _WalletStats({
    required this.tripCount,
    required this.totalSpent,
    required this.totalSaved,
  });
}

class _TxMeta {
  final IconData icon;
  final Color bg, fg;
  const _TxMeta({required this.icon, required this.bg, required this.fg});
}

class _PayMethod {
  final String label, sub, value;
  final IconData icon;
  final Color color;
  const _PayMethod({
    required this.label,
    required this.sub,
    required this.icon,
    required this.color,
    required this.value,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// PRIVATE WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

// Subtle woven diagonal-line motif confined to the hero card's corner —
// the one bold gesture on this screen; a quiet nod, not a costume.
class _WeavePatternPainter extends CustomPainter {
  final Color color;
  const _WeavePatternPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    final region = Rect.fromLTWH(
      size.width * 0.45,
      -size.height * 0.15,
      size.width * 0.75,
      size.height * 0.75,
    );

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));

    const spacing = 22.0;
    for (double x = region.left - region.height;
        x < region.right;
        x += spacing) {
      canvas.drawLine(
        Offset(x, region.bottom),
        Offset(x + region.height, region.top),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WeavePatternPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _AddMoneyButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AddMoneyButton({required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, color: AppColors.background, size: 15),
                const SizedBox(width: 5),
                Text('Add Money',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.background,
                    )),
              ],
            ),
          ),
        ),
      );
}

class _VisibilityToggle extends StatelessWidget {
  final bool visible;
  final VoidCallback onTap;
  const _VisibilityToggle({required this.visible, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              visible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              color: AppColors.textOnDarkMuted,
              size: 20,
            ),
          ),
        ),
      );
}

class _BalanceSkeleton extends StatelessWidget {
  const _BalanceSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Container(
        height: 38,
        width: 180,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
      );
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionBtn(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Material(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: AppColors.darkNavy, size: 18),
                  const SizedBox(width: 8),
                  Text(label,
                      style: AppTextStyles.labelLarge.copyWith(
                        color: AppColors.darkNavy,
                        fontWeight: FontWeight.w700,
                      )),
                ],
              ),
            ),
          ),
        ),
      );
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String value, label;
  final Color color;
  const _StatChip({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(height: 8),
          Text(value, style: AppTextStyles.heading4.copyWith(color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: AppTextStyles.caption, textAlign: TextAlign.center),
        ]),
      );
}

class _StatsDiv extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
      width: 0.5,
      height: 36,
      color: AppColors.border,
      margin: const EdgeInsets.symmetric(horizontal: 12));
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  Color get _color {
    final s = status.toLowerCase();
    if (s.contains('complete') || s.contains('success')) {
      return AppColors.success;
    }
    if (s.contains('fail') || s.contains('cancel')) return AppColors.error;
    if (s.contains('pending')) return AppColors.warning;
    return AppColors.warning;
  }

  String get _label {
    final s = status.split('.').last;
    return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(_label,
            style: AppTextStyles.caption.copyWith(
              color: _color,
              fontSize: 9,
              fontWeight: FontWeight.w700,
            )),
      );
}

class _SheetHandle extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.border,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

class _SecurityBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.successLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_rounded, color: AppColors.success, size: 14),
            const SizedBox(width: 6),
            Text('Secured by Bridge · MoMo payments only',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.success,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
      );
}