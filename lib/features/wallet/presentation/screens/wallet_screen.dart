// lib/features/wallet/presentation/screens/wallet_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../widgets/common/shared_widgets.dart';
import '../providers/wallet_providers.dart';
import '../providers/wallet_controller.dart';
import 'transaction_detail_screen.dart';
import '../../domain/entities/transaction.dart';
import '../../domain/entities/wallet.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Derived stats provider — computed from live transaction stream
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
      if (cat == 'ride' || desc.contains('ride') ||
          desc.contains('taxi') || desc.contains('okada')) {
        tripCount++;
      }
    } else if (tx.type == TransactionType.credit) {
      final desc = tx.description.toLowerCase();
      if (desc.contains('promo') || desc.contains('bonus') ||
          desc.contains('reward') || desc.contains('cashback')) {
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
// WALLET SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class WalletScreen extends ConsumerStatefulWidget {
  final ScrollController scrollController;

  const WalletScreen({super.key, required this.scrollController});

  @override
  ConsumerState<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends ConsumerState<WalletScreen> {

  String _activeFilter = 'All';
  bool _balanceVisible = true;

  static const _filters = [
    'All', 'Rides', 'Deliveries', 'Gas', 'Top-ups', 'Transfers',
  ];

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final walletAsync = ref.watch(walletStreamProvider);
    final txAsync    = ref.watch(recentTransactionsStreamProvider);
    final stats      = ref.watch(_walletStatsProvider);

    ref.listen<AsyncValue<Wallet>>(walletStreamProvider, (_, next) {
      next.whenOrNull(error: (e, _) => _showError('Wallet error: $e'));
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: widget.scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [

            SliverToBoxAdapter(
              child: walletAsync.when(
                data:    (w) => _buildBalanceHeader(w),
                loading: ()  => _buildBalanceHeader(null),
                error:   (_, __) => _buildBalanceHeader(null),
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
                // Pre-build flat item list to avoid O(n²) builder
                final items = _buildFlatItemList(_groupTransactions(filtered));
                return SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) => items[i],
                    childCount: items.length,
                  ),
                );
              },
              loading: () => SliverToBoxAdapter(child: _buildTxSkeleton()),
              error:   (e, _) => SliverToBoxAdapter(
                  child: _buildTxError(e.toString())),
            ),

            SliverToBoxAdapter(
              child: SizedBox(
                  height: MediaQuery.of(context).padding.bottom + 32),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Balance header
  // ─────────────────────────────────────────────

  Widget _buildBalanceHeader(Wallet? wallet) {
    final balance = wallet?.totalBalance ?? 0.0;

    return Container(
      color: AppColors.darkNavy,
      padding: EdgeInsets.only(
        top:    MediaQuery.of(context).padding.top + 16,
        left:   20,
        right:  20,
        bottom: 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Title + add money ──
          Row(
            children: [
              Text('My Wallet',
                  style: AppTextStyles.heading3
                      .copyWith(color: AppColors.background)),
              const Spacer(),
              _AddMoneyButton(onTap: _showTopUpSheet),
            ],
          ),

          const SizedBox(height: 24),

          // ── Balance label ──
          Text('Available Balance',
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textOnDarkMuted)),
          const SizedBox(height: 6),

          // ── Balance value + visibility toggle ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: wallet == null
                    ? _BalanceSkeleton(key: const ValueKey('skeleton'))
                    : _balanceVisible
                        ? Text(
                            'GHS ${balance.toStringAsFixed(2)}',
                            key: const ValueKey('visible'),
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              color: AppColors.background,
                              letterSpacing: -0.5,
                            ),
                          )
                        : const Text(
                            'GHS ••••••',
                            key: ValueKey('hidden'),
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              color: AppColors.background,
                              letterSpacing: 3,
                            ),
                          ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _balanceVisible = !_balanceVisible);
                },
                child: Icon(
                  _balanceVisible
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: AppColors.textOnDarkMuted,
                  size: 20,
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Action buttons ──
          Row(
            children: [
              _ActionBtn(icon: Icons.arrow_upward_rounded,
                  label: 'Top Up',   onTap: _showTopUpSheet),
              const SizedBox(width: 10),
              _ActionBtn(icon: Icons.arrow_downward_rounded,
                  label: 'Withdraw', onTap: _showWithdrawSheet),
              const SizedBox(width: 10),
              _ActionBtn(icon: Icons.swap_horiz_rounded,
                  label: 'Transfer', onTap: _showTransferSheet),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Stats row — all values from live data
  // ─────────────────────────────────────────────

  Widget _buildStatsRow(_WalletStats stats) => ColoredBox(
        color: AppColors.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              _StatChip(
                value: '${stats.tripCount}',
                label: 'Trips',
                color: AppColors.success,
              ),
              _StatsDiv(),
              _StatChip(
                value: 'GHS ${stats.totalSpent.toStringAsFixed(0)}',
                label: 'Total spent',
                color: AppColors.info,
              ),
              _StatsDiv(),
              _StatChip(
                value: 'GHS ${stats.totalSaved.toStringAsFixed(0)}',
                label: 'Saved',
                color: AppColors.primary,
              ),
            ],
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // Section header
  // ─────────────────────────────────────────────

  Widget _buildSectionHeader() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Transactions', style: AppTextStyles.heading4),
            GestureDetector(
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
          ],
        ),
      );

  // ─────────────────────────────────────────────
  // Filter chips
  // ─────────────────────────────────────────────

  Widget _buildFilterChips() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: _filters.map((f) {
            final isActive = _activeFilter == f;
            return GestureDetector(
              onTap: () => setState(() => _activeFilter = f),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: isActive
                      ? AppColors.primary
                      : AppColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: isActive
                          ? AppColors.primary
                          : AppColors.border),
                ),
                child: Text(f,
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isActive
                          ? AppColors.background
                          : AppColors.textSecondary,
                      fontWeight: isActive
                          ? FontWeight.w700
                          : FontWeight.w400,
                    )),
              ),
            );
          }).toList(),
        ),
      );

  // ─────────────────────────────────────────────
  // Transaction filtering & grouping
  // ─────────────────────────────────────────────

  List<Transaction> _filterTransactions(List<Transaction> all) {
    if (_activeFilter == 'All') return all;
    return all
        .where((tx) => _categoryLabel(tx) == _activeFilter)
        .toList();
  }

  Map<String, List<Transaction>> _groupTransactions(
      List<Transaction> list) {
    final map = <String, List<Transaction>>{};
    for (final tx in list) {
      map.putIfAbsent(_dateGroupKey(tx.createdAt), () => []).add(tx);
    }
    return map;
  }

  /// Pre-builds a flat widget list from grouped transactions so the
  /// SliverChildBuilderDelegate is O(1) per item instead of O(n²).
  List<Widget> _buildFlatItemList(
      Map<String, List<Transaction>> grouped) {
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
    final cat  = (tx.metadata?['category'] as String? ?? '').toLowerCase();
    final desc = tx.description.toLowerCase();
    if (cat == 'gas_order'  || desc.contains('gas'))      return 'Gas';
    if (cat == 'delivery'   || desc.contains('delivery')) return 'Deliveries';
    if (cat == 'transfer'   || desc.contains('transfer')) return 'Transfers';
    if (cat == 'ride'       || desc.contains('ride') ||
        desc.contains('taxi') || desc.contains('okada'))  return 'Rides';
    return 'Rides';
  }

  String _dateGroupKey(DateTime date) {
    final diff = DateTime.now().difference(date).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7)  return 'This Week';
    return 'Earlier';
  }

  // ─────────────────────────────────────────────
  // Transaction tile
  // ─────────────────────────────────────────────

  Widget _groupHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Text(label,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            )),
      );

  Widget _buildTxTile(Transaction tx) {
    final isCredit = tx.type == TransactionType.credit;
    final category = _categoryLabel(tx);
    final meta     = _txMeta(isCredit, category);

    final txItem = TxItem(
      icon:     meta.icon,
      iconBg:   meta.bg,
      iconColor: meta.fg,
      label:    tx.description,
      sub:      _formatDate(tx.createdAt),
      amount:   '${isCredit ? '+' : '-'}GHS ${tx.amount.toStringAsFixed(2)}',
      isCredit: isCredit,
      type:     category,
      ref:      tx.reference,
      fullDate: _formatFullDate(tx.createdAt),
      status:   tx.status.toString().split('.').last,
      note:     tx.metadata?['note'] as String? ?? '',
    );

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => TransactionDetailScreen(tx: txItem)),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                  color: meta.bg,
                  borderRadius: BorderRadius.circular(12)),
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
                  const SizedBox(height: 2),
                  Text(_formatDate(tx.createdAt),
                      style: AppTextStyles.caption),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${isCredit ? '+' : '-'}GHS ${tx.amount.toStringAsFixed(2)}',
                  style: AppTextStyles.labelLarge.copyWith(
                    color: isCredit
                        ? AppColors.success
                        : AppColors.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                _StatusBadge(status: tx.status.toString()),
              ],
            ),
          ],
        ),
      ),
    );
  }

  _TxMeta _txMeta(bool isCredit, String category) {
    if (isCredit) {
      return _TxMeta(
        icon: Icons.arrow_upward_rounded,
        bg: AppColors.successLight,
        fg: AppColors.success,
      );
    }
    switch (category) {
      case 'Gas':
        return _TxMeta(
          icon: Icons.local_fire_department_rounded,
          bg: const Color(0xFFFEF3C7),
          fg: const Color(0xFFD97706),
        );
      case 'Deliveries':
        return _TxMeta(
          icon: Icons.inventory_2_rounded,
          bg: AppColors.infoLight,
          fg: AppColors.info,
        );
      case 'Transfers':
        return _TxMeta(
          icon: Icons.swap_horiz_rounded,
          bg: const Color(0xFFF3E8FF),
          fg: const Color(0xFF7C3AED),
        );
      default:
        return _TxMeta(
          icon: Icons.directions_car_rounded,
          bg: AppColors.errorLight,
          fg: AppColors.error,
        );
    }
  }

  // ─────────────────────────────────────────────
  // States: empty / skeleton / error
  // ─────────────────────────────────────────────

  Widget _buildEmptyState() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 20),
        child: Center(
          child: Column(children: [
            Container(
              width: 72, height: 72,
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
            Text('Could not load transactions',
                style: AppTextStyles.heading4),
            const SizedBox(height: 6),
            Text(message,
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _refresh,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('Retry',
                    style: AppTextStyles.labelMedium
                        .copyWith(color: AppColors.background)),
              ),
            ),
          ]),
        ),
      );

  // ─────────────────────────────────────────────
  // Top-up sheet
  // ─────────────────────────────────────────────

  void _showTopUpSheet() {
    int selectedAmountIndex  = -1;
    int selectedMethodIndex  = 0;
    final customCtrl = TextEditingController();

    // Amounts fetched from remote config in a full implementation;
    // kept here as sensible GHS defaults.
    final amounts  = [20.0, 50.0, 100.0, 200.0, 500.0];
    final methods  = _payMethods();

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
          final canPay =
              resolvedAmount != null && resolvedAmount > 0;

          return SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 20, right: 20, top: 16,
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

                // Amount presets
                Text('Select amount', style: AppTextStyles.labelLarge),
                const SizedBox(height: 10),
                SizedBox(
                  height: 44,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: amounts.length,
                    itemBuilder: (_, i) {
                      final isSel = selectedAmountIndex == i;
                      return GestureDetector(
                        onTap: () => setLocal(() {
                          selectedAmountIndex = i;
                          customCtrl.clear();
                        }),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSel
                                ? AppColors.primary
                                : AppColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                                color: isSel
                                    ? AppColors.primary
                                    : AppColors.border),
                          ),
                          child: Text(
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
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),

                // Custom amount
                TextField(
                  controller: customCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  onChanged: (_) =>
                      setLocal(() => selectedAmountIndex = -1),
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
                        borderSide:
                            const BorderSide(color: AppColors.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: AppColors.border)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: AppColors.primary, width: 1.5)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 20),

                // Payment methods
                Text('Pay with', style: AppTextStyles.labelLarge),
                const SizedBox(height: 10),
                ...methods.asMap().entries.map((e) {
                  final isSel = selectedMethodIndex == e.key;
                  final m     = e.value;
                  return GestureDetector(
                    onTap: () =>
                        setLocal(() => selectedMethodIndex = e.key),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: isSel
                            ? AppColors.primary
                                .withValues(alpha: 0.06)
                            : AppColors.surfaceAlt,
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
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: m.color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child:
                              Icon(m.icon, color: m.color, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(m.label,
                                  style: AppTextStyles.labelLarge),
                              Text(m.sub,
                                  style: AppTextStyles.caption),
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
                  );
                }),

                const SizedBox(height: 16),

                // Security badge
                _SecurityBadge(),

                const SizedBox(height: 16),

                // CTA
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: !canPay
                        ? null
                        : () async {
                            Navigator.pop(ctx);
                            await _processTopUp(
                              resolvedAmount!,
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
                          ? 'Pay GHS ${resolvedAmount!.toStringAsFixed(2)} via Paystack'
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

  // ─────────────────────────────────────────────
  // Process top-up
  // WalletController handles email resolution for phone-auth users.
  // ─────────────────────────────────────────────

  Future<void> _processTopUp(double amount, String method) async {
    try {
      final success = await ref.read(walletControllerProvider).topUp(
        amount: amount,
        paymentMethod: method,
      );
      if (success && mounted) {
        await _refresh();
        _showSuccess(
            'GHS ${amount.toStringAsFixed(2)} added to your wallet');
      }
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      msg.contains('cancelled')
          ? _showError('Payment cancelled')
          : _showError('Top-up failed: $msg');
    }
  }

  // ─────────────────────────────────────────────
  // Withdraw sheet
  // ─────────────────────────────────────────────

  void _showWithdrawSheet() => showModalBottomSheet(
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
              Text('Withdraw funds', style: AppTextStyles.heading3),
              const SizedBox(height: 4),
              Text('Coming soon — withdrawal in development',
                  style: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.textSecondary)),
              const SizedBox(height: 20),
              PrimaryButton(
                  label: 'Close',
                  onTap: () => Navigator.pop(context)),
            ],
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // Transfer sheet
  // ─────────────────────────────────────────────

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
                  label: 'Coming Soon',
                  onTap: () => Navigator.pop(context)),
            ],
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // Filter sheet
  // ─────────────────────────────────────────────

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
                spacing: 8, runSpacing: 8,
                children: _filters.map((f) {
                  final isSel = tempFilter == f;
                  return GestureDetector(
                    onTap: () => setLocal(() => tempFilter = f),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSel
                            ? AppColors.primary
                            : AppColors.surfaceAlt,
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

  // ─────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────

  Future<void> _refresh() async {
    await ref.read(walletProvider.notifier).refresh();
    ref.invalidate(transactionHistoryProvider);
    ref.invalidate(recentTransactionsStreamProvider);
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AppColors.error,
    ));
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.check_circle_rounded,
            color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(msg)),
      ]),
      backgroundColor: AppColors.success,
    ));
  }

  List<_PayMethod> _payMethods() => [
        _PayMethod(
          label: 'MTN MoMo',
          sub: 'Mobile Money',
          icon: Icons.phone_android_rounded,
          color: const Color(0xFFFFCC00),
          value: 'momo',
        ),
        _PayMethod(
          label: 'Vodafone Cash',
          sub: 'Mobile Money',
          icon: Icons.phone_android_rounded,
          color: const Color(0xFFE60000),
          value: 'vodafone',
        ),
        _PayMethod(
          label: 'Debit / Credit Card',
          sub: 'Visa · Mastercard',
          icon: Icons.credit_card_rounded,
          color: AppColors.info,
          value: 'card',
        ),
      ];

  String _formatDate(DateTime date) {
    final diff = DateTime.now().difference(date).inDays;
    if (diff == 0) {
      return 'Today ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
    }
    if (diff == 1) return 'Yesterday';
    if (diff < 7)  return '${date.day}/${date.month}';
    return '${date.day}/${date.month}/${date.year}';
  }

  String _formatFullDate(DateTime date) {
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec',
    ];
    final h      = date.hour;
    final m      = date.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final hour   = h > 12 ? h - 12 : (h == 0 ? 12 : h);
    return '${months[date.month - 1]} ${date.day}, ${date.year} · $hour:$m $period';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MODELS
// ─────────────────────────────────────────────────────────────────────────────

class TxItem {
  final IconData icon;
  final Color    iconBg, iconColor;
  final String   label, sub, amount, type, ref, fullDate, status, note;
  final bool     isCredit;

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
  final int    tripCount;
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
  final Color    bg, fg;
  const _TxMeta({required this.icon, required this.bg, required this.fg});
}

class _PayMethod {
  final String   label, sub, value;
  final IconData icon;
  final Color    color;
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

class _AddMoneyButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AddMoneyButton({required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded,
                  color: AppColors.background, size: 15),
              SizedBox(width: 5),
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
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;
  const _ActionBtn(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(children: [
              Icon(icon, color: AppColors.background, size: 19),
              const SizedBox(height: 4),
              Text(label,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.background)),
            ]),
          ),
        ),
      );
}

class _StatChip extends StatelessWidget {
  final String value, label;
  final Color  color;
  const _StatChip(
      {required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(value,
              style: AppTextStyles.heading4.copyWith(color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: AppTextStyles.caption,
              textAlign: TextAlign.center),
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
    return AppColors.warning;
  }

  @override
  Widget build(BuildContext context) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          status.split('.').last,
          style: AppTextStyles.caption.copyWith(
            color: _color,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

class _SheetHandle extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 40, height: 4,
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
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.successLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_rounded,
                color: AppColors.success, size: 14),
            const SizedBox(width: 6),
            Text(
              'Secured by Paystack · 256-bit encryption',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.success,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}