# CTS Go — Authentication Remediation, Phase 1

- **Date:** 12 October 2026
- **Source of findings:** `AUTH_FLOW_AUDIT.md`, left unchanged; this file is the remediation record.
- **Status:**
  - Implemented and tested locally.
  - **Nothing deployed, committed, or changed in any console.**
  - Existing uncommitted work in both repos was preserved; no file was reset, stashed or overwritten.

## Results at a glance

| Suite | Result |
|---|---|
| Driver `flutter test` | **38 passed** (12 existing C4 + 26 new) |
| Driver `flutter analyze` | 12 issues, the same pre-existing baseline; none in changed files |
| Passenger `flutter test` | **55 passed** (52 existing + 3 new) |
| Passenger IDE diagnostics on changed files | none |
| Rules emulator suite | **92 passing / 23 failing** (was 64 / 25). All 26 new tests pass. DRV-S01 and DRV-S02 now pass. The 23 remaining failures are all pre-existing. |
| Functions unit tests (`roles`, `driver_map`) | 9 / 9 |
| Functions payment smoke (emulator) | 28 / 28 (unchanged) |

The 23 rules failures still open, all known before this phase:
- DRV-S04, DRV-S10, DRV-P07
- MON-S09–S11
- TRIP-S01–S08, TRIP-S11–S16, TRIP-S18–S20

One rules run crashed the emulator (a segmentation fault) before any test ran. The re-run gave the figures above.

---

## Phase 1A — AUTH-04: Driver sign-out (Driver app)

**Files**
- `lib/features/driver/services/driver_sign_out.dart` (new): the ordered sign-out sequence, as a Firebase-free class.
- `lib/features/driver/services/driver_session_service.dart` (new): Firebase wiring. Concurrent calls share one run.
- `lib/features/driver/services/driver_runtime_service.dart`: the GPS subscription is now `static` (process-wide).
- `lib/features/driver/presentation/driver_settings_screen.dart`: uses the service. `prefs.clear()` is removed.
- `lib/features/driver/data/driver_profile_service.dart`: `signOut()` delegates to the service (profile-screen logout).
- `lib/core/services/driver_flow_resolver.dart`: the "no driver profile" sign-out uses the service.

**Behaviour corrected**
1. The UID is captured first.
2. `goOffline()` runs. Because the GPS stream is now process-wide, this also stops the stream started from the home toggle.
3. The FCM token is removed from `drivers/{uid}` **only if it equals this device's token** (transaction), while the user is still signed in. A doc that doesn't exist is never created.
4. The local FCM token is deleted.
5. `FirebaseAuth.signOut()` is **always** attempted.

Steps 2–4 are bounded (5 s each) and never throw. The logged outcome lists step names only, with no UID or token.

**Preferences:** the only key in SharedPreferences is `onboarding_complete`. `prefs.clear()` removed it, which forced drivers back through onboarding after logout. Sign-out now leaves preferences untouched.

**All logout paths, searched:**
- Settings, the profile screen and the resolver now use the service.
- `lib/app/auth_gate.dart` still calls `signOut()` directly, but it is not referenced anywhere (AUTH-19).

**Tests** (`test/features/auth/driver_sign_out_test.dart`, 9):
- order: offline and token cleanup happen while signed in, then sign-out
- another device's token is left alone
- sign-out still happens when every step fails
- sign-out still happens when steps hang (timeout)
- no signed-in user
- repeated sign-out
- a failed auth sign-out is reported, not thrown
- no PII in the result text
- the onboarding preference survives

**Remaining risk / verification**
- **Device test required:** after logout, `isOnline` and `isAvailable` are false, `fcmToken` is removed, and no dispatch push arrives.
  - Nothing here claims dispatch has stopped in production.
- The separate `LocationService` (a Riverpod notifier) may still try location writes after logout. After sign-out those writes are denied, but the stream isn't stopped. This is a low-impact follow-up.
- `DriverNotificationService.clearToken()` (unused, deletes unconditionally) is left in place. Prefer the new service.

---

## Phase 1B — Driver authentication correctness (Driver app)

### AUTH-05: server-first profile read

**Files**
- `lib/core/services/driver_profile_read.dart` (new)
- `lib/core/services/driver_flow_resolver.dart`

**Behaviour**
- `AppFlowResolver` reads `drivers/{uid}` from the server first.
- If the phone is offline, it falls back to the cache, but routes on a cached copy **only if it carries a role**.
- "No profile → sign out" happens only when the **server** says the doc is missing.
- An unconfirmed cached copy returns the login route without signing out.
- Step routing (role → setup → vehicle → documents → **approval** → shell) is unchanged.

**Tests:** `test/features/auth/driver_profile_read_test.dart` (7).

### AUTH-08 and AUTH-09: one completion path

**Files**
- `lib/features/auth/domain/driver_auth_completion.dart` (new, Firebase-free)
- `lib/features/auth/data/driver_auth_completion_service.dart` (new wiring)
- `login_screen.dart`, `signup_screen.dart`, `otp_verification_screen.dart`

**Behaviour**
- Every verified credential goes through the same steps: **sign in → (sign-up) `createDriverDocument` → `AppFlowResolver`**. This applies to:
  - login auto-verification (was an empty stub)
  - sign-up auto-verification (previously skipped provisioning and jumped to role selection)
  - manual OTP
  - auto-verification after a resend (was ignored)
- The routing decision always comes from the resolver, so approval checks can't be bypassed.
- Overlapping automatic and manual completions share one run: the credential is consumed once and provisioning happens once.
- Sign-up for a number that is already a driver now lands on that driver's real step instead of role selection.

**Tests:** `test/features/auth/driver_auth_completion_test.dart` (4):
- login routing
- sign-up provisioning
- overlap, consumed once
- a failed sign-in does no provisioning or routing, and a retry works

**Not changed (by instruction):** the forced-reCAPTCHA retry (AUTH-10).

**Remaining risk / verification:**
- **Device test:** instant verification and auto-retrieval on a Play-services phone; repeated fresh-install logins of a returning driver.
- `driver_login_screen.dart` (unrouted) still has its own `signInWithCredential` (AUTH-19).

---

## Phase 1C — AUTH-03: push-token / profile integrity

**Driver**
- `lib/features/driver/services/push_token_store.dart` (new).
- `driver_notification_service.dart`:
  - The token save uses `update()`. A missing doc is a skip; it can no longer create `drivers/{uid}`.
  - No UID in logs.
- `lib/core/services/driver_profile_defaults.dart` (new) and `driver_service.dart` `createDriverDocument`:
  - Server read before deciding.
  - New doc: full defaults.
  - Existing doc (for example a token-only stub from older versions): adds only the **missing, owner-writable** defaults. It never overwrites, and never sets `isApproved`, `uid` or `createdAt`.
  - A missing `isApproved` already means "not approved" everywhere.

**Passenger**
- `lib/features/home/services/push_token_store.dart` (new) and `notification_service.dart`:
  - The token save uses `update()` (can't create `users/{uid}`).
  - New `saveCurrentToken()`.
- `auth_providers.dart` `_createPassengerProfile`: saves the token right after the profile is created. The sign-in save is now skipped for brand-new accounts.

**Backend:** `functions/wallet.js`
- `getRole()` → `classifyRole()`. A `drivers/{uid}` doc counts as a driver only with a `driver_*` role.
- Precedence:
  1. real driver record
  2. passenger profile
  3. role-less driver doc (driver mid-signup)
  4. unknown
- `exports._roles` is test-only; it isn't exported from `index.js`.

**Tests**
- Driver `test/features/auth/push_token_integrity_test.dart` (6).
- Passenger `test/home/push_token_store_test.dart` (3).
- Functions `functions/test/roles.test.js` (5).
- Rules DSC-P02 / DSC-P04: an old-version token-only create still works, and a stub can be completed with owner defaults.

**Deployment required (not done):** `firebase deploy --only functions` for every function defined in `wallet.js` that calls `getRole`:
- `getWalletBalance`
- `requestWithdrawal`
- …

Payment functions are frozen and production deploys of Functions are separately gated (B0 runbook, `PAYSTACK_SECRET_KEY` declarations). **Owner approval is needed.** Until then, the client-side changes alone stop new stubs from being created.

**Same weakness, not changed** (payment code under the money freeze):
- `bridge.js:547` (payout eligibility by doc existence)
- `getDriverWallet` (`wallet.js`)
- `notifications.js:208`

**Existing stubs in production:** passengers who ever opened the Driver app may already have token-only `drivers/{uid}` docs. With the new `getRole` they are classified correctly. They aren't cleaned up; that would need a production data review (not done).

---

## AUTH-01 (Critical): trip and location read authorization (rules)

**File:** `firestore.rules` (also contains the earlier `driver_map` block, already deployed).

**Diff summary**
```
+ function isActiveDriver()   // approved == true AND signupStep != 'suspended'

  match /trips/{tripId}
-   allow read: if isAuth();
+   allow read: if isParty(passengerId, driverId)
+               || (resource.data.status == 'searching' && isActiveDriver())
+               || isAdmin();

    match /locations/{locationId}
-     allow read: if isAuth();
-     allow create, update: if isAuth() && (resource == null || trip.driverId == uid);
+     allow read: if isAdmin() || isParty(trip.passengerId, trip.driverId);
+     allow create, update: if isAuth() && trip.driverId == uid;

  match /drivers/{driverId}     (DRV-S01/S02)
-   allow create: if isOwner(driverId) || isAdmin();
+   allow create: if isAdmin() || (isOwner(driverId)
+       && keys().hasOnly([signup / device / location fields])
+       && get('isApproved', false) == false
+       && get('uid', driverId) == driverId);
```

**Design decision: no `driverId == null` requirement.**
- A first draft also required `driverId == null`. That forces the Driver request query to add a `driverId` filter (plus a new composite index). The Driver app **already on Play** would then get zero ride requests until every driver updated.
- Accepting a trip sets `driverId` and moves `status` off `searching` in one transaction, so `status == 'searching'` already identifies open, unassigned trips.
- The deployed rule therefore works with the existing app query. The draft's app-query and index changes were reverted.

**Query verification:**

| Query | Proven by |
|---|---|
| Passenger history / active / home | `passengerId == uid` |
| Driver history / earnings | `driverId == uid` |
| Driver request list (unchanged) | `status == 'searching'` + approved driver |
| Single-doc reads in tracking and trip screens | party |

**Tests:** `rules-tests/test/trip_access.test.js`, all passing.
- **Keeps working (TRA-P01–P09):**
  - passenger own trip
  - passenger history query
  - assigned driver read
  - driver earnings query
  - approved driver running the real request query
  - approved driver single read (accept transaction)
  - admin
  - parties reading locations
  - assigned driver writing a location
- **Denied (TRA-S01–S10):**
  - an unrelated passenger, for a single trip, a list, or open requests
  - an unapproved driver
  - a suspended driver
  - an approved driver reading another driver's assigned trip
  - an approved driver querying accepted trips
  - a signed-out user
  - non-parties reading or writing locations
- **Driver sign-up create (DSC-P01–P04, DSC-S01–S03):**
  - the app's sign-up payload is accepted
  - an old-version token create still works
  - `goOnline` on a missing doc still works
  - a stub can be completed
  - denied: self-approval; money or rating fields; `signupStep`; another UID

**Remaining risks**
- **DRV-S04 (still failing):** `signupStep` is owner-writable, so a suspended driver can clear their own suspension. That also weakens the "not suspended" part of `isActiveDriver()`.
- **TRIP-S18/S19 (still failing):** any signed-in user, approved driver or not, can still *claim* an unassigned trip through the update rule. Natural fix: `isActiveDriver()` on the claim branch, in C2.
- The other known trip and money write gaps are unchanged (C2).
- `isActiveDriver()` costs up to 2 extra document reads per trip read evaluation (billing / latency, small).

**Deployment required (not done):** `firebase deploy --only firestore:rules`.
- No app update or index is needed first.
- Owner approval required (AP-6).
- Rollback: re-release the previous ruleset `08f89544-25c5-46fe-8a90-9d5b4ffd17ad`.

---

## Out of scope, recorded

| Finding | Status / dependency |
|---|---|
| AUTH-02 self-sign-up | Console: confirm Identity Platform "disable sign-up" availability; admin accounts must exist first. With AUTH-01 deployed, the trip-data exposure from cheap accounts is closed. |
| AUTH-06 deletion | Needs the owner's data-retention policy; then a callable plus rules. |
| AUTH-07 deactivation | Needs the policy decision. |
| AUTH-10 forced reCAPTCHA | Needs device validation on the device class that originally failed. |
| AUTH-12 test numbers | Console review. |
| AUTH-13 App Check | Separate change; enforcement off. |
| AUTH-18 dual role | Owner decision. `getRole` now resolves the common case correctly. |

## Owner actions needed (none taken)

1. **Approve the rules deploy** (AUTH-01, DRV-S01/S02). This is the highest-value action, and it's safe with the current apps.
2. Approve the Functions deploy for `getRole` (gated with payment functions).
3. Build and device-test the Driver app:
   - logout stops dispatch
   - auto-verification
   - returning-driver fresh installs
4. Build and device-test the Passenger app:
   - sign-up saves the push token
   - login race (fresh installs)
5. Decide policies for AUTH-06, AUTH-07 and AUTH-18.

---

## Phase 1D: trip-assignment and suspension integrity (rules only)

**Files changed:**
- `firestore.rules` (trips `update`; drivers owner `update` plus the new `ownerSignupStepChangeAllowed()`)
- `rules-tests/test/assignment.test.js` (new, 25 tests)

No app, Functions, payment or console changes were made.

### Trips update (TRIP-S06/S14/S15/S18/S19/S20)
- **Before:** any signed-in user could claim any unassigned trip (`driverId == null`). Parties could rewrite `driverId` and `passengerId`.
- **After:**
  - Parties may update their trip only if `driverId` and `passengerId` stay unchanged.
  - A claim requires all of:
    - the trip is `searching` and unassigned
    - the claimant is an **active driver** (approved and not suspended)
    - the claimant assigns **themselves**
    - the new status is `tripAccepted`
    - the write touches only `driverId`, `driverName`, `driverPhone`, `driverRating`, `driverPlate`, `status` and `acceptedAt`. That is exactly the released accept payload, unchanged since 27 May 2026.

### Drivers update (DRV-S04)
- The owner may never set `signupStep` to `approved`, `suspended` or `rejected`, and may not change it at all while suspended or rejected.
- Moving from `approved` back to an onboarding step (document re-upload) stays allowed. It grants nothing, because `isApproved` and the other approval fields (`isRejected`, `approvedAt`/`approvedBy`, …) are outside the owner allow-list.

### Results

Rules suite: **124 passing / 16 failing**, up from 92 / 23.
- **Newly passing:** DRV-S04, TRIP-S06, S14, S15, S18, S19, S20, plus 25/25 new ASG/APR tests.
- **All released-app behaviour tests still pass:** TRIP-P01–P13, TRA-P, DSC-P, C4, AVL, MAP, and the new ASG-P01–P05 / APR-P01–P03 (accept transaction, passenger cancel, location stream, driver cancel and release transaction, completion, onboarding step, document re-upload, suspended driver going offline).
- **The 16 remaining failures all predate this work** (payment, lifecycle and money gaps; payment logic is out of scope):
  - DRV-S10, DRV-P07
  - MON-S09–S11
  - TRIP-S01–S05, S07, S08, S11–S13, S16
- **No new failures.**
- One test of mine was wrong and was corrected: APR-S04 used a seed whose suspended driver still had `isApproved: true`, so the write changed nothing. It now uses an Admin-style suspension (`isApproved: false`).

### Fallbacks confirmed intact (unchanged)
- **Driver:** `retryWithRecaptcha` / `setSettings(forceRecaptchaFlow: true)` on `app-not-authorized` / `invalid-app-credential` is still in login, sign-up and OTP resend. No fallback line differs from HEAD.
- **Passenger:**
  - `FirebaseAppCheck.activate` (debug provider in debug builds, Play Integrity in release) is unchanged.
  - The SDK's built-in reCAPTCHA fallback is untouched: no `setSettings` or app-verification changes anywhere.
  - `main.dart` and the Gradle files are unchanged.

### Compatibility with released apps
- **Driver:** request list query, accept transaction, mark busy, arrive/start/complete, live location, cancel plus release, earnings and history queries all pass.
- **Passenger:** create, cancel (searching and assigned), timeout, confirm, dispute, rate, tracking, history and active-trip queries all pass.
- **Admin:** `isAdmin()` bypass unchanged (money and suspension writes stay frozen by C1). **Functions:** Admin SDK, unaffected.
- **Not verified:**
  - Driver builds older than 27 May 2026 (a different accept flow).
  - Live production data that contradicts the model (for example a `searching` trip that already has a `driverId`). Such a trip can't be claimed (claim requires `driverId == null`) but can be read by active drivers.

### Still open
- **Deliveries:** any signed-in user can read `pending` unassigned deliveries and claim one (`driverId == null` → self). This is the same class as AUTH-01 / TRIP-S18 and needs the delivery query and accept path reviewed before tightening.
- **Gas orders:** `pendingApproval` orders are readable by any signed-in user. Claiming is already server-side (`acceptGasOrder`).
- **Document self-approval:** a driver can write `documents.<key>.status = "approved"`. Rules can't check every value inside the `documents` map. Fixing it needs an architectural change: move the review status to an admin-only field or collection. Driver approval itself (`isApproved`) is protected.
- **`role` / `serviceType` / vehicle changes after approval:** a policy decision is needed (should a change require re-approval?). If yes, the owner rule can require these fields unchanged while `isApproved == true`. Released-app paths that would then be refused for approved drivers: vehicle setup and role selection, reachable from document re-upload.
- **Payment, lifecycle and money rules:** the 16 failures above.

### Production proposal
The current `firestore.rules` is **safe to propose for deployment**. It needs no app update, index or Functions change first. Deploy with `firebase deploy --only firestore:rules`; roll back by re-releasing ruleset `08f89544-25c5-46fe-8a90-9d5b4ffd17ad`. **Owner approval (AP-6) is required. Not deployed.**

---

## Phase 1E: delivery and gas privacy, document review, role and vehicle policy (rules only)

**Files changed:**
- `firestore.rules`: deliveries, gas_orders, drivers (create and update), plus new `isActiveDeliveryDriver()`, `ownerDocumentsChangeAllowed()` and `isOwnerDocumentUpload()`.
- `rules-tests/test/orders_documents.test.js` (new, 33 tests).
- `rules-tests/test/assignment.test.js`: APR-P02 corrected (see below).

No app, Functions, payment or console changes were made. The Driver repo is unchanged by this phase.

### Flows traced (committed code = released apps)

**Delivery**
1. Passenger `DeliveryRepository.createDelivery`: `status: 'pending'`, `driverId: null`.
2. `onDeliveryCreated` notifies approved `driver_delivery` drivers (Admin SDK).
3. Only `driver_delivery` drivers see the request list. Its query is `status == 'pending'`, `driverId == null`, `orderBy createdAt`, plus `weightTier in [...]`.
4. Accept is a **client transaction** (`requests_section.dart`). It checks `driverId == null` and `status == 'pending'`, then writes `driverId`, `driverName`, `driverPhone`, `driverRating`, `status: 'driverAssigned'` and `acceptedAt`. The field list has been the same since 22 May 2026; the 18 May version wrote a subset.
5. After that, the assigned driver writes status steps, location, OTP and completion, and cancels in a transaction with the driver release (C4).
6. The passenger cancels, rates and attaches escrow. **No party ever changes `driverId` or `passengerId`.**

**Gas**
1. Passenger creates the order as `pendingApproval` with `driverId: null`.
2. Only `driver_delivery` drivers see the request list. Its query is `status == 'pendingApproval'`, `driverId == null`, `orderBy createdAt`.
3. The claim is **server-only**: `acceptGasOrder` requires role `driver_delivery`, approved, online and available, plus vehicle capability.

**Documents**
- The Driver app merge-writes `documents.<key> = {status: 'uploaded', url, fileType, uploadedAt, expiryDate?}`. There are 8 keys, plus `profile_photo`, which the app reads.
- `approveDriver` (a Function) writes `status: 'approved'` or `'rejected'` and `rejectionReason`.

### Fixes

**Deliveries**
- Read: parties, admins, and **active delivery drivers** for `pending` and unassigned deliveries. Active means approved, not suspended, role `driver_delivery`.
- Create: must be unassigned.
- Update:
  - Parties can't change `driverId` or `passengerId`.
  - A claim must come from an active delivery driver, for themselves, on a `pending` unassigned delivery, set `driverAssigned`, and touch only the accept fields.

**Gas orders**
- Read: customer, assigned driver, admins, and active delivery drivers for `pendingApproval` and unassigned orders.
- Create: must be unassigned.
- Update: unchanged. It already prevented a client from changing `driverId`, so claiming stays server-side.

**Documents (the smallest safe change, with no data move, app release or Function deploy)**
- On create and owner update, the `documents` map is compared with its previous value.
- Only the known document keys may change. Each changed entry must be a fresh upload: `status == 'uploaded'`, a string `url`, and only the upload fields.
- A leftover `rejectionReason` may stay only if unchanged. `set(merge)` merges nested maps, so resubmitting a rejected document keeps it.
- Result: `approved`, `rejected` and `rejectionReason` remain writable only by admins and the Function. Uploads, resubmissions and re-uploads after approval still work.
- A full structural move (review status in a separate admin-only field) is **not needed** for security. It would need an app release, a Function change and Admin app changes, so it's optional later cleanup.

### Role and vehicle changes (item 4, reported only, not implemented)

**Current behaviour:** `role`, `serviceType` and `vehicleType` are owner-writable at any time. An approved driver can reach role selection and vehicle setup from document re-upload (`driver_documents_screens.dart` → vehicle setup → role selection).

**Security implications**
1. An approved ride driver can switch `role` to `driver_delivery` and immediately:
   - read open deliveries and gas orders (the new rules key on role)
   - claim deliveries
   - be dispatched deliveries
   - pass `acceptGasOrder`'s role check

   All of this without admin review of a delivery vehicle or documents.
2. Changing `serviceType` (okada / taxi / pragyia) switches which ride requests the driver sees and claims.
3. `vehicleType` drives `acceptGasOrder`'s vehicle-capability check, so a driver can self-upgrade to refill types their vehicle can't handle.

**Proposed policy options (owner decision required)**
- **Option A (rules + small app copy change):** while `isApproved == true`, the owner may not change `role`, `serviceType` or `vehicleType` (optionally also `vehiclePlate` / `vehicleModel`). A change needs admin action or re-application. The released apps' vehicle-setup and role-selection screens would then show a write error for approved drivers, so add an app message ("Contact support to change your vehicle").
- **Option B (Function, no client error):** a `drivers/{uid}` update trigger sets `isApproved: false` and `signupStep: 'documentsUploaded'` when those fields change on an approved driver. The driver drops into pending review automatically. Needs a Functions deploy.

**Recommendation:** Option A for launch (it's simple and testable), with the app message in the next release.

### Results

Rules suite: **157 passing / 16 failing**, up from 124 / 16.
- **New:** 33/33 DLV / GAS / DOC tests pass.
- **Earlier groups still pass:** TRA/DSC 26, ASG/APR 25, TRIP-P 13, C4, AVL, MAP.
- **The 16 failures are the same pre-existing list** (payment, lifecycle and money):
  - DRV-S10, DRV-P07
  - MON-S09–S11
  - TRIP-S01–S05, S07, S08, S11–S13, S16
- **No new failures.**
- **Corrected along the way:**
  - APR-P02 (my Phase 1D test) used an invented payload. It replaced the whole documents map with an unknown key and status `pending`, which the app never writes. It now mirrors the app's merge upload plus the submit step.
  - The first version of the document rule rejected a resubmission that still carried the old `rejectionReason` (`set(merge)` behaviour). The rule was fixed and covered by DOC-P02 and DOC-S06.

**Fallbacks:** unchanged and verified.
- Driver `retryWithRecaptcha` / `forceRecaptchaFlow` in login, sign-up and OTP: 0 changed lines vs HEAD.
- Passenger `FirebaseAppCheck.activate` (Play Integrity / debug provider): `main.dart` unchanged.
- The SDK reCAPTCHA fallback is untouched.

### Remaining risks
- **Role / vehicle self-change (above).** This is the main gap left in eligibility-based access.
- Delivery and gas OTPs (`deliveryOtp`) are still readable by the assigned driver: a known earlier finding, a payment and lifecycle concern, out of scope.
- **Not verified:** Driver builds before 18 May 2026 (a different delivery accept flow), and before 27 May 2026 for rides.
- Each order read by a non-party costs up to 3 extra document reads (the driver doc via `isActiveDriver` / `isActiveDeliveryDriver`). This is small, but measurable on billing.
- `profile_photo` is accepted as a document key because the app reads it. No current code writes it.

### Production readiness
The complete proposed `firestore.rules` is **ready for owner review and a staged production deploy**:
- It needs no app release, index or Functions change first.
- Every released-app read and write tested keeps working.
- The 16 known failures are unrelated payment and lifecycle rules (C2).

Deploy with `firebase deploy --only firestore:rules`; roll back by re-releasing ruleset `08f89544-25c5-46fe-8a90-9d5b4ffd17ad`. **Not deployed; owner approval (AP-6) required.**

---

## Phase 1F: Policy A, confirmation codes, final review (rules only)

> **Correction: rollback target.** Earlier sections name `08f89544-25c5-46fe-8a90-9d5b4ffd17ad` as the rollback ruleset. That is the **older** ruleset from 2 October. The ruleset live now is **`96fb236f-14f5-4eb3-8cda-da0a2c20c9e4`**, deployed 12 October 06:16 UTC with the `driver_map` rule. **Roll back to `96fb236f…`.** Rolling back to `08f89544…` would also remove the map-marker rule.

**Files changed:**
- `firestore.rules`
- `rules-tests/test/eligibility_codes.test.js` (new, 23 tests)
- `FIRESTORE_RULES_PROPOSED.diff` (new): the full diff of production `96fb236f…` against the proposal, +200 / −24.

No app, Functions, payment or console changes were made.

### Policy A: eligibility fields
- While a driver is approved, **or suspended**, the owner may not change `role`, `serviceType` or `vehicleType`.
  - Suspension is included because the Admin app's unsuspend sets `isApproved: true` without re-reviewing anything else.
- Drivers still in onboarding (not yet approved) set them freely. Admins can always change them.
- Re-saving the same value is not a change, so the released vehicle-setup screen still saves for approved drivers as long as nothing actually changes.
- A driver who actually changes vehicle or role after approval now gets the app's existing save error. The app copy ("contact support") is a future app release, not part of this change.
- A rejected driver (`signupStep: 'rejected'`, not approved) is **not** locked, so they can correct details. Their `signupStep` is still locked (DRV-S04), so they can't re-enter review on their own.

### Confirmation codes (`deliveryOtp`)

**Finding:** the code is **sensitive**. `onDeliveryCompleted` / `onGasOrderCompleted` treat `otpSubmitted == deliveryOtp` as proof of delivery before settling the order and releasing payment. Two weaknesses:
1. **Overwrite (fixed):** the assigned driver, or the passenger, could rewrite `deliveryOtp` and then submit the same value.
   - Rule: no client may change `deliveryOtp` after creation, on deliveries or gas orders.
   - The released apps never write it after creation. Admins and Functions (Admin SDK) still can.
2. **Read exposure (not fixable in rules):** the code sits on the order document, which the assigned driver must be able to read. The released Driver app even fetches it and compares locally. Firestore rules cannot hide a single field.

**Smallest real fix** (needs owner approval: it touches payment-adjacent completion code and two app releases):
- (a) The Passenger app writes the code to a passenger-only document (for example `deliveries/{id}/private/confirmation`, readable by the passenger and admins only) instead of the order. It displays it from there.
- (b) The Driver app always prompts for the code and sends it unverified as `otpSubmitted`.
- (c) The completion check reads the private document. That's a change to the settlement Functions, which is out of scope here.
- (d) Optionally, a rule on completion: `otpSubmitted == get(private).code`.

**Rollout order:** Driver app first, then the Functions, then the Passenger app. Until then, a dishonest assigned driver can still complete without the recipient, but every such completion is recorded with the driver's identity.

### Results

Rules suite: **180 passing / 16 failing**, up from 157 / 16.
- **New:** 23/23 ELG / OTP tests pass:
  - every protected field × approved / suspended (both seed styles) / unapproved
  - admin changes
  - same-value vehicle-setup write
  - unrelated profile fields
  - document upload
  - online / offline
  - code rewrite by driver and by passenger
  - legitimate completion with code
- **Earlier groups unchanged:** TRA/DSC 26, ASG/APR 25, DLV/GAS/DOC 33, TRIP-P 13, C4, AVL, MAP.
- **The 16 failures are the same pre-existing list** (payment, lifecycle and money): DRV-S10, DRV-P07, MON-S09–S11, TRIP-S01–S05, S07, S08, S11–S13, S16.
- **No new failures.**

**Fallbacks:** verified unchanged.
- Driver `retryWithRecaptcha` / `forceRecaptchaFlow` in login, sign-up and OTP: 0 changed lines vs HEAD.
- Passenger `main.dart` (App Check, Play Integrity / debug) unchanged.
- No `setSettings` or app-verification changes in either repo.

### Project ID and deployment notes
- **Verified: `ctstransportapp`**
  - Passenger `.firebaserc` default (the deploy target)
  - Passenger `firebase.json` (`"rules": "firestore.rules"`)
  - both apps' `firebase_options.dart`
  - both `google-services.json`
  - `functions/config.js`
- **Hazard:** the Driver repo has its own `firebase.json` with a Firestore rules target and an **old `firestore.rules` (22 May 2026)**. Deploy **only from the Passenger repo**:
  `firebase deploy --only firestore:rules --project ctstransportapp`
  Never deploy from the Driver repo.
