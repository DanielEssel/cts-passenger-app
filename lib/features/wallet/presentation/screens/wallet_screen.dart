// lib/features/wallet/presentation/screens/wallet_screen.dart

import 'package:flutter/material.dart';
import '../../../../core/theme/cts_theme.dart';
import '../../../../core/widgets/cts_ui.dart';
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

    ref.listen<AsyncValue<Wallet>>(walletStreamProvider, (_, next) {
      next.whenOrNull(error: (e, _) {
        debugPrint('Wallet stream error: $e');
        _showError("We couldn't load your wallet. Pull down to try again.");
      });
    });

    final reduceMotion = MediaQuery.of(context).disableAnimations;

    final scrollView = CustomScrollView(
      controller: widget.scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        const SliverToBoxAdapter(
          child: SafeArea(bottom: false, child: CtsPageTitle('Wallet')),
        ),
        SliverToBoxAdapter(
          child: walletAsync.when(
            data: (w) => _buildBalanceCard(w),
            loading: () => _buildBalanceCard(null),
            error: (_, __) => _buildBalanceCard(null),
          ),
        ),
        SliverToBoxAdapter(child: _buildActivityHeader()),
        SliverToBoxAdapter(child: _buildFilterChips()),
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
          error: (e, _) {
            debugPrint('Transactions stream error: $e');
            return SliverToBoxAdapter(
                child: _buildTxError('Check your connection and try again.'));
          },
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

    // The MoMo sheet shows every payment stage itself, so the page needs
    // no overlay of its own.
    return Scaffold(
      backgroundColor: CtsTheme.background,
      body: RefreshIndicator(
        color: CtsTheme.primary,
        onRefresh: _refresh,
        child: animatedContent,
      ),
    );
  }

  // ── Balance card — the one deep-green surface on this screen ──
  //
  // Shows the wallet's total; when part of it is held for a trip in
  // progress, splits it into what can be spent now and what is on hold.
  Widget _buildBalanceCard(Wallet? wallet) {
    final total = wallet?.totalBalance ?? 0.0;
    final held = wallet?.heldBalance ?? 0.0;
    final available = wallet?.availableBalance ?? 0.0;
    final showSplit = wallet != null && held > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(ctsGutter, 0, ctsGutter, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(CtsTheme.radiusXl),
        child: DecoratedBox(
          decoration: const BoxDecoration(gradient: CtsTheme.forestGradient),
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
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.account_balance_wallet_rounded,
                            size: 18, color: CtsTheme.vivid),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                              showSplit ? 'Total balance' : 'Available balance',
                              style: CtsText.label
                                  .copyWith(color: CtsTheme.onForestMuted)),
                        ),
                        _VisibilityToggle(
                          visible: _balanceVisible,
                          onTap: () {
                            HapticFeedback.lightImpact();
                            setState(() => _balanceVisible = !_balanceVisible);
                          },
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        transitionBuilder: (child, anim) =>
                            FadeTransition(opacity: anim, child: child),
                        child: wallet == null
                            ? _BalanceSkeleton(key: const ValueKey('skeleton'))
                            : FittedBox(
                                key: ValueKey(_balanceVisible),
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: _BalanceAmount(
                                    amount: total, visible: _balanceVisible),
                              ),
                      ),
                    ),
                    if (showSplit) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: _BalanceSplit(
                          available: available,
                          held: held,
                          visible: _balanceVisible,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: CtsPrimaryButton(
                        label: 'Top up',
                        icon: Icons.add_rounded,
                        onPressed: _showTopUpSheet,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActivityHeader() => Padding(
        padding: const EdgeInsets.fromLTRB(ctsGutter, 28, ctsGutter, 12),
        child: Semantics(
          header: true,
          child: Text('Recent activity', style: CtsText.title3),
        ),
      );

  Widget _buildFilterChips() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: ctsGutter),
        child: Row(
          children: _filters.map((f) {
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: CtsFilterChip(
                label: f,
                icon: _filterIcons[f],
                selected: _activeFilter == f,
                onTap: () => setState(() => _activeFilter = f),
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

  // One ledger card per date group, rows separated by hairlines.
  List<Widget> _buildFlatItemList(Map<String, List<Transaction>> grouped) {
    final widgets = <Widget>[];
    for (final entry in grouped.entries) {
      widgets.add(CtsGroupLabel(entry.key));
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: ctsGutter),
        child: _LedgerCard(children: [
          for (final tx in entry.value) _buildTxRow(tx, entry.key),
        ]),
      ));
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

  Widget _buildTxRow(Transaction tx, String group) {
    final isCredit = tx.type == TransactionType.credit;
    final category = _categoryLabel(tx);
    final meta = _txMeta(isCredit, category);

    final txItem = TxItem(
      icon: meta.icon,
      iconBg: meta.bg,
      iconColor: meta.fg,
      label: tx.description,
      sub: _formatDate(tx.createdAt),
      amount: '${isCredit ? '+' : '-'}GHS ${ctsMoney(tx.amount)}',
      isCredit: isCredit,
      type: category,
      ref: tx.reference,
      fullDate: _formatFullDate(tx.createdAt),
      status: tx.status.toString().split('.').last,
      note: tx.metadata?['note'] as String? ?? '',
    );

    final when = _rowTime(tx.createdAt, group);
    final kind = meta.kind;
    final statusName = tx.status.name;
    final statusText = statusName[0].toUpperCase() + statusName.substring(1);

    return _TxRow(
      icon: meta.icon,
      tone: meta.tone,
      title: tx.description.isEmpty ? kind : tx.description,
      subtitle: '$kind · $when',
      amount: ctsMoney(tx.amount),
      isCredit: isCredit,
      status: tx.status,
      semanticsLabel: '${tx.description.isEmpty ? kind : tx.description}, '
          '${isCredit ? 'received' : 'paid'} GHS ${ctsMoney(tx.amount)}, '
          '$statusText, $when',
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => TransactionDetailScreen(tx: txItem)),
      ),
    );
  }

  // Time for rows under "Today"/"Yesterday"; day and time further back.
  String _rowTime(DateTime d, String group) {
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
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final time = '$h:${d.minute.toString().padLeft(2, '0')} '
        '${d.hour >= 12 ? 'PM' : 'AM'}';
    if (group == 'Today' || group == 'Yesterday') return time;
    final year = d.year == DateTime.now().year ? '' : ' ${d.year}';
    return '${d.day} ${months[d.month - 1]}$year';
  }

  // Same service colours as Trips: rides green, deliveries sky, gas ember.
  _TxMeta _txMeta(bool isCredit, String category) {
    if (isCredit) {
      return _TxMeta(
          icon: Icons.south_west_rounded,
          tone: CtsTone.success,
          kind: 'Money in');
    }
    switch (category) {
      case 'Gas':
        return _TxMeta(
            icon: Icons.local_fire_department_rounded,
            tone: CtsTone.gas,
            kind: 'Gas');
      case 'Deliveries':
        return _TxMeta(
            icon: Icons.inventory_2_rounded,
            tone: CtsTone.delivery,
            kind: 'Delivery');
      case 'Transfers':
        return _TxMeta(
            icon: Icons.swap_horiz_rounded,
            tone: CtsTone.info,
            kind: 'Transfer');
      default:
        return _TxMeta(
            icon: Icons.directions_car_rounded,
            tone: CtsTone.brand,
            kind: 'Ride');
    }
  }

  Widget _buildEmptyState() => _activeFilter == 'All'
      ? const CtsEmptyState(
          icon: Icons.receipt_long_rounded,
          title: 'No transactions yet',
          message: 'Your top-ups and payments will appear here.',
        )
      : CtsEmptyState(
          icon: _filterIcons[_activeFilter] ?? Icons.receipt_long_rounded,
          title: 'No ${_activeFilter.toLowerCase()} yet',
          message: 'Nothing in this category among your recent activity.',
          actionLabel: 'Show all activity',
          onAction: () => setState(() => _activeFilter = 'All'),
        );

  Widget _buildTxSkeleton() => Padding(
        padding: const EdgeInsets.fromLTRB(ctsGutter, 22, ctsGutter, 0),
        child: Semantics(
          label: 'Loading transactions',
          child: _LedgerCard(
            children: List.generate(
              4,
              (_) => const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    CtsSkeleton(width: 40, height: 40, radius: 20),
                    SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CtsSkeleton(width: 150),
                          SizedBox(height: 8),
                          CtsSkeleton(width: 90, height: 11),
                        ],
                      ),
                    ),
                    CtsSkeleton(width: 60),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  Widget _buildTxError(String message) => CtsEmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load transactions',
        message: message,
        actionLabel: 'Retry',
        onAction: _refresh,
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
                Text('Mobile Money via The Bridge Solutions',
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
                          color:
                              isSel ? AppColors.primary : AppColors.surfaceAlt,
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
                                        size: 14, color: AppColors.background),
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
                              color:
                                  isSel ? AppColors.primary : AppColors.border,
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

  // The amount sheet has already closed itself (Navigator.pop(ctx) above),
  // so nothing else is popped here: an extra pop would close the Wallet
  // page itself when it was opened as /wallet from a booking screen.
  // The MoMo sheet returns true only after a confirmed success.
  Future<void> _processTopUp(double amount, String method) async {
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

  // ── FIX 2: Mobile Money networks offered for Bridge top-ups ──
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

class _TxMeta {
  final IconData icon;
  final CtsTone tone;
  final String kind; // short category shown under the description
  _TxMeta({required this.icon, required this.tone, required this.kind});
  Color get bg => tone.background;
  Color get fg => tone.foreground;
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

class _VisibilityToggle extends StatelessWidget {
  final bool visible;
  final VoidCallback onTap;
  const _VisibilityToggle({required this.visible, required this.onTap});

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: onTap,
        tooltip: visible ? 'Hide balance' : 'Show balance',
        icon: Icon(
          visible ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          color: CtsTheme.onForestMuted,
          size: 22,
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

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  CtsTone get _tone {
    final s = status.toLowerCase();
    if (s.contains('complete') || s.contains('success')) {
      return CtsTone.success;
    }
    if (s.contains('fail') || s.contains('cancel')) return CtsTone.error;
    if (s.contains('refund')) return CtsTone.info;
    return CtsTone.warning;
  }

  String get _label {
    final s = status.split('.').last;
    return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
  }

  @override
  Widget build(BuildContext context) => CtsStatusPill(_label, tone: _tone);
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
            Flexible(
              child: Text('Secured by Bridge · MoMo payments only',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w600,
                  )),
            ),
          ],
        ),
      );
}

// "GHS 1,290.50" with the cedi figure dominant and the currency and pesewas
// quieter, as on a bank card.
class _BalanceAmount extends StatelessWidget {
  final double amount;
  final bool visible;
  const _BalanceAmount({required this.amount, required this.visible});

  @override
  Widget build(BuildContext context) {
    const big = TextStyle(
      fontFamily: CtsTheme.fontFamily,
      fontSize: 40,
      height: 1.1,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.2,
      color: Colors.white,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    final small = big.copyWith(
        fontSize: 20, letterSpacing: -0.2, color: CtsTheme.onForestMuted);
    if (!visible) {
      return Semantics(
        label: 'Balance hidden',
        excludeSemantics: true,
        child: Text.rich(TextSpan(children: [
          TextSpan(text: 'GHS ', style: small),
          TextSpan(text: '••••••', style: big.copyWith(letterSpacing: 2)),
        ])),
      );
    }
    final text = ctsMoney(amount);
    final dot = text.lastIndexOf('.');
    return Semantics(
      label: 'GHS $text',
      excludeSemantics: true,
      child: Text.rich(TextSpan(children: [
        TextSpan(text: 'GHS ', style: small),
        TextSpan(text: text.substring(0, dot), style: big),
        TextSpan(text: text.substring(dot), style: small),
      ])),
    );
  }
}

// Available and on-hold amounts side by side (stacked with large text).
class _BalanceSplit extends StatelessWidget {
  final double available;
  final double held;
  final bool visible;
  const _BalanceSplit(
      {required this.available, required this.held, required this.visible});

  Widget _figure(String label, double value, IconData icon) => Semantics(
        label: visible ? '$label: GHS ${ctsMoney(value)}' : '$label: hidden',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 14, color: CtsTheme.onForestMuted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    style: CtsText.caption
                        .copyWith(color: CtsTheme.onForestMuted)),
              ),
            ]),
            const SizedBox(height: 4),
            Text(visible ? 'GHS ${ctsMoney(value)}' : 'GHS ••••',
                style:
                    CtsText.price.copyWith(fontSize: 16, color: Colors.white)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final a = _figure('Available', available, Icons.check_circle_rounded);
    final h = _figure('On hold', held, Icons.lock_clock_rounded);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: ctsLargeText(context)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [a, const SizedBox(height: 12), h],
            )
          : IntrinsicHeight(
              child: Row(children: [
                Expanded(child: a),
                VerticalDivider(
                    width: 24, color: Colors.white.withValues(alpha: 0.14)),
                Expanded(child: h),
              ]),
            ),
    );
  }
}

// White card holding one day's transactions, separated by hairlines.
class _LedgerCard extends StatelessWidget {
  final List<Widget> children;
  const _LedgerCard({required this.children});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: CtsTheme.surface,
          borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
          border: Border.all(color: CtsTheme.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                const Divider(
                    height: 1, indent: 70, color: CtsTheme.borderLight),
              children[i],
            ],
          ],
        ),
      );
}

// One ledger row. Amount sits right-aligned beside the description; with
// large text it moves under it so neither is squeezed.
class _TxRow extends StatelessWidget {
  final IconData icon;
  final CtsTone tone;
  final String title;
  final String subtitle;
  final String amount;
  final bool isCredit;
  final TransactionStatus status;
  final String semanticsLabel;
  final VoidCallback onTap;

  const _TxRow({
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.isCredit,
    required this.status,
    required this.semanticsLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final large = ctsLargeText(context);
    final failed = status == TransactionStatus.failed;
    final amountText = Text(
      '${isCredit ? '+' : '−'} GHS $amount',
      textAlign: TextAlign.right,
      style: CtsText.price.copyWith(
        fontSize: 15.5,
        color: failed
            ? CtsTheme.textTertiary
            : isCredit
                ? CtsTheme.primary
                : CtsTheme.textPrimary,
        decoration: failed ? TextDecoration.lineThrough : null,
      ),
    );
    final pill = status == TransactionStatus.completed
        ? null
        : _StatusBadge(status: status.toString());

    final iconDisc = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: tone.background, shape: BoxShape.circle),
      child: Icon(icon, size: 19, color: tone.foreground),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            maxLines: large ? 3 : 1,
            overflow: TextOverflow.ellipsis,
            style: CtsText.cardTitle),
        const SizedBox(height: 2),
        Text(subtitle, style: CtsText.caption),
      ],
    );

    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: large
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          iconDisc,
                          const SizedBox(width: 14),
                          Expanded(child: text),
                        ]),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [amountText, if (pill != null) pill],
                    ),
                  ],
                )
              : Row(
                  children: [
                    iconDisc,
                    const SizedBox(width: 14),
                    Expanded(child: text),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        amountText,
                        if (pill != null) ...[const SizedBox(height: 4), pill],
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
