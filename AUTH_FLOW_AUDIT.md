# CTS Go — Authentication Flow Audit (Passenger & Driver)

- **Date of audit and documentation check:** 12 October 2026
- **Firebase project:** `ctstransportapp` (functions region `europe-west2`)
- **Scope:** Passenger app, Driver app, the Firestore rules and Cloud Functions in the Passenger repo, and production Auth / App Check configuration (read-only).
- **Method:** static code inspection; read-only production configuration and metadata queries; one recorded login attempt on a physical device; official documentation.
- **What was not done:** no source files were changed for this audit, nothing was deployed, and no console settings were touched.

**Confidence labels used throughout:**
- **Confirmed:** seen in code or configuration, or reproduced.
- **Probable:** strong static evidence, but not reproduced.
- **Needs Runtime Verification:** cannot be settled without a device, Play build or console access.

---

## 0. Repository state at audit time

| | Passenger | Driver |
|---|---|---|
| Path | `passenger/cts-transport-passenger-app-clean` | `driver/cts-transport-driver-app-clean` |
| Branch / HEAD | `checkpoint/2026-10-10` @ `88f27f1` | `checkpoint/2026-10-10` @ `deaca6f` |
| Uncommitted | 35 entries (P1, C4, map-marker and login-race work) | 5 entries (C4) |
| Package id | `com.cts.passenger` | `com.cts.ctsgo.driver` (a third registered app, `com.cts.driver`, appears unused) |
| `firebase_core` / `firebase_auth` (locked) | 4.15.0 / 6.7.0 | 3.15.2 / 5.7.0 |
| `firebase_app_check` (locked) | 0.4.7 (pinned exactly) | 0.3.2+10 (declared, **never activated**) |
| `cloud_firestore` / `cloud_functions` / `firebase_messaging` | 6.10.0 / 6.5.0 / 16.7.0 | 5.6.12 / 5.6.2 / 15.2.10 |
| `flutter_riverpod` | 3.3.1 | 2.6.1 |
| Android `targetSdk` | 36 | 36 |
| iOS | `ios/` exists; iOS auth not evaluated (no evidence of an iOS release) | same |

Uncommitted Passenger auth-related changes made earlier today, which are part of the current state:
- `lib/features/auth/data/passenger_profile_check.dart` (new)
- edits to `_finishLogin` in `auth_providers.dart`
- edits to `passenger_flow_resolver.dart`
- `test/auth/passenger_profile_check_test.dart`

They fix the login race described in AUTH-05. They pass unit tests but have **not yet been confirmed on a device across repeated fresh installs.**

---

## A. Executive summary

**Passenger app — functional login: fair after today's fix; account lifecycle: weak.**
- Phone OTP login and sign-up are reasonably structured:
  - a single Riverpod notifier
  - duplicate-submit guards
  - resend tokens
  - a server-verified profile check (fixed today)
- Account deletion is broken. The client writes to a collection the rules deny (AUTH-06).
- "Deactivate" is never enforced (AUTH-07).
- Phone numbers and UIDs are written to device logs in release builds (AUTH-11).

**Driver app — functional login: fragile; session hygiene: poor.**
- The login path discards automatic verification (AUTH-08).
- The sign-up auto-verify path skips creating the driver document (AUTH-09).
- Sign-out leaves the driver **online, available and still receiving dispatch pushes** (AUTH-04).
- The reCAPTCHA retry duplicates behaviour the Firebase SDK already provides, and forces reCAPTCHA for the rest of the session (AUTH-10).
- The "Forgot password" screen is a simulation with no backend (AUTH-14).

**Backend boundary (affects both) — the most serious issues:**
- **AUTH-01 (Critical):** any signed-in identity can read **every** trip. That includes passenger names, exact pickup and drop-off addresses and coordinates, and driver names and phone numbers.
- **AUTH-02 (High):** email/password sign-up is open on the project, which makes AUTH-01 exploitable without an SMS: anyone with the public API key can create an account over REST.
- **AUTH-03 (High):** both apps' push-token savers create profile documents for *any* signed-in identity. Backend role detection (`getRole`) then misclassifies passengers as drivers.

**App Check:** enforcement is **off** for every service, including Auth and Firestore. App Check is therefore not causing login failures today. It is also not protecting anything.

**Phone-verification configuration (verified read-only):**
- Phone sign-in is enabled.
- SMS region policy is set to an allowlist of Ghana only.
- The release signing key used by local builds (SHA-1 and SHA-256) is registered for both apps.
- 8 test phone numbers are configured in the **production** project (AUTH-12).

### Top five priorities

1. **AUTH-01:** restrict `trips` (and `trips/{id}/locations`) reads to the trip's parties and approved drivers.
2. **AUTH-02:** stop open self-sign-up on the project while keeping Admin email login working.
3. **AUTH-04:** take the driver offline and clear the push token on Driver sign-out.
4. **AUTH-03:** stop push-token saves from creating profile documents; fix `getRole` misclassification.
5. **AUTH-06 / AUTH-07:** implement working account deletion (also a Google Play requirement) and enforce deactivation.

---

## B. Architecture comparison

### B.1 Passenger flow (actual)

1. **App launch:** `main.dart`:
   1. `Firebase.initializeApp(DefaultFirebaseOptions)`
   2. `PricingService.fetch()` (a Firestore read, *before* App Check)
   3. `FirebaseAppCheck.activate(Debug in debug builds, else PlayIntegrity)`
   4. `NotificationService.initialize()`. This registers an `authStateChanges` listener that saves the FCM token on every sign-in (`set(..., merge: true)` on `users/{uid}`).
2. **Splash:** `SplashScreen` runs `StartupResolver.resolve()`:
   - Onboarding not seen → onboarding.
   - Otherwise it waits up to 3 s on `authStateChanges().first`. No user → login.
   - Otherwise → `PassengerFlowResolver.resolve(uid)`.
3. **`PassengerFlowResolver`** (`lib/core/startup/passenger_flow_resolver.dart`):
   - Reads `users/{uid}`: server first, with a cache fallback that can only *confirm* a passenger (today's change).
   - No profile → clear token, sign out, go to sign-up.
   - Role ≠ passenger → clear token, sign out, go to login.
   - `hasSeenWelcome` false → welcome.
   - Otherwise → shell.
   - On any error → clear token, sign out, go to login (fails closed; an offline cold start with no cache signs the user out).
4. **Login:** `LoginScreen._requestOtp` → `AuthNotifier.sendOtp` → `verifyPhoneNumber(timeout 60 s)`.
   - `codeSent` stores the `verificationId` and resend token; the screen pushes the OTP screen.
   - `verificationCompleted` (auto) → `_completeAutomaticVerification` → `signInWithCredential` → `_finishAfterCredential`.
   - `verificationFailed` → `_phoneErrorMessage` → snackbar.
5. **OTP:** `OtpVerificationScreen._verifyOtp`. Auto-submit fires on the last digit, guarded against double submission. It calls `verifyOtp` → `signInWithCredential` → `_finishLogin`, which:
   - reads the **server** profile
   - rejects non-passengers (sign out, "No passenger account found")
   - otherwise stamps `lastLoginAt` and navigates to the shell.
6. **Sign-up:** `SignupScreen` → `AuthNotifier.signUp` → the same OTP flow with `pendingProfile`. `_createPassengerProfile`:
   - calls `user.reload()`
   - reads the doc with a *default* (cache-capable) read
   - blocks any non-passenger role
   - `set(merge)` the profile with `role: 'passenger'`
   - then goes to welcome, which sets `hasSeenWelcome`.
7. **Logout:** `AuthNotifier.signOut` → `NotificationService.clearToken()` (bounded, matches the token, deletes the device token) → `FirebaseAuth.signOut()`.
8. **Unused code:** `lib/app/auth_gate.dart` (`AuthGate`) is not referenced anywhere.

### B.2 Driver flow (actual)

1. **App launch:** `main.dart`:
   - `Firebase.initializeApp()`, also run again in the background FCM handler (expected).
   - Firestore persistence with an unlimited cache.
   - **No App Check activation.**
   - `DriverNotificationService.initialize()` registers an `authStateChanges` listener that saves the FCM token with `set(..., merge: true)` on **`drivers/{uid}`**.
2. **Splash:** `StartupResolver` → `AppFlowResolver.resolveDestination(uid)` (`lib/core/services/driver_flow_resolver.dart`). It does a default (cache-capable) read of `drivers/{uid}`:
   - No document → sign out → login, with no message.
   - Otherwise the first unmet step wins: role → account setup → vehicle → documents → pending approval → shell.
   - Any error → login.
3. **Login:** `features/auth/presentation/login_screen.dart` `_login()` → `verifyPhoneNumber`:
   - `codeSent` → OTP screen (`isDriverLogin: true`).
   - **`verificationCompleted: async {/*...*/}` is an empty stub.**
   - `verificationFailed`: on `app-not-authorized` or `invalid-app-credential`, it sets `setSettings(forceRecaptchaFlow: true)` and retries once.
4. **OTP:** `otp_verification_screen.dart` `_verifyOtp` → `signInWithCredential`:
   - Login → `AppFlowResolver`.
   - Sign-up → `DriverService.createDriverDocument(phone)`, which writes only if the doc is missing, then → role selection.
5. **Sign-up:** `signup_screen.dart` uses the same retry pattern. Its `verificationCompleted` signs in and goes **straight to role selection without `createDriverDocument`**.
6. **Logout:**
   - `driver_settings_screen.dart` runs `prefs.clear()` then `FirebaseAuth.signOut()`.
   - `DriverProfileService.signOut()` runs `FirebaseAuth.signOut()` only.
   - **Neither calls `goOffline()` or `clearToken()`.**
7. **Unused or dead code:**
   - `features/driver_auth/presentation/screens/driver_login_screen.dart` and `driver_phone_screen.dart` (routes use `DriverAccountSetupScreen` for `driverPhone`).
   - `lib/app/auth_gate.dart`.
   - `DriverForgotPasswordScreen` is routed but simulated.

### B.3 Comparison

| Aspect | Passenger | Driver |
|---|---|---|
| Auth state ownership | Central `AuthNotifier` (Riverpod) | Logic spread across screens, no notifier |
| Auto verification | Handled, guarded against double consumption | Login: discarded; Sign-up: handled but skips provisioning |
| reCAPTCHA handling | Relies on SDK default (correct per docs) | Manual forced retry (redundant, sticky) |
| Profile read for routing | Server-first (after today's fix) | Default read (same cache race as Passenger had) |
| Wrong-app account handling | Explicit message + sign-out | Silent sign-out (no doc) or partial doc → role selection |
| Logout hygiene | Token cleanup before sign-out | No token cleanup, no offline |
| App Check | Activated (not enforced server-side) | Not activated |
| Shared risk | FCM saver creates `users/{uid}` | FCM saver creates `drivers/{uid}` |

**Safe consistency opportunity:**
- Give the Driver app the same pattern Passenger now has: one auth notifier, a server-first profile check, token cleanup on logout.
- **Do not** share code across repos yet. The FlutterFire major versions differ (Auth 6.x vs 5.x, Riverpod 3 vs 2).

---

## C. Findings register

### AUTH-01: Every signed-in identity can read all trips and trip locations

- **Applies to:** Both (backend rules)
- **Severity:** Critical
- **Confidence:** Confirmed. The deployed rules match the repo (checked earlier today), and the email provider is enabled (see AUTH-02).
- **Where:**
  - `firestore.rules`: `match /trips/{tripId}` has `allow read: if isAuth();`
  - `match /trips/{tripId}/locations/{locationId}` has `allow read: if isAuth();`
- **Evidence:** trip documents (`TripRequest.toFirestore`) carry:
  - `passengerName`
  - `pickupLocation` / `dropoffLocation` (exact coordinates)
  - `pickupAddress` / `dropoffAddress`
  - the driver's name, phone and plate (added on accept)
- **Why it matters:** authentication is being treated as authorization. Any authenticated identity, including one created over REST with the public API key (AUTH-02), can list every rider's home and work addresses and every driver's phone number.
- **Fix:**
  - Allow read only when one of these holds:
    - the reader is a party to the trip
    - the trip is `status == 'searching' && driverId == null` **and** the reader is an approved, active driver (`get(drivers/uid).data.isApproved == true`)
    - the reader is an admin
  - Apply the same to `locations`.
  - The driver request query must add `.where('driverId', isNull: true)` so the rule can be proven for the query. The production index `(status, driverId, createdAt desc)` already exists.
- **Regression risk:** Medium. Affects the driver request list, passenger history and tracking.
- **Required tests:** rules emulator tests for:
  - party reads
  - stranger denied
  - unapproved driver denied
  - approved driver can query searching trips
- **Platform change:** rules deploy (owner approval AP-6). Part of planned C2.

### AUTH-02: Email/Password sign-up is open on the production project

- **Applies to:** Both (project config)
- **Severity:** High
- **Confidence:** Confirmed (Identity Toolkit config, read-only: `signIn.email.enabled = true`).
- **Evidence:**
  - Neither mobile app uses email auth.
  - The **Admin dashboard does** (`ctsride-admin/src/lib/auth-context.tsx`, `signInWithEmailAndPassword`).
- **Why it matters:** anyone can create unlimited accounts without an SMS. Each one passes `isAuth()` (AUTH-01) and `isOwner()` create rules. That includes creating `drivers/{uid}` with `isApproved: true`, the known DRV-S01 rules gap.
- **Fix:**
  - Do **not** disable the provider; Admin login needs it.
  - Instead, block client-side sign-up. Identity Platform's user-actions setting ("Enable create (sign up)" off, `client.permissions.disabledUserSignup`) does this; its availability on this project **Needs Runtime Verification** in the console.
  - Create admin users from the console or Admin SDK only.
  - Independently, close DRV-S01/S02 in C2.
- **Regression risk:** Low, provided admin accounts already exist.
- **Required tests:**
  - A REST sign-up attempt is rejected (staging).
  - Admin login still works.
- **Platform change:** Firebase / Identity Platform console.

### AUTH-03: Push-token savers create profile documents for any identity, which corrupts role detection

- **Applies to:** Both
- **Severity:** High
- **Confidence:** Confirmed in code; impact Probable.
- **Where:**
  - Passenger `notification_service.dart` `_persistToken`: `users/{uid}`, `set(merge)` on every `authStateChanges` user.
  - Driver `driver_notification_service.dart` `_persistToken`: `drivers/{uid}`, same.
- **Evidence:**
  - Signing into the Driver app with a passenger's number creates `drivers/{uid}` (token fields only).
  - `functions/wallet.js` `getRole()` checks `drivers` **first**, so that passenger is then treated as a driver by `getWalletBalance` and related functions.
  - Also, Driver `createDriverDocument` skips when the doc "exists", leaving drivers with no defaults (`isApproved`, `serviceType`, …).
  - On Passenger, a token-only `users` doc made a real passenger look unregistered on cached reads (the root cause of the login failure; see AUTH-05).
- **Fix:**
  - Use `update()` (never create) for token saves. If the doc doesn't exist yet, skip and save after provisioning (call `_saveToken()` at the end of profile creation).
  - Make `getRole` require a real driver record (for example `role` in `driver_hailing` / `driver_delivery`), not mere existence.
- **Regression risk:** Medium. A new user's token isn't saved until provisioning finishes, so the post-provisioning save must be added in the same change.
- **Required tests:**
  - unit tests for the token saver (no create)
  - a rules or emulator test that the first sign-in creates no doc
  - a Functions test for `getRole`
- **Platform change:** Functions deploy for `getRole`.

### AUTH-04: Driver sign-out leaves the driver online, available and receiving pushes

- **Applies to:** Driver
- **Severity:** High
- **Confidence:** Confirmed.
- **Where:**
  - `driver_settings_screen.dart` (~l.150–160): `prefs.clear()` then `FirebaseAuth.signOut()`.
  - `driver_profile_service.dart:20` `signOut()`.
  - `DriverRuntimeService.goOffline()` and `DriverNotificationService.clearToken()` are never called on logout. `clearToken` has no callers at all.
- **Why it matters:**
  - Dispatch (`onTripCreatedNotify`) keeps sending ride requests to a signed-out device.
  - The driver stays visible on the passenger map (`driver_map`) and counts as available.
  - The next person to sign in on the same device inherits notifications.
- **Fix:** one `DriverSessionService.signOut()` that:
  1. `goOffline()` (bounded)
  2. clears the token on `drivers/{uid}` while still authenticated
  3. `FirebaseMessaging.deleteToken()`
  4. `FirebaseAuth.signOut()`

  Use it from both call sites. Mirror Passenger's `PushTokenCleanup` (bounded, never blocks sign-out).
- **Regression risk:** Low.
- **Required tests:** unit tests with fakes for ordering and timeouts; a device check that dispatch stops after logout.
- **Platform change:** none.

### AUTH-05: Profile check could use a stale cache right after sign-in (login rejected as "No passenger account")

- **Applies to:** Passenger (fixed, not yet confirmed on device); Driver (same pattern, open)
- **Severity:** High (it blocked real logins)
- **Confidence:** Passenger Confirmed by device logs and `lastLoginAt` evidence. Driver Probable.
- **Where:**
  - Passenger: previously `_finishLogin` did `docRef.get()`. Now `readPassengerProfile()` reads the server copy only.
  - Driver: `AppFlowResolver._fetchDriverData` uses a default `get()` with unlimited persistence, while the FCM saver races to write `drivers/{uid}`. A returning driver could be routed to **role selection** off a token-only cached doc.
- **Fix (Driver):**
  - Server-first read.
  - Never route on a cached doc that lacks `role`.
  - Together with AUTH-03.
- **Regression risk:** Low.
- **Required tests:**
  - Passenger: `test/auth/passenger_profile_check_test.dart` (done, 6 tests).
  - Driver: an equivalent pure-function test.
  - Device: repeated fresh-install logins.

### AUTH-06: Account deletion always fails

- **Applies to:** Passenger
- **Severity:** High (also a Google Play policy requirement for apps with account creation)
- **Confidence:** Confirmed.
- **Where:** `privacy_security_screen.dart` `_deleteAccount()` writes `account_deletion_requests/{uid}`.
- **Evidence:**
  - `firestore.rules` has no `account_deletion_requests` match, so the write is denied and the user sees "Could not process deletion".
  - No Cloud Function processes such requests.
- **Fix:**
  - Implement a callable `requestAccountDeletion`: it authenticates, records the request, and marks the profile.
  - A server job deletes the data and calls `admin.auth().deleteUser(uid)`.
  - Retention rules for wallet and trip records need an owner policy decision. **Do not invent one.**
- **Regression risk:** Low.
- **Required tests:** a Functions emulator test and rules tests.
- **Platform change:** Functions deploy; Play Console data-deletion declaration.

### AUTH-07: "Deactivate account" is not enforced

- **Applies to:** Passenger
- **Severity:** Medium
- **Confidence:** Confirmed.
- **Where:**
  - `_deactivateAccount()` sets `users/{uid}.isDeactivated = true` and signs out.
  - Nothing reads `isDeactivated`: no client, rules or Functions reference.
- **Fix:** decide the policy first (reversible on next login or not?), then enforce it in `PassengerFlowResolver` / `_finishLogin` and, if required, in rules.
- **Regression risk:** Low.
- **Required tests:** unit tests on the classification function.
- **Platform change:** none.

### AUTH-08: Driver login discards automatic verification

- **Applies to:** Driver
- **Severity:** Medium
- **Confidence:** Confirmed in code; impact Needs Runtime Verification.
- **Where:** `features/auth/presentation/login_screen.dart` `verificationCompleted: (cred) async {/*...*/}`.
- **Evidence:** per Firebase docs, `onVerificationCompleted` covers both instant verification ("the phone number can be instantly verified without needing to send or enter a verification code") and auto-retrieval.
- **Why it matters:** if instant verification occurs and no code is sent, the driver is left with no path forward. With auto-retrieval, manual entry still works.
- **Fix:** sign in with the credential and route through `AppFlowResolver`, guarded against double consumption, as Passenger does.
- **Regression risk:** Low.
- **Required tests:** a unit test on the completion handler with fakes; a device test on a Play-services phone.
- **Platform change:** none.

### AUTH-09: Driver sign-up auto-verify path skips creating the driver document

- **Applies to:** Driver
- **Severity:** Medium
- **Confidence:** Confirmed in code.
- **Where:** `signup_screen.dart` `verificationCompleted` signs in, then goes to `roleSelection`. Only the manual OTP path calls `DriverService.createDriverDocument`.
- **Impact:** role selection then `update()`s a doc that may not exist (NOT_FOUND), or exists only as a token stub (AUTH-03) with no defaults.
- **Fix:** route both completion paths through one function: sign in → `createDriverDocument` → resolver.
- **Regression risk:** Low.
- **Required tests:** unit test.
- **Platform change:** none.

### AUTH-10: Manual forced-reCAPTCHA retry duplicates SDK behaviour and is sticky

- **Applies to:** Driver
- **Severity:** Medium
- **Confidence:** Confirmed in code.
- **Where:** `login_screen.dart`, `signup_screen.dart` and `otp_verification_screen.dart` call `FirebaseAuth.instance.setSettings(forceRecaptchaFlow: true)` and retry on `app-not-authorized` / `invalid-app-credential`.
- **Evidence:**
  - Firebase docs: Android phone auth already uses reCAPTCHA when Play Integrity can't be used, for example on devices without Play services or apps not distributed through Google Play.
  - The forced flow is documented as `forceRecaptchaFlowForTesting`.
  - `app-not-authorized` usually means a configuration problem (package or SHA fingerprints), which a retry would mask.
  - The setting is never reset, so every later verification in that app session is forced to reCAPTCHA.
- **Fix:**
  - Remove the forced retry. Rely on the SDK's fallback.
  - Map these codes to a clear message plus logging.
  - Keep a forced-reCAPTCHA switch only behind a debug or remote flag, reset after use.
  - Confirm on the uncertified device that originally failed before removing anything.
- **Regression risk:** Medium. Needs device verification on the device class that originally failed.
- **Required tests:** device tests on a certified device, an uncertified device and an emulator.
- **Platform change:** none. The SHA-1 and SHA-256 of the **Play app-signing key** must be registered; this Needs Runtime Verification in Play Console.

### AUTH-11: Phone numbers and UIDs written to device logs in release builds

- **Applies to:** Both
- **Severity:** Medium
- **Confidence:** Confirmed (device log contained full numbers).
- **Where:**
  - Passenger `auth_providers.dart`: `debugPrint` of `$phone` (l.157, 277) and UIDs (409, 555, …).
  - Driver: `debugPrint('FCM persist uid=…')` and error messages.
- **Why it matters:** `debugPrint` is not stripped in release builds, so logs readable over ADB or by OEM log collectors contain PII.
- **Fix:** mask numbers (keep the last 2–3 digits), drop UIDs from logs, or gate behind `kDebugMode`.
- **Regression risk:** None.
- **Required tests:** none beyond review; optionally a lint rule.
- **Platform change:** none.

### AUTH-12: Test phone numbers configured on the production project

- **Applies to:** Both
- **Severity:** Medium
- **Confidence:** Confirmed (8 configured; the values were not printed).
- **Why it matters:**
  - A test number signs in with a fixed code and no SMS. Anyone who learns a number and its code can sign in as that account.
  - At least one test number currently owns a real passenger profile.
- **Fix:**
  - Keep only the numbers needed for store review.
  - Make sure none of them owns admin, driver or wallet value.
  - Rotate the codes.
  - Prefer a staging project for QA.
- **Regression risk:** Low (store-review access must be kept).
- **Required tests:** none.
- **Platform change:** Firebase console.

### AUTH-13: App Check is activated after the first Firestore read; Driver has none; enforcement is off

- **Applies to:** Both
- **Severity:** Low today (Medium before enabling enforcement)
- **Confidence:** Confirmed. Enforcement: Firestore, Auth (identitytoolkit), Storage, Maps and Places are all `UNENFORCED`.
- **Evidence:**
  - Passenger `main.dart` calls `PricingService.fetch()` (Firestore) before `FirebaseAppCheck.activate`. Docs: initialize App Check "before you use any other Firebase SDKs".
  - The Driver app never activates App Check.
  - Play Integrity's default `PLAY_RECOGNIZED` requirement means sideloaded or locally built releases would fail App Check once it's enforced.
- **Fix:**
  - Move `activate` directly after `initializeApp` in Passenger.
  - Add App Check to Driver.
  - Watch the console metrics for several weeks before enforcing.
  - Never enforce on Auth until Driver ships App Check.
  - Use the debug provider for local QA builds.
- **Regression risk:** Low (no enforcement).
- **Required tests:** console metrics review.
- **Platform change:** later, enforcement toggles.

### AUTH-14: Driver "Forgot password" screen is a simulation

- **Applies to:** Driver
- **Severity:** Low
- **Confidence:** Confirmed.
- **Where:** `driver_forgot_password_screen.dart` uses `Future.delayed` steps with no Firebase calls.
- **Why it matters:** the product authenticates by phone OTP, so the screen is misleading.
- **Fix:** remove the route, or replace it with "Log in with your phone number".
- **Regression risk:** None.
- **Required tests:** none.
- **Platform change:** none.

### AUTH-15: Passenger profile creation uses a cache-capable read and may skip first-creation fields

- **Applies to:** Passenger
- **Severity:** Low
- **Confidence:** Probable.
- **Where:** `_createPassengerProfile` uses `docRef.get()` (default source). If the token stub from AUTH-03 exists, `isNewDoc` is false, so `createdAt` and `termsAcceptedAt` are never written.
- **Fix:** resolved by AUTH-03, plus a server read here.
- **Regression risk:** Low.
- **Required tests:** unit test.
- **Platform change:** none.

### AUTH-16: Error mapping exposes raw Firebase messages and misses common codes

- **Applies to:** Both
- **Severity:** Low
- **Confidence:** Confirmed.
- **Where:** Passenger `_phoneErrorMessage` defaults to `'Verification failed: ${message ?? code}'`. It has no cases for:
  - `network-request-failed`
  - `invalid-app-credential`
  - `app-not-authorized`
  - `user-disabled`
  - `captcha-check-failed`
  - `web-context-cancelled`

  Driver maps only 3 codes.
- **Fix:** explicit user-friendly messages for each code, and log the raw code.
- **Regression risk:** None.
- **Required tests:** a unit test on the mapping.
- **Platform change:** none.

### AUTH-17: Request lock can stick if `verifyPhoneNumber` never calls back

- **Applies to:** Passenger
- **Severity:** Low
- **Confidence:** Needs Runtime Verification.
- **Where:** `sendOtp` / `signUp` return early while `state.isLoading` is true, and `isLoading` is cleared only in callbacks.
- **Fix:** a watchdog timeout (for example 90 s) that resets `isLoading`.
- **Regression risk:** Low.
- **Required tests:** unit test with a fake.
- **Platform change:** none.

### AUTH-18: Cross-app identity collision (one phone = one UID across both apps)

- **Applies to:** Both
- **Severity:** Medium (product decision)
- **Confidence:** Confirmed.
- **Where:**
  - Passenger blocks numbers whose `users` role isn't passenger.
  - Driver does not check `users` at all.
  - Because both apps share the project, the same person cannot hold both roles, and the backend's role detection is ambiguous (AUTH-03).
- **Fix:** owner decision: either forbid dual roles explicitly in both apps, or model roles per collection and stop inferring role from document existence.
- **Regression risk:** Medium.
- **Required tests:** Functions and rules tests.
- **Platform change:** none.

### AUTH-19: Dead or duplicate auth code

- **Applies to:** Both
- **Severity:** Low
- **Confidence:** Confirmed.
- **Where:**
  - `AuthGate` is unused in both apps.
  - Driver `driver_login_screen.dart` and `driver_phone_screen.dart` are unrouted.
  - A third Firebase Android app, `com.cts.driver`, is registered.
- **Fix:** remove after confirmation, to reduce confusion.
- **Regression risk:** None.
- **Required tests:** none.
- **Platform change:** none.

**Already tracked elsewhere and referenced here:**
- DRV-S01/S02 (driver can create its own driver doc with `isApproved: true` or a balance): rules failures in the Phase 1 suite, planned for C2.
- The broken `createPassengerWallet` trigger signature (`functions/index.js:9`): new passenger wallets are not auto-created.

---

## D. Firebase compliance matrix

| Requirement | Passenger | Driver | Evidence | Required action |
|---|---|---|---|---|
| Phone provider enabled; SMS region policy set | Compliant | Compliant | Auth config: phone enabled, allowlist `GH` | None |
| SHA-1 and SHA-256 registered (local upload key) | Compliant | Compliant | Registered fingerprints match the release builds' signer | Verify the Play **app-signing** key is also registered |
| Rely on SDK reCAPTCHA fallback; forced flow only for testing | Compliant | Non-compliant | AUTH-10 | Remove forced retry |
| Handle `verificationCompleted` (instant/auto) | Compliant | Partially compliant | AUTH-08, AUTH-09 | Implement |
| Keep `verificationId` after auto-retrieval timeout | Compliant | Compliant | Both keep it | None |
| Resend with `forceResendingToken` | Compliant | Compliant | Both pass the token | None |
| App Check initialized before other Firebase SDK use | Non-compliant | Not applicable (not used) | AUTH-13 | Reorder / add |
| App Check debug provider not used in release | Compliant | Not applicable | `kDebugMode` switch | None |
| App Check enforcement | Not verified (off by choice) | Not verified | All services `UNENFORCED` | Plan staged enforcement |
| Account deletion available in app | Non-compliant | Not verified | AUTH-06; Driver has no deletion flow found | Implement |
| Delete requires recent login or server-side deletion | Non-compliant | Not verified | No working path | Server-side deletion |
| Authorization enforced by rules, not by being signed in | Non-compliant | Non-compliant | AUTH-01, DRV-S01 | C2 rules |
| No PII in production logs | Non-compliant | Non-compliant | AUTH-11 | Mask |
| Test phone numbers kept out of production | Non-compliant | Non-compliant | AUTH-12 | Reduce / rotate |
| Session cleanup on sign-out | Compliant | Non-compliant | AUTH-04 | Implement |

---

## E. Root-cause assessment

1. **Today's "No passenger account" login failure:**
   - **Root cause:** two independent writers and readers of the profile document race at sign-in. The token saver `set(merge)`s a role-less stub, and the profile check read a cached view of it.
   - **Contributing:** the default `get()` source; a fresh install with an empty cache.
   - **Symptoms:** the "verification session is no longer available" popup is a consequence. The rejected attempt resets auth state, and a second submit finds no session.
2. **Historical `INVALID_APP_CREDENTIAL` / Play Integrity failures:**
   - **Root cause (not reproducible today):** uncertified devices failing Play Integrity, possibly combined with unregistered signing fingerprints at that time.
   - **Today's state:** the local release signer is registered. The SDK falls back to reCAPTCHA by itself. App Check enforcement is off, so App Check cannot be the cause.
   - **Device verification needed** before removing the Driver workaround.
3. **Data exposure (AUTH-01/02/03):**
   - **Root cause:** rules equate "signed in" with "trusted", while account creation is cheap (email sign-up open) and profile documents can be self-created.

---

## F. Phased implementation plan

Each step is small, independently testable, and per app.

1. **Critical security (backend; owner approval for deploys):**
   - **AUTH-01:** trip read rules plus the driver query change.
     - Files: `firestore.rules`, Driver `requests_section.dart` (add `driverId isNull`), `rules-tests/`.
     - Rollback: redeploy the previous ruleset (its ID is in the release history).
   - **AUTH-02:** disable self-sign-up in the console after confirming admin accounts exist. Rollback: re-enable.
   - **DRV-S01/S02:** C2.
2. **Functional login defects:**
   - **Driver AUTH-08, AUTH-09, AUTH-05:**
     - one completion function
     - server-first resolver read
     - unit tests in `test/features/auth/`
   - **Passenger:** device confirmation of the AUTH-05 fix; AUTH-17 watchdog; AUTH-16 messages.
3. **App Check / Play Integrity / reCAPTCHA:**
   - **AUTH-10:** remove the forced retry, after device tests on the device class that originally failed.
   - **AUTH-13:** reorder Passenger init; add Driver App Check (dependency already declared, so no new dependency).
   - Verify the Play app-signing SHA in Play Console.
4. **Provisioning and authorization consistency:**
   - **AUTH-03:** token savers use `update`, save after provisioning; `getRole` fix (Functions deploy).
   - **AUTH-04:** Driver session sign-out service.
   - **AUTH-06/07:** deletion callable and deactivation policy (owner policy input required).
   - **AUTH-18:** owner decision on dual roles.
5. **Dependency and API migrations:** none required for correctness.
   - Driver is on the FlutterFire Auth 5.x line and Passenger on 6.x. The changelog shows no phone-auth-specific changes between 5.7.0 and 6.7.0 (the latest).
   - Align versions only as a separate, tested change.
   - `firebase_app_check` 0.4.8 is available; Passenger pins 0.4.7, with no known reason to bump.
6. **Observability and regression:**
   - **AUTH-11:** log hygiene.
   - **AUTH-12:** test-number review.
   - **AUTH-19:** dead-code removal.
   - Add an auth event log (code-only, no PII) for `verificationFailed` codes to Crashlytics or Analytics (needs owner approval if it's a new dependency).

---

## G. Acceptance criteria

**Passenger (production-ready when all pass):**
- 20 consecutive logins (10 on fresh installs) with a registered passenger succeed on a Play-certified device, with no "No passenger account" errors.
- An unregistered number is routed to sign-up. A driver number gets a clear message. Neither leaves a `users/{uid}` document behind.
- Sign-up creates exactly one `users/{uid}` with `role`, `createdAt` and `termsAcceptedAt`.
- Logout clears the FCM token on the profile, and no pushes arrive afterwards.
- Account deletion completes end-to-end (staging), and the Auth user is gone.
- No full phone number or UID appears in `adb logcat` from a release build.
- Rules suite: a stranger cannot read another user's trip; passenger and driver parties can.

**Driver:**
- Login and sign-up succeed on a certified device, an uncertified device (reCAPTCHA via the SDK) and the emulator, with no forced-reCAPTCHA setting left enabled.
- Instant or auto verification completes into the correct onboarding step.
- A returning approved driver always reaches the shell (10 fresh-install attempts).
- After logout, `isOnline` and `isAvailable` are false, `fcmToken` is removed, and no dispatch push is received.
- A passenger number used in the Driver app never causes the backend to treat that passenger as a driver.

**Project:**
- Self-sign-up is blocked (REST sign-up attempt rejected); admin login works.
- Production test numbers are reviewed and minimized.
- App Check metrics are reviewed before any enforcement is enabled.

---

## H. Edge-case matrix

Key: ✓ handled, ◐ partial, ✗ not handled, ? not verifiable statically.

| # | Scenario | Passenger | Driver | Evidence |
|---|---|---|---|---|
| 1 | New user, supported device | ✓ | ◐ | Driver AUTH-09 |
| 2 | Returning authenticated user | ✓ (after fix) | ◐ | AUTH-05 |
| 3 | Uncertified / modified device | ? | ◐ | SDK reCAPTCHA fallback; Driver forced retry (AUTH-10) |
| 4 | Weak / no network | ◐ | ◐ | Passenger: server read fails with a retry message; offline cold start without cache signs out. Driver: generic error |
| 5 | SMS delay / failure | ✓ | ✓ | Manual entry and resend kept |
| 6 | Incorrect OTP | ✓ | ✓ | Mapped `invalid-verification-code` |
| 7 | Expired code / session | ✓ | ✓ | `session-expired` mapped |
| 8 | Repeated requests / resends | ✓ | ◐ | Passenger `isLoading` guard (AUTH-17 risk); Driver no guard on login button beyond `_isLoading` |
| 9 | App killed while waiting | ◐ | ◐ | `verificationId` held only in memory, so the user must restart the flow |
| 10 | Restart after auth, before profile | ✓ | ✓ | Passenger resolver → sign-up; Driver resolver → onboarding step |
| 11 | Auth account, no Firestore profile | ✓ | ◐ | Driver: silent sign-out, or a token stub (AUTH-03) |
| 12 | Profile but Auth account deleted | ? | ? | Not handled explicitly; token refresh failure surfaces as errors |
| 13 | Duplicate sign-up, existing number | ✓ | ◐ | Passenger merges an existing passenger; Driver routes to role selection regardless |
| 14 | Quota / rate limit | ✓ | ◐ | Passenger maps `too-many-requests` / `quota-exceeded`; Driver generic |
| 15 | Config / API key / domain errors | ◐ | ◐ | Raw message (AUTH-16) / forced retry masks it (AUTH-10) |
| 16 | App Check token failure | ✓ (not enforced) | N/A | Enforcement off |
| 17 | Play Integrity failure | ? | ◐ | Device test needed |
| 18 | reCAPTCHA interrupted | ◐ | ◐ | `web-context-cancelled` unmapped |
| 19 | Disabled / deleted account | ✗ | ✗ | `user-disabled` unmapped; no token-revocation handling |
| 20 | Different distribution channels | ? | ? | Play app-signing SHA not verified |
| 21 | Outdated app version | ✗ | ✗ | No minimum-version gate (contributed to today's build 8 incident) |
| 22 | Concurrent login / logout / listeners | ◐ | ✗ | Passenger race fixed for the profile read; token saver still races (AUTH-03) |
| 23 | Network recovery after failure | ✓ | ◐ | Passenger retry re-uses the current user |
| 24 | Driver authenticated, not approved | N/A | ✓ | Routed to pending screen |
| 25 | Onboarding incomplete | ✓ | ✓ | Welcome / step routing |
| 26 | Account switching on one device | ✓ | ✗ | AUTH-04 |
| 27 | Permission denied on profile creation | ✓ | ◐ | Passenger surfaces an error; Driver generic |
| 28 | Function failure in provisioning | ✗ | N/A | `createPassengerWallet` trigger broken (separate finding) |

---

## I. Test inventory and strategy

**Existing tests:**
- **Passenger** `test/`: 52 passing. Auth-related:
  - `test/auth/passenger_profile_check_test.dart` (6)
  - `test/home/push_token_cleanup_test.dart`
- **Driver** `test/`: C4 cancellation tests only. **No auth tests.**
- **Rules** `rules-tests/`: 64 passing, 25 known failing. No `users/{uid}` or `trips` read-isolation tests for strangers.
- **Functions:** payment harness plus `driver_map` unit tests. No auth or provisioning tests.

**Safe to run locally or offline:**
- pure-function unit tests (classification, error mapping, cleanup ordering with fakes)
- rules emulator tests
- Functions emulator tests (`demo-*` project)

**Need devices, Play builds or console (not done without authorization):**
- Real SMS.
- An uncertified-device reCAPTCHA flow.
- Play-distributed build app-signing verification.
- App Check metrics.
- Disabling self-sign-up.
- Test-number review.

---

## J. Files inspected

**Passenger:**
- `lib/main.dart`, `lib/firebase_options.dart` (header only)
- `lib/features/auth/providers/auth_providers.dart`
- `lib/features/auth/data/passenger_profile_check.dart`
- `lib/features/auth/presentation/{login_screen,otp_verification_screen,signup_screen(callers),welcome_screen}.dart`
- `lib/core/startup/{startup_resolver,passenger_flow_resolver}.dart`
- `lib/app/auth_gate.dart`
- `lib/features/splash/splash_screen.dart`
- `lib/features/home/services/notification_service.dart`
- `lib/features/profile/presentation/privacy_security_screen.dart`
- `firestore.rules`
- `functions/{index,wallet}.js` (role and wallet parts)
- `pubspec.yaml`, `pubspec.lock`
- `android/app/build.gradle.kts`, `android/settings.gradle.kts`

**Driver:**
- `lib/main.dart`
- `lib/features/auth/presentation/{login_screen,signup_screen,otp_verification_screen,role_selection_screen}.dart`
- `lib/core/services/{driver_flow_resolver,driver_service}.dart`
- `lib/features/driver/services/{driver_notification_service,driver_runtime_service}.dart`
- `lib/features/driver_auth/presentation/screens/*` (routing and calls)
- `lib/features/driver/presentation/driver_settings_screen.dart`
- `lib/features/driver/data/driver_profile_service.dart`
- `pubspec.yaml`, `pubspec.lock`, `android/app/build.gradle.kts`

**Admin:** `src/lib/auth-context.tsx` (provider usage only).

**Production (read-only metadata):**
- Identity Toolkit config: provider flags, SMS region, test-number *count* only.
- App Check service enforcement modes.
- Registered Android apps and their SHA fingerprints (truncated in output).

## K. Intentionally not inspected

- `google-services.json`, `key.properties` and keystores: secrets; only the public signer fingerprints were read, from built artifacts.
- Test phone number values and codes: sensitive.
- Production user, trip or driver documents: data reads are blocked by policy, and not needed for this audit.
- iOS auth configuration: no evidence of an iOS release; marked Not verified.
- Admin app beyond its auth provider: out of scope.

## L. Commands executed (all read-only)

- `git status`, `git log`, `pubspec.lock` parsing (both repos): no changes.
- `gcloud` / REST: App Check services, Identity Toolkit config (filtered output), `androidApps` and SHA list (truncated output).
- `apksigner` / `keytool -printcert` on locally built release artifacts (fingerprints truncated).
- Earlier today: passenger `flutter test` 52/52 passing; recorded `adb logcat` of one login attempt (deleted afterwards; it contained phone numbers).

## M. Official documentation consulted (12 Oct 2026)

- https://firebase.google.com/docs/auth/android/phone-auth: app verification (Play Integrity, reCAPTCHA fallback, SHA requirements), `onVerificationCompleted` semantics, `forceRecaptchaFlowForTesting`, SMS region policy and quotas.
- https://firebase.google.com/docs/app-check/android/play-integrity-provider: initialization order, `PLAY_RECOGNIZED` requirement, debug provider, enforcement semantics.
- https://firebase.google.com/docs/auth/android/manage-users: deletion requires recent sign-in; stale tokens after deletion.
- https://pub.dev/packages/firebase_auth/changelog: latest 6.7.0; no phone-auth-specific changes between 5.7.0 and 6.7.0.
- https://pub.dev/packages/firebase_app_check/changelog: latest 0.4.8; `activate` parameter deprecations in 0.4.1+1.

## N. Open questions and access limits

1. Is the **Play app-signing** certificate (as opposed to the upload key) registered for both apps? This needs Play Console.
2. Can self-sign-up be disabled on this project (Identity Platform user actions)? This needs a console check.
3. Which device or Android build produced the historical `INVALID_APP_CREDENTIAL`? This is needed to validate removing AUTH-10.
4. What are the policies for account deletion data retention (wallet and trip records) and for deactivation?
5. Should one person be able to be both passenger and driver (AUTH-18)?
6. Is the third registered Android app `com.cts.driver` still used?
