# Proposed release manifest: escrow containment (Phase 1E, 2026-10-20; corrected in Phase 1G)

A proposal for review. Nothing has been committed or deployed. A commit and each deployment step below need separate explicit approval.

> **This release commit must never be the source of a full Functions deployment, or of any Bridge, Paystack or withdrawal deployment.** It keeps HEAD's `bridge.js`, `config.js`, `wallet.js` and `withdrawal_approval.js`, which contain known-broken and callback-trusting payment code: `bridge.js:719` calls `_needsManualReview`, defined only in `withdrawal_approval.js:96` and never imported (a ReferenceError in `initiateBridgePayout`); HEAD's top-up and payout callbacks credit or refund on unverified callbacks (PT-01, PT-02, PT-06–PT-08); PT-05 and PT-10 give order-dependent results against it. None of these functions is deployed from this release; production runs the Oct 18 hotfix (`BRIDGE-RECONCILIATION.md`).

## Branch and base

- Proposed branch: `release/escrow-containment-2026-10`, from `9dcabda` (`checkpoint/2026-10-10`).
- Build it in a separate `git worktree` so the main working tree, and every uncommitted change in it, stays as it is.

## Scope

| # | Category | In this release |
|---|---|---|
| 1 | Escrow containment and settlement validation | Yes |
| 2 | Stale-escrow recovery and `adminAttachEscrow` | Yes |
| 3 | Rules candidate and index definitions | Yes (deployed separately, see the rollout) |
| 4 | Bridge, Paystack and withdrawal work | **No**: these files stay at HEAD, see `BRIDGE-RECONCILIATION.md` |
| 5 | Flutter UI, assets, platform, pubspec, working-tree `firestore.rules`, `rules-tests/` | **No**: left uncommitted in the working tree |

## Expected file list

Working-tree content (category 1–3):

```
functions/escrow.js                  (M)
functions/trips.js                   (M)
functions/delivery_settlement.js     (M)
functions/notifications.js           (M)  dispatch waits for a linked payment; onDeliveryPaymentAttached
functions/index.js                   (M)
functions/package.json               (M)  test scripts only
functions/order_settlement.js        (new)
functions/payment_verification.js    (new)
functions/completion_code.js         (new)
functions/admin_auth.js              (new)
functions/alert_payload.js           (new, Phase 1G) admin alerts in the shape the admin bell reads
functions/scripts/check_hold_limit_settings.js (new, not uploaded)
functions/scripts/release_tests.js   (new, Phase 1G, not uploaded) release-scope test runner
functions/test/**                    (M/new, not uploaded)
firestore.indexes.json               (M)  +escrows(status,heldAt) +ledger(status,createdAt)
deploy/phase1c/firestore.rules       (new) rules candidate
deploy/phase1c/firebase.json         (new) rules-only config
deploy/phase1e/*.md                  (new) this manifest and the Bridge reconciliation
```

Kept at HEAD in the release (the working-tree versions stay uncommitted):

```
functions/bridge.js  functions/config.js  functions/wallet.js  functions/withdrawal_approval.js
```

Evidence that this split is coherent (Phase 1F, re-run in Phase 1G on a tree rebuilt from `git archive HEAD` plus exactly this file list): the release-scope suite passes completely, and every full-suite failure is in a test of the excluded Bridge, Paystack or withdrawal code (see "Tests"). Phase 1E's "27 failures" figure was wrong: it left out `withdrawal_approval.test.js`, and two of its failures were files missing from a scratch copy.

`functions/index.js` mixes categories: it also wires `resolveUnconfirmedPayout` to `withdrawal_approval.js` and drops `acceptTrip`, `onDriverAlertCreated` and the Paystack exports. That is harmless for a named-target deploy but must be resolved before any full deploy.

## Runtime package (uploaded for each target)

Every target loads `index.js`, which `require`s every module at start-up (20 modules, plus `alert_payload.js` from Phase 1G; all uploaded). The upload list (firebase-tools walker, `firebase.json` ignore rules) is **30 files**: all runtime `.js` modules, `package.json`, `package-lock.json`, `.env.ctstransportapp`, `.npmrc`, `.eslintrc.js`, `.gitignore`, `src/index.ts`, `tsconfig.json` and `tsconfig.dev.json`. Tests, scripts, `*.md`, `*.bak` and logs are excluded (`test:deploy-packaging`).

The release tree exposes **52 endpoints**, not the working tree's 53: `resolveUnconfirmedPayout` is absent, because HEAD's `withdrawal_approval.js` does not export it. That is irrelevant to a named deploy, but a full deploy from this release would also delete the deployed `resolveUnconfirmedPayout`.

| Target | Trigger | Code it executes |
|---|---|---|
| `onTripCompleted` | Firestore update `trips/{tripId}` | `trips.js`, `escrow.js`, `order_settlement.js`, `payment_verification.js`, `alert_payload.js` |
| `onDeliveryCompleted` | Firestore update `deliveries/{deliveryId}` | `trips.js`, `delivery_settlement.js`, `escrow.js`, `alert_payload.js` |
| `onGasOrderCompleted` | Firestore update `gas_orders/{orderId}` | `trips.js`, `completion_code.js`, `escrow.js`, `alert_payload.js` |
| `releaseStuckEscrows` | Schedule, every 1 hours | `escrow.js`, `alert_payload.js` |
| `adminAttachEscrow` | Callable (new) | `escrow.js`, `admin_auth.js` |

All are Gen 2, `europe-west2`, with no secrets bound. Params: `PAYMENTS_MODE`, `BRIDGE_API_BASE`, `BRIDGE_CALLBACK_BASE_URL` from `.env.ctstransportapp`. Declared secret params, none bound to the five targets: `BRIDGE_CLIENT_KEY`, `BRIDGE_SECRET_KEY`, `BRIDGE_SERVICE_ID` and **`PAYSTACK_SECRET_KEY`** (declared by HEAD's `wallet.js`; the working tree no longer declares it). firebase-tools resolves every declared secret at deploy, whatever the `--only` filter (`ensureSecret` in `deploy/functions/params.js`). All four exist in Secret Manager with an ENABLED latest version (checked 2026-10-20), so nothing is prompted for or created; re-check before deploying. SDK: lockfile pins `firebase-functions` 7.4.0 and `firebase-admin` 13.10.0 (the gas trigger moves from v6); the lockfile is in sync with `package.json`. Required API: Cloud Scheduler (already enabled).

## Tests

### Test scope (Phase 1G decision)

All tests stay in the repository; none is deleted, weakened or marked as passing. Tests are excluded from the release scope by their **subject** (code this release keeps at HEAD and does not deploy), not by whether they fail. The definition lives in `functions/scripts/release_tests.js`, which refuses to run if an exclusion no longer matches a test, and prints every excluded file and test before and after the run. Excluded tests are filtered out (`--test-skip-pattern`), so they do not appear in the release-scope counts at all.

| Excluded from the release scope | Tests | Subject | Result in the release tree |
|---|---|---|---|
| `test/payments/bridge_topup.test.js` (whole file) | BTU-01–BTU-16 | Bridge top-up callbacks, Paystack removal (`bridge.js`, `config.js`, `wallet.js`) | 4 pass; BTU-02, 03, 10, 11, 12, 13, 14, 16 fail (HEAD still has Paystack, and applies callbacks) |
| `test/payments/security.test.js` (whole file) | PT-01–PT-12 | Bridge top-up and payout callbacks, payout approval (`bridge.js`, `withdrawal_approval.js`) | PT-01, 02, 06, 07, 08, 09, 11, 12 fail (unverified callbacks credit or refund; PT-12 is the ReferenceError). PT-05 and PT-10 are order-dependent: run alone, PT-05 passes and PT-10 fails (5 of 5 runs); in the full suite of 2026-10-20 the reverse. PT-03, 04 pass |
| `test/payments/smoke.test.js` (whole file) | SMK-01–SMK-14, R1–R4 | Bridge payment-config guard, env wiring, Paystack removal, runbook (`config.js`, `bridge.js`, `wallet.js`) | SMK-10, SMK-14 fail (Paystack still at HEAD); the rest pass |
| `test/payments/withdrawal_approval.test.js` (whole file) | WDA-01–WDA-67 | Driver withdrawals and payout outcomes (`withdrawal_approval.js`, `bridge.js`) | WDA-01–04 fail (ReferenceError), WDA-06, 10–14, 16, 20, 21 (×2), 60 (×2), 61 (×5) fail; WDA-62 hangs (no timeout handling at HEAD) and the tests after it in the file are **not run**: unverified |
| `test/payments/wallet_integrity.test.js` › "cash takings are not wallet funds" | WI-P01–WI-P04 | Driver withdrawable balance (`wallet.js`) | WI-P01, 03, 04 fail; WI-P02 passes |

Coverage evidence (Phase 1F) that none of these exercises the five targets: no failing test references a target or its settlement and recovery helpers, and V8 coverage shows `security` and `smoke` never load the target modules, and `bridge_topup` and `withdrawal_approval` execute none of their functions.

### Results (2026-10-20)

| Run | Command | Result |
|---|---|---|
| Release scope, release tree | `npm run test:release` (26 files) | **419/419 pass**, 0 fail; 4 files and 4 tests not run, as listed above |
| Full suite, release tree | all test files, `--test-timeout=45000` | 499 tests: 455 pass, 43 fail, 1 cancelled. Every failure is in the excluded rows above |
| Full suite, working tree | all test files, candidate rules | **515/515 pass** |

The release scope includes the 40 candidate rules tests (`settlement_rules.test.js`), the recovery safety tests SES-26, SES-27 and REC-06, and the alert-visibility tests ALV-01–ALV-41.

### Required before commit (in the release worktree)

1. `npm run test:release`: every in-scope test passes.
2. The full suite: no failure outside the excluded rows above.
3. `npm run test:deploy-packaging`.
4. Offline load of the five targets, and `node --check` on every module.
5. firebase-tools `validateSpec` on `firestore.indexes.json`.
6. ESLint: not installed in `functions/node_modules` or on the PATH; not run.

## Deployment targets (named only)

```
firebase deploy --project ctstransportapp \
  --only functions:onTripCompleted,functions:onDeliveryCompleted,functions:onGasOrderCompleted,functions:releaseStuckEscrows,functions:adminAttachEscrow
```

Optional, not yet included: `functions:dailyReconciliation`. It moves no money, and the candidate version classifies stale escrows the way recovery does.

A filtered deploy plans deletions only inside its filter (`createDeploymentPlan` in `deploy/functions/release/planner.js`); all five targets exist in the release, so it deletes nothing.

## Before any deployment: monitoring must work

Production has no alert policies, log-based metrics or notification channels, and before Phase 1G no escrow or settlement alert carried `read: false`, so the admin bell (`ctsride-admin` `AdminAlertsBell`: unread, newest `createdAt` first, shows `message`) never showed them. Phase 1G fixes the alert documents (`alert_payload.js`); the rest is still open:

- **Fixed locally:** every alert the five targets and the shared escrow and settlement modules write has `read: false`, a `message` and a `createdAt`, and carries ids and reasons only (tests ALV-01–ALV-41).
- **Still required, admin UI (separate change):** the bell shows `driverName` as the title (empty for these alerts) and links every alert to `/drivers`; there is no screen for escrow reviews, waivers or recovery.
- **Still required, production (separate approval):** log-based alerting on ERROR from `releasestuckescrows` and `dailyreconciliation`, a heartbeat alert when no `recoverStaleEscrows:` summary is logged for two hours, and a notification channel.

## Index creation (after the deployment gates, separately approved)

Order: deploy the five targets → pass the pre-index gates (Phase 1F report: new source generation, archive hash, 100% traffic on the new revision, a logged failing run on the new revision, decision on deleting `releasestuckescrows-00001-hep` and `-00002-ruf`, monitoring in place) → create the two indexes with targeted commands:

```
gcloud firestore indexes composite create --project=ctstransportapp --collection-group=escrows --query-scope=COLLECTION --field-config=field-path=status,order=ascending --field-config=field-path=heldAt,order=ascending
gcloud firestore indexes composite create --project=ctstransportapp --collection-group=ledger --query-scope=COLLECTION --field-config=field-path=status,order=ascending --field-config=field-path=createdAt,order=ascending
```

The `escrows` index is the one that switches on stale-escrow recovery, for whichever code is serving: it must never exist while the old `releaseStuckEscrows` can run. The `ledger` index only unblocks the nightly report's read.

## Explicitly excluded from deployment

- Any full `firebase deploy` or `--only functions`. It would offer to delete `reconcileBridgePayments`, `acceptTrip`, `onDriverAlertCreated`, `initializePaystackPayment`, `verifyPaystackPayment`, `paystackWebhook` and (from this release tree) `resolveUnconfirmedPayout`, and replace the Oct 18 Bridge code with HEAD's broken version.
- Every Bridge, Paystack and withdrawal function.
- `firebase deploy --only firestore:indexes` with the repository's `firestore.indexes.json`. Production has 31 composite indexes and the file lists 13, so a deploy could delete 20 live indexes. Create the two new indexes with targeted `gcloud` commands (see the rollout).
- The working-tree `firestore.rules`. Only `deploy/phase1c/firestore.rules` is the candidate.
- The Flutter apps.
