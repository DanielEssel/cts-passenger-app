# Gas Supplier Linked Riders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a supplier offer a confirmed gas order to one linked CTSGo rider. The rider accepts or declines. If no one accepts in time, the order falls back to CTSGo dispatch. CTSGo pays the rider's delivery fee to the rider. The plan also fixes three existing problems: reversal debt that silently disappears, wallet credits labelled as payouts, and the portal earnings filter.

**Architecture:**
- Backend changes go into the existing modules in the passenger repo's `functions/`:
  - `gas_supplier_fulfilment.js` (assignment)
  - `gas_settlement_ledger.js` (posting, reversals and debts)
  - `gas_supplier_payouts.js` (credit and payout guards)
  - `notifications.js` (one trigger)
  - a new `gas_supplier_riders.js` (links)
- Clients only call callables. Rules deny client access to every new collection.
- The portal, admin app and driver app change only their existing gas screens and repositories.

**Tech Stack:**
- Firebase Functions v2 (Node, `node --test` on the Firestore emulator), Firestore rules (mocha with `@firebase/rules-unit-testing`)
- Next.js/TypeScript (vitest) for the portal and admin app
- Flutter (`flutter test`) for the driver app

**Spec:** [`../specs/2026-10-29-gas-supplier-linked-rider-design.md`](../specs/2026-10-29-gas-supplier-linked-rider-design.md), revision 3

## Global Constraints

- **Do not commit, push, deploy, change production settings, enable `settings/gas_supplier_fulfilment` or `settings/gas_supplier_payouts`, or start a real payment.** Each task ends with a checkpoint (`git diff --stat` and `git status --short`), not a commit.
- Preserve everything already in the working trees. The passenger repo has about 222 changed or untracked files, and the driver repo about 69. Touch only the files listed in each task.
- Use illustrative amounts only. Never hard-code a commission rate; tests build terms with explicit test rates.
- All amounts are whole pesewas. The commission is `floor(product × rateBps / 10000)` on the product only.
- `riderAcceptMinutes` must be a whole number from 1 to 60; the default is 5. `MAX_RIDER_DECLINES = 3`. `DISPATCH_RADIUS_KM = 10`. `LINKED_RIDER_LOCATION_MAX_AGE_MS = 10 * 60 * 1000` (R1, default). Portal polling: every 20 000 ms.
- Refusal reason codes are exactly the ones in spec §3. Existing codes and messages stay unchanged.
- Offline `supplier_rider` behaviour and money must not change.
- **Emulator.** Start it with:

  ```
  /usr/lib/jvm/java-21-openjdk-amd64/bin/java -jar ~/.cache/firebase/emulators/cloud-firestore-emulator-v1.22.0.jar --host 127.0.0.1 --port 8086 --project_id demo-ctsgo-payments
  ```

  Run it in the background and stop it after the task. The Firebase CLI is not installed.
  - Functions tests: `cd functions && FIRESTORE_EMULATOR_HOST=127.0.0.1:8086 GCLOUD_PROJECT=demo-ctsgo-payments node --test --test-concurrency=1 test/payments/<file>`
  - Rules tests: `cd rules-tests && FIRESTORE_EMULATOR_HOST=127.0.0.1:8086 npx mocha test/<file>`
- **Paths.**

  | Name | Path |
  | --- | --- |
  | P | `~/Desktop/Projects/okada-apps/passenger/cts-transport-passenger-app-clean` |
  | Portal | `~/Desktop/Projects/okada-apps/ctsgo-gas-supplier-portal` |
  | Admin | `~/Desktop/Projects/okada-apps/ctsride-admin` |
  | Driver | `~/Desktop/Projects/okada-apps/driver/cts-transport-driver-app-clean` |

  Commands are written relative to the repo root they name.

## Verified environment and baselines (2026-10-29)

- **The Firebase CLI is not installed.** The Firestore emulator runs from the jar with Java 21, using the command above (`java -version` defaults to 17, which can't load the jar).
- **Functions baselines**, with the emulator on 127.0.0.1:8086 and `node --test`:

  | Suite | Pass |
  | --- | --- |
  | `gas_settlement_ledger` | 34 / 34 |
  | `gas_supplier_payouts` | 16 / 16 |
  | `gas_supplier_fulfilment` | **61 / 61** (not 74) |
  | `gas_supplier_orders` | 22 / 22 |

  The summary lines start with `ℹ`.
- **Rules baseline:** `cd rules-tests && FIRESTORE_EMULATOR_HOST=127.0.0.1:8086 npx mocha <file>` runs the **whole** suite, because `.mocharc` sets `spec`. Result: 443 passing, 0 failing.
- **Test-ID collision:** GSL-D01–D08 already exist (daily statements). The new debt tests in Task 2 are therefore **GSL-OD01–OD09**, mapped from the old plan IDs:

  | Old plan ID | New ID |
  | --- | --- |
  | D01 | OD01 |
  | D02 | OD02 |
  | D03 | OD03 |
  | D04 | OD04 |
  | D05 | OD05 |
  | D06 | OD06 |
  | D07 | OD07 |
  | D08 | OD08 |
  | S02 | OD09 |

  Existing **GSL-D03** asserts automatic netting after settlement. Task 2 rewrites it to the F3 behaviour. This is an intentional, approved change and must be reported as such.
- **Untracked targets:** `gas_settlement_ledger.js`, `gas_supplier_payouts.js` and their tests are untracked, so git has no diff baseline. Pre-change copies and their sha256 sums are in the session scratchpad, under `baseline/files`.
- **Release blockers B4 and B5:** see spec §9. B5 (admin self-escalation through `admins/{uid}` rules) undermines every super-admin control this plan relies on.

## Review Focus

1. **A `linked_rider` order seen or claimed by other CTSGo drivers.** Expect: invisible to them, and their accept refused (`job_taken`). Pinned in Task 5 (GSF-LR02). Both the list and the accept change land in the same task, so they ship in one deploy.
2. **A reversal after the wallet credit, then a later earning for the same driver.** Expect: the later statement pays the full new earning; the debt remains outstanding with an alert. Pinned in Task 2 (GSL-D03).
3. **The rider's clock is wrong, or the app is backgrounded across `expiresAt`.** Expect: the server decides. A late accept gets `offer_expired`, and the card shows "Expired" from `serverNowMs`. Pinned in Task 5 (GSF-LR11) and Task 12 (countdown skew test).
4. **A stationary rider with no recent GPS fix accepts.** Expect: the app takes a fresh fix first. Without one, the accept is blocked in the app and refused by the server (`driver_location_stale`). Pinned in Task 1 (DP-LS02) and Task 12 (accept-without-fix test).
5. **Two admins act on the same statement or debt at once** (credit and withhold, or two resolutions). Expect: exactly one wins, and the other gets a version or state refusal. Pinned in Task 3 (GSP-LR04) and Task 2 (GSL-D06).

---

## Backend: passenger repo (`P`)

### Task 1: Stale-location check

**Files:**
- Modify: `functions/dispatch_policy.js` (add after `driverRejection`, around line 143; export it)
- Test: `functions/test/payments/dispatch_targeting.test.js` (append; pure, no emulator)

**Interfaces:**
- Produces:
  - `driverLocationStale(driver, nowMs, maxAgeMs) -> "driver_location_stale" | null`, which reads `driver.lastLocationUpdate` (a Firestore Timestamp, `{toMillis()}`).
  - `LINKED_RIDER_LOCATION_MAX_AGE_MS = 600000`.

- [ ] **Step 1: Write failing tests**
  - DP-LS01: `lastLocationUpdate` 9 min old → `null`; exactly 10 min → `null`; 10 min + 1 ms → `"driver_location_stale"`.
  - DP-LS02: missing, `null`, a non-Timestamp value, or a value in the future by more than 60 s → `"driver_location_stale"`.
- [ ] **Step 2: Run** `node --test test/payments/dispatch_targeting.test.js`. Expected: the new tests FAIL (`driverLocationStale is not a function`).
- [ ] **Step 3: Implement** `driverLocationStale`. Do not call it from `driverRejection`, so existing dispatch is unchanged.
- [ ] **Step 4: Run** the same command. Expected: PASS, all existing tests included.
- [ ] **Step 5: Checkpoint** `git status --short functions/dispatch_policy.js functions/test/payments/dispatch_targeting.test.js`. No commit.

### Task 2: Ledger changes (mode allowlist, audit basis, settled-entry reversal debts, statement guard, `entryStatus`)

**Files:**
- Modify: `functions/gas_settlement_ledger.js`:
  - `postingProblem` (lines 226-246)
  - `postOrderEntitlements` (345-413)
  - `reverseOrderEntitlements` (415-462)
  - `prepareStatements` (464-555)
  - `entryStatus` (274-291)
  - header comment (lines 1-78)
  - exports
- Test: `functions/test/payments/gas_settlement_ledger.test.js` (append)

**Interfaces:**
- Produces:
  - `DEBTS = "gas_settlement_debts"`
  - `debtStage(statement) -> "before_payout" | "after_payout"`: `before_payout` when `payoutStatus` is `"not_started"`, or `"failed"` with `party === "supplier"`.
  - `resolveSettlementDebt(actor, {debtId, action, resolution?, reason, evidence?, expectedVersion}) -> {debtId, status, resolution?, version}`. `action` is one of:
    - `"resolve"`: `before_payout` only (`withhold` or `pay_in_full`). One super admin; the debt becomes `status: "resolved"`.
    - `"propose"`: `after_payout` only (`written_off` or `recovered_externally`). Sets `status: "resolution_proposed"`, with `proposal {resolution, by, reason, evidence, at}`.
    - `"approve"` / `"reject"`: on a proposed debt, by a **different** super admin. `approve` gives `resolved`; `reject` gives `outstanding`, with the proposal moved to `rejectedProposals[]`.

    This follows R2 and mirrors `proposeTerms` and `decideTerms`.
  - Exported callable `adminResolveGasSettlementDebt`.
  - `entryStatus` gains these outcomes:
    - `"outstanding_adjustment"`: claim has a `debtId` and the debt is outstanding.
    - `"resolved_adjustment"`: claim has a `debtId` and the debt is resolved.
    - `"credited_to_wallet"`: claimed and the statement has `party: "driver"`, `payoutMethod: "driver_wallet"` and `payoutStatus: "paid"`.

    The ctx gains `debt` and the statement's `party` and `payoutMethod`.
  - Debt doc shape: as in spec §3.6.
  - `postOrderEntitlements` writes `basis.deliveryMode` on all three entries, and `basis.linkedSupplierId` on the driver entry when `linked_rider`.

**Steps:**

- [ ] **Step 1: Write failing tests.** Use the existing helpers and a test-only rate. Seed orders the same way GSL-P02 does.
  - **GSL-LR01:** a delivered `linked_rider` order (with `driverId`, `linkedSupplierId == supplierId` and `acceptedFeePesewas == allocation.driverNetPesewas`) posts exactly three entries:
    - `{o}__supplier__entitlement == supplierNetPesewas`
    - `{o}__driver__entitlement` with `partyId == driverId` and amount `== deliveryFeePesewas`
    - `{o}__platform__commission`
    - Assert there is no `{o}__supplier__delivery_fee` and that the sum equals `customerTotalPesewas`.
  - **GSL-LR02:** the same snapshot under `ctsgo_driver`, `linked_rider` and `supplier_rider` gives identical commission and supplier entitlement amounts. Only the delivery entry's ID and party differ.
  - **GSL-LR05:** `postOrderEntitlements` refuses with these reasons:
    - `deliveryMode` missing or `"other"` → `order_delivery_mode_unknown`
    - `linked_rider` without `driverId` → `order_driver_missing`
    - `linked_rider` with a `linkedSupplierId` mismatch → `order_linked_supplier_mismatch`
    - `linked_rider` with `acceptedFeePesewas ≠ allocation` → `rider_fee_mismatch`
    - `supplier_rider` with `driverId` → `order_driver_unexpected`, as today
  - **GSL-LR03:** run `postOrderEntitlements` five times concurrently and then repeat it. Assert exactly three entries and every later call returns `alreadyPosted`.
  - **GSL-D01:** reversal before any statement → no debt doc; the next `prepareStatements` claims the original and its reversal together, the net is 0 and the status is `prepared_no_payout` (existing behaviour, kept).
  - **GSL-D02:** post, prepare (the driver line is claimed), then reverse with a super-admin reason. Assert:
    - `gas_settlement_debts/{o}__driver__reversal` exists with `amountPesewas == fee`, `stage == "before_payout"`, `status == "outstanding"` and `statementId == the claiming statement`;
    - the claim `gas_settlement_claims/{o}__driver__reversal` has a `debtId` and no `statementId`;
    - the alert `gas_settlement_debt_{o}__driver__reversal` exists.
  - **GSL-D03:** after the claiming statement is credited (its `payoutStatus` set to `paid` with `driver_wallet` in the test seed), a reversal creates `stage == "after_payout"`. A later delivered order for the same driver is prepared into a new statement whose net equals **only** the new fee. The debt is still outstanding.
  - **GSL-D04:** with a forged unclaimed negative entry seeded directly, `prepareStatements` creates no statement for that party and raises `gas_settlement_negative_statement`.
  - **GSL-D05:** the allowed resolutions are `resolve` with `withhold` or `pay_in_full` for `before_payout`, and `propose` with `written_off` or `recovered_externally` for `after_payout`.
    - Any other pairing gives `resolution_not_allowed`.
    - A reason shorter than 3 characters gives `reason_required`.
    - For `after_payout`, evidence shorter than 6 characters gives `evidence_required`.
    - A non-super admin gives permission-denied.
    - Every success writes one `audit_log` entry, `gas_settlement_debt_resolved`.
  - **GSL-D06:** two concurrent resolutions with the same `expectedVersion`. Exactly one succeeds; the other gets `debt_changed` or `debt_resolved`.
  - **GSL-D08:** an `after_payout` resolution needs two super admins.
    - The proposer's own `approve` → `proposer_cannot_approve`.
    - A second super admin's `approve` → `resolved`, with both uids recorded and two audit rows.
    - `reject` → `outstanding` again, and the debt can be proposed again.
    - Approving without a proposal → `no_proposal`.
  - **GSL-D07:** `withhold` sets the statement's `withheldPesewas += amount` and `payablePesewas = netPesewas − withheldPesewas`. The statement's `netPesewas` and `lines` are unchanged.
  - **GSL-S02:** `entryStatus` returns:
    - `outstanding_adjustment` and `resolved_adjustment` for debt claims;
    - `credited_to_wallet` for driver lines in a `paid`/`driver_wallet` statement;
    - `paid` for supplier lines in a `paid` statement (unchanged).
- [ ] **Step 2: Run** `node --test … test/payments/gas_settlement_ledger.test.js` on the emulator. Expected: the new tests FAIL; the existing GSL tests PASS.
- [ ] **Step 3: Implement.**
  - The allowlist and the fee check go in `postOrderEntitlements`, after it reads the allocation.
  - `reverseOrderEntitlements` reads `gas_settlement_claims/{originalId}`, and the claiming statement if there is one, in its transaction. For each claimed original it creates the reversal's claim (with `debtId`), the debt (`version: 1`) and the alert.
  - `prepareStatements` skips any group whose net is below 0 and raises the alert.
  - `resolveSettlementDebt` runs in one transaction: debt `status == outstanding` and `version == expectedVersion`. For `withhold` it updates the statement and requires a `before_payout` stage still valid.
  - Never write `drivers.commissionOwed` or any wallet field.
  - Update the header comment with the linked-rider slot and the debt rule.
- [ ] **Step 4: Run** the full suite: `gas_settlement_ledger.test.js`, `gas_supplier_fulfilment.test.js` and `gas_supplier_payouts.test.js`. Expected: all PASS.
- [ ] **Step 5: Checkpoint** (no commit).

### Task 3: Payout guards and server-side reconciliation

**Files:**
- Modify: `functions/gas_supplier_payouts.js`:
  - `payoutProblem` (69-77)
  - `approveSupplierPayout` (162-224)
  - `settleDriverStatement` (278-314)
  - header comment
- Test: `functions/test/payments/gas_supplier_payouts.test.js` (append)

**Interfaces:**
- Consumes: `DEBTS` and `debtStage` from Task 2.
- Produces:
  - `statementReconciliationProblem(statement, claimsById) -> string | null`, pure.
  - `payableOf(statement) -> int`, which returns `payablePesewas ?? netPesewas`.

**Steps:**

- [ ] **Step 1: Write failing tests.**
  - **GSP-LR01:** two concurrent `settleDriverStatement` calls on one statement. Assert:
    - exactly one `ledger/gas_driver_settlement_{id}`;
    - `walletBalance` increased once, by `payableOf`;
    - one `audit_log` entry `gas_driver_statement_settled`;
    - no `payments` document written;
    - the statement has `payoutMethod: "driver_wallet"`.
  - **GSP-LR02:** settle and approve refuse with these reasons:
    - lines sum ≠ net → `statement_lines_mismatch`
    - a line's claim names another statement → `statement_claims_mismatch`
    - an outstanding `before_payout` debt names the statement → `statement_has_outstanding_debt`

    In each case nothing changes, and no transport call is made (spy on `_setTransportForTests`).
  - **GSP-LR03:** after a debt is resolved with `withhold`, the driver is credited `net − withheld`. If the payable amount is 0, `payoutStatus` becomes `"not_required"`, with no ledger row and no wallet change. The supplier side does the same: the Bridge amount equals `payable / 100`.
  - **GSP-LR04:** a credit racing a `withhold` resolution on the same statement. Either the credit lands first (the debt becomes `after_payout`-invalid for `withhold` → `debt_stage_changed`), or the withhold lands first (the credit refuses until the debt is resolved, and then pays the reduced amount). Never both full credit and withhold.
  - **GSP-LR05:** regression. GSP-S01–S11 and D01 pass unchanged. A supplier `unknown` outcome is never re-sent. After a confirmed `failed`, a new approval uses a new `attemptId` and `transactionId`.
- [ ] **Step 2: Run** the payouts test file. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
  - Both functions call `statementReconciliationProblem` inside their transaction, reading every line's claim with `tx.get`. Statements are at most 400 lines, so this is within limits.
  - The debt check is `tx.get(query(DEBTS, statementId ==, status == outstanding))`.
  - The amount comes from `payableOf`.
  - The stored driver values stay `payoutStatus: "paid"` with `payoutMethod: "driver_wallet"`.
- [ ] **Step 4: Run** the payouts, ledger and fulfilment test files. Expected: all PASS.
- [ ] **Step 5: Checkpoint.**

### Task 4: Rider links (callables, collections, audit)

**Files:**
- Create: `functions/gas_supplier_riders.js`
- Modify: `functions/index.js`, next to the gas exports (lines 200-245). Add `const gasRiders = require("./gas_supplier_riders");` and spread its exports in the same way as `gasSettlement`.
- Create: `functions/test/payments/gas_supplier_riders.test.js`

**Interfaces:**
- Consumes: `requireSuperAdmin` (from `gas_settlement_ledger.js`).
- Produces:
  - `RIDERS = "gas_supplier_riders"` and `RIDER_AUDIT = "gas_supplier_rider_audit"`.
  - `activeRiderLink(tx, driverId, supplierId) -> link | null`, used by Task 5.
  - The three callables, with their contracts as in spec §3.1.
  - `linkRider`, `revokeRider` and `listRiders` are exported for tests.

**Steps:**

- [ ] **Step 1: Write failing tests.**
  - **GSR-01:** each callable is refused for: no auth, a passenger, a driver, a supplier member, an inactive admin, and an active admin without `super_admin`. No writes happen.
  - **GSR-02:** link is refused for each case:
    - missing driver → `driver_not_found`
    - `role: "driver_hailing"` → `driver_wrong_role`
    - `isApproved: false` → `driver_not_approved`
    - `signupStep: "suspended"` → `driver_not_approved`
    - `admins/{uid}` exists → `admin_cannot_be_rider`
    - `gas_supplier_members/{uid}` exists → `supplier_member_cannot_be_rider`
    - supplier missing or not approved → `supplier_not_found`
  - **GSR-03:**
    - Link to supplier A, then link to B → `rider_linked_to_other_supplier`.
    - Revoke, then link to B → `version` goes 1 → 2 → 3.
    - Linking to the same supplier again → returns the current link with no new audit row.
  - **GSR-04:** revoke without a reason → `reason_required`; a second revoke → `already_revoked`. The audit has exactly one row per change, with `action`, `by` and `version`.
  - **GSR-05:** revoke while the rider holds a pending offer (seed one). The offer is cleared, `lastRiderOffer.outcome == "revoked"`, and `voidedOrderId` is returned.
- [ ] **Step 2: Run.** Expected: FAIL (module not found).
- [ ] **Step 3: Implement** with one transaction per callable. To find a pending offer during revoke, use `tx.get(query(ORDERS, "riderOffer.driverId" ==, "status" == "confirmed"))`. On the order whose offer is voided, set `riderDeadlineAt = now + riderAcceptMinutes` (spec §2.2). Read the setting through the helper `riderAcceptMinutes(flag)`, defined in this module and re-exported for Task 5.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Checkpoint.**

### Task 5: Assignment (accept as linked rider, list, assign, accept, decline, open-job exclusion)

**Files:**
- Modify: `functions/gas_supplier_fulfilment.js`:
  - constants (lines 107-122)
  - `supplierRespond` (252-285)
  - `listJobs` (358-374)
  - `acceptJob` (409-430)
  - `supplierRequestDriver` (315-330)
  - exports (672-752)
  - header comment (1-91)
- Test: `functions/test/payments/gas_supplier_fulfilment.test.js` (new `describe("linked riders")`)

**Interfaces:**
- Consumes:
  - `activeRiderLink` (Task 4)
  - `driverLocationStale` and `LINKED_RIDER_LOCATION_MAX_AGE_MS` (Task 1)
  - `allocationRef` (ledger)
  - `riderAcceptMinutes(flag) -> int` and `DEFAULT_RIDER_ACCEPT_MINUTES = 5` (Task 4)
- Produces:
  - `MAX_RIDER_DECLINES = 3`
  - `linkedRiderRejection(tx, order, driverId, nowMs) -> string | null`, which runs in this order: link, released, declined, `driverRejection` (with location), stale location.
  - Callables `supplierListGasRiders`, `supplierAssignGasRider` and `declineGasSupplierRiderOffer`. Contracts as in spec §3.2.
  - `listJobs` returns `{jobs, offers, serverNowMs}`.
  - Order fields as in spec §2.1.

**Steps:**

- [ ] **Step 1: Write failing tests.** Every test seeds `lastLocationUpdate` to now unless it is testing staleness.
  - **GSF-LR01:** the full path:
    1. Accept as `linked_rider`.
    2. `supplierListGasRiders({orderId})` shows the rider as eligible, with `deliveryFeePesewas`.
    3. Assign. The offer has `deliveryFeePesewas == allocation.driverNetPesewas`.
    4. The rider accepts with `offerSeq`. Assert `driverAssigned`, `acceptedFeePesewas` and `linkedSupplierId`.
    5. Arrive, hand-over, then the customer's code. Assert the order is delivered.
    6. Assert the ledger posts `driver/entitlement` to the rider and the rider is freed.
  - **GSF-LR02:** a second eligible driver gets `listGasSupplierJobs().jobs` without the order. Their `acceptGasSupplierJob({orderId})` and `({orderId, offerSeq})` both give `job_taken`.
  - **GSF-LR03:** assignment is refused for:
    - another supplier's order → `order_not_found`
    - another supplier's rider → `rider_not_linked`
    - an unlinked or revoked rider → `rider_not_linked`
    - a `ctsgo_driver` or `supplier_rider` order → `invalid_transition`
  - **GSF-LR04:** each rider state gives its refusal code at assignment:
    - offline → `driver_unavailable`
    - `isAvailable: false` → `driver_unavailable`
    - `currentTripId` set → `driver_on_job`
    - `driver_hailing` → `wrong_service`
    - wrong vehicle → `vehicle_not_eligible`
    - location 11 km away → `outside_radius`
    - no location → `driver_location_invalid`
    - `lastLocationUpdate` 11 minutes old → `driver_location_stale`
    - unapproved → `driver_not_approved`
  - **GSF-LR05:** the same changes made between the offer and the accept give the same codes at acceptance, and the order is unchanged.
  - **GSF-LR06:** two concurrent assignments with `replacesSeq: 0` and different riders. Exactly one succeeds; the other gets `offer_changed`. Retrying the winner's exact call returns the same `offerSeq`.
  - **GSF-LR07:** a rider holding a pending offer on order A cannot be offered order B → `rider_has_pending_offer`.
  - **GSF-LR08:** after the order is re-offered from rider A to rider B:
    - A's accept → `job_taken`; A's decline → `offer_not_found`.
    - B's accept with the previous seq → `offer_stale`.
  - **GSF-LR09:**
    - A declines. Re-offering to A → `rider_declined`. B is offered and accepts.
    - Repeating A's decline → OK with no change.
    - On a fresh order, three declines → `deliveryMode == "ctsgo_driver"` and `ctsgoFallbackReason == "riders_declined"`.
  - **GSF-LR16:**
    - A wrong code increments `completionFailures` and locks after 5, for the linked rider.
    - `supplierCompleteGasOrder` on a `linked_rider` order → `order_not_found`.
    - `supplierHandOverGasOrder` before `atStation` → `driver_not_at_station`.
  - **GSF-LR17:** the fee is fixed. Seed `riderOffer.deliveryFeePesewas` different from the allocation; accept → `rider_fee_changed`.
  - **GSF-LR19:** `supplierRequestGasDriver` with a pending offer → `ctsgo_driver`, reason `supplier_request`, offer withdrawn. After `driverAssigned` → `invalid_transition`.
  - **GSF-LR20:**
    - `supplierListGasRiders` returns only the caller's active links.
    - Its JSON contains none of `phone`, `vehiclePlate`, `location`, `rating`, `walletBalance`, `distanceKm`.
    - A member of another supplier gets `[]`.
  - **GSF-LR21:** with the fulfilment flag off, every new callable is refused (`gas_supplier_fulfilment_disabled`).
  - **GSF-F01–F04** (offline `supplier_rider`) and **GSF-S20/S21** pass unchanged. Add `supplier_rider` to GSF-LR02, so offline-rider orders also stay out of `jobs`.
- [ ] **Step 2: Run** the fulfilment test file. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
  - `supplierListGasRiders` reads links with `where("supplierId", "==", sid).where("status", "==", "active")`, plus each `drivers/{id}`.
  - The pending-offer check and the `offers` query use `where("riderOffer.driverId", "==", uid).where("status", "==", "confirmed")`.
  - `jobView` is reused for offers.
  - The `listJobs` exclusion (`o.deliveryMode === "linked_rider"`) and the `acceptJob` branch must be in this task.
- [ ] **Step 4: Run** the fulfilment, ledger and payouts test files. Expected: all 74 existing GSF tests plus the new ones PASS.
- [ ] **Step 5: Checkpoint.**

### Task 6: Deadlines, fallback, cancellation, release, recovery alert, rider earnings

**Files:**
- Modify: `functions/gas_supplier_fulfilment.js`:
  - `cancel` (573-600)
  - `adminReleaseDriver` (702-734)
  - the schedule at 651-659 (call `expireRiderOffers` after `expireUnansweredOrders`)
  - new `expireRiderOffers` and `myEarnings`
  - exports
- Test: `functions/test/payments/gas_supplier_fulfilment.test.js`

**Interfaces:**
- Consumes: `entryStatus`, `DEBTS` and `CLAIMS` (Task 2).
- Produces:
  - `expireRiderOffers({now}) -> {fallbacks: [{orderId, reason}]}`
  - Callable `listMyGasSupplierEarnings` → `{earnings: [{orderId, amountPesewas, status, deliveredAtMs, eligibleFromMs, creditedAtMs, linkedSupplierName}]}`
    - `status` is one of `pending`, `owed`, `credited_to_wallet`, `reversed`, `outstanding_adjustment`.
    - `eligible` and `settlement_prepared` both map to `owed`; `resolved_adjustment` maps to `reversed`.

**Steps:**

- [ ] **Step 1: Write failing tests.**
  - **GSF-LR10:** `expireRiderOffers({now: expiresAt})` gives:
    - `ctsgo_driver`, `rider_timeout`, the offer cleared and `lastRiderOffer.outcome == "timed_out"`.
    - Reruns change nothing.
    - The rider's late accept → `job_taken`.
    - A CTSGo driver now sees the order in `jobs` and completes it. The ledger pays that driver.
  - **GSF-LR11:** an accept at `expiresAt − 1 ms` racing the sweep at `expiresAt`, and the reverse. Each time exactly one outcome happens, and the driver record is consistent (`currentTripId` set only if accepted).
  - **GSF-LR11b:** accept at `now ≥ expiresAt` before the sweep → `offer_expired`.
  - **GSF-LR12:**
    - No offer within M minutes after confirmation → `no_rider_assigned`.
    - After a decline, the window restarts from the decline.
    - A `driverAssigned` order is never swept.
  - **GSF-LR13:**
    - `riderAcceptMinutes` values 1 and 60 are used.
    - 0, 61, 2.5, `"5"` and missing all fall back to 5, and an invalid value logs a warning.
    - Changing the setting after an offer leaves its `expiresAt` unchanged.
  - **GSF-LR14:** passenger cancel and admin cancel, each with an offer pending. The refund happens once, the offer is cleared with `outcome "cancelled"`, and a later accept or decline is refused.
  - **GSF-LR15:** admin release from `driverAssigned` and from `atStation` on a `linked_rider` order:
    - `ctsgo_driver` with reason `admin_release`;
    - the rider is freed and appears in `releasedDriverIds`;
    - the escrow is still HELD and `completionCode` is unchanged;
    - the released rider's accept → `released_from_job`.
  - **GSF-LR18 (F4/F5):** admin cancel at `outForDelivery` of a `linked_rider` order:
    - full refund;
    - no `gas_settlement_ledger` entries;
    - the rider is freed;
    - `admin_alerts/gas_cylinder_recovery_{orderId}` exists once, with `type: "gas_cylinder_recovery_required"`.

    Also assert:
    - A repeated cancel creates no second alert.
    - Cancelling at `driverAssigned` creates no recovery alert.
    - The same happens for a `ctsgo_driver` order handed over.
  - **GSF-LR22:** `listMyGasSupplierEarnings` returns only the caller's driver entries, with the statuses moving pending → owed → credited_to_wallet. For a debt-held reversal it returns `outstanding_adjustment`. Its JSON contains no `commission`, `supplier` amount or `customerTotal`. Another driver's entries are never returned.
  - **GSF-T01–T08** pass unchanged.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - The sweep queries `status == confirmed, deliveryMode == linked_rider` and runs one transaction per order.
  - `myEarnings` queries the ledger with `party == driver, partyId == uid`, then reads the claims, statements, debts, escrows and terms needed for `entryStatus`.
- [ ] **Step 4: Run** all three gas test files. Expected: PASS.
- [ ] **Step 5: Checkpoint.**

### Task 7: Offer notifications

**Files:**
- Modify: `functions/notifications.js`. Add `exports.onGasSupplierRiderOfferChanged`, plus a helper `notifyRiderOnce(uid, {inboxId, type, title, body, orderId, channel})` near `notifyDriver` (line 271).
- Modify: `functions/index.js` only if `notifications.js` exports are listed one by one. Check lines 1-60 first.
- Test: `functions/test/payments/gas_supplier_fulfilment.test.js` (`describe("rider offer notifications")`). Test the handler as an exported pure function, `handleRiderOfferChange(before, after, orderId, {now, fcm})`, with a fake FCM.

**Interfaces:**
- Produces: `handleRiderOfferChange(...) -> {sent: string[], skipped: string[]}`.
- Push `data`: `{type: "GAS_SUPPLIER_RIDER_OFFER" | "GAS_SUPPLIER_RIDER_OFFER_ENDED", orderId}`.
- Android `tag` and APNs `apns-collapse-id`: `gsro_{orderId}`.

**Steps:**

- [ ] **Step 1: Write failing tests.**
  - **GSF-N01:** a new offer creates one inbox doc, `drivers/{r}/notifications/gas_rider_offer_{o}_{seq}_offer`, and one FCM send. Calling the handler again with the same change creates nothing and sends nothing.
  - **GSF-N02:**
    - A delayed event whose seq is no longer current, or whose offer has expired, sends no offer push.
    - A withdrawn, timed-out, cancelled or revoked offer sends one `…_ENDED` push to the previous rider only.
    - Accepted and declined offers send nothing.
    - The payload keys are exactly `type` and `orderId`.
  - **GSF-N03:**
    - When FCM rejects with `messaging/registration-token-not-registered`, the token is removed and the order is untouched.
    - Any other FCM error leaves the order untouched.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Create the inbox doc with `create()`; on ALREADY_EXISTS, skip the push. Reuse `dropDeadToken`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Checkpoint.**

### Task 8: Firestore rules

**Files:**
- Modify: `firestore.rules`:
  - `gasSwitchOk` (around lines 1026-1033)
  - new matches next to the gas settlement block (around 1430-1450): `gas_supplier_riders`, `gas_supplier_rider_audit`, `gas_settlement_debts`
- Modify: `Portal/rules-candidate/portal-collections.rules`. Mirror the three matches and follow its README to rebuild the candidates.
- Test: `rules-tests/test/gas_switches.test.js` and `rules-tests/test/gas_settlement.test.js` (append); new `rules-tests/test/gas_supplier_riders.test.js`.

**Steps:**

- [ ] **Step 1: Write failing tests.**
  - **RULES-LR01:** `gas_supplier_riders` and `gas_supplier_rider_audit` refuse every read and write for:
    - unauthenticated users;
    - a passenger;
    - a driver;
    - the linked driver themselves;
    - a supplier member;
    - an admin;
    - a super admin.
  - **RULES-LR02:** `gas_settlement_debts`: admins can read; every client write is refused, including from a super admin.
  - **RULES-LR03:** a super admin can set `riderAcceptMinutes` to 1 or 60. The values 0, 61, 2.5 and `"5"` are refused. A non-super admin is refused. Existing `supplierResponseMinutes` cases still pass.
  - **RULES-LR04:** a driver cannot update `gas_supplier_orders/{id}`: `riderOffer`, `driverId`, `acceptedFeePesewas`.
- [ ] **Step 2: Run** `npx mocha test/gas_supplier_riders.test.js test/gas_switches.test.js test/gas_settlement.test.js`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the whole rules suite (`npx mocha`). Expected: no new failures compared with the baseline taken before Step 3. Record the baseline counts first, because the README notes failures already present in committed tests.
- [ ] **Step 5: Checkpoint.**

## Supplier portal (`Portal`)

### Task 9: Earnings filter fix (F6, separate and narrow)

**Files:**
- Modify: `src/server/portal-service.ts:98` (`ENTRY_ID`)
- Modify: `src/lib/domain/ledger.ts`: the `entryStatus` copy and the kinds that `projectSupplierLedger` handles. Status parity covers `outstanding_adjustment`, `resolved_adjustment` and `credited_to_wallet`.
- Modify: `src/server/portal-store.ts` and `src/server/firestore-store.ts`: `SettlementData.debts: Record<string, {status: string}>`, loaded for the supplier's reversal entries.
- Modify: `src/app/(portal)/earnings/page.tsx`: the label "Outstanding adjustment · CTSGo will contact you" (R5).
- Test: `tests/unit/portal-earnings.test.ts` (new) and `tests/unit/settlement-parity.test.ts` (extend)

**Steps:**

- [ ] **Step 1: Write failing tests.**
  - **PE-01:** a `supplier_rider` order with `{o}__supplier__entitlement` 29 500 and `{o}__supplier__delivery_fee` 1 500, both claimed by statement S with net 31 000. `supplierEarnings` returns both lines, and their sum equals S's `netPesewas`.
  - **PE-02:** after `{o}__supplier__reversal` (−29 500) and `{o}__supplier_delivery__reversal` (−1 500) are claimed together in the next statement S2, all four lines are shown. The sum of S2's displayed lines equals S2's net, which is 0.
  - **PE-03:** `ctsgo_driver` and `linked_rider` orders: the displayed supplier lines equal `{o}__supplier__entitlement` only. No driver entry is ever shown, and the displayed sum equals the supplier statement's net.
  - **PE-04:** IDs such as `{o}__supplierX__delivery_fee`, `{o}__driver__entitlement` and a mismatched `orderId` prefix are dropped.
  - **PE-05:** a debt-held reversal shows `outstanding_adjustment`.
  - **Parity:** `entryStatus` in the portal equals the functions' `entryStatus` for every new ctx case. Follow the existing parity test's pattern.
- [ ] **Step 2: Run** `npx vitest run tests/unit/portal-earnings.test.ts tests/unit/settlement-parity.test.ts`. Expected: PE-01/02 FAIL, because the delivery-fee lines are missing.
- [ ] **Step 3: Implement.** Change the regex to `/^[A-Za-z0-9_-]{1,128}__(supplier__(entitlement|delivery_fee|reversal)|supplier_delivery__reversal)$/`. Nothing else in the filter changes.
- [ ] **Step 4: Run** `npm test && npm run typecheck && npm run lint`. Expected: PASS (the baseline is 231 tests).
- [ ] **Step 5: Checkpoint.**

### Task 10: Linked-rider assignment UI, polling, staff guard

**Files:**
- Modify: `src/lib/domain/projections.ts` (lines 180-320):
  - `DELIVERY_MODES`, `deliveryOptions`, `projectOrder`
  - new `SupplierOrder` fields `riderOffer`, `lastRiderOffer`, `riderOfferSeq`, `ctsgoFallbackReason` and `assignedRiderId`
- Modify: `src/lib/data/repository.ts`, `http-repository.ts` and `demo-repository.ts`:
  - `listRiders(session, orderId?) -> {riders: LinkedRider[], deliveryFeePesewas?: number}`
  - `assignRider(session, orderId, riderId, replacesSeq) -> {offerSeq, expiresAtMs}`
- Modify: `src/lib/use-resource.ts`: option `{pollMs?: number}`. A silent refresh runs only while `document.visibilityState === "visible"`; a failed poll keeps the last data.
- Modify: `src/app/(portal)/orders/page.tsx`
- Create: `src/components/orders/RiderPicker.tsx`
- Modify: `src/server/staff/membership-admin.ts` (refuse an active rider with `rider_cannot_be_member`) and `src/server/staff-handler.ts` (`STATUS.rider_cannot_be_member = 409`)
- Test:
  - `tests/unit/order-actions.test.tsx` (extend)
  - `tests/unit/use-resource.test.ts` (new)
  - `tests/unit/portal-handler.test.ts` (assert no `driverId` in the new fields)
  - `tests/unit/staff-route.test.ts` (extend)

**Steps:**

- [ ] **Step 1: Write failing tests.**
  - **PO-01:** with a fallback-arrangement profile, three accept buttons appear. The linked-rider confirmation shows "CTSGo pays the rider the delivery fee of GH₵15.00 directly", using the illustrative fee from the demo data.
  - **PO-02:** the picker lists eligible riders as selectable. Ineligible riders are disabled, with the labels "Offline", "On another job", "Vehicle can't carry this order", "Too far from the customer", "Location not recent", "Declined this order" and "Already has an offer".
  - **PO-03:** a pending offer shows the rider's name and an `m:ss` countdown. When `assignRider` throws `offer_changed`, the page shows "This order changed; refreshed" and reloads.
  - **PO-04:** the confirm button is disabled while a call is in flight, and a double click sends one call.
  - **PO-05:** each fallback reason shows its text.
  - **UR-01:** polling refreshes without the loading state, pauses when hidden, and keeps the data when a poll fails.
  - **ST-01:** `link` or `provision` of a uid with an active rider link → 409 `rider_cannot_be_member`.
  - **PH-01:** the strip test still finds no `driverId` text.
- [ ] **Step 2: Run** `npx vitest run` on those files. Expected: FAIL.
- [ ] **Step 3: Implement.** Make the demo repository enforce the same refusals as the server for these tests.
- [ ] **Step 4: Run** `npm test && npm run typecheck && npm run lint`. Expected: PASS.
- [ ] **Step 5: Checkpoint.**

## Admin app (`Admin`)

### Task 11: Settlement labels, the rider-payment view, debts, reconciliation

**Files:**
- Modify: `src/lib/gas-supplier-ops.ts`:
  - `payoutStatusLabel(status, party, method)` (line 236). The driver reading of `paid` with `driver_wallet` is "Credited to CTSGo wallet"; `not_required` reads "Nothing to pay".
  - `settlementStage` (line 225) adds `credited_to_wallet` and `outstanding_adjustment`.
  - `deliveryModeLabel` (line 272) adds "Linked supplier rider (delivery fee paid by CTSGo to the rider)".
  - New `riderPaymentSummary(entries, claims, statements, debts, withdrawals) -> {earnedPending, owed, credited, withdrawalRequested, sentAwaitingConfirmation, outcomeUnknown, paidOutConfirmed, failed, outstandingAdjustments}`, all in pesewas.
  - New `orderModeReconciles(order, entries) -> boolean`, which also checks the delivery party against the mode.
- Modify: `src/app/gas-settlement/page.tsx`: the driver section uses `riderPaymentSummary`, and a new debts panel calls `adminResolveGasSettlementDebt`. Withdrawals are read from `withdrawals` with `where("userId", "==", driverId)`, as `withdrawals/page.tsx` already does.
- Modify: `src/app/gas-suppliers/[id]/page.tsx` (line 282) to render `<SupplierRiders supplierId>`.
- Create: `src/components/features/gas-suppliers/SupplierRiders.tsx`
- Test: `tests/c8-gas-supplier-ops.test.mjs` (extend)

**Steps:**

- [ ] **Step 1: Write failing tests.**
  - **AO-01:** `payoutStatusLabel("paid", "driver", "driver_wallet")` returns "Credited to CTSGo wallet". `("paid", "supplier", "mobile_money")` returns "Payout completed". No driver input returns a string containing "Payout completed".
  - **AO-02:** `riderPaymentSummary` sorts amounts into the right buckets, using illustrative amounts:
    - one pending entry, one owed entry and one credited statement;
    - withdrawals in `pending`, `processing/sent`, `processing/unknown`, `completed` and `failed`;
    - one outstanding debt.

    Assert:
    - `paidOutConfirmed` counts only `completed`;
    - `credited` never adds into `paidOutConfirmed`;
    - `outcomeUnknown` counts `processing/unknown`.
  - **AO-03:** `orderModeReconciles` is false for a `linked_rider` order with a `supplier__delivery_fee` entry, and false for a `supplier_rider` order with a `driver__entitlement` entry. It is true for each correct shape.
  - **AO-04:** `deliveryModeLabel("linked_rider")` returns the text above.
- [ ] **Step 2: Run** `npm run test:c1`. Expected: FAIL.
- [ ] **Step 3: Implement.** `SupplierRiders` follows the `SupplierLogins` patterns (Card, Modal, toast), calling the three callables through `httpsCallable(functions, …)`. The debts panel offers only the resolutions allowed for the debt's stage, and requires a reason and, for `after_payout`, evidence.
- [ ] **Step 4: Run** `npm run test:c1 && npm run lint && npx tsc --noEmit`. Expected: PASS.
- [ ] **Step 5: Checkpoint.**

## Driver app (`Driver`)

### Task 12: Offer and earnings data layer, location refresh

**Files:**
- Modify: `lib/features/gas_supplier_jobs/domain/gas_supplier_job.dart`:
  - `GasSupplierJob` gains `int? offerSeq`, `int? expiresAtMs` and `double? deliveryFee` (already present).
  - New class `GasSupplierEarning {orderId, amountPesewas, status, deliveredAtMs, eligibleFromMs, creditedAtMs, linkedSupplierName}`.
  - New `gasEarningLabel(String status) -> String`.
  - `gasSupplierJobMessage` gains these messages:
    - `offer_expired`: "This offer has expired."
    - `offer_stale`: "This offer changed. Pull to refresh."
    - `rider_not_linked`: "You're no longer linked to this supplier."
    - `rider_fee_changed`: "This offer changed. Pull to refresh."
    - `driver_location_stale`: "Your location is out of date. Turn on location and try again."
- Modify: `lib/features/gas_supplier_jobs/data/gas_supplier_job_repository.dart`:
  - `openJobs()` returns `GasSupplierJobList {jobs, offers, serverNowMs}`.
  - `accept(String orderId, {int? offerSeq})`
  - `decline(String orderId, int offerSeq)`
  - `myEarnings() -> List<GasSupplierEarning>`
  - The constructor takes `Future<bool> Function()? refreshLocation`. Production uses `GeolocatorLocationSource().currentPosition()` and `FirestoreJobLocationStore().writeProfileLocation(uid, pos)`, and returns false when there is no fix.
  - `accept` with an `offerSeq` calls `refreshLocation` first and throws `GasSupplierJobFailure('failed-precondition', 'driver_location_stale', …)` without calling the server when it returns false.
- Test: `test/features/gas_supplier_jobs/gas_supplier_jobs_test.dart` (extend)

**Steps:**

- [ ] **Step 1: Write failing tests.**
  - **DA-01:** `openJobs` parses `offers`, including `offerSeq`, `expiresAtMs` and `deliveryFeePesewas / 100`, plus `serverNowMs`. Old responses without `offers` give an empty list.
  - **DA-02:** `accept('o1', offerSeq: 2)` sends `{orderId: 'o1', offerSeq: 2}` after `refreshLocation`. When `refreshLocation` returns false, no call is made and the reason is `driver_location_stale`.
  - **DA-03:** `decline('o1', 2)` sends `declineGasSupplierRiderOffer` with `{orderId, offerSeq}`.
  - **DA-04:** `gasEarningLabel` maps:
    - `pending` → "Earned · pending"
    - `owed` → "Owed"
    - `credited_to_wallet` → "Credited to wallet"
    - `reversed` → "Reversed"
    - `outstanding_adjustment` → "Under review"

    No status maps to a label containing "Paid".
  - **DA-05:** each new reason maps to its message exactly.
- [ ] **Step 2: Run** `flutter test test/features/gas_supplier_jobs/`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test test/features/gas_supplier_jobs/ && flutter analyze lib/features/gas_supplier_jobs`. Expected: PASS, with the 11 existing tests included.
- [ ] **Step 5: Checkpoint.**

### Task 13: Offer card, earnings list, push routing

**Files:**
- Modify: `lib/features/gas_supplier_jobs/presentation/gas_supplier_jobs_screen.dart`:
  - an "Offer from your supplier" section with a `GasSupplierOfferCard`;
  - a 1 s countdown ticker that uses `serverNowMs − localNow` as the skew;
  - a 30 s refresh while offers exist;
  - an earnings section.
- Modify: `lib/features/gas_supplier_jobs/presentation/gas_supplier_jobs_entry.dart` to show "Delivery offer waiting" when there are offers.
- Modify: `lib/main.dart` (routes map, line 157) to add `'/gas-supplier-jobs': (_) => const GasSupplierJobsScreen()`.
- Modify: `lib/features/driver/services/driver_notification_service.dart`:
  - `routeForTap` maps the two new types to `/gas-supplier-jobs`;
  - `_channelForType` maps the offer type to the trip channel and the ended type to the general channel.
- Test:
  - `test/features/gas_supplier_jobs/gas_supplier_jobs_test.dart` (widget tests)
  - the existing notification-service test file for `routeForTap` (find it with `grep -rl routeForTap test/`)

**Steps:**

- [ ] **Step 1: Write failing widget tests.**
  - **DU-01:** an offer card shows "Delivery fee GH₵15.00 · paid by CTSGo" (illustrative), the station, the address and the countdown. Its Accept key is `gsj-offer-accept-{id}` and its Decline key is `gsj-offer-decline-{id}`.
  - **DU-02:** with `serverNowMs` 120 s ahead of the device and `expiresAtMs = serverNow + 60 s`, the card shows `1:00`, not `3:00`. At 0 it shows "Expired" and both buttons are disabled.
  - **DU-03:** Accept success pushes `GasSupplierActiveJobScreen`. A `job_taken` or `offer_expired` refusal shows the message and reloads.
  - **DU-04:** Decline asks for confirmation, then calls `decline`.
  - **DU-05:** the fee explanation text is exactly as in spec §5. The delivered screen shows "Earned GH₵15.00 · pending", and no widget in the gas screens shows "Paid".
  - **DU-06:** `routeForTap({'type': 'GAS_SUPPLIER_RIDER_OFFER', 'orderId': 'o'})` returns `'/gas-supplier-jobs'`. Existing request types still return null.
- [ ] **Step 2: Run** `flutter test test/features/gas_supplier_jobs/` and the notification test. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test && flutter analyze`. Expected: no new failures or warnings compared with the baseline recorded before Step 3.
- [ ] **Step 5: Checkpoint.**

## Task 14: Full regression and release checklist (no deploy)

- [ ] **Step 1:** Run the full suites:
  - passenger `functions/test/payments/*.test.js` on the emulator;
  - `rules-tests` (`npx mocha`);
  - portal `npm test && npm run typecheck && npm run lint`;
  - admin `npm run test:c1 && npm run lint`;
  - driver `flutter test && flutter analyze`.

  Expected: every new test passes, and there are no regressions from the recorded baselines.
- [ ] **Step 2:** Add a short release checklist to the spec's §10. Use exactly these items:
  - **B1:** a read-only production query for `prepared_no_payout` statements with any negative line.
  - Named-function deploy list:
    - `supplierListGasRiders`, `supplierAssignGasRider`, `declineGasSupplierRiderOffer`, `listMyGasSupplierEarnings`
    - `adminLinkGasSupplierRider`, `adminRevokeGasSupplierRider`, `adminListGasSupplierRiders`, `adminResolveGasSettlementDebt`
    - `onGasSupplierRiderOfferChanged`
    - and the changed `acceptGasSupplierJob`, `listGasSupplierJobs`, `supplierRespondGasOrder`, `supplierRequestGasDriver`, `cancelGasSupplierOrder`, `adminCancelGasSupplierOrder`, `adminReleaseGasSupplierDriver`, `expireUnansweredGasSupplierOrders`, `adminReverseGasSupplierEntitlements`, `adminPrepareGasSettlementStatements`, `prepareDailyGasSettlementStatements`, `adminSettleGasDriverStatement`, `adminApproveGasSupplierPayout`
  - The rules-candidate rebuild.
  - Both switches stay off.
- [ ] **Step 3:** Run `git status --short` in all four repos and confirm that only the files named in this plan changed (beyond the pre-existing working changes). Report the result. **Do not commit.**

---

## Self-review notes

- **Spec coverage:**

  | Spec section | Task(s) |
  | --- | --- |
  | §2 | 5, 6 |
  | §3.1 | 4 |
  | §3.2 | 5, 6 |
  | §3.3 | 7 |
  | §3.4–3.6 | 2 |
  | §3.7 | 3 |
  | §3.8 | 6 |
  | §3.9 | 8 |
  | §3.10 | 10 |
  | §4 | 9, 10 |
  | §5 | 12, 13 |
  | §6 | 11 |
  | Financial checks 1–9 | 1 and 2 → GSL-LR01/03; 3 → GSL-LR01/02, PE-03; 4 → GSL-LR03, GSP-LR01; 5 → AO-01, GSP-LR01, DA-04, DU-05; 6 → GSP-LR05; 7 → GSL-D01–D07; 8 → GSF-F01–F04, GSL-LR02, PE-01/02; 9 → PE-01–05 |

- **Open decisions this plan assumes the recommendation for:**
  - R1: 10 minutes.
  - R2: one super admin for the before-payout resolutions, and two different super admins for `written_off` and `recovered_externally` (Task 2, GSL-D08). If you choose a single approver instead, drop `propose`/`approve`/`reject` and GSL-D08.
  - R3: no offset.
  - R5: show adjustments in the portal.
