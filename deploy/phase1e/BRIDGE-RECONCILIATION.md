# Bridge source reconciliation (Phase 1E, 2026-10-20)

Read-only evidence. Nothing here was deployed, merged or committed.

## Provenance of the deployed Bridge code

| Item | Value |
|---|---|
| Deployed archive | `gs://gcf-v2-sources-67007923864-europe-west2/<fn>/function-source.zip` |
| Oct 18 functions (one archive, MD5 `xzq63xhlQansnHAHcUMC5w==`) | `reconcileBridgePayments` gen 1792316184586643 (09:36:24Z); `resolveUnconfirmedPayout`, `bridgeTopUpCallback`, `initiateBridgePayout`, `bridgePayoutCallback` (09:37:09–10Z) |
| Runtime | GEN_2, nodejs22, `deployment-tool: cli-firebase`, `firebase-functions-hash 4e3a78c3…` |
| Source revision | None recorded (deployed from a non-Git folder) |
| Local source | `~/Desktop/Projects/okada-apps/bridge-hotfix-20261016/functions/`: every file is byte-identical to the deployed archive |
| Hotfix base | `bridge-hotfix-20261016/deployed-base/`: byte-identical to the deployed `onGasOrderCompleted` archive (uploaded 2026-07-12) |
| Hotfix delta | `bridge.js` (1042 → 1806 lines) and `index.js` (+2 exports). `wallet.js`, `escrow.js`, `trips.js`, `notifications.js`, `package*.json` unchanged |
| SDK | `firebase-functions` ^6.3.2, `firebase-admin` ^13.10.0 (lockfile from base) |
| Still on July code | `initiateBridgeTopUp` (differs from the hotfix only by phone masking in its success log line), `checkBridgeTopUpStatus` (identical) |
| Hotfix tests | Its own harness: 149/149 pass against the verified archive extract (run with SDK 7.4.0 from this repo's `node_modules`, Bridge HTTP stubbed in process) |

The deployed hotfix exists in no Git repository. It must be committed before any Bridge function is deployed again.

## Three lineages

| | Deployed base (July) | Deployed hotfix (Oct 18) | This working tree (`functions/bridge.js`, Oct 16) |
|---|---|---|---|
| Callback trust | Trusted the callback body | Callback is a notification only. Status comes from `get_transaction_status`. HMAC signature is checked when present (`REQUIRE_SIGNED_CALLBACKS = false`) | Callbacks are never applied (`verifyBridgeCallback` always unverified). Money moves only by admin action |
| Top-up credit | From callback | Verified success only, stored amount, from `pending`, fixed-ID ledger `bridge_topup_<ref>`, exactly once | Not credited automatically |
| Payout settlement | From callback | Lookup recorded. Auto-complete and auto-refund are off. Admin resolves. Idempotent refund `bridge_payout_refund_<ref>` | Attempt model in `withdrawal_approval.js` (`attemptId`, `payoutOutcome: "sending"`, `assertHeldFor`) |
| Reconciler | none | `reconcileBridgePayments` every 10 min, throttled lookups, cursor in `bridge_reconcile_state` | none |
| Admin resolution | none | `resolveUnconfirmedPayout` in `bridge.js` (payments-record model) | `resolveUnconfirmedPayout` in `withdrawal_approval.js` (withdrawal-attempt model). Same request shape `{withdrawalId, outcome, evidence}` |
| Gateway target | Hard-coded production URLs | Hard-coded production URLs | Per-environment `config.js` guard (`PAYMENTS_MODE`, `BRIDGE_API_BASE`, `BRIDGE_CALLBACK_BASE_URL`) |
| Phone in logs | Full number | Masked | n/a |

## Classification

| Difference | Class | Notes |
|---|---|---|
| `reconcileBridgePayments` (deployed, missing locally) | Required deployed behaviour to preserve | The only automatic path that completes top-ups. Deleting it, or deploying the working-tree `bridgeTopUpCallback`, stops top-ups from being credited |
| Hotfix `bridgeTopUpCallback`: lookup-verified credit, signature check, flood caps, fixed-ID ledger | Required deployed behaviour to preserve (security fix) | Stronger than the working tree's "never apply" plus manual handling, for top-ups |
| Hotfix `initiateBridgePayout` / `bridgePayoutCallback` / `refundPayoutOnce` / `_markPayoutUncertain` | Required deployed behaviour to preserve | `NOT_SENT` refunds only on pre-connection errors. Everything else is held for verification |
| Hotfix `resolveUnconfirmedPayout` vs working-tree `withdrawal_approval.resolveUnconfirmedPayout` | Unknown: needs investigation | Same API, different data model. Payouts created by the deployed `initiateBridgePayout` have not been tested against the working-tree resolver. Do not deploy the working-tree version until it is |
| Working-tree `approveWithdrawal` / `rejectWithdrawal` (not deployed; called by the admin app) | Unrelated local work (new feature) | The admin app's approve and reject buttons call functions that do not exist in production |
| Working-tree `config.js` per-environment guard and `_bridgeShared` | Security improvement to port | Port into the hotfix code; do not replace it |
| Working-tree removal of Paystack (`initializePaystackPayment`, `verifyPaystackPayment`, `paystackWebhook`; Flutter Paystack files deleted) | Unrelated local work (intentional removal) | Still deployed (May–June source). Removing them needs an explicit decision and a named `functions:delete`, never a side effect of a full deploy |
| `acceptTrip`, `onDriverAlertCreated` (deployed, removed from the working-tree `index.js`) | Unknown | No current driver, passenger or admin source calls `acceptTrip`. Older driver builds may. Keep deployed |
| Deployed `initiateBridgeTopUp` logs full phone numbers | Security fix not yet deployed | The hotfix masks the number but that function was not redeployed |

## Required before any Bridge function is deployed from this repository

1. Commit the verified hotfix source as the baseline for Bridge code. A reviewer can take it from `bridge-hotfix-20261016/functions/` once its identity with the deployed archive (above) is re-checked.
2. Port the working-tree improvements onto it: the config guard and `_bridgeShared`. Keep the hotfix trust model.
3. Reconcile the two payout lifecycles and the two `resolveUnconfirmedPayout` versions with the admin app's `src/lib/withdrawal-actions.ts`.
4. Run the hotfix harness (149 tests) and the repository suite against the result.

None of this is needed for the five escrow targets: they never call `bridge.js`. `index.js` only loads it, which declares three secrets that are not bound to those targets.
