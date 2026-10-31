# Escrow auto-refund defect: historical impact assessment

**Status:** prepared, not run against any live data. Read-only. Nothing in this procedure adjusts wallets, creates ledger entries, refunds customers or pays drivers.

## What went wrong

Until the fix in `escrow.js`, the hourly `releaseStuckEscrows` job refunded **every** wallet escrow still `HELD` two hours after it was created. It recorded `releaseReason: "auto_expired"` and did not check whether the order was still in progress. Gas Pickup & Return orders are estimated at 2 h 30 m, so they were the most exposed. Any order that waited a long time for a driver was also at risk.

If such an order was later completed:

| Service | What the completion handler did | Trace it left on the order |
|---|---|---|
| Gas | Found the escrow not `HELD`, released nothing, but still marked the order processed. | `walletProcessed: true` and `driverEarnings` written; **no** `capture_<escrowId>` ledger entry |
| Delivery | Stopped with an error. | `settlementStatus: "failed"`, `walletProcessError` mentioning "was refunded and cannot settle delivery" |

In both cases the customer got their money back and the driver was not paid for a completed job.

## Running the assessment

The script `scripts/assess_auto_expired_escrows.js` only reads. It refuses to run anywhere except the local emulator unless given explicit flags. Production needs a separate flag, which should be used only with written authorisation.

```bash
# Remote read (staging or production) — only with authorisation:
node scripts/assess_auto_expired_escrows.js --project <project-id> --allow-remote-read
node scripts/assess_auto_expired_escrows.js --project ctstransportapp \
  --allow-remote-read --production-read-authorized > assessment.json
```

It prints a JSON report:

- **`counts`:** the escrows found and how each was classified.
- **`findings`:** one entry per order that needs attention. Each entry has the escrow and order ids, passenger and driver ids, the amounts, the hold / refund / completion times, the ledger entries found, and the completion trace from the table above.
- **`evidenceChecklist`:** the checks listed below.

**What each classification means:**
- **`likely_affected`:** the order reached `delivered` (Gas) or `completed` (Delivery) after the escrow was refunded, and no capture exists.
- **`needs_manual_check`:** the order completed, but a capture also exists, a timestamp is missing, or the refund came after completion.
- **Not listed:** the order never completed (refund correct), the order is missing, or it's a ride (out of scope).

## Evidence to verify for each listed order

Confirm all of these before deciding on any correction:

1. **Order document:**
   - status history and completion time (`deliveredAt` / `completedAt`)
   - `driverId`, `paymentMethod`
   - `totalPrice` / `estimatedFare`
   - `otpSubmitted`
2. **Escrow document:** `amount`, `driverNet`, `platformFee`, `heldAt`, `releasedAt`, `releaseReason: "auto_expired"`.
3. **Ledger:** the `REFUND` entry `refund_<escrowId>` exists, and **no** `CAPTURE` entry `capture_<escrowId>` exists.
4. **Customer wallet:** the refund was credited, and no later deduction was made for this order.
5. **Driver earnings:** `drivers/<driverId>` and `drivers/<driverId>/earnings/summary` show no credit for this order around its completion time.
6. **Earlier corrections:** any manual admin adjustment, support ticket or payout already made for this order, so the driver is not paid twice.
7. **Proof of delivery:** OTP submission or customer confirmation that the service actually happened.

## Decisions this does not make

The fair outcome for each order is a business decision for finance or operations, made with the evidence above. For example: pay the driver from platform funds, or charge the customer again with their consent. No correction should be applied automatically. Each correction should be a separately reviewed operation with its own ledger record.

## Limitations

- Escrows refunded before the `auto_expired` reason existed, or refunded under a different reason, are not found.
- A Delivery order completed with an earlier version of `onDeliveryCompleted` may leave a different trace. The classification relies on the escrow, ledger and timestamps, not only on the order's trace fields.
- Ride escrows (`referenceType: "trip"`) are counted as out of scope and not analysed.
