# Dispatch remediation — release plan (not approved, nothing deployed)

Status on 2026-10-21: local only. Emulator-tested; not device-tested; no
production read, write or deployment has been made for this change.

## 1. Inventory

### Functions (passenger repo `functions/`, region europe-west2)

| Function | Change | Local source (sha256/12) | Latest snapshot containing it | Live source |
|---|---|---|---|---|
| onTripCreatedNotify | modified: policy, vehicle check, no (0,0) default, dead-token cleanup | notifications.js `bdc372b9aaed` + dispatch_policy.js `f871b91d964f` | escrow-release/b0926 notifications.js `afadac475b24` (also b0818) | **unknown** |
| onDeliveryCreated | modified: booked vehicle + tier; ends undeliverable bookings | same | b0926 | **unknown** |
| onDeliveryPaymentAttached | modified (same dispatch path) | same | none | **unknown** |
| onGasOrderCreated | modified: policy; push has no route | same | b0926 (no vehicle filter there) | **unknown** |
| onDeliveryStatusChanged | modified: frees driver on cancel/flag; reasoned cancel message | same | b0926 | **unknown** |
| onGasOrderStatusChanged | modified: frees driver on cancel/fail/flag | same | b0926 | **unknown** |
| acceptGasOrder | modified: policy (suspended, on-job → `driver_on_job`) | accept_gas_order.js `b41b30b9e63b` | none | **unknown** |
| onDriverTokenSaved | **new** | driver_tokens.js `b3a175741ced` | — | not deployed |
| dispatch_policy.js | **new shared module** (requires gas_dispatch_policy.js `1d9dedd1e25c`) | | | |

Pre-change local baselines: notifications.js `dac2e6f87d52`,
accept_gas_order.js `c93677ae73ba`, firestore.rules `845b9e3fbfde`.

The snapshots in `bridge-hotfix-20261016/` record what was live for the
functions listed in its README only. They do not prove which upload the
functions above run from.

**Shared-module dependency.** notifications.js requires escrow.js
(`secureTripPayment`, deliveryPaymentLinked's escrow reads). Local escrow.js
(`42a6642b4737`) carries the unreleased escrow Phase 2 changes. A deploy from
the local tree ships local escrow.js inside every function above. Either
deploy after Phase 2 is approved and live, or build a release directory
(deployed source + only these files), as escrow-release/ does.

### Firestore rules
Local `firestore.rules` `31fbec833b94`:
- `rideClaimEligible` adds a vehicle match;
- new `deliveryClaimEligible`: online, available, no `currentTripId`, booked vehicle and tier.

Read rules are unchanged. Live rules: **unknown** (run `rules-tests/npm run check-deployed`, which is read-only).

### Indexes
No new query shape. `firestore.indexes.json` lacks the composites the Driver
App request lists already use, so live indexes were created outside this file:
- `trips`: status, serviceType, createdAt desc
- `deliveries`: status, driverId, weightTier, createdAt desc
- `gas_orders`: status, driverId, createdAt desc

`onDriverTokenSaved` queries `drivers.fcmToken ==`, which needs only the
single-field index; check that no exemption exists. Do not deploy indexes from this
file until it is reconciled with `firebase firestore:indexes` (read-only).

### Apps
- **Driver:** 1.0.2+32 → **must ship as 1.0.3**. The update gate compares x.y.z only.
- **Passenger:** 1.0.0+9 → next version.
- **Version gate:** `app_config/mobile.driverMinimumVersion` / `passengerMinimumVersion`. It is client-side and fails open. Driver builds before 2026-09-29 (c58ef22) do not have it.

## 2. Read-only verification to approve before any change
1. **Function list:** `firebase functions:list --project ctstransportapp`.
2. **Per function above:** `gcloud functions describe <fn> --gen2 --region europe-west2 --project ctstransportapp --format="value(updateTime,buildConfig.source.storageSource)"`.
3. **Source zips:** copy the current generation of each from `gs://gcf-v2-sources-67007923864-europe-west2/<fn>/function-source.zip` to a local folder, record hashes and diff against the snapshots. These are also the rollback artifacts.
4. **Rules:** `npm run check-deployed` in `rules-tests/`.
5. **Indexes:** `firebase firestore:indexes --project ctstransportapp`.
6. **Driver data (aggregates only, no ids or tokens):**
   - approved `driver_hailing` drivers whose `vehicleType` does not match `serviceType`, or is missing (they stop getting rides);
   - `driver_delivery` drivers with a `vehicleType` outside motorcycle, tricycle and miniTruck, including legacy spellings;
   - drivers with `currentTripId` set whose job is terminal (they will be blocked from claims);
   - pending deliveries per vehicle/tier pair.
7. **App versions:** installed Driver/Passenger version distribution, from Play Console / App Store.

## 3. Rollout sequence and interim states

| Stage | Change | State while later stages are pending | Verify after |
|---|---|---|---|
| 0 | Section 2 checks; fix any drivers with bad vehicle data (admin, separately approved) | — | aggregates are zero, or each case accepted |
| 1 | Driver App 1.0.3, staged rollout | Works with both old and new backend and rules: claims add the driver doc in the same transaction (allowed by both rule sets); request taps ignore routes | device test D1–D6 on staging, then crash-free and claim-error rate in production |
| 1b | Passenger App release | Works with both backends; Medium shows Aboboya only | P1–P3 |
| 2 | Functions in section 1 (from a reviewed release directory), plus new `onDriverTokenSaved` | Old apps: notified only when eligible; claims still governed by old rules; Medium/Okada bookings are cancelled with a reason and any hold refunded | dispatch logs (counts only), `dispatch_rejected` alerts, refund ledger for any cancelled wallet booking |
| 3 | `driverMinimumVersion = 1.0.3` once adoption is sufficient | Builds from 2026-09-29 onward must update; older builds keep running | version distribution |
| 4 | Firestore rules (ride vehicle, delivery claim checks) | Old Driver builds: list filters disagree with the new rules, so some claims fail with permission errors. Old Aboboya builds never list Large orders, as today. | rules tests on staging; claim error rate |
| 5 (decision) | Restrict open-request reads (see section 5) | | |

Do stage 4 only after stage 1 adoption. Before that, old builds cause claim
failures for orders the old list shows but the new rules refuse.

## 4. Rollback

| What | How to roll back | Notes |
|---|---|---|
| Functions | Redeploy the zips saved in section 2.3 | Live source is currently unknown, so these must be saved before deploying. |
| `onDriverTokenSaved` | `firebase functions:delete onDriverTokenSaved` | Tokens it released are not restored; drivers re-save on the next app start or token refresh. |
| Rules | Re-release the previous ruleset from the Firebase release history | Save the live rules first (section 2.4). |
| Bookings ended by stage 2 | **Cannot be undone** | The cancellation and its escrow refund are final. |
| App releases | **Cannot be recalled from devices** | Halt the staged rollout, or ship a newer build. A minimum-version bump cannot be undone for users who updated (harmless). |

**Stop and roll back if any of these happen:**
- a dispatch log shows recipients for a rejected job;
- `driver_unavailable` or `driver_on_job` counts spike to every driver;
- claim permission-denied rates rise for current builds;
- any escrow refund other than for `dispatch_rejected` bookings.

## 5. Decisions required (not made in code)
1. **Okada carries Small only, so Medium bookings go to Aboboya.** This follows the 0–5 kg card, but Medium customers now pay the Aboboya fare. The alternative is to change the Okada card to 0–20 kg and edit the tier table in 4 places.
2. **Flagged orders free the driver.** Implemented so as to keep today's "go online again" workflow. The alternative is to keep the driver blocked until review.
3. **Radius is checked at dispatch only, not at claim time.** Rules cannot measure distance and driver locations are self-reported. A claim-time check would need claims to move to callables.
4. **Open-request visibility.** Pending deliveries and gas orders (receiver and passenger names and phone numbers, exact addresses, notes, photo, receipt email, `deliveryOtp`) are readable by every active Delivery driver. Searching trips are readable by every active Ride driver. Rules cannot hide fields. Options:
   - (a) after the minimum version is enforced, require list queries to filter on the driver's own service/vehicle and match that in rules (still nationwide);
   - (b) move personal data and the code to a document readable only after assignment (schema change);
   - (c) serve open requests from a callable.
5. **`deliveryOtp` is readable by the assigned driver** (a party), so the code does not prove the recipient was present. This predates this change; it is a separate decision.
6. **Settlement clears `currentTripId` without checking which job it points to** (onTripCompleted, onDeliveryCompleted, onGasOrderCompleted). A driver who took a new job seconds before settlement finishes would have the new job cleared. This predates this change; a follow-up money-trigger change is needed.
7. **Location freshness.** There is no cutoff because parked drivers send no heartbeat. Add a heartbeat before choosing one.
