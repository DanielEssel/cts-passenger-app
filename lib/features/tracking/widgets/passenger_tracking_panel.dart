// lib/features/tracking/widgets/passenger_tracking_panel.dart
//
// Shared presentation for the passenger's Ride, Delivery and Gas tracking
// screens, so all three read the same way:
//
//   TrackingLayout          map on top, details panel, pinned action bar
//   TrackingStatusHeader    what is happening + whether you need to act
//   TrackingProgressBar     named steps of the service's real workflow
//   TrackingDriverCard      driver details, only what is actually known
//   TrackingLocationNote    honest live / stale / unavailable location
//   TrackingActionBar       one primary action, at most one secondary
//   TrackingCancelLink      cancellation, kept apart from other actions
//   showTrackingConfirm     confirmation dialog with its own context
//   TrackingEndedScreen     cancelled / unknown / missing orders
//
// Presentation only: every decision comes from tracking_view.dart.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/cts_theme.dart';
import '../domain/tracking_view.dart';

const _charcoal = CtsTheme.textPrimary;
const _muted = CtsTheme.textSecondary;
const _green = CtsTheme.primary;
const _danger = CtsTheme.error;

// ── Layout ──────────────────────────────────────────────────────────────────

/// Map on top, a scrolling details panel below it and an action bar pinned
/// above the system navigation area, so the essential actions never scroll
/// or drag out of view.
class TrackingLayout extends StatelessWidget {
  final Widget map;
  final List<Widget> children;
  final Widget? actions;

  const TrackingLayout({
    super.key,
    required this.map,
    required this.children,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Column(
      children: [
        Expanded(flex: 42, child: map),
        Expanded(
          flex: 58,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: CtsTheme.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 18,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  20, 20, 20, actions == null ? bottomInset + 20 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
        if (actions != null) actions!,
      ],
    );
  }
}

/// 48 dp round button for use over the map.
class TrackingMapButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const TrackingMapButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: Tooltip(
          message: label,
          child: Material(
            color: CtsTheme.surface,
            shape: const CircleBorder(),
            elevation: 3,
            shadowColor: Colors.black26,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Icon(icon, color: _charcoal, size: 22),
              ),
            ),
          ),
        ),
      );
}

// ── Status ──────────────────────────────────────────────────────────────────

/// The current state in plain words, and whether the passenger must act.
/// The headline is a live region, so screen readers announce changes.
class TrackingStatusHeader extends StatelessWidget {
  final TrackingView view;

  const TrackingStatusHeader({super.key, required this.view});

  @override
  Widget build(BuildContext context) {
    final tone = switch (view.phase) {
      TrackingPhase.ended || TrackingPhase.unknown => _danger,
      TrackingPhase.review => CtsTheme.warning,
      _ => _green,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(view.icon, color: tone, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    liveRegion: true,
                    header: true,
                    child: Text(
                      view.headline,
                      style: const TextStyle(
                        fontSize: 21,
                        height: 1.2,
                        fontWeight: FontWeight.w800,
                        color: _charcoal,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    view.detail,
                    style: const TextStyle(
                        fontSize: 15, height: 1.4, color: _muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (!view.isOver &&
            view.phase != TrackingPhase.unknown &&
            view.phase != TrackingPhase.review) ...[
          const SizedBox(height: 14),
          _YouNeedTo(text: view.youNeedTo),
        ],
      ],
    );
  }
}

class _YouNeedTo extends StatelessWidget {
  final String? text;
  const _YouNeedTo({required this.text});

  @override
  Widget build(BuildContext context) {
    final act = text != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: act ? CtsTheme.warningTint : CtsTheme.primaryTint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: act ? CtsTheme.warningBorder : CtsTheme.mintBorder,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            act ? Icons.touch_app_rounded : Icons.check_circle_rounded,
            size: 20,
            color: act ? CtsTheme.warning : _green,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: act ? 'What to do: ' : '',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                TextSpan(
                  text: text ??
                      "You don't need to do anything right now. "
                          "We'll update this screen as things change.",
                ),
              ]),
              style:
                  const TextStyle(fontSize: 15, height: 1.4, color: _charcoal),
            ),
          ),
        ],
      ),
    );
  }
}

/// Named progress steps. Completed steps have a tick, the current one is
/// bold with a filled marker, upcoming ones are grey: never colour alone.
class TrackingProgressBar extends StatelessWidget {
  final List<String> steps;

  /// Current step; steps.length means every step is done.
  final int current;

  const TrackingProgressBar({
    super.key,
    required this.steps,
    required this.current,
  });

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty || current < 0) return const SizedBox.shrink();
    final allDone = current >= steps.length;
    return Semantics(
      label: allDone
          ? 'All ${steps.length} steps complete'
          : 'Step ${current + 1} of ${steps.length}: ${steps[current]}',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(child: _step(i)),
          ],
        ],
      ),
    );
  }

  Widget _step(int i) {
    final done = i < current;
    final now = i == current;
    final color = done || now ? _green : CtsTheme.border;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 5,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (done) ...[
              const Icon(Icons.check_rounded, size: 14, color: _green),
              const SizedBox(width: 2),
            ],
            Flexible(
              child: Text(
                steps[i],
                maxLines: 2,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: now ? FontWeight.w800 : FontWeight.w500,
                  color: now
                      ? _charcoal
                      : done
                          ? _muted
                          : CtsTheme.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Driver ──────────────────────────────────────────────────────────────────

/// The assigned driver, showing only details that actually exist. A missing
/// rating is not shown as 0 or 5; missing vehicle details are left out.
class TrackingDriverCard extends StatelessWidget {
  final String? name;
  final double? rating;
  final String? vehicle;
  final String? plate;

  /// "Your driver" / "Your rider".
  final String roleLabel;

  const TrackingDriverCard({
    super.key,
    required this.name,
    this.rating,
    this.vehicle,
    this.plate,
    this.roleLabel = 'Your driver',
  });

  @override
  Widget build(BuildContext context) {
    final display = (name ?? '').trim().isEmpty ? roleLabel : name!.trim();
    final parts = display.split(RegExp(r'\s+'));
    final initials = parts.length >= 2
        ? '${parts.first[0]}${parts.last[0]}'.toUpperCase()
        : display[0].toUpperCase();
    final hasRating = rating != null && rating! > 0;
    final details = [
      if ((vehicle ?? '').trim().isNotEmpty) vehicle!.trim(),
      if (hasRating) '★ ${rating!.toStringAsFixed(1)}',
    ];

    return Semantics(
      container: true,
      label: [
        '$roleLabel: $display',
        if ((vehicle ?? '').trim().isNotEmpty) vehicle!.trim(),
        if ((plate ?? '').trim().isNotEmpty) 'Plate ${plate!.trim()}',
        if (hasRating) 'rated ${rating!.toStringAsFixed(1)}',
      ].join(', '),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: CtsTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: CtsTheme.border),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: _green,
              child: Text(
                initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    roleLabel.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 12,
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w700,
                      color: _muted,
                    ),
                  ),
                  Text(
                    display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: _charcoal,
                    ),
                  ),
                  if (details.isNotEmpty)
                    Text(
                      details.join('  ·  '),
                      style: const TextStyle(fontSize: 14, color: _muted),
                    ),
                  if ((plate ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: CtsTheme.textPrimary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        plate!.trim(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Says honestly how current the driver's position on the map is. Re-checks
/// every 15 s so "Live" turns into "Updated 3 min ago" when updates stop.
class TrackingLocationNote extends StatefulWidget {
  final bool hasLocation;
  final DateTime? updatedAt;

  /// Overridable clock for tests.
  final DateTime Function() now;

  const TrackingLocationNote({
    super.key,
    required this.hasLocation,
    required this.updatedAt,
    this.now = DateTime.now,
  });

  @override
  State<TrackingLocationNote> createState() => _TrackingLocationNoteState();
}

class _TrackingLocationNoteState extends State<TrackingLocationNote> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now();
    final f = locationFreshness(
      hasLocation: widget.hasLocation,
      updatedAt: widget.updatedAt,
      now: now,
    );
    final (icon, color, text) = switch (f) {
      LocationFreshness.live => (
          Icons.circle,
          _green,
          'Live location',
        ),
      LocationFreshness.stale => (
          Icons.schedule_rounded,
          CtsTheme.warning,
          '${lastUpdatedLabel(widget.updatedAt, now)} · may have moved',
        ),
      LocationFreshness.unavailable => (
          Icons.location_off_rounded,
          _muted,
          "Driver's location isn't available yet",
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: CtsTheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 8),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: f == LocationFreshness.live ? 10 : 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _charcoal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Places ──────────────────────────────────────────────────────────────────

/// Pickup and destination addresses, with the one the driver is heading to
/// emphasised.
class TrackingRouteSummary extends StatelessWidget {
  final String fromLabel;
  final String fromAddress;
  final String? toLabel;
  final String? toAddress;
  final bool emphasiseTo;
  final String? priceLabel;

  const TrackingRouteSummary({
    super.key,
    required this.fromLabel,
    required this.fromAddress,
    this.toLabel,
    this.toAddress,
    this.emphasiseTo = false,
    this.priceLabel,
  });

  @override
  Widget build(BuildContext context) {
    Widget row(IconData icon, Color color, String label, String address,
            bool strong) =>
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _muted,
                    ),
                  ),
                  Text(
                    address.trim().isEmpty ? '—' : address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: strong ? 16 : 15,
                      fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
                      color: _charcoal,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CtsTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CtsTheme.border),
      ),
      child: Column(
        children: [
          row(Icons.trip_origin_rounded, _green, fromLabel, fromAddress,
              !emphasiseTo),
          if (toAddress != null) ...[
            const SizedBox(height: 12),
            row(Icons.place_rounded, _danger, toLabel ?? 'Destination',
                toAddress!, emphasiseTo),
          ],
          if (priceLabel != null) ...[
            const Divider(height: 24, color: CtsTheme.border),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Price',
                    style: TextStyle(fontSize: 15, color: _muted),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    priceLabel!,
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: _charcoal,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── Actions ─────────────────────────────────────────────────────────────────

class TrackingAction {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  const TrackingAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.busy = false,
  });
}

/// Pinned actions: [primary] as a filled button and an optional quieter
/// [secondary] beside it. Text scales up to [maxTextScale]; beyond that the
/// buttons would not fit a small phone.
class TrackingActionBar extends StatelessWidget {
  final TrackingAction primary;
  final TrackingAction? secondary;

  static const maxTextScale = 1.5;

  const TrackingActionBar({
    super.key,
    required this.primary,
    this.secondary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: CtsTheme.surface,
        border: Border(top: BorderSide(color: CtsTheme.borderLight)),
      ),
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: maxTextScale,
        child: Row(
          children: [
            if (secondary != null) ...[
              Expanded(child: _TrackingButton(secondary!, primary: false)),
              const SizedBox(width: 12),
            ],
            Expanded(child: _TrackingButton(primary, primary: true)),
          ],
        ),
      ),
    );
  }
}

class _TrackingButton extends StatelessWidget {
  final TrackingAction action;
  final bool primary;

  const _TrackingButton(this.action, {required this.primary});

  @override
  Widget build(BuildContext context) {
    final onTap = action.busy ? null : action.onTap;
    final fg = primary ? CtsTheme.onVivid : _charcoal;
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (action.busy)
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: fg),
          )
        else
          Icon(action.icon, size: 20),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            action.label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
    const padding = EdgeInsets.symmetric(horizontal: 12, vertical: 12);
    return primary
        ? FilledButton(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              backgroundColor: CtsTheme.vivid,
              foregroundColor: CtsTheme.onVivid,
              disabledBackgroundColor: CtsTheme.vivid.withValues(alpha: 0.6),
              disabledForegroundColor: CtsTheme.onVivid,
              minimumSize: const Size.fromHeight(56),
              padding: padding,
              shape: shape,
            ),
            child: child,
          )
        : OutlinedButton(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
              foregroundColor: _charcoal,
              minimumSize: const Size.fromHeight(56),
              padding: padding,
              side: const BorderSide(color: CtsTheme.border, width: 1.5),
              shape: shape,
            ),
            child: child,
          );
  }
}

/// Cancellation, deliberately quiet and separate from the other actions.
class TrackingCancelLink extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback onTap;

  const TrackingCancelLink({
    super.key,
    required this.label,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Center(
        child: TextButton.icon(
          key: const ValueKey('tracking-cancel'),
          onPressed: busy ? null : onTap,
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: _danger),
                )
              : const Icon(Icons.close_rounded, size: 18),
          label: Text(
            busy ? 'Cancelling…' : label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          style: TextButton.styleFrom(
            foregroundColor: CtsTheme.errorDeep,
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
        ),
      );
}

/// A two-button confirmation. Returns true only when confirmed. Pops with
/// the dialog's own context, so it never closes the tracking screen.
Future<bool> showTrackingConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String keepLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
      ),
      content: Text(
        message,
        style: const TextStyle(fontSize: 15, height: 1.4, color: _muted),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          style: TextButton.styleFrom(
            foregroundColor: _charcoal,
            minimumSize: const Size(48, 48),
          ),
          child: Text(keepLabel,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          style: FilledButton.styleFrom(
            backgroundColor: destructive ? _danger : CtsTheme.vivid,
            foregroundColor: destructive ? Colors.white : CtsTheme.onVivid,
            minimumSize: const Size(48, 48),
          ),
          child: Text(confirmLabel,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
  return result == true;
}

/// Full-screen state for an order with nothing left to track: cancelled,
/// failed, no driver found, not found, or an unknown status. Never shows
/// tracking controls.
class TrackingEndedScreen extends StatelessWidget {
  final TrackingView view;
  final String homeLabel;
  final VoidCallback onHome;

  const TrackingEndedScreen({
    super.key,
    required this.view,
    required this.onHome,
    this.homeLabel = 'Back to home',
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CtsTheme.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TrackingStatusHeader(view: view),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: onHome,
                  style: FilledButton.styleFrom(
                    backgroundColor: CtsTheme.vivid,
            foregroundColor: CtsTheme.onVivid,
                    minimumSize: const Size.fromHeight(56),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    homeLabel,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
