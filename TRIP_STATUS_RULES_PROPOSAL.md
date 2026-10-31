# Proposal: enforce the ride status order in Firestore rules

**Status:** proposed, not deployed. Needs owner approval before any `firebase deploy`.
**Prepared:** 2026-10-13, alongside the Driver app ride-lifecycle fix.

## Problem

Today the `trips` update rule lets either party write **any** `status`, as long
as `driverId`/`passengerId` are unchanged. The order of a ride
(`tripAccepted → driverArrived → tripStarted → completed`) is enforced only by
the apps. The Driver app now checks the order in a transaction
(`lib/features/trips/domain/ride_lifecycle.dart`), but an old app version or a
modified client could still:

- complete a ride that never started (payout follows after auto-confirm);
- let a passenger write `completed` or `tripStarted`;
- reopen or cancel a trip that is already completed.

## Change

One helper, `tripStatusChangeAllowed()`, added to the party branch of
`match /trips/{tripId}` → `allow update`. Exact diff:
[`rules-tests/proposed/trip-status.rules.diff`](rules-tests/proposed/trip-status.rules.diff)
(full proposed file: `rules-tests/proposed/firestore.trip-status.rules`).

| Who | Allowed status changes |
|---|---|
| Assigned driver | `tripAccepted → driverArrived → tripStarted → completed`; `cancelledByDriver` from any of the first three |
| Passenger | `searching → noDriversAvailable` (search timeout); `cancelledByPassenger` from `searching`, `tripAccepted`, `driverArrived`, `tripStarted` |
| Either party | any update that leaves `status` unchanged (location, rating, confirmation) |
| Unchanged | admin writes; the driver acceptance branch (`searching → tripAccepted`); Cloud Functions (Admin SDK, not subject to rules) |

These are exactly the transitions the current Passenger and Driver apps write,
so no shipped client flow is blocked. Cancellation policy is unchanged.

## Evidence (Firestore emulator, `demo-ctsgo-rules`, never production)

- New tests `rules-tests/proposed/trip_status.test.js`: **15 passing**
  (allowed paths for both roles; refuses accepted→completed, arrived→completed,
  accepted→started, completed→started, cancelled→started; passenger cannot
  complete or start; neither party can remove the `status` field).
- Existing suite against the proposed rules: **182 passing / 14 failing**,
  versus **180 / 16** against the current rules (full run with the proposal
  tests: 197 / 14). The two newly passing tests are
  existing security cases `TRIP-S04` (passenger cannot complete an assigned
  trip) and `TRIP-S05` (cannot cancel a completed trip). The 14 remaining
  failures are identical under both rulesets (pre-existing, tracked elsewhere).

Reproduce (needs Java 21+):

```bash
cd rules-tests
RULES_FILE=proposed/firestore.trip-status.rules \
  firebase emulators:exec --only firestore --project demo-ctsgo-rules \
  --config ../firebase.json "npx mocha test proposed"
```

## Review corrections (2026-10-13)

- **Fixed in this proposal:** the first draft read the new status as
  `request.resource.data.get('status', from)`, so a write that *removed* the
  `status` field counted as "unchanged" and was allowed. It now reads
  `get('status', null)`; a removed status matches no transition. Covered by the
  test "a party cannot remove the status field".
- **Not fixed by this proposal (pre-existing, tracked separately):** a
  permitted update may still change other trip fields. The remaining failing
  security tests `TRIP-S01/S02/S03/S11/S12/S13/S16` show either party can
  change the fare, escrow, settlement flags, distance or passenger
  confirmation, including in the same write as an allowed status change (for
  example, a driver completing correctly while inflating the fare). Closing
  that needs a per-role field allowlist on `trips` updates; it is a separate
  change and should be reviewed with this one.
- Every allowed transition matches a write in the shipped apps or a Cloud
  Function (Functions use the Admin SDK and bypass rules: `expired`,
  `noDriversAvailable`, `tripAccepted` via `acceptTrip`, `flagged`).
  The only client write it would block is the legacy `cancelled` in the
  passenger's unused `lib/features/ride/presentation/screens/driver_matching_screen.dart`.

## Rollout (requires approval)

1. Ship the Driver app with the new lifecycle first. Old Driver builds still
   write `tripAccepted → completed` and **would be blocked** by this rule, so the
   rule must wait until old driver builds are retired (or forced to update).
2. Apply the diff to `firestore.rules`, re-run the full suite, then
   `firebase deploy --only firestore:rules`.
3. Rollback: redeploy the previous ruleset from the Firebase console release
   history.

## Related finding (not part of this change)

`functions/trips.js` `onTripCompleted` has its fraud check disabled
(`const TEST_MODE = true;`), so very short/fast completions are not flagged.
`startedAt`, which the Driver app now writes on trip start, only feeds that
check; fares and settlement do not use it.
