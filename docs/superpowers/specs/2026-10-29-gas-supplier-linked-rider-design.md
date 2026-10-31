# Gas supplier linked riders: design

Status: **revision 3, 2026-10-29. Nothing is implemented.** This spec is local only: not committed, deployed or switched on.

Repos:
- **passenger**: `functions/`, `firestore.rules`, `rules-tests/`
- **portal**: `ctsgo-gas-supplier-portal`
- **admin**: `ctsride-admin`
- **driver**: `cts-transport-driver-app-clean`

Plan: [`../plans/2026-10-29-gas-supplier-linked-rider.md`](../plans/2026-10-29-gas-supplier-linked-rider.md)

**Approved decisions:**
- D1 = B: CTSGo pays linked riders directly.
- F1–F7 as recorded in §8.
- The assignment decisions D3–D8 as recorded in §8.

## 0. Scope

A supplier offers one confirmed order to **one linked rider** of its choice. A linked rider is an approved CTSGo `driver_delivery` driver whom a super admin has linked to that supplier.

The rider accepts or declines in the Driver App. If no rider takes the order in time, the backend moves it to CTSGo dispatch.

The money works like this:
- The rider's delivery fee is the order's agreed delivery fee. It is shown to the rider before they accept and is fixed for the order.
- CTSGo records that fee as the rider's own entitlement, credits it to the rider's CTSGo wallet, and the rider withdraws it through the existing withdrawal flow.
- The supplier receives product plus handling, minus commission, and never the rider's fee.
- The offline `supplier_rider` mode keeps its current behaviour: the supplier receives the delivery fee.

## 1. Verified facts (read-only, 2026-10-29)

### 1.1 Financial verification requested on 2026-10-29

| # | Check | Result | Evidence |
| --- | --- | --- | --- |
| 1 | The customer hold covers the whole order before capture | **Yes, exactly equal.** At payment, the escrow must be HELD, belong to the passenger, not be attached elsewhere, and equal `priceSnapshot.total` to the pesewa. The snapshot comes from the server's quote (`gas_quotes` cannot be read by clients). The allocation must still reconcile, and the terms must be usable. At capture, the escrow problem and its binding to the order are checked again inside the delivery transaction. Posting checks the amount against the total once more. | `gas_supplier_orders.js:186-189`; `gas_supplier_fulfilment.js:203-247, 486-545`; `gas_settlement_ledger.js:226-246` |
| 2 | Product, handling, delivery and commission are allocated exactly once | **Yes.** `computeAllocation` runs once, in the transaction that creates the order (`tx.create` of `finance/allocation`), and is never recomputed. `allocate` refuses any split that does not add up to the total. Posting is one transaction of three `create`s with deterministic IDs; a partial posting is refused, and a complete one is a no-op. | `gas_supplier_orders.js:419-436`; `gas_settlement_ledger.js:147-176, 345-413` |
| 3 | Supplier proceeds exclude a linked rider's fee | **Yes by construction.** Only `supplier_rider` routes the fee to the supplier (`deliverySlot`). Any other mode posts `driver/entitlement` to `order.driverId`. The supplier entry is always `product + handling − commission`. Tests pin this (GSL-LR01/02/07). | `gas_settlement_ledger.js:259-263` |
| 4 | The rider's entitlement is created once and credited to the wallet once | **Yes.** The entitlement is `{orderId}__driver__entitlement` (`create`). The statement line is `gas_settlement_claims/{entryId}` (`create`). The wallet credit is `ledger/gas_driver_settlement_{statementId}` (`create`), and the same transaction requires `payoutStatus == not_started`. | `gas_settlement_ledger.js:520-545`; `gas_supplier_payouts.js:278-314` |
| 5 | A wallet credit is never shown as a confirmed Mobile Money payment | **The data is correct, but the admin display is wrong.** A credit writes `payoutMethod: "driver_wallet"`, a ledger row of type `EARNING` (not `PAYOUT`), and no `payments` record. But the admin app labels any statement with `payoutStatus "paid"` as **"Payout completed"** (`payoutStatusLabel`) and its entries as **`payout_completed`** (`settlementStage`), whatever the method. **Fix in §6.** | `ctsride-admin/src/lib/gas-supplier-ops.ts:225-241` |
| 6 | An uncertain Bridge outcome cannot trigger an automatic resend | **Yes, for both paths.** One attempt is claimed per transaction. Anything other than `000`/`202` (sent) or `001`/`003` (refused) is `unknown`, and `unknown` is never re-sent. A late answer cannot override an admin's resolution (`attemptId` check). "Paid" requires evidence. Withdrawals: `approveWithdrawal` only accepts `pending`; `resolveUnconfirmedPayout` only accepts `processing`. Supplier: `payoutProblem` allows only `not_started`/`failed`, and `failed` is reached only through an explicit refusal or a confirmed failure. | `withdrawal_approval.js:36-90, 256-300, 386-460`; `gas_supplier_payouts.js:126-275` |
| 7 | Reversals keep the full outstanding debt | **No (existing defect).** An unclaimed reversal is put into the party's next statement. If that statement has positive lines, the reversal is **deducted automatically**. If not, the net is ≤ 0, the statement becomes `prepared_no_payout`, the line is claimed, and **the debt is lost**. The existing test GSL-D03 ("a refund after settlement is netted as a negative line on a later statement") **asserts the automatic netting on purpose**. F3 changes that approved behaviour, so GSL-D03 will be rewritten. No test covers the case where the debt is lost. **Fix in §3.6 (F3).** | `gas_settlement_ledger.js:415-462, 464-555, 313-315` |
| 8 | Offline `supplier_rider` money is unchanged | **Yes, if the plan is followed.** No amount or slot changes. The only ledger changes are a mode allowlist (`supplier_rider` still requires no `driverId`), the F3 debt handling (all modes), and audit fields on `basis`. GSF-F01–F04 and GSL-LR10 cover this mode. | |
| 9 | The portal filter fix leaves totals and other modes alone | **Yes.** `portal-service.ts:98` (`ENTRY_ID`) is a display filter on entries the portal reads. Widening it to `__supplier__delivery_fee` and `__supplier_delivery__reversal` changes no ledger data. It still requires `party == supplier` and `partyId == caller`, so other parties and modes are unaffected. Verified by running the current regex: those two IDs return `false`. | |

### 1.2 F7 verification (wallet-credit action)

| Property | Result | Evidence |
| --- | --- | --- |
| Server-side authorisation | `adminSettleGasDriverStatement` calls `requireSuperAdmin`, which checks that `admins/{uid}` is active with `role == super_admin`. | `gas_supplier_payouts.js:330`; `gas_settlement_ledger.js:320-327` |
| Idempotency | One transaction, guarded by `payoutProblem(s, "driver")` (only `not_started`), plus a deterministic ledger `create`. GSP-D01 covers it. | `:278-314` |
| Audit | `audit_log` entry `gas_driver_statement_settled` records the admin uid and email, the driver and the amount. | `:121-126, 312` |
| Reconciliation | **Missing on the server.** The admin page only enables the button when its own client-side check `orderReconciles` passes. The server does not check that the lines add up to `netPesewas`, that each line is claimed by this statement, or that no line has been reversed since preparation. **Hardening in §3.7.** | `ctsride-admin/src/app/gas-settlement/page.tsx:332` |
| New feature switch? | **Not needed.** The action is manual, super-admin only and exactly once, and no money leaves CTSGo. Cash leaves only through withdrawals, which have their own admin approval and evidence rules. | |

### 1.3 Other relevant facts

- **Withdrawable amount.** At withdrawal, `drivers.commissionOwed` (cash-job commission) is deducted automatically from `walletBalance` (`bridge.js:744-760`). A linked rider who owes cash commission will therefore see a smaller withdrawable amount than their credited gas fees. This is existing, approved driver behaviour. The new gas reversal debts **must not** feed `commissionOwed`, because that would be automatic recovery.
- **Withdrawal approval and resolution require an active admin, not a super admin** (`withdrawal_approval.js:256-270, 386-390`). This is existing behaviour. It is listed in §9 for your decision; this plan does not change it.
- **Driver location** is self-reported. `lastLocationUpdate` (`serverTimestamp`) is written at most every 30 s, and only when a GPS fix arrives (`driver_location_publisher.dart:58-90`). A rider who isn't moving may produce no fixes, so the app refreshes the location just before accepting (§5).
- **Assignment code** (from revision 2): the only guard on `listJobs` and `acceptJob` is `=== "supplier_rider"`. A `linked_rider` order would be claimable by every CTSGo driver until both are changed **in the same deploy** (GSF-LR02). Completion, hand-over and capture already work for any non-`supplier_rider` driver order.

## 2. Assignment state machine

### 2.1 Order fields (server-written)

```
deliveryMode: "ctsgo_driver" | "supplier_rider" | "linked_rider"
riderOffer?: { driverId, seq, offeredAt, expiresAt, deliveryFeePesewas }
riderOfferSeq: int
riderDeadlineAt?: Timestamp
lastRiderOffer?: { driverId, seq, outcome, at }   // accepted|declined|timed_out|withdrawn|cancelled|revoked
declinedRiderIds: string[]
riderDeclineCount: int
linkedSupplierId?: string          // set at acceptance
acceptedFeePesewas?: int           // = allocation.driverNetPesewas, set at acceptance
ctsgoFallbackReason?: "supplier_request"|"rider_timeout"|"no_rider_assigned"|"riders_declined"|"admin_release"
```

### 2.2 States and transitions

```
pendingApproval ──accept(linked_rider)──▶ CONFIRMED/linked, NO_OFFER   [riderDeadlineAt = now+M]
NO_OFFER ──assign(rider, replacesSeq)──▶ OFFERED(seq+1)                  [riderDeadlineAt = expiresAt = now+M]
OFFERED ──assign(other rider, replacesSeq=seq)──▶ OFFERED(seq+1)         [old offer: withdrawn]
OFFERED ──rider accepts (seq, now<expiresAt, eligible, link active, fee == allocation)──▶ driverAssigned
OFFERED ──rider declines(seq)──▶ NO_OFFER [declines+1, riderDeadlineAt=now+M]; at 3 declines ──▶ FALLBACK(riders_declined)
OFFERED ──sweep: now ≥ expiresAt──▶ FALLBACK(rider_timeout)
NO_OFFER ──sweep: now ≥ riderDeadlineAt──▶ FALLBACK(no_rider_assigned)
NO_OFFER|OFFERED ──supplier "pass to CTSGo"──▶ FALLBACK(supplier_request)
OFFERED ──link revoked──▶ NO_OFFER [outcome=revoked, riderDeadlineAt=now+M]
FALLBACK = confirmed/ctsgo_driver, offer cleared; an ordinary CTSGo order from here on
driverAssigned|atStation ──admin release──▶ FALLBACK(admin_release); the rider is freed and can't retake it
driverAssigned → atStation → (supplier hand-over) outForDelivery → (customer's code) delivered    [existing path]
any state before delivered ──cancel──▶ cancelled (§3.8)
```

- **M** is `settings/gas_supplier_fulfilment.riderAcceptMinutes`: a whole number from 1 to 60, defaulting to 5. Each offer stores its own `expiresAt`.
- **Acceptance** checks `expiresAt` inside its own transaction. The sweep acts only at or after `expiresAt`, so the two cannot both succeed.
- **Eligibility** is checked at both assignment and acceptance:
  - an active link to this supplier;
  - every `driverRejection("gas")` check (approved, online and available, not on a job, delivery role, suitable vehicle, valid location, within 10 km of the customer);
  - **`lastLocationUpdate` no older than `LINKED_RIDER_LOCATION_MAX_AGE_MS`** (R1, default 10 min), otherwise `driver_location_stale`.
- **Revoking a link** does not affect an accepted job. The rider finishes it and earns the fee, unless an admin releases it.

## 3. Backend (`functions/`)

### 3.1 New `gas_supplier_riders.js` (super admin, not gated)

| Callable | Request | Response | Refusals |
| --- | --- | --- | --- |
| `adminLinkGasSupplierRider` | `{supplierId, driverId}` | `{driverId, supplierId, status:"active", version}` | `not_super_admin`, `supplier_not_found`, `driver_not_found`, `driver_wrong_role`, `driver_not_approved`, `admin_cannot_be_rider`, `supplier_member_cannot_be_rider`, `rider_linked_to_other_supplier` |
| `adminRevokeGasSupplierRider` | `{driverId, reason}` | `{driverId, status:"revoked", version, voidedOrderId}` | `reason_required`, `rider_not_found`, `already_revoked` |
| `adminListGasSupplierRiders` | `{supplierId}` | `{riders:[{driverId,name,vehicle,status,version,linkedAt,linkedBy,revokedAt,revokeReason}], audit:[≤50]}` | `not_super_admin` |

- **Records:**
  - `gas_supplier_riders/{driverUid}` (one supplier per driver) holds `{driverId, supplierId, status, version, linkedBy, linkedAt, revokedBy?, revokedAt?, revokeReason?}`.
  - `gas_supplier_rider_audit/{auto}` is append-only and written in the same transaction.
- **Revoking** clears the rider's pending offer in the same transaction.

### 3.2 `gas_supplier_fulfilment.js`: assignment callables

All of these are gated. "Member" means `requireSupplierMember`.

| Callable | Request → Response | Rules |
| --- | --- | --- |
| `supplierRespondGasOrder` (changed) | `deliveryMode` may be `linked_rider` | Only for `supplier_riders_ctsgo_fallback` suppliers. Needs at least one active link (`no_linked_riders`). Initialises the §2.1 fields. |
| `supplierListGasRiders` (new) | `{orderId?}` → `{riders:[{riderId,name,vehicle,eligible,reason}], deliveryFeePesewas?}` | Returns only the caller's supplier's active links. Never returns phone, plate, location, distance, rating or earnings. With `orderId`: `reason` is a `driverRejection` code, `driver_location_stale`, `declined_this_order`, `released_from_job` or `has_pending_offer`, and the order's fee is returned so the supplier sees it before assigning. |
| `supplierAssignGasRider` (new) | `{orderId, riderId, replacesSeq}` → `{orderId, offerSeq, expiresAtMs}` | In one transaction: the order is the caller's, `confirmed`, `linked_rider`, with no `driverId`. A retry of the same offer returns it; otherwise `replacesSeq ≠ riderOfferSeq` is refused as `offer_changed`. Then: not declined, not released, link active for this supplier (`rider_not_linked`), eligibility (§2.2), and no other pending offer for this rider (a transactional query). Writes `riderOffer` with `deliveryFeePesewas = allocation.driverNetPesewas`. |
| `acceptGasSupplierJob` (changed) | `{orderId, offerSeq?}` | `linked_rider` branch: refused with `job_taken` (not the named rider), `offer_stale`, `offer_expired`, `rider_not_linked`, `released_from_job`, an eligibility code, or `rider_fee_changed` (`riderOffer.deliveryFeePesewas ≠ allocation.driverNetPesewas`). Writes as today, plus `linkedSupplierId` and `acceptedFeePesewas`. The existing branch refuses `linked_rider` with `job_taken`. |
| `declineGasSupplierRiderOffer` (new) | `{orderId, offerSeq}` → `{orderId, status, fallback:boolean}` | Named rider only. A repeat is idempotent. Otherwise `offer_not_found` or `offer_stale`. The third decline falls back in the same transaction. |
| `listGasSupplierJobs` (changed) | → `{jobs, offers, serverNowMs}` | `jobs` excludes `linked_rider`. `offers` is the caller's unexpired offers: `jobView` plus `{offerSeq, expiresAtMs, deliveryFeePesewas, feePaidBy:"ctsgo"}`. |
| `supplierRequestGasDriver` (changed) | | Also allowed on `linked_rider` orders with no `driverId` (reason `supplier_request`). |
| `listMyGasSupplierEarnings` (new) | → `{earnings:[{orderId, amountPesewas, status, deliveredAtMs, eligibleFromMs, creditedAtMs, linkedSupplierName}]}` | The caller's own `driver` entries only. `status` is `pending`, `owed`, `credited_to_wallet`, `reversed` or `outstanding_adjustment` (§3.7). Never returns commission, supplier amounts or the customer total. |

Other changes in this file:
- `expireRiderOffers({now})` is called from the existing every-minute schedule. It runs one transaction per order and runs even while switched off.
- `cancel` and `adminReleaseDriver` follow §3.8 and §2.2.

### 3.3 Notifications (`notifications.js`)

A new trigger, `onGasSupplierRiderOfferChanged` (an `onDocumentUpdated` on `gas_supplier_orders/{orderId}`), sends:
- `GAS_SUPPLIER_RIDER_OFFER` to the offered rider;
- `GAS_SUPPLIER_RIDER_OFFER_ENDED` to that rider when the offer is withdrawn, times out, is cancelled or is revoked.

How it stays safe:
- The inbox doc ID is `gas_rider_offer_{orderId}_{seq}_{kind}`, written with `create`. If that doc already exists, no push is sent.
- Before an offer push, the trigger re-reads the order and sends only if the offer is still current.
- The FCM tag and collapse ID are `gsro_{orderId}`.
- The payload carries only `{type, orderId}`, and dead tokens are cleaned up.
- A push never authorises anything.
- There is no push to CTSGo drivers on fallback (D7).

### 3.4 Financial model

Allocation, unchanged; amounts are in pesewas and fixed when the order is created:

```
customerTotal = product + handling + delivery
commission    = floor(product × rateBps / 10000)        // product only; terms must say handling/delivery not commissionable
supplierNet   = product + handling − commission
driverNet     = delivery                                // the rider's fee for linked_rider (F1)
supplierNet + driverNet + commission == customerTotal
```

Entries posted at delivery (deterministic IDs, one transaction):

| Mode | Supplier | Delivery | CTSGo |
| --- | --- | --- | --- |
| `ctsgo_driver` | `{o}__supplier__entitlement` = supplierNet | `{o}__driver__entitlement` → CTSGo driver | `{o}__platform__commission` |
| **`linked_rider`** | `{o}__supplier__entitlement` = supplierNet | **`{o}__driver__entitlement` → linked rider** | `{o}__platform__commission` |
| `supplier_rider` | `{o}__supplier__entitlement` = supplierNet | `{o}__supplier__delivery_fee` → supplier | `{o}__platform__commission` |

Changes to `gas_settlement_ledger.js`:
- **`postingProblem`** checks an explicit mode allowlist:
  - `supplier_rider` must have no `driverId`.
  - `ctsgo_driver` and `linked_rider` must have a `driverId`.
  - `linked_rider` must also have `linkedSupplierId == supplierId` and `acceptedFeePesewas == allocation.driverNetPesewas`.
  - Anything else is `order_delivery_mode_unknown`. The fee check runs in `postOrderEntitlements`, which reads the allocation.
- **`basis`** gains `deliveryMode`, plus `linkedSupplierId` on the rider's entry. These are audit fields only; amounts don't change.

### 3.5 Exactly-once keys

| Item | Key |
| --- | --- |
| Capture | escrow HELD→CAPTURED and `ledger/capture_{escrowId}` |
| Rider fee, supplier proceeds, commission | `gas_settlement_ledger/{orderId}__driver__entitlement`, `__supplier__entitlement`, `__platform__commission` |
| Reversals | `{orderId}__{driver\|supplier\|supplier_delivery\|platform}__reversal` |
| Statement line | `gas_settlement_claims/{entryId}` (statement lines and held reversals, §3.6) |
| **Outstanding debt (new)** | `gas_settlement_debts/{reversalEntryId}` |
| Statement | `gas_settlement_statements/{date}__{party}__{partyId}` |
| Wallet credit | `ledger/gas_driver_settlement_{statementId}` |
| Supplier payout | `payments/{transactionId}` (one per attempt, with an `attemptId`) and `ledger/gas_supplier_payout_{statementId}` |
| Withdrawal | `withdrawals/{id}` (an `attemptId` per attempt). After a confirmed failure, a retry is a **new withdrawal**. |
| Debt resolution | the `version` on `gas_settlement_debts/{id}`, plus an `audit_log` entry |

### 3.6 Settled-entry reversals (F3), applying to every party and mode

**Rule:** a reversal must never disappear, and must never be deducted automatically from later earnings.

- **`reverseOrderEntitlements`**, in its existing transaction, also reads the claim for each original entry (and the claiming statement, if there is one).
  - **Original not claimed:** behaviour is unchanged. The reversal and the original are claimed together in the next statement and net to 0.
  - **Original claimed:** the transaction also:
    - creates `gas_settlement_claims/{reversalId}` as `{entryId, debtId, claimedAt}` with no `statementId`, so automatic statements skip it;
    - creates `gas_settlement_debts/{reversalId}`;
    - creates the admin alert `gas_settlement_debt_{reversalId}`, with severity high.

  The debt document:

  ```
  { debtId, party, partyId, orderId, reversalEntryId, originalEntryId, statementId,
    amountPesewas: |reversal|, stage: "before_payout"|"after_payout",
    status: "outstanding"|"resolution_proposed"|"resolved", proposal?, rejectedProposals?, resolution?, reason?, evidence?,
    resolvedBy?, approvedBy?, resolvedAt?, version, createdAt }
  ```

  `stage` is `before_payout` when the claiming statement's `payoutStatus` is `not_started` (or `failed` for a supplier). Otherwise it is `after_payout`, because money may already have moved.
- **`prepareStatements`** adds a safety check: it never creates a statement whose net is below 0. Such a group is left out and raises the alert `gas_settlement_negative_statement`. This should never happen while §3.6 holds.
- **`entryStatus`**, and its portal copy, return `outstanding_adjustment` for a reversal whose claim has a `debtId` and whose debt is outstanding. Once the debt is resolved, they return `resolved_adjustment`.
- **New callable `adminResolveGasSettlementDebt({debtId, resolution, reason, evidence, expectedVersion})`**, in `gas_settlement_ledger.js`. It runs as a super admin, in one transaction, and requires `status == outstanding` and a matching `version`.

  | Stage | Allowed resolutions | Effect |
  | --- | --- | --- |
  | `before_payout` | `withhold` | The statement's `withheldPesewas` increases by the amount, and `payablePesewas = netPesewas − withheldPesewas`. The statement's `netPesewas` and lines are never edited. |
  | `before_payout` | `pay_in_full` | Nothing is withheld; CTSGo absorbs the amount. |
  | `after_payout` | `written_off` | CTSGo absorbs the amount. Requires evidence. |
  | `after_payout` | `recovered_externally` | The party repaid outside the platform. Requires evidence. |

  - Each resolution writes an `audit_log` entry `gas_settlement_debt_resolved`.
  - There is **no offset against future entitlements**; that would be a clawback, and it needs its own approved rule (R3).
  - Who may resolve a debt (R2, recommended and planned): one super admin can resolve a `before_payout` debt. An `after_payout` debt is **proposed** by one super admin and **approved or rejected by a different super admin**, as commission terms already work. While a resolution is proposed, the debt still blocks nothing that is already paid, and it stays visible.

### 3.7 Payout changes (`gas_supplier_payouts.js`)

- **Before money moves.** `settleDriverStatement` and `approveSupplierPayout` refuse with **`statement_has_outstanding_debt`** while any `before_payout` debt for this statement is outstanding. The check is a transactional query on `gas_settlement_debts` (`statementId ==`, `status == outstanding`).
- **Server-side reconciliation, inside the same transaction:**
  - the sum of `lines` must equal `netPesewas` (`statement_lines_mismatch`);
  - every line's claim must name this statement (`statement_claims_mismatch`);
  - there must be at least one line.
- **Amount paid or credited.** Both use `payablePesewas ?? netPesewas`, which must be greater than 0. If `payablePesewas == 0` after withholding, the statement is marked `payoutStatus: "not_required"` instead of being paid.
- **Driver credit status.** The stored values stay as they are today: `payoutStatus: "paid"` with `payoutMethod: "driver_wallet"`. This avoids a data migration and keeps the existing tests valid.
  - Every reader derives **`credited_to_wallet`** from `party == "driver"` together with `payoutMethod == "driver_wallet"`. The readers are `entryStatus` (ledger and portal parity copy), the admin labels and `listMyGasSupplierEarnings`.
  - No reader may show a driver statement as a payout or as "paid".
  - `payoutProblem` for drivers keeps allowing only `not_started`.
- **Withdrawals** are unchanged (`withdrawal_approval.js`, `bridge.js`).

### 3.8 Cancellation and the rider (F4, F5)

| Stage when cancelled | Who may cancel | Customer | Rider | Ledger | Operational |
| --- | --- | --- | --- | --- | --- |
| No offer, or offer pending | Passenger, or an admin with a reason | Full refund (existing `settleRefund`) | Offer withdrawn; the rider is notified | Nothing posted | — |
| `driverAssigned` / `atStation` | Admin only | Full refund | Freed. **No entitlement** (F4) | Nothing posted | — |
| `outForDelivery` (handed over) | Admin only | Full refund | Freed. **No entitlement** (F4) | Nothing posted | **New:** the cancel transaction writes the admin alert `gas_cylinder_recovery_{orderId}` (type `gas_cylinder_recovery_required`, severity high, `orderId`, `supplierId`, `driverId`, `deliveryMode`). It appears on the admin order page and in alerts. Recovering the cylinder is an offline procedure (F5). |
| `delivered` | No one (existing) | No refund (existing) | The fee is earned and posted | Posted once | — |
| After posting | Super-admin reversal only, with a reason; **it never refunds** | — | Before a statement: it nets to 0. After the line is claimed: an outstanding debt (§3.6). **Never deducted automatically.** | Reversal entry, plus a debt record | Alert |

Nothing ever reverses an earned entitlement automatically. Cancelling a delivered order is impossible, so a cancellation can't touch an entitlement.

### 3.9 Rules (`firestore.rules`, gas section)

- `gas_supplier_riders`, `gas_supplier_rider_audit` and `gas_settlement_debts`: no client reads or writes. Admins see riders and debts through callables. **Exception:** `gas_settlement_debts` gets `allow read: if isAdmin()`, so the admin settlement page can list debts as it already lists the ledger.
- In `gasSwitchOk`, `riderAcceptMinutes` must be an integer from 1 to 60 when present.
- The same blocks are mirrored in `ctsgo-gas-supplier-portal/rules-candidate/portal-collections.rules`.
- The existing ledger, claims and statements rules stay as they are.

### 3.10 Portal staff API

`link` and `provision` refuse a uid that has an active `gas_supplier_riders` doc, with `rider_cannot_be_member` (409).

## 4. Supplier portal

- **Orders page.**
  - It polls every 20 s while visible and keeps the last data when a poll fails. A banner announces new orders.
  - The accept options are linked rider, my rider (offline) and CTSGo driver.
  - The `linked_rider` confirmation reads: "CTSGo pays the rider the delivery fee of GH₵x.xx directly. Your proceeds are the product and handling amounts less commission."
  - The rider picker shows eligible riders and greys out ineligible ones with a plain-language reason.
  - The order shows its states: pending with a countdown, declined then choose another, accepted, and CTSGo takeover with its reason.
  - Every assignment sends `replacesSeq`; `offer_changed` reloads.
- **Earnings (F6, a separate task).**
  - `ENTRY_ID` accepts `__supplier__(entitlement|delivery_fee|reversal)` and `__supplier_delivery__reversal`.
  - Debt-held reversals are shown as "Outstanding adjustment".
  - The page's existing check that statement lines add up to the statement net now passes for offline-rider statements.
  - `entryStatus` parity covers `outstanding_adjustment`, `resolved_adjustment` and `credited_to_wallet`. Credited-to-wallet only applies to drivers, but parity keeps both copies identical.

## 5. Driver app

- **Offer card.**
  - It shows the station, the customer's address, the item, **"Delivery fee GH₵x.xx · paid by CTSGo"** and a countdown corrected for clock skew.
  - It has Accept and Decline buttons; Decline asks for confirmation.
  - Once expired, the card is disabled.
  - Each refusal shows its own message.
- **Accepting.** Accept first takes a fresh position and writes it to the driver profile. It uses the existing `LocationSource.currentPosition()` and `JobLocationStore.writeProfileLocation(uid, position)`. If there is no fix, accepting is blocked with "Turn on location to accept". Accept then opens the existing `GasSupplierActiveJobScreen`.
- **Fee wording.** "You earn this fee when the customer confirms delivery with their code. After CTSGo's settlement hold, CTSGo credits it to your CTSGo wallet. You can then request a withdrawal. Money is paid out only when CTSGo confirms the transfer. Any commission you owe from cash jobs is deducted when you withdraw."
- **Gas earnings list** (`listMyGasSupplierEarnings`).
  - Each row is labelled **Earned · pending**, **Owed**, **Credited to wallet {date}**, **Reversed** or **Under review** (`outstanding_adjustment`).
  - The four money stages never share a label: *earned* (the entitlement), *credited to wallet*, *withdrawal requested* (the existing withdrawal screens) and *paid out* (only `completed`, which an admin confirms with Bridge).
- **Pushes.** The two new push types open the new `/gas-supplier-jobs` named route.

## 6. Admin app

- **`SupplierRiders` panel** on the supplier page: list, link, revoke with a reason, and the audit trail.
- **Settlement labels.**
  - `payoutStatusLabel(status, party, method)`: driver statements read **"Credited to CTSGo wallet"**, never "Payout completed".
  - `settlementStage` returns `credited_to_wallet` for driver lines.
  - New labels: `not_required`, `outstanding_adjustment` and `statement_has_outstanding_debt`.
- **Driver settlement.** One row per driver with these columns:
  - **Earned, pending**
  - **Owed**
  - **Credited to wallet**
  - **Withdrawal requested** (`pending`)
  - **Sent, awaiting confirmation** (`processing`/`sent`)
  - **Outcome unknown, unresolved** (`processing`/`unknown`)
  - **Paid out (confirmed)** (`completed`)
  - **Failed** (`failed`, hold returned)
  - **Outstanding adjustments**

  The withdrawal columns are per driver, because the wallet is pooled. A linked rider is tagged with their supplier.
- **Debts panel.** Lists outstanding and resolved debts and offers the allowed resolutions (§3.6), each with a reason and evidence. Every debt raises an alert.
- **Reconciliation.**
  - Per order: the parts add up to the total, which equals the captured amount, and the delivery party matches the mode. A `linked_rider` order has no supplier `delivery_fee`.
  - Per party:
    - entries net of reversals = credited + owed + outstanding debts + resolved write-offs;
    - credited = the sum of the `gas_driver_settlement_*` ledger rows.
- **Orders.** The order page shows the mode label, the offer history, the fallback reason and the cylinder-recovery alert.

## 7. Tests

See the plan. Every financial invariant above has a named test.

## 8. Decisions

| | Decision |
| --- | --- |
| D1 | CTSGo pays linked riders directly. |
| F1 | The rider's fee is the order's delivery fee, shown before assignment and fixed for the order. |
| F2 | Wallet credit, then the existing withdrawal flow. The four stages are kept distinct everywhere. |
| F3 | A debt is preserved, raises an alert and needs an explicit, audited resolution. It is never hidden and never deducted automatically. |
| F4 | No compensation for cancellation after acceptance or hand-over, and no automatic reversal of an earned fee. |
| F5 | Recovery itself is out of scope. Cancelling after hand-over raises a recovery alert. |
| F6 | A narrow fix to the portal filter, with tests that the lines reconcile with the statement. |
| F7 | Wallet credit stays a super-admin-only action, with server-side reconciliation added and no new switch. |
| D3 | A deadline when no offer is pending: M minutes. |
| D4 | Three declines, then fallback. |
| D5 | An admin release goes to CTSGo dispatch. |
| D6 | A revoke doesn't end an accepted job; the rider earns the fee unless an admin releases it. |
| D7 | No push to CTSGo drivers on fallback. |
| D8 | The 10 km check at both offer and acceptance, refusing a missing or stale location. |

## 9. Open decisions and blockers

| # | Item | Recommendation |
| --- | --- | --- |
| R1 | The maximum location age for linked riders. | 10 minutes, with the fresh fix the app takes on accept. |
| R2 | Who may resolve a settlement debt. | One super admin with a reason for `before_payout`. **Two different super admins** (one proposes, the other approves) for `written_off` and `recovered_externally`, as commission terms already work. |
| R3 | Offsetting a debt against future entitlements. | Not in this implementation. It is a clawback and needs its own approved rule. |
| R4 → **B4 (release blocker)** | `approveWithdrawal`, `rejectWithdrawal` and `resolveUnconfirmedPayout` accept **any active admin** (`admins/{uid}.active == true`, role not checked; `withdrawal_approval.js:256-268, 312-322, 386-389`, `admin_auth.js`). Roles in use: `admin` and `super_admin` (`ctsride-admin/src/types/index.ts:3`). A linked rider's fee reaches cash only through these callables. | Change separately, under its own approval: limit all three to super admins, or define an approved payments-operator role. Until then, **this feature must not be released.** |
| **B5 (critical, live, release blocker)** | `firestore.rules` `match /admins/{uid} { allow write: if isAdmin(); }` lets any active admin **set their own `role` to `super_admin`, or create a new super admin**. Proven on the emulator on 2026-10-29 with a scratch probe against both the working copy and `release-20261028/live-artifacts/firestore.rules.b40605f3` (both ALLOWED). The deployed stage-3a rules contain the same block. Every super-admin control depends on this rule: commission terms (two-person), payouts, debt resolution (two-person), rider links, and the gas switches. | A separate security fix that needs owner approval: deny client writes to `admins` (or allow them only to super admins, never on their own document, and never granting a role above their own), plus rules tests. Also needed before release: an audit of the current `admins` documents. |
| R5 | Show suppliers their own outstanding adjustments in the portal? | Yes, read-only: "Outstanding adjustment · CTSGo will contact you". |
| B1 | Production data: before F3 ships, check whether any `prepared_no_payout` statement already absorbed a debt. | A read-only query in the release checklist. Gas fulfilment is switched off, so none is expected. |
| B2 | The Firebase CLI is not installed locally. Emulator tests run with the Java 21 Firestore emulator started by hand (see the plan). | — |
| B3 | `lib/features/gas_supplier_jobs/` and `lib/core/services/location/` in the driver repo, and most Gas files in the passenger repo, are **untracked**. A commit later must stage only the files in the plan. | — |

### 10.1 Release checklist (added 2026-10-29 after implementation; nothing here is done)
1. Audit the production `admins` docs. Every intended approver needs `role: "super_admin"`, and nobody else may have it. Then deploy the B5 rules (admins) and B4 (super-admin withdrawal callables; no client writes to withdrawals) together.
2. Rules artifact: deploy P/firestore.rules directly, or patch build.py to carry the withdrawals and gas-switch (`settings`) blocks, rebuild both portal candidates, and run `rules:verify`. The current candidates leave `settings` writable by any admin.
3. Owner decision on B6 and I4: admin client writes to `wallets` and to driver money fields (`drivers/{id}` update is `isAdmin()` with no field limit).
4. I6: rider withdrawals cannot be approved today. `approveWithdrawal` and `rejectWithdrawal` are undeployed and have no admin UI. Ship that path, or document the offline process.
5. Deploy the indexes before the functions (firestore.indexes.json: `gas_settlement_debts`, `gas_supplier_orders` riderOffer.driverId + status and status + deliveryMode, `gas_supplier_riders`).
6. Deploy all of these functions together, as named functions:
   - `supplierListGasRiders`, `supplierAssignGasRider`, `declineGasSupplierRiderOffer`, `listMyGasSupplierEarnings`
   - `adminLinkGasSupplierRider`, `adminRevokeGasSupplierRider`, `adminListGasSupplierRiders`, `adminResolveGasSettlementDebt`
   - `onGasSupplierRiderOfferChanged`
   - `acceptGasSupplierJob`, `listGasSupplierJobs`, `supplierRespondGasOrder`, `supplierRequestGasDriver`, `cancelGasSupplierOrder`, `adminCancelGasSupplierOrder`, `adminReleaseGasSupplierDriver`, `expireUnansweredGasSupplierOrders`
   - `adminReverseGasSupplierEntitlements`, `adminPrepareGasSettlementStatements`, `prepareDailyGasSettlementStatements`, `adminSettleGasDriverStatement`, `adminApproveGasSupplierPayout`, `adminResolveGasSupplierPayout`
   - `approveWithdrawal`, `rejectWithdrawal`, `resolveUnconfirmedPayout`
7. Read-only production checks:
   - B1: `prepared_no_payout` statements with a negative line.
   - The count of `gas_supplier_orders` without `deliveryMode`, since posting now refuses them.
8. `settings/gas_supplier_fulfilment.enabled` and `settings/gas_supplier_payouts.enabled` stay off until the owner gives the go-ahead.
