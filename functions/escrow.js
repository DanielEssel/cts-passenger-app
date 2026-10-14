  "use strict";
  const { onCall, HttpsError, onRequest } = require("firebase-functions/v2/https");
  const { onSchedule }   = require("firebase-functions/v2/scheduler");
  const admin            = require("firebase-admin");
  const crypto           = require("crypto");

  const getDb          = () => admin.firestore();
  const FieldValue     = admin.firestore.FieldValue;
  const { defineSecret } = require("firebase-functions/params");
  const paystackSecret = defineSecret("PAYSTACK_SECRET_KEY");

  function requireAuth(request) {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Sign in required");
    return request.auth.uid;
  }

  async function getPlatformFeePercent() {
    try {
      const snap = await getDb().collection("settings").doc("platform").get();
      const pct = snap.exists ? snap.data()?.platformFeePercent : null;
      return (typeof pct === "number" ? pct : 15) / 100;
    } catch (_) {
      return 0.15; // safe default
    }
  }


  async function writeLedger(tx, entry) {
    const ref = getDb().collection("ledger").doc();
    tx.set(ref, { ...entry, createdAt: FieldValue.serverTimestamp() });
  }

  // ── holdBalance ───────────────────────────────────────────────────────────────
  exports.holdBalance = onCall(
    { region: "europe-west2", minInstances: 0 },
    async (request) => {
    const uid = requireAuth(request);
    const { amount, serviceType, referenceType } = request.data;
    if (!amount || amount <= 0) throw new HttpsError("invalid-argument", "Invalid amount");

    const walletRef = getDb().collection("wallets").doc(uid);
    const escrowRef  = getDb().collection("escrows").doc();
    let escrowId     = escrowRef.id;
    const feePercent = await getPlatformFeePercent();
    await getDb().runTransaction(async (tx) => {
      const wallet = await tx.get(walletRef);
      if (!wallet.exists) throw new HttpsError("failed-precondition", "Wallet not found. Please top up first.");

      const balance = wallet.data().balance ?? 0;
      if (balance < amount) {
        throw new HttpsError("failed-precondition",
          `Insufficient balance. You have GH₵${balance.toFixed(2)}, need GH₵${amount.toFixed(2)}.`,
          { currentBalance: balance, required: amount, shortfall: amount - balance }
        );
      }

      tx.update(walletRef, { balance: FieldValue.increment(-amount), heldBalance: FieldValue.increment(amount), lastUpdatedAt: FieldValue.serverTimestamp() });

      tx.set(escrowRef, {
        id: escrowId, userId: uid, serviceType, referenceType,
        referenceId: null, amount,
        platformFee: Math.round(amount * feePercent * 100) / 100,
        driverNet:   Math.round(amount * (1 - feePercent) * 100) / 100,
        status: "HELD", heldAt: FieldValue.serverTimestamp(),
        releasedAt: null,
        expiresAt: new Date(Date.now() + 2 * 60 * 60 * 1000),
      });

      await writeLedger(tx, {
        type: "HOLD", status: "COMPLETED", fromUserId: uid, fromType: "passenger",
        toType: "escrow", amount, currency: "GHS", platformFee: 0, driverNet: 0,
        referenceType, referenceId: escrowId, idempotencyKey: escrowId,
        processedAt: FieldValue.serverTimestamp(),
      });
    });

    return { success: true, escrowId };
  });

  // ── attachEscrowToOrder ───────────────────────────────────────────────────────
  // Links a HELD escrow to the order it pays for. Called by the passenger
  // app right after creating the order (rides already carry escrowId on the
  // trip; deliveries and gas orders get it in a follow-up update).
  //
  // Nothing from the client is trusted beyond the ids:
  //   • the service type must be one of ESCROW_ORDER_COLLECTIONS;
  //   • the order must exist in that type's collection and belong to the
  //     caller (passengerId), as must the escrow;
  //   • the order's escrowId, if already set, must be this escrow;
  //   • an escrow held for one service (referenceType at hold time) cannot
  //     be attached to another;
  //   • an order can have only one escrow. A server-only link document
  //     (escrowOrderLinks/{type}:{orderId}) is created in the same
  //     transaction, so two attaches racing for one order cannot both win;
  //     escrows attached before this check existed are found by query.
  // Repeating an attach that already happened is accepted (idempotent).
  const ESCROW_ORDER_COLLECTIONS = {
    trip: "trips",
    delivery: "deliveries",
    gas_order: "gas_orders",
  };
  exports.ESCROW_ORDER_COLLECTIONS = ESCROW_ORDER_COLLECTIONS;

  async function attachEscrowForUser(uid, { escrowId, referenceId, referenceType } = {}) {
    if (typeof escrowId !== "string" || !escrowId ||
        typeof referenceId !== "string" || !referenceId) {
      throw new HttpsError("invalid-argument", "escrowId and referenceId required");
    }
    // Own keys only: "toString" / "__proto__" must not resolve to anything.
    const collection = typeof referenceType === "string" &&
      Object.prototype.hasOwnProperty.call(ESCROW_ORDER_COLLECTIONS, referenceType)
      ? ESCROW_ORDER_COLLECTIONS[referenceType]
      : null;
    if (!collection) throw new HttpsError("invalid-argument", "Unsupported referenceType");
    if (referenceId.includes("/")) throw new HttpsError("invalid-argument", "Invalid referenceId");

    const escrowRef = getDb().collection("escrows").doc(escrowId);
    const orderRef  = getDb().collection(collection).doc(referenceId);
    const linkRef   = getDb().collection("escrowOrderLinks").doc(`${referenceType}:${referenceId}`);
    const legacyQuery = getDb().collection("escrows")
      .where("referenceId", "==", referenceId).limit(5);

    return getDb().runTransaction(async (tx) => {
      const [escrow, order, link, legacy] = await Promise.all([
        tx.get(escrowRef), tx.get(orderRef), tx.get(linkRef), tx.get(legacyQuery),
      ]);
      if (!escrow.exists) throw new HttpsError("not-found", "Escrow not found");
      const e = escrow.data();
      if (e.userId !== uid) throw new HttpsError("permission-denied", "Not your escrow");
      if (!order.exists) throw new HttpsError("not-found", "Order not found");
      const o = order.data();
      if (o.passengerId !== uid) throw new HttpsError("permission-denied", "Not your order");

      // Already attached to exactly this order: a retried call.
      if (e.referenceId === referenceId && e.referenceType === referenceType &&
          (!link.exists || link.data().escrowId === escrowId)) {
        return { success: true, alreadyAttached: true };
      }
      if (e.referenceId != null) {
        throw new HttpsError("failed-precondition", "Escrow already attached");
      }
      if (e.status !== "HELD") throw new HttpsError("failed-precondition", "Escrow not active");
      if (e.referenceType != null && e.referenceType !== referenceType) {
        throw new HttpsError("failed-precondition", "Escrow was held for another service");
      }
      if (o.escrowId != null && o.escrowId !== escrowId) {
        throw new HttpsError("failed-precondition", "Order is paid by another escrow");
      }
      if (link.exists && link.data().escrowId !== escrowId) {
        throw new HttpsError("failed-precondition", "Order already has an escrow");
      }
      const otherAttached = legacy.docs.some((d) =>
        d.id !== escrowId && d.data().referenceType === referenceType);
      if (otherAttached) {
        throw new HttpsError("failed-precondition", "Order already has an escrow");
      }

      tx.update(escrowRef, { referenceId, referenceType });
      tx.set(linkRef, {
        escrowId, referenceType, referenceId, userId: uid,
        linkedAt: FieldValue.serverTimestamp(),
      });
      return { success: true };
    });
  }
  exports.attachEscrowForUser = attachEscrowForUser;

  exports.attachEscrowToOrder = onCall(
    { region: "europe-west2", minInstances: 0 },
    async (request) => {
    const uid = requireAuth(request);
    return attachEscrowForUser(uid, request.data ?? {});
  });

  // ── releaseEscrow — used by onTripCompleted CF ────────────────────────────────
  // The HELD check is made inside the transaction, so a release can never run
  // on an escrow that a concurrent refund has already returned (or vice
  // versa). Returns true when this call released it, false when it was not
  // HELD (already released or refunded).
  //
  // [expect], when given, is checked inside the same transaction:
  // { userId, referenceId, referenceType }. A mismatch throws
  // EscrowMismatchError and nothing is released, so a caller can never
  // release an escrow that belongs to another order. Callers that do not
  // pass it (rides, gas) behave exactly as before.
  async function releaseEscrow(escrowId, driverId, reason = "service_completed", expect = null) {
    const escrowRef = getDb().collection("escrows").doc(escrowId);

    return getDb().runTransaction(async (tx) => {
      const escrow = await tx.get(escrowRef);
      if (!escrow.exists) throw new Error("Escrow not found: " + escrowId);
      if (escrow.data().status !== "HELD") {
        console.log(`Escrow ${escrowId} already ${escrow.data().status}`);
        return false;
      }
      if (expect) {
        for (const field of ["userId", "referenceId", "referenceType"]) {
          if (expect[field] !== undefined && escrow.data()[field] !== expect[field]) {
            throw new EscrowMismatchError(`escrow_${field}_mismatch`, escrowId);
          }
        }
      }

      const { userId, amount, platformFee, driverNet } = escrow.data();

      const walletRef = getDb().collection("wallets").doc(userId);
      const walletDoc = await tx.get(walletRef);
      if (!walletDoc.exists) throw new Error("Passenger wallet not found");

      tx.update(walletRef, { heldBalance: FieldValue.increment(-amount), lastUpdatedAt: FieldValue.serverTimestamp() });

      if (driverId && driverNet > 0) {
        const driverRef   = getDb().collection("drivers").doc(driverId);
        const summaryRef  = getDb().collection("drivers").doc(driverId)
                              .collection("earnings").doc("summary");

        // Update driver document
        tx.update(driverRef, {
          totalEarnings:  FieldValue.increment(driverNet),
          todayEarnings:  FieldValue.increment(driverNet),
          walletBalance:  FieldValue.increment(driverNet),
          completedTrips: FieldValue.increment(1),
          isAvailable:    true,
          currentTripId:  FieldValue.delete(),
        });

        // Update earnings summary subcollection (read by driver wallet screen)
        tx.set(summaryRef, {
          todayEarnings:    FieldValue.increment(driverNet),
          weekEarnings:     FieldValue.increment(driverNet),
          lifetimeEarnings: FieldValue.increment(driverNet),
          totalEarnings:    FieldValue.increment(driverNet),
          lastUpdatedAt:    FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      tx.update(escrowRef, { status: "RELEASED", releasedAt: FieldValue.serverTimestamp(), releaseReason: reason });

      await writeLedger(tx, {
        type: "CAPTURE", status: "COMPLETED", fromUserId: userId, fromType: "escrow",
        toUserId: driverId || null, toType: "driver", amount, currency: "GHS",
        platformFee, driverNet,
        referenceType: escrow.data().referenceType,
        referenceId:   escrow.data().referenceId || escrowId,
        idempotencyKey: `capture_${escrowId}`, processedAt: FieldValue.serverTimestamp(),
      });
      return true;
    });
  }
  exports.releaseEscrow = releaseEscrow;

  /** An escrow did not match the order it was asked to settle. */
  class EscrowMismatchError extends Error {
    constructor(reason, escrowId) {
      super(`Escrow ${escrowId}: ${reason}`);
      this.name = "EscrowMismatchError";
      this.reason = reason;
    }
  }
  exports.EscrowMismatchError = EscrowMismatchError;

  // ── refundEscrow — used on cancellation ──────────────────────────────────────
  // The HELD check is made inside the transaction: if two refunds (or a
  // refund and a release) race, Firestore retries the loser, which then sees
  // the new status and stops. The wallet is credited at most once. Returns
  // true when this call refunded, false when the escrow was no longer HELD.
  async function refundEscrow(escrowId, reason = "cancelled") {
    const escrowRef = getDb().collection("escrows").doc(escrowId);

    return getDb().runTransaction(async (tx) => {
      const escrow = await tx.get(escrowRef);
      if (!escrow.exists) throw new Error("Escrow not found: " + escrowId);
      if (escrow.data().status !== "HELD") {
        console.log(`Escrow ${escrowId} already ${escrow.data().status}`);
        return false;
      }

      const { userId, amount } = escrow.data();
      const walletRef = getDb().collection("wallets").doc(userId);
      tx.update(walletRef, { balance: FieldValue.increment(amount), heldBalance: FieldValue.increment(-amount), lastUpdatedAt: FieldValue.serverTimestamp() });
      tx.update(escrowRef, { status: "REFUNDED", releasedAt: FieldValue.serverTimestamp(), releaseReason: reason });

      await writeLedger(tx, {
        type: "REFUND", status: "COMPLETED", fromType: "escrow",
        toUserId: userId, toType: "passenger", amount, currency: "GHS",
        platformFee: 0, driverNet: 0,
        referenceType: escrow.data().referenceType,
        referenceId:   escrow.data().referenceId || escrowId,
        idempotencyKey: `refund_${escrowId}`, processedAt: FieldValue.serverTimestamp(),
      });
      return true;
    });
  }
  exports.refundEscrow = refundEscrow;

  // ── Paystack Webhook — HMAC verified ─────────────────────────────────────────
  exports.paystackWebhook = onRequest(
    { region: "europe-west2", minInstances: 0, secrets: ["PAYSTACK_SECRET_KEY"] },
    async (req, res) => {
      if (req.method !== "POST") return res.status(405).send("Method not allowed");

      const signature = req.headers["x-paystack-signature"];
          
      const secret = paystackSecret.value();

      if (!signature) return res.status(401).send("Unauthorized");

      const hash = crypto.createHmac("sha512", secret)
        .update(JSON.stringify(req.body)).digest("hex");

      if (hash !== signature) {
        console.error("Invalid Paystack signature");
        return res.status(401).send("Unauthorized");
      }

      const { event, data } = req.body;
      const reference = data?.reference;
      if (!reference) return res.status(400).send("No reference");

      const webhookRef = getDb().collection("webhook_events").doc(reference);
      const existing   = await webhookRef.get();

      if (existing.exists && existing.data().status === "processed") {
        return res.status(200).send("Already processed");
      }

      await webhookRef.set({ reference, event, status: "received", receivedAt: FieldValue.serverTimestamp(), rawPayload: data }, { merge: true });

      // Acknowledge immediately
      res.status(200).send("OK");

      try {
        if (event === "charge.success") {
          const userId    = data.metadata?.userId;
          const amountGhs = data.amount / 100;
          if (!userId) throw new Error("No userId in metadata");

          // Idempotency
          const existing = await getDb().collection("ledger")
            .where("idempotencyKey", "==", `topup_${reference}`).limit(1).get();
          if (!existing.empty) { console.log("Already processed topup:", reference); return; }

          const walletRef = getDb().collection("wallets").doc(userId);
          await getDb().runTransaction(async (tx) => {
            const wallet = await tx.get(walletRef);
            if (!wallet.exists) {
              tx.set(walletRef, { userId, balance: amountGhs, heldBalance: 0, currency: "GHS", isActive: true, createdAt: FieldValue.serverTimestamp(), lastUpdatedAt: FieldValue.serverTimestamp() });
            } else {
              tx.update(walletRef, { balance: FieldValue.increment(amountGhs), lastUpdatedAt: FieldValue.serverTimestamp() });
            }
            await writeLedger(tx, {
              type: "TOPUP", status: "COMPLETED", toUserId: userId, toType: "passenger",
              fromType: "paystack", amount: amountGhs, currency: "GHS",
              platformFee: 0, driverNet: 0, referenceType: "topup",
              referenceId: reference, paystackRef: reference,
              idempotencyKey: `topup_${reference}`, processedAt: FieldValue.serverTimestamp(),
            });
          });

          // Notify
          const userDoc  = await getDb().collection("users").doc(userId).get();
          const fcmToken = userDoc.data()?.fcmToken;
          if (fcmToken) {
            await admin.messaging().send({
              token: fcmToken,
              notification: { title: "💰 Wallet Topped Up!", body: `GH₵${amountGhs.toFixed(2)} added to your wallet.` },
              data: { type: "wallet_topup" },
            }).catch(console.error);
          }
        }

        await webhookRef.update({ status: "processed", processedAt: FieldValue.serverTimestamp() });
      } catch (e) {
        console.error("Webhook processing error:", e.message);
        await webhookRef.update({ status: "failed", failedAt: FieldValue.serverTimestamp(), failureReason: e.message, retryCount: FieldValue.increment(1) });
      }
    }
  );

  // ── Stale escrow recovery ──────────────────────────────────────────────────
  //
  // An escrow is HELD from holdBalance until the order's completion trigger
  // releases it to the driver or its cancellation trigger refunds it. An
  // order can legitimately take longer than two hours (Pickup & Return gas
  // is estimated at 2 h 30 m), so age alone must never trigger a refund:
  // refunding an in-progress order made the service free and left the
  // driver unpaid, because the completion trigger then found nothing HELD.
  //
  // The hourly job looks at HELD escrows older than two hours and decides
  // from the order they belong to:
  //   • no order at all           → refund (abandoned hold: the order was
  //                                  never created, or creation failed)
  //   • order missing (deleted)   → refund (nothing left to deliver)
  //   • order cancelled / failed  → refund (the cancellation trigger did not
  //                                  run or failed)
  //   • order still in progress   → keep (its own trigger will settle it)
  //   • order completed           → keep and alert (completion should have
  //                                  released it; needs a person to check)
  //   • status not recognised     → keep and alert
  //   • anything unexpected       → keep and alert
  // The order is found by the escrow's referenceId (set by
  // attachEscrowToOrder), or, for an unattached escrow, by the order's
  // escrowId field, which covers an attach that failed after the order was
  // created.

  const STALE_ESCROW_MS = 2 * 60 * 60 * 1000;
  const LONG_HELD_ALERT_MS = 24 * 60 * 60 * 1000;

  const ORDER_COLLECTION_BY_REFERENCE = {
    trip: "trips",
    delivery: "deliveries",
    gas_order: "gas_orders",
  };

  // Statuses of each order type, as written by the apps and triggers:
  // `active` are in progress (including held for review by a trigger),
  // `refund` ended without the service, `settled` ended with it.
  const ORDER_STATUSES = {
    trips: {
      active: ["searching", "tripAccepted", "driverArrived", "tripStarted",
        "inProgress", "flagged"],
      refund: ["cancelled", "cancelledByDriver", "cancelledByPassenger",
        "noDrivers", "noDriversAvailable", "expired"],
      settled: ["completed"],
    },
    deliveries: {
      active: ["pending", "driverAssigned", "pickupEnroute", "arrivedAtPickup",
        "packagePicked", "deliveryEnroute", "arrivedAtDropoff", "flagged"],
      refund: ["cancelled", "cancelledByDriver", "cancelledByPassenger"],
      settled: ["completed"],
    },
    gas_orders: {
      active: ["pendingApproval", "driverAssigned", "driverEnRoute",
        "driverArrived", "pickedUp", "atStation", "refilling", "returning",
        "pendingOtp", "flagged"],
      refund: ["cancelled", "failed"],
      settled: ["delivered"],
    },
  };

  /**
   * What recovery does with a stale HELD escrow. Pure, for tests.
   * @param {{attached: boolean, orderFound: boolean, collection?: string,
   *          orderStatus?: string}} s
   * @returns {{action: "refund"|"keep"|"review", reason: string}}
   */
  function staleEscrowAction({ attached, orderFound, collection, orderStatus }) {
    if (!orderFound) {
      return attached
        ? { action: "refund", reason: "order_missing" }
        : { action: "refund", reason: "abandoned_hold" };
    }
    const statuses = ORDER_STATUSES[collection];
    if (!statuses) return { action: "review", reason: "unknown_order_type" };
    if (typeof orderStatus !== "string" || orderStatus.length === 0) {
      return { action: "review", reason: "order_without_status" };
    }
    if (statuses.refund.includes(orderStatus)) {
      return { action: "refund", reason: `order_${orderStatus}` };
    }
    if (statuses.settled.includes(orderStatus)) {
      return { action: "review", reason: "settled_order_still_held" };
    }
    if (statuses.active.includes(orderStatus)) {
      return { action: "keep", reason: "order_in_progress" };
    }
    // A status this code does not know: never refund, never assume active.
    return { action: "review", reason: "unknown_order_status" };
  }
  exports.staleEscrowAction = staleEscrowAction;

  /** Finds the order a HELD escrow belongs to. */
  async function findEscrowOrder(escrowId, data) {
    const attached = data.referenceId != null && data.referenceId !== "";
    if (attached) {
      const collection = ORDER_COLLECTION_BY_REFERENCE[data.referenceType];
      if (!collection) return { attached, collection: null, order: null, unknownType: true };
      const snap = await getDb().collection(collection).doc(data.referenceId).get();
      return { attached, collection, order: snap.exists ? snap : null };
    }
    // Unattached: the order may still exist if attaching failed after it
    // was created (the client also writes escrowId on the order).
    const collections = data.referenceType && ORDER_COLLECTION_BY_REFERENCE[data.referenceType]
      ? [ORDER_COLLECTION_BY_REFERENCE[data.referenceType]]
      : Object.values(ORDER_COLLECTION_BY_REFERENCE);
    for (const collection of collections) {
      const q = await getDb().collection(collection)
        .where("escrowId", "==", escrowId).limit(1).get();
      if (!q.empty) return { attached, collection, order: q.docs[0] };
    }
    return { attached, collection: null, order: null };
  }

  /**
   * Decides, without changing anything, what each HELD escrow older than
   * two hours needs. Shared by the hourly recovery and the nightly
   * reconciliation so both classify the same way.
   * @returns {Promise<Array<{escrowId: string, data: object,
   *   heldAt: Date|null, action: string, reason: string, error?: string}>>}
   */
  async function assessStaleEscrows({ now = Date.now() } = {}) {
    const cutoff = new Date(now - STALE_ESCROW_MS);
    const stale = await getDb().collection("escrows")
      .where("status", "==", "HELD").where("heldAt", "<", cutoff).get();

    const results = [];
    for (const doc of stale.docs) {
      const data = doc.data();
      const heldAt = data.heldAt?.toDate?.() ?? null;
      try {
        const found = await findEscrowOrder(doc.id, data);
        const decision = found.unknownType
          ? { action: "review", reason: "unknown_reference_type" }
          : staleEscrowAction({
            attached: found.attached,
            orderFound: found.order != null,
            collection: found.collection,
            orderStatus: found.order?.data()?.status,
          });
        results.push({ escrowId: doc.id, data, heldAt, ...decision });
      } catch (e) {
        results.push({ escrowId: doc.id, data, heldAt, action: "error",
          reason: "lookup_failed", error: e.message });
      }
    }
    return results;
  }
  exports.assessStaleEscrows = assessStaleEscrows;

  /**
   * One recovery pass over stale HELD escrows. Exported for tests; the
   * hourly schedule below calls it.
   */
  async function recoverStaleEscrows({ now = Date.now() } = {}) {
    const assessed = await assessStaleEscrows({ now });

    const summary = { refunded: 0, kept: 0, review: [], longHeld: [], failed: 0 };
    for (const item of assessed) {
      try {
        if (item.action === "refund") {
          // refundEscrow re-checks HELD in its transaction, so a settlement
          // that lands at the same moment still wins cleanly.
          if (await refundEscrow(item.escrowId, `auto_${item.reason}`)) summary.refunded++;
        } else if (item.action === "review") {
          summary.review.push({ escrowId: item.escrowId, reason: item.reason });
        } else if (item.action === "keep") {
          summary.kept++;
          if (item.heldAt && now - item.heldAt.getTime() > LONG_HELD_ALERT_MS) {
            summary.longHeld.push(item.escrowId);
          }
        } else {
          summary.failed++;
          console.error(`Stale escrow ${item.escrowId}:`, item.error);
        }
      } catch (e) {
        summary.failed++;
        console.error(`Stale escrow ${item.escrowId}:`, e.message);
      }
    }

    if (summary.refunded > 0) {
      await getDb().collection("admin_alerts").add({ type: "stuck_escrows_released", count: summary.refunded, createdAt: FieldValue.serverTimestamp() });
    }
    if (summary.review.length > 0 || summary.longHeld.length > 0) {
      await getDb().collection("admin_alerts").add({
        type: "escrows_need_review",
        review: summary.review.slice(0, 50),
        longHeld: summary.longHeld.slice(0, 50),
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    console.log(`recoverStaleEscrows: ${summary.refunded} refunded, ${summary.kept} kept, ` +
      `${summary.review.length} review, ${summary.failed} failed of ${assessed.length}`);
    return summary;
  }
  exports.recoverStaleEscrows = recoverStaleEscrows;

  // ── Stuck escrow release — runs every hour ────────────────────────────────────
  exports.releaseStuckEscrows = onSchedule(
    { schedule: "every 1 hours", region: "europe-west2", minInstances: 0 },
    async () => { await recoverStaleEscrows(); }
  );

  /**
   * The nightly reconciliation figures. Escrows older than two hours are
   * classified like the hourly recovery does: those of orders still in
   * progress are normal and only counted (`heldActiveEscrows`); the rest
   * need attention and are reported as stuck. Exported for tests.
   */
  async function buildReconciliationReport({ now = Date.now() } = {}) {
    const today      = new Date(now);
    const startOfDay = new Date(today); startOfDay.setHours(0,0,0,0);

    const walletsSnap = await getDb().collection("wallets").get();
    let totalBalance  = 0, totalHeld = 0;
    walletsSnap.docs.forEach(d => { totalBalance += d.data().balance || 0; totalHeld += d.data().heldBalance || 0; });

    const ledgerSnap  = await getDb().collection("ledger").where("createdAt", ">=", startOfDay).where("status", "==", "COMPLETED").get();
    const todayVolume = ledgerSnap.docs.reduce((s, d) => s + (d.data().amount || 0), 0);

    const assessed = await assessStaleEscrows({ now });
    const attention = assessed.filter((e) => e.action !== "keep");
    const longHeld = assessed.filter((e) => e.action === "keep" && e.heldAt &&
      now - e.heldAt.getTime() > LONG_HELD_ALERT_MS);
    const failedSnap  = await getDb().collection("webhook_events").where("status", "==", "failed").get();

    return {
      date: today.toISOString().split("T")[0],
      totalWalletBalance: totalBalance, totalHeldBalance: totalHeld,
      totalLiability: totalBalance + totalHeld,
      todayTransactions: ledgerSnap.size, todayVolume,
      // Held over two hours and needing attention (abandoned, order
      // missing, cancelled but unrefunded, completed but unsettled,
      // unknown state, or lookup failed).
      stuckEscrows: attention.length,
      stuckEscrowDetails: attention.slice(0, 50)
        .map((e) => ({ escrowId: e.escrowId, action: e.action, reason: e.reason })),
      // Held over two hours for orders still in progress: expected.
      heldActiveEscrows: assessed.length - attention.length,
      longHeldEscrows: longHeld.length,
      failedWebhooks: failedSnap.size,
    };
  }
  exports.buildReconciliationReport = buildReconciliationReport;

  async function runDailyReconciliation({ now = Date.now() } = {}) {
    const report = await buildReconciliationReport({ now });
    await getDb().collection("reconciliation").add({
      ...report, createdAt: FieldValue.serverTimestamp(),
    });

    if (report.stuckEscrows > 0 || report.longHeldEscrows > 0 || report.failedWebhooks > 0) {
      await getDb().collection("admin_alerts").add({
        type: "reconciliation_anomaly",
        message: `${report.stuckEscrows} stuck escrows, ` +
          `${report.longHeldEscrows} held over 24 h on active orders, ` +
          `${report.failedWebhooks} failed webhooks`,
        stuckEscrowDetails: report.stuckEscrowDetails,
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    console.log(`✅ Reconciliation complete: balance=${report.totalWalletBalance} held=${report.totalHeldBalance} ` +
      `stuck=${report.stuckEscrows} activeHeld=${report.heldActiveEscrows}`);
    return report;
  }
  exports.runDailyReconciliation = runDailyReconciliation;

  // ── Daily reconciliation — midnight Ghana ─────────────────────────────────────
  exports.dailyReconciliation = onSchedule(
    { schedule: "0 0 * * *", timeZone: "Africa/Accra", region: "europe-west2", minInstances: 0 },
    async () => { await runDailyReconciliation(); }
  );

  // ── refundEscrowOnError — callable for client rollback ───────────────────────
  // Called when trip/delivery/gas order creation fails after escrow hold
  exports.refundEscrowOnError = onCall(
    { region: "europe-west2", minInstances: 0 },
    async (request) => {
      const uid     = requireAuth(request);
      const { escrowId, reason } = request.data;

      if (!escrowId) throw new HttpsError("invalid-argument", "escrowId required");

      const escrowRef = getDb().collection("escrows").doc(escrowId);
      const escrow    = await escrowRef.get();

      if (!escrow.exists) throw new HttpsError("not-found", "Escrow not found");
      if (escrow.data().userId !== uid) throw new HttpsError("permission-denied", "Not your escrow");
      if (escrow.data().referenceId !== null) {
        throw new HttpsError("failed-precondition", "Escrow already attached to an order — cannot refund");
      }

      await refundEscrow(escrowId, reason || "order_creation_failed");
      return { success: true };
    }
  );
