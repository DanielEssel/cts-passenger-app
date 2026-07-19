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
  exports.attachEscrowToOrder = onCall(
    { region: "europe-west2", minInstances: 0 },
    async (request) => {
    const uid = requireAuth(request);
    const { escrowId, referenceId, referenceType } = request.data;
    if (!escrowId || !referenceId) throw new HttpsError("invalid-argument", "escrowId and referenceId required");

    const escrowRef = getDb().collection("escrows").doc(escrowId);
    const escrow    = await escrowRef.get();
    if (!escrow.exists)                     throw new HttpsError("not-found", "Escrow not found");
    if (escrow.data().userId !== uid)       throw new HttpsError("permission-denied", "Not your escrow");
    if (escrow.data().status !== "HELD")    throw new HttpsError("failed-precondition", "Escrow not active");
    if (escrow.data().referenceId !== null) throw new HttpsError("failed-precondition", "Escrow already attached");

    await escrowRef.update({ referenceId, referenceType });
    return { success: true };
  });

  // ── releaseEscrow — used by onTripCompleted CF ────────────────────────────────
  async function releaseEscrow(escrowId, driverId, reason = "service_completed") {
    const escrowRef = getDb().collection("escrows").doc(escrowId);
    const escrow    = await escrowRef.get();
    if (!escrow.exists)                  throw new Error("Escrow not found: " + escrowId);
    if (escrow.data().status !== "HELD") { console.log(`Escrow ${escrowId} already ${escrow.data().status}`); return; }

    const { userId, amount, platformFee, driverNet } = escrow.data();

    await getDb().runTransaction(async (tx) => {
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
    });
  }
  exports.releaseEscrow = releaseEscrow;

  // ── refundEscrow — used on cancellation ──────────────────────────────────────
  async function refundEscrow(escrowId, reason = "cancelled") {
    const escrowRef = getDb().collection("escrows").doc(escrowId);
    const escrow    = await escrowRef.get();
    if (!escrow.exists)                  throw new Error("Escrow not found: " + escrowId);
    if (escrow.data().status !== "HELD") { console.log(`Escrow ${escrowId} already ${escrow.data().status}`); return; }

    const { userId, amount } = escrow.data();

    await getDb().runTransaction(async (tx) => {
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

  // ── Stuck escrow release — runs every hour ────────────────────────────────────
  exports.releaseStuckEscrows = onSchedule(
    { schedule: "every 1 hours", region: "europe-west2", minInstances: 0 },
    async () => {
      const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000);
      const stuck = await getDb().collection("escrows")
        .where("status", "==", "HELD").where("heldAt", "<", twoHoursAgo).get();

      let released = 0;
      for (const doc of stuck.docs) {
        try { await refundEscrow(doc.id, "auto_expired"); released++; }
        catch (e) { console.error(`Failed to release ${doc.id}:`, e.message); }
      }
      if (released > 0) {
        await getDb().collection("admin_alerts").add({ type: "stuck_escrows_released", count: released, createdAt: FieldValue.serverTimestamp() });
      }
      console.log(`releaseStuckEscrows: ${released}/${stuck.size} released`);
    }
  );

  // ── Daily reconciliation — midnight Ghana ─────────────────────────────────────
  exports.dailyReconciliation = onSchedule(
    { schedule: "0 0 * * *", timeZone: "Africa/Accra", region: "europe-west2", minInstances: 0 },
    async () => {
      const today      = new Date();
      const startOfDay = new Date(today); startOfDay.setHours(0,0,0,0);

      const walletsSnap = await getDb().collection("wallets").get();
      let totalBalance  = 0, totalHeld = 0;
      walletsSnap.docs.forEach(d => { totalBalance += d.data().balance || 0; totalHeld += d.data().heldBalance || 0; });

      const ledgerSnap  = await getDb().collection("ledger").where("createdAt", ">=", startOfDay).where("status", "==", "COMPLETED").get();
      const todayVolume = ledgerSnap.docs.reduce((s, d) => s + (d.data().amount || 0), 0);

      const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000);
      const stuckSnap   = await getDb().collection("escrows").where("status", "==", "HELD").where("heldAt", "<", twoHoursAgo).get();
      const failedSnap  = await getDb().collection("webhook_events").where("status", "==", "failed").get();

      await getDb().collection("reconciliation").add({
        date: today.toISOString().split("T")[0],
        totalWalletBalance: totalBalance, totalHeldBalance: totalHeld,
        totalLiability: totalBalance + totalHeld,
        todayTransactions: ledgerSnap.size, todayVolume,
        stuckEscrows: stuckSnap.size, failedWebhooks: failedSnap.size,
        createdAt: FieldValue.serverTimestamp(),
      });

      if (stuckSnap.size > 0 || failedSnap.size > 0) {
        await getDb().collection("admin_alerts").add({
          type: "reconciliation_anomaly",
          message: `${stuckSnap.size} stuck escrows, ${failedSnap.size} failed webhooks`,
          createdAt: FieldValue.serverTimestamp(),
        });
      }
      console.log(`✅ Reconciliation complete: balance=${totalBalance} held=${totalHeld}`);
    }
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
