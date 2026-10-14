// Alert-only detection of delivery settlements that stopped part-way.
//
// onDeliveryCompleted takes a lock (settlementStatus "processing",
// settlementStartedAt = server time), settles, then marks the delivery
// walletProcessed / "completed". If the function dies after the lock — in
// particular after the escrow was released but before the final update —
// the delivery stays "processing" and nothing else reports it (the escrow
// is no longer HELD, so the escrow recovery job never sees it).
//
// Telling an interrupted settlement from a running one: the handler runs
// with the default event-function timeout (60 s; the platform maximum is
// 540 s) and no retries, and settlementStartedAt is written by the server
// in the same transaction as "processing". A delivery still "processing"
// STUCK_AFTER_MS (30 min) after that time cannot belong to a live run.
//
// This sweep only reads and writes admin alerts. It never changes an
// order, an escrow, a wallet or a driver balance, and never retries a
// settlement: operations decide (see the settlement runbook).

"use strict";

const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

const db = () => admin.firestore();

const STUCK_AFTER_MS = 30 * 60 * 1000;

/**
 * Classifies one delivery found in "processing". Pure.
 * @returns {{stuck: boolean, state: string}}
 */
function classifyProcessingDelivery({ deliveryId, delivery, escrow, now }) {
  if (delivery.walletProcessed === true || delivery.settlementStatus !== "processing") {
    return { stuck: false, state: "not_processing" };
  }
  const startedAt = delivery.settlementStartedAt?.toDate?.() ?? null;
  if (startedAt && now - startedAt.getTime() < STUCK_AFTER_MS) {
    return { stuck: false, state: "may_still_be_running" };
  }
  if (!startedAt) return { stuck: true, state: "processing_without_start_time" };
  if (!delivery.escrowId) return { stuck: true, state: "interrupted_without_escrow" };
  if (!escrow) return { stuck: true, state: "interrupted_escrow_missing" };
  if (escrow.status === "RELEASED" && escrow.referenceId === deliveryId) {
    // Driver already paid from escrow; only the order's bookkeeping is missing.
    return { stuck: true, state: "released_not_recorded" };
  }
  if (escrow.status === "HELD") return { stuck: true, state: "interrupted_before_release" };
  return { stuck: true, state: `interrupted_escrow_${String(escrow.status).toLowerCase()}` };
}

/**
 * One sweep. Alerts each stuck settlement once per lock attempt: the alert
 * id is derived from the delivery and its settlementStartedAt, and is
 * created only if absent. Returns a summary.
 */
async function sweepStuckDeliverySettlements({ now = Date.now() } = {}) {
  // Single-field equality: no composite index needed. The set of
  // deliveries in "processing" at any moment is small.
  const processing = await db().collection("deliveries")
    .where("settlementStatus", "==", "processing").get();

  const summary = { checked: processing.size, stuck: 0, alerted: 0, alreadyAlerted: 0 };
  for (const doc of processing.docs) {
    const delivery = doc.data();
    const escrowSnap = delivery.escrowId
      ? await db().collection("escrows").doc(String(delivery.escrowId)).get()
      : null;
    const escrow = escrowSnap?.exists ? escrowSnap.data() : null;
    const { stuck, state } = classifyProcessingDelivery({
      deliveryId: doc.id, delivery, escrow, now,
    });
    if (!stuck) continue;
    summary.stuck++;

    const startedAt = delivery.settlementStartedAt?.toDate?.() ?? null;
    const alertId = `stuck_settlement_${doc.id}_${startedAt ? startedAt.getTime() : "nostart"}`;
    try {
      // Ids and state only: no personal data.
      await db().collection("admin_alerts").doc(alertId).create({
        type: "delivery_settlement_stuck",
        deliveryId: doc.id,
        escrowId: delivery.escrowId ?? null,
        state,
        settlementStartedAt: delivery.settlementStartedAt ?? null,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      summary.alerted++;
    } catch (e) {
      if (e.code === 6 || /already exists/i.test(e.message ?? "")) {
        summary.alreadyAlerted++;
      } else {
        throw e;
      }
    }
  }
  if (summary.stuck > 0) {
    console.warn(`Stuck delivery settlements: ${summary.stuck} (${summary.alerted} new alerts)`);
  }
  return summary;
}

exports.detectStuckDeliverySettlements = onSchedule(
  { schedule: "every 30 minutes", region: "europe-west2", minInstances: 0 },
  async () => { await sweepStuckDeliverySettlements(); },
);

exports.classifyProcessingDelivery = classifyProcessingDelivery;
exports.sweepStuckDeliverySettlements = sweepStuckDeliverySettlements;
exports.STUCK_AFTER_MS = STUCK_AFTER_MS;
