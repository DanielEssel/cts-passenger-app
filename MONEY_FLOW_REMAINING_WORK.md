# CTS Transport — Money Flow: Remaining Work

_Checkpoint after verifying ride, delivery, and gas payouts end-to-end (escrow held → released → driver credited, 20% split, no double-charge). Platform fee is admin-driven; CF fare calculators aligned to the admin schema + client `PricingService`._

---

## ✅ Done & verified
- Ride payout: escrow release, correct 20% split, driver credited, charged once.
- Delivery payout: wallet/escrow path AND cash path (commission debt) — no double-charge.
- Gas payout: escrow release at 20%; gas booking unblocked (removed disabled `deductForGasOrder` call in `gas_payment_sheet.dart`).
- Platform fee reads `settings/platform.platformFeePercent` everywhere (escrow hold, completion).
- `onTripCompleted` guard fixed (proceeds on completed+unprocessed, not only on status change).
- CF fare calculators (`calculateRideFare` w/ perMinRate + surge-then-floor, `calculateDeliveryFare`, `calculateGasFare`) deployed and matched to admin schema + client `PricingService`.
- Top-up button navigation fixed (`rootNavigator: true` to reach `/wallet`).
- Home-screen location feeds `rideRequestProvider.setOrigin` so driver markers render.
- `getCurrentLocation` cached-first (fast fix, no Accra fallback).

---

## 🔴 Priority 1 — MUST do before real users

### 1. Turn off TEST_MODE in `onTripCompleted`
- `functions/trips.js` → `onTripCompleted` has `const TEST_MODE = true;` which **disables the fraud check** (short-distance/short-time flagging).
- Set to `false`. Better: read from `settings/platform` (e.g. `settings.fraudCheckEnabled`) so it's config-driven, not hardcoded.
- Without this, any 0-distance/instant trip pays out unchallenged.

---

## 🟡 Priority 2 — Fare consistency (client cleanup)

The CF and client `PricingService` now use the same formula + same `settings/platform` doc, so they already agree. Remaining: kill the **rogue hardcoded** client calcs that bypass `PricingService`.

### 2. Fix `ride_option.dart:240`
- Replace hardcoded `basePrice: type.baseFare + (type.pricePerKm * 8.2)` (fixed 8.2km guess).
- Use `PricingService` or read `state.calculatedFare` (which already uses `PricingService`).

### 3. Fix `delivery_vehicle_screen.dart:69,81`
- Remove hardcoded `'baseFare': 5.0 / 15.0`.
- Use `PricingService.calculateDeliveryFare`.

### 4. Ensure `PricingService.fetch()` runs on startup / before booking
- So the settings cache is warm and fares reflect current admin values.

### 5. (Optional, stronger) Adopt the `calculateFare` callable — full Option A
- Server-authoritative, tamper-proof fares. Files ready: `calculateFare_callable.js`, `fare_calculators.js`.
- Requires client refactor: `calculatedFare` getter (sync) → fetch+store from callable (async) in `RideRequestState`, repointed across ride/delivery/gas.
- Also harden `holdBalance` to recompute fare server-side and ignore client `amount` (prevents a tampered client from holding a fake amount).

---

## 🟡 Priority 3 — Money integrity & ops

### 6. Payout-failure alerting
- If `releaseEscrow` throws, the doc gets `walletProcessError` and sits silently. Add monitoring/admin alert so a driver never goes unpaid unnoticed.

### 7. Cash commission collection
- `commissionOwed` accumulates on drivers (cash trips/deliveries) but nothing settles it.
- Build settlement: deduct from wallet earnings, or block withdrawal until paid.

### 8. Stuck-escrow cleanup
- Old pre-fix escrows still `HELD` (e.g. passenger had ~85 GHS zombie held balance).
- Run/verify `releaseStuckEscrows` to refund them.

### 9. Uniform transaction history
- Only gas writes passenger `transactions` entries; driver wallet UI computes Total in/out/pending from a transactions collection nothing consistently populates.
- Make all three services write consistent ledger/transaction entries (passenger debit + driver credit).

---

## 🟢 Priority 4 — Cleanup & infra

### 10. App Check
- Logs show `403 App attestation failed`. Set up debug tokens / proper attestation before enforcing App Check in production.

### 11. Dedupe files
- Two `gas_payment_sheet.dart` (`widgets/` and `presentation/widgets/`) — only `presentation/widgets/` is used; the other has the same disabled-deduct bug.
- Also noted earlier: duplicate ride_tracking / confirm_ride_bar files. Dedupe to avoid editing the wrong copy.

### 12. Compute Engine API
- Enable to stop the intermittent Firestore pre-check failures on deploy:
  `https://console.developers.google.com/apis/api/compute.googleapis.com/overview?project=67007923864`

### 13. Fare magnitude sanity
- Delivery hit ~105 GHS for a small parcel ~40km out (per-km model on long distance). Confirm the per-km delivery model is intended for long hauls, or cap/tier it.

---

## Key facts
- Project: `ctstransportapp` (number `67007923864`), region `europe-west2`.
- Settings doc: `settings/platform` (fields per admin panel: platformFeePercent, okada/taxi/delivery/gas pricing, toggles, withdrawal limits).
- Principle: **client never moves money** — it requests state changes; Cloud Functions move money via escrow.
- Escrow lifecycle: `holdBalance` (booking, balance→heldBalance) → `releaseEscrow` (completion, clears held + credits driver driverNet + CAPTURE ledger) → status RELEASED.
- Driver earnings fields: `walletBalance` (withdrawable), `todayEarnings`/`weekEarnings`/`totalEarnings`, plus `drivers/{id}/earnings/summary` subdoc. `commissionOwed` for cash.
- Deploy flakiness: transient `firestore.googleapis.com` pre-check failures — retry (sometimes drop `--debug`, sometimes toggle network). Enabling Compute Engine API fixes it.