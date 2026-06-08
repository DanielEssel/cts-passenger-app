# CTS Transport — Booking Flow Production-Readiness Review

_Goal: take each service's booking flow (delivery, ride, gas) edge-to-edge to production-ready — equal weight on logic/money correctness AND UX/UI. Walk every screen, fix in priority order, template shared fixes across all three services._

Legend: 🔴 must-fix (blocker) · 🟡 should-fix · 🟢 polish · ⭐ money/stuck-passenger (highest)

---

## CROSS-SERVICE TEMPLATES (fixes that repeat across delivery/ride/gas)
These were found in delivery but almost certainly recur — apply to all three:
- **T1 ⭐ Hardcoded client fares → use `PricingService`** (which matches the CF calculators). No per-screen baseFare/perKm constants.
- **T2 ⭐ Road distance, not straight-line** — use Directions API, not `Geolocator.distanceBetween`. No hardcoded distance fallback (surface error instead).
- **T3 ⭐ Matching timeout** — every "finding a driver" screen needs a timeout (~60-90s) → "no drivers available" → cancel(+refund) or retry. Never infinite spin.
- **T4 Broken `/wallet` nav** — any top-up button inside the tab shell needs `Navigator.of(context, rootNavigator: true).pushNamed('/wallet')`.
- **T5 Real map or honest downgrade** — tracking screens using `MapPlaceholder` either get a real map bound to `driverCurrentLocation`, or drop the "Live"/map framing.
- **T6 Non-functional UI** — Report sheets / Share buttons that do nothing must be wired or removed.
- **T7 Rating + receipt at completion** — capture driver rating + show fare receipt (repo `rate*` methods exist but UI often missing).
- **T8 Raw error dumps** — `Text('Error: $e')` / `Text(e.toString())` → friendly messages + retry.
- **T9 Phone validation/normalization** — Ghana numbers to international (`0xxx` → `233xxx`) for wa.me links and driver contact.

---

## SERVICE 1: DELIVERY  — _reviewed (4 screens)_

Flow: `DeliveryScreen` (/delivery) → `DeliveryVehicleScreen` (/delivery-vehicle) → `DeliveryMatchingScreen` (/delivery-matching) → `DeliveryTrackingScreen` (/delivery-tracking)

### 🔴 Group A — Money & stuck-passenger
- [ ] **A2 ⭐** Vehicle fares hardcoded (`baseFare 5/15/40`, `perKm 2.5/4/7` at vehicle_screen lines 69/81/95) — diverge from admin/CF. → use `PricingService.calculateDeliveryFare`. **(T1)**
  - DECISION: per-vehicle delivery rates (okada/aboboya/miniTruck), defaults Okada 5/2.5/10, Aboboya 15/4/20, MiniTruck 40/7/50; shared weight/fragile/helper/cancellation surcharges. Schema change touches 4 places.
  - [x] Piece 1: CF `calculateDeliveryFare` rewritten per-vehicle w/ backward-compatible fallback (fare_calculators.js) + `calculateFare` callable delivery branch updated. Call site trips.js:~375 passes `after.vehicleType, after.requiresHelpers`. **DEPLOYED** (safe — falls back to flat/default rates until per-vehicle blocks exist in settings).
  - [ ] Piece 2: admin panel — add per-vehicle delivery fields + helperSurcharge
  - [x] Piece 2: admin panel — per-vehicle delivery fields + helperSurcharge added (interface, defaults, JSX Section, load deep-merge guard). **DONE — renders & saves; settings/platform now has delivery.okada/aboboya/miniTruck.**
  - [ ] Piece 3: client `PricingService.calculateDeliveryFare` per-vehicle (same fallback)
  - [x] Piece 3: client `PricingService.calculateDeliveryFare` per-vehicle (added per-vehicle blocks to _defaults, rewrote method to take vehicleType + requiresHelpers, added deliveryHelperSurcharge getter). **DONE — flutter analyze clean for pricing_service.**
  - [x] Piece 4: delivery vehicle screen — uses PricingService.calculateDeliveryFare per card + confirm + breakdown; removed hardcoded baseFare/perKm/canSurcharge; removed muddled passenger surcharge selector (fixes D14 double-count); /wallet nav → rootNavigator (fixes B9). **COMPILES (flutter analyze clean). Pending fare-consistency test.**
  - **A2 ✅ VERIFIED END-TO-END** — Okada/Small/Fragile @1.5km: quote 19.07 (= 10 base + 1.4×1.479 + 3 small + 4 fragile) == escrow held == CF log `fare=19.07 driver=15.26 fee=3.81` (20% split). Reads live admin settings, surcharges applied, no divergence.
- [ ] **A3 ⭐** Escrow holds client `_totalFare` — follows A2; once client==CF they agree.
- [ ] **A4 ⭐** Matching screen has NO timeout → infinite spin if no driver accepts. Add timeout → no-driver state → cancel(+auto-refund)/retry. **(T3)**
- [x] **A5 ✅ VERIFIED** — delivery now uses Google Directions road distance (Bawjiasi dropoff: was ~1.5km straight-line, now 2.4km road, no `~`). Fix required adding Directions API to the MAPS_API_KEY's allowed APIs in Cloud Console + Application restrictions=None. Honest "~approx" straight-line fallback retained if Directions fails. Breakdown/chips show real settings values. **(T2)**
- [ ] **SECURITY:** MAPS_API_KEY was exposed in a terminal paste — ROTATE it (Cloud Console → Credentials → regenerate), update env.json, restrict new key to Maps SDK + Places + Directions only.
- [x] Cancellation refund — **WORKS**: CF `onDeliveryCancelled` (trips.js:900) calls `refundEscrow`. _Verify in test that heldBalance clears._

### 🔴 Group B — Broken/fake UI
- [ ] **B6** Tracking map is `MapPlaceholder` — no real live tracking, but labeled "Live". → real map on `driverCurrentLocation` or honest downgrade. **(T5)**
- [ ] **B7** Report sheet: every issue just `Navigator.pop` — files nothing. → wire to `admin_alerts`/`reports` or remove. **(T6)**
- [ ] **B8** Tracking "Share" button fakes "link copied" — copies nothing. → implement or remove. **(T6)**
- [x] **B9** `/wallet` top-up nav broken in vehicle_screen `_confirmDelivery`. → `rootNavigator: true`. **DONE (in Piece 4).**

### 🔴 Group C — Validation & safety
- [ ] **C10** Receiver phone collected but not required/validated. → require + validate Ghana format. (`_canProceed` + `_validationHint`).
- [ ] **C11** Silent wrong-pickup: GPS failure → hardcoded Accra `GeoPoint(5.6037,-0.1870)` + "Current location", no error. → show error, leave geo null, allow retry.
- [ ] **C12** Weight tiers offer Aboboya/Mini Truck which may have zero drivers → guaranteed no-match. → gate tiers to fulfillable fleet.
- [ ] **C13** No post-assignment cancellation on tracking screen. → add cancel (with `cancellationFee` rules).

### 🟡 Group D — should-fix
- [x] **D14** Helper surcharge double-count + muddled passenger surcharge selector. **DONE** — helperSurcharge now in schema/PricingService/CF (charged once via requiresHelpers); passenger surcharge selector removed (driver-requested surcharges deferred to a future post-match approval flow).
- [ ] **D15** No rating/receipt at completion (repo `rateDelivery` exists, unused). **(T7)**
- [ ] **D16** Cancelled-status on matching screen silently pops (no "why"); stream null/error keeps spinning; no same-pickup==dropoff guard; dropoff search errors swallowed silently.

### 🟢 Group E — polish
- [ ] **E17** Fake ETAs ("2/5/8 min away") not from real drivers; `fareRange` dead code; phone normalization for wa.me **(T9)**; disabled-state affordances on Call/Share when no phone; OTP card shows before driver assigned.

---

## SERVICE 2: RIDE (okada/taxi) — _pending walk_
Flow (to map): book_ride_screen → (ride options) → matching → ride_tracking_screen.
Known already: `ride_option.dart:240` hardcoded `baseFare + pricePerKm*8.2` **(T1)**; book_ride `/wallet` nav fixed earlier; uses `PricingService` for `calculatedFare` (good baseline). Expect T1-T8 to recur.

## SERVICE 3: GAS — _pending walk_
Flow (to map): gas_order_screen → gas_payment_sheet → matching → gas tracking (active_gas_order on driver side).
Known already: payment sheet fixed (removed disabled deduct); booking holds escrow; CF completion verified. Expect T3/T5/T6/T7 on tracking.

---

## Notes
- Money flows (ride/delivery/gas payout) already verified working — see MONEY_FLOW_REMAINING_WORK.md.
- CF fare calculators deployed & aligned to admin schema + client `PricingService`.
- Cancellation refunds: CFs exist for trip/delivery/gas (`onDeliveryCancelled` etc.) → client cancel just sets status=cancelled, CF refunds. Verify each in test.