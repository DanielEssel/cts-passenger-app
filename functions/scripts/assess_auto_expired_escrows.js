// Read-only historical impact assessment for the escrow auto-refund defect.
//
// Before the fix, the hourly releaseStuckEscrows job refunded every HELD
// escrow older than two hours with releaseReason "auto_expired", even when
// its order was still in progress. If that order was later completed:
//   • Gas:      onGasOrderCompleted found the escrow not HELD, released
//               nothing, and still marked the order walletProcessed with
//               driverEarnings written: the driver was not paid.
//   • Delivery: onDeliveryCompleted threw "was refunded and cannot settle
//               delivery" and set settlementStatus "failed".
//
// This script only READS. It never writes to Firestore, adjusts wallets,
// creates ledger entries, refunds customers or pays drivers. It lists the
// escrows that may be affected and the evidence a person must check.
//
// Usage (local emulator, the default and only unflagged mode):
//   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 node scripts/assess_auto_expired_escrows.js
//
// A remote project needs explicit flags; production needs a separate one,
// to be used only with written authorisation:
//   node scripts/assess_auto_expired_escrows.js --project <id> --allow-remote-read
//   ... --project ctstransportapp --allow-remote-read --production-read-authorized

"use strict";

const PRODUCTION_PROJECT = "ctstransportapp";

const ORDER_COLLECTION_BY_REFERENCE = {
  delivery: "deliveries",
  gas_order: "gas_orders",
};
const IN_SCOPE = Object.values(ORDER_COLLECTION_BY_REFERENCE);
const SETTLED_STATUS = { deliveries: "completed", gas_orders: "delivered" };

/** Evidence a person must review for each potentially affected order. */
const EVIDENCE_CHECKLIST = [
  "Order document: status history, completion time (deliveredAt / completedAt), driverId, paymentMethod, totalPrice / estimatedFare, otpSubmitted.",
  "Escrow document: amount, driverNet, platformFee, heldAt, releasedAt and releaseReason \"auto_expired\".",
  "Ledger: the REFUND entry refund_<escrowId> (amount returned to the customer) and the absence of CAPTURE capture_<escrowId>.",
  "Customer wallet: that the refunded amount was credited and not later deducted again for this order.",
  "Driver earnings: drivers/<driverId> and earnings/summary show no credit for this order around its completion time.",
  "Any manual admin adjustment, support ticket or payout already made for this order (to avoid paying twice).",
  "Delivery confirmation: OTP submission or customer confirmation showing the service was actually delivered.",
];

const toDate = (v) => (v && typeof v.toDate === "function" ? v.toDate() : null);
const iso = (d) => (d ? d.toISOString() : null);

async function ledgerByKey(db, key) {
  const q = await db.collection("ledger").where("idempotencyKey", "==", key).get();
  return q.docs.map((d) => ({ id: d.id, type: d.data().type, amount: d.data().amount,
    processedAt: iso(toDate(d.data().processedAt) ?? toDate(d.data().createdAt)) }));
}

async function findOrder(db, escrowId, escrow) {
  const collection = ORDER_COLLECTION_BY_REFERENCE[escrow.referenceType];
  if (collection && escrow.referenceId) {
    const snap = await db.collection(collection).doc(escrow.referenceId).get();
    if (snap.exists) return { collection, id: snap.id, data: snap.data() };
  }
  for (const c of IN_SCOPE) {
    const q = await db.collection(c).where("escrowId", "==", escrowId).limit(1).get();
    if (!q.empty) return { collection: c, id: q.docs[0].id, data: q.docs[0].data() };
  }
  return null;
}

/**
 * Classifies one auto-expired escrow. Pure.
 * @returns {"likely_affected"|"needs_manual_check"|"not_affected"}
 */
function classify({ settled, captureCount, refundedAt, completedAt }) {
  if (!settled) return "not_affected";
  if (captureCount > 0) return "needs_manual_check"; // refunded and captured?
  if (!refundedAt || !completedAt) return "needs_manual_check";
  return refundedAt < completedAt ? "likely_affected" : "needs_manual_check";
}

/** Reads and assesses every escrow refunded with reason "auto_expired". */
async function assessAutoExpiredEscrows(db) {
  const escrows = await db.collection("escrows")
    .where("releaseReason", "==", "auto_expired").get();

  const findings = [];
  const counts = { total: escrows.size, outOfScope: 0, orderMissing: 0,
    not_affected: 0, likely_affected: 0, needs_manual_check: 0 };

  for (const doc of escrows.docs) {
    const e = doc.data();
    if (e.referenceType && !ORDER_COLLECTION_BY_REFERENCE[e.referenceType]) {
      counts.outOfScope++; // e.g. rides: not part of this assessment
      continue;
    }
    const order = await findOrder(db, doc.id, e);
    if (!order) {
      counts.orderMissing++;
      continue;
    }
    const o = order.data;
    const settled = o.status === SETTLED_STATUS[order.collection];
    const completedAt = toDate(o.deliveredAt) ?? toDate(o.completedAt) ??
      toDate(o.settlementCompletedAt) ?? toDate(o.walletProcessedAt);
    const refundedAt = toDate(e.releasedAt);
    const refunds = await ledgerByKey(db, `refund_${doc.id}`);
    const captures = await ledgerByKey(db, `capture_${doc.id}`);
    const classification = classify({
      settled, captureCount: captures.length, refundedAt, completedAt,
    });
    counts[classification]++;
    if (classification === "not_affected") continue;

    findings.push({
      classification,
      escrowId: doc.id,
      orderCollection: order.collection,
      orderId: order.id,
      orderStatus: o.status,
      passengerId: e.userId ?? o.passengerId ?? null,
      driverId: o.driverId ?? null,
      paymentMethod: o.paymentMethod ?? null,
      escrowAmount: e.amount ?? null,
      escrowDriverNet: e.driverNet ?? null,
      heldAt: iso(toDate(e.heldAt)),
      refundedAt: iso(refundedAt),
      completedAt: iso(completedAt),
      refundLedger: refunds,
      captureLedger: captures,
      // How each completion handler left the order:
      signals: {
        walletProcessed: o.walletProcessed ?? null,
        recordedDriverEarnings: o.driverEarnings ?? null,
        settlementStatus: o.settlementStatus ?? null,
        walletProcessError: o.walletProcessError ?? null,
      },
    });
  }

  return {
    generatedAt: new Date().toISOString(),
    readOnly: true,
    scope: "escrows with releaseReason \"auto_expired\" whose Gas or Delivery order reached delivered/completed",
    counts,
    evidenceChecklist: EVIDENCE_CHECKLIST,
    findings,
  };
}

/** Refuses anything but the emulator unless explicitly allowed. */
function resolveTarget(argv, env) {
  const flag = (n) => argv.includes(n);
  const pIdx = argv.indexOf("--project");
  const project = pIdx >= 0 ? argv[pIdx + 1] : undefined;

  if (env.FIRESTORE_EMULATOR_HOST) {
    return { projectId: project || env.GCLOUD_PROJECT || "demo-ctsgo-payments", remote: false };
  }
  if (!project) throw new Error("No emulator: pass --project <id> --allow-remote-read for a remote read.");
  if (!flag("--allow-remote-read")) throw new Error("Remote reads need --allow-remote-read.");
  if (project === PRODUCTION_PROJECT && !flag("--production-read-authorized")) {
    throw new Error("Production reads need written authorisation and --production-read-authorized.");
  }
  return { projectId: project, remote: true };
}

async function main() {
  const { projectId } = resolveTarget(process.argv.slice(2), process.env);
  const admin = require("firebase-admin");
  if (!admin.apps.length) admin.initializeApp({ projectId });
  const report = await assessAutoExpiredEscrows(admin.firestore());
  process.stdout.write(JSON.stringify(report, null, 2) + "\n");
}

module.exports = { assessAutoExpiredEscrows, classify, resolveTarget, EVIDENCE_CHECKLIST };

if (require.main === module) {
  main().catch((e) => {
    console.error(e.message);
    process.exit(1);
  });
}
