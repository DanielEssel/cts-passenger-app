  "use strict";
  const { onCall, HttpsError } = require("firebase-functions/v2/https");
  const { onSchedule }   = require("firebase-functions/v2/scheduler");
  const admin            = require("firebase-admin");

  const getDb          = () => admin.firestore();
  const FieldValue     = admin.firestore.FieldValue;
  const { verifyHeldAmount, PRICE_CHECKED_TYPES } = require("./payment_verification");
  const { quotedHoldProblem, QUOTES } = require("./delivery_quotes");
  const { requireActiveAdmin } = require("./admin_auth");
  const { adminAlert } = require("./alert_payload");
  const { releaseFieldsIfCurrent } = require("./active_job");

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

  // ── holdBalance amount limits ─────────────────────────────────────────────────
  // Agreed with the product owner (2026-10-14):
  //   • minimum GHS 5.00 — the lowest configured service minimum fare
  //     (Ride/Okada); no legitimate order holds less while every
  //     settings/platform minimumFare / minDeliveryFee stays at or above it
  //     (a lower configured minimum would make short wallet orders fail);
  //   • maximum from settings/platform.maxEscrowHold, GHS 5,000 when that is
  //     unset or invalid (the existing maxWithdrawalAmount figure), so
  //     admins can raise it for large commercial gas orders without a deploy.
  // Amounts must be numbers in whole pesewas (at most two decimals).
  const HOLD_MIN_AMOUNT = 5.0;
  const HOLD_MAX_DEFAULT = 5000.0;
  exports.HOLD_MIN_AMOUNT = HOLD_MIN_AMOUNT;
  exports.HOLD_MAX_DEFAULT = HOLD_MAX_DEFAULT;

  /**
   * Why [amount] cannot be held, or null when it can. Pure.
   * @returns {null | {code: "invalid-argument"|"out-of-range", reason: string}}
   */
  function holdAmountProblem(amount, maxAmount = HOLD_MAX_DEFAULT) {
    if (typeof amount !== "number" || !Number.isFinite(amount)) {
      return { code: "invalid-argument", reason: "amount_not_a_finite_number" };
    }
    if (amount <= 0) return { code: "invalid-argument", reason: "amount_not_positive" };
    // Whole pesewas: the amount must equal itself rounded to two decimals.
    // Exact for any value written with ≤ 2 decimals (1.13 parses to the same
    // double as Number("1.13")), and rejects any finer fraction.
    if (Number(amount.toFixed(2)) !== amount) {
      return { code: "invalid-argument", reason: "amount_more_than_two_decimals" };
    }
    if (amount < HOLD_MIN_AMOUNT) return { code: "out-of-range", reason: "amount_below_minimum" };
    if (amount > maxAmount) return { code: "out-of-range", reason: "amount_above_maximum" };
    return null;
  }
  exports.holdAmountProblem = holdAmountProblem;

  /** settings/platform.maxEscrowHold when a positive finite number, else the default. */
  async function getMaxEscrowHold() {
    try {
      const snap = await getDb().collection("settings").doc("platform").get();
      const v = snap.exists ? snap.data()?.maxEscrowHold : null;
      return typeof v === "number" && Number.isFinite(v) && v >= HOLD_MIN_AMOUNT ? v : HOLD_MAX_DEFAULT;
    } catch (_) {
      return HOLD_MAX_DEFAULT;
    }
  }

  /** What a hold may be for: the orders attachEscrowToOrder links, and supplier Gas. */
  const HOLD_REFERENCE_TYPES = new Set(["trip", "delivery", "gas_order", "gas_supplier_order"]);

  /** settings/gas_supplier_fulfilment.enabled === true, read now; off on any doubt. */
  async function supplierGasEnabled() {
    try {
      const snap = await getDb().collection("settings").doc("gas_supplier_fulfilment").get();
      return snap.exists && snap.data()?.enabled === true;
    } catch (_) {
      return false;
    }
  }

  // ── Wallet Delivery and Gas: held back until the apps keep the code secret ──
  // A Delivery or legacy Gas order is completed with a code the receiver
  // gives the driver. Passenger builds before 1.0.1 write that code on the
  // order, where the assigned driver can read it, and Driver builds before
  // 1.0.3 cannot complete an order without it. A wallet payment for these
  // services is therefore taken only once app_config/mobile requires
  // Passenger 1.0.1 and Driver 1.0.3 (the minimum versions the apps already
  // enforce) AND the owner has switched it on separately
  // (app_config/payments.deliveryGasWalletEnabled === true; server-only,
  // absent = off). Raising the minimum versions alone never enables it;
  // until both hold, these services are cash only. Ride wallet is not
  // affected.
  const CODE_SECURE_MINIMUM = { passengerMinimumVersion: "1.0.1", driverMinimumVersion: "1.0.3" };
  const CODE_VERIFIED_TYPES = new Set(["delivery", "gas_order"]);

  /** x.y.z of [v] as numbers, or null. Build suffixes (+N) are ignored, as the apps' gate does. */
  function versionParts(v) {
    const m = typeof v === "string" ? /^(\d+)\.(\d+)\.(\d+)(?:\+.*)?$/.exec(v.trim()) : null;
    return m ? m.slice(1, 4).map(Number) : null;
  }

  /** True when version [v] is at least [min]; false when [v] is missing or malformed. Pure. */
  function versionAtLeast(v, min) {
    const a = versionParts(v);
    const b = versionParts(min);
    if (!a || !b) return false;
    for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
    return true;
  }
  exports.versionAtLeast = versionAtLeast;

  /**
   * Whether wallet payment may fund Delivery and Gas orders now: the
   * dedicated switch is exactly true and the code-secure minimum versions
   * are required. Off on any doubt (missing document, any other value, read
   * error).
   */
  async function walletDeliveryGasAvailable() {
    try {
      const [mobile, payments] = await Promise.all([
        getDb().collection("app_config").doc("mobile").get(),
        getDb().collection("app_config").doc("payments").get(),
      ]);
      if ((payments.exists ? payments.data() : {})?.deliveryGasWalletEnabled !== true) return false;
      const cfg = mobile.exists ? mobile.data() : {};
      return Object.entries(CODE_SECURE_MINIMUM).every(([k, min]) => versionAtLeast(cfg?.[k], min));
    } catch (_) {
      return false;
    }
  }
  exports.walletDeliveryGasAvailable = walletDeliveryGasAvailable;

  const WALLET_DELIVERY_GAS_UNAVAILABLE =
    "Wallet payment for Delivery and Gas is not available yet. Please choose cash.";

  // ── holdBalance ───────────────────────────────────────────────────────────────
  exports.holdBalance = onCall(
    { region: "europe-west2", minInstances: 0 },
    async (request) => {
    const uid = requireAuth(request);
    const { amount, serviceType, referenceType } = request.data ?? {};
    // Validated before any read or write: a refused request changes nothing.
    // A hold is for one known service; supplier Gas holds only while that
    // service is switched on (settings/gas_supplier_fulfilment.enabled).
    if (!HOLD_REFERENCE_TYPES.has(referenceType)) {
      throw new HttpsError("invalid-argument", "Unsupported referenceType",
        { reason: "reference_type_invalid" });
    }
    if (referenceType === "gas_supplier_order" && !(await supplierGasEnabled())) {
      throw new HttpsError("failed-precondition", "Gas supplier ordering is not available.",
        { reason: "supplier_gas_disabled" });
    }
    if (CODE_VERIFIED_TYPES.has(referenceType) && !(await walletDeliveryGasAvailable())) {
      throw new HttpsError("failed-precondition", WALLET_DELIVERY_GAS_UNAVAILABLE,
        { reason: "wallet_delivery_gas_unavailable" });
    }
    const maxAmount = await getMaxEscrowHold();
    const problem = holdAmountProblem(amount, maxAmount);
    if (problem) {
      throw new HttpsError(problem.code,
        problem.code === "out-of-range"
          ? `Amount must be between GH₵${HOLD_MIN_AMOUNT.toFixed(2)} and GH₵${maxAmount.toFixed(2)}.`
          : "Invalid amount.",
        { reason: problem.reason, min: HOLD_MIN_AMOUNT, max: maxAmount });
    }

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
  //     escrows attached before this check existed are found by query;
  //   • for Ride and Delivery, the held amount must equal the booked fare
  //     and be at least the server's minimum price (payment_verification.js).
  //     A hold that fails this is never linked: the order is cancelled and
  //     the hold returned to the passenger's wallet.
  // A delivery's escrowId is also written here, in the same transaction, so
  // the order is never left paid-for but not pointing at its payment if the
  // app's follow-up write fails (rides carry it from creation).
  // Repeating an attach that already happened is accepted (idempotent).
  const ESCROW_ORDER_COLLECTIONS = {
    trip: "trips",
    delivery: "deliveries",
    gas_order: "gas_orders",
  };
  exports.ESCROW_ORDER_COLLECTIONS = ESCROW_ORDER_COLLECTIONS;

  // [actor] (admin recovery, adminAttachEscrow) adds checks and an audit
  // record and never cancels or refunds: { adminUid, adminEmail, reason }.
  async function attachEscrowForUser(uid, { escrowId, referenceId, referenceType } = {}, actor = null) {
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
    const priceChecked = PRICE_CHECKED_TYPES.has(referenceType);
    const settings = priceChecked ? await readPlatformSettings() : null;
    const codeServiceOpen = CODE_VERIFIED_TYPES.has(referenceType) && !actor
      ? await walletDeliveryGasAvailable() : true;

    const result = await getDb().runTransaction(async (tx) => {
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
      // A passenger links a hold only to a booking still open: never to one
      // that ended or was settled (admin recovery has its own rules below).
      if (!actor && (o.walletProcessed === true ||
          !ORDER_STATUSES[collection].active.includes(o.status))) {
        throw new HttpsError("failed-precondition", "Order is no longer open");
      }
      if (actor) {
        // Recovery is for an order that still needs this payment: in
        // progress, or completed with its settlement blocked.
        const statuses = ORDER_STATUSES[collection];
        if (o.walletProcessed === true) {
          throw new HttpsError("failed-precondition", "Order is already settled");
        }
        if (statuses.refund.includes(o.status)) {
          throw new HttpsError("failed-precondition", "Order ended without the service; it is refunded, not attached");
        }
        if (![...statuses.active, ...statuses.settled].includes(o.status)) {
          throw new HttpsError("failed-precondition", "Order status cannot be recovered here");
        }
        const booked = Number(referenceType === "gas_order" ? o.totalPrice : o.estimatedFare);
        if (!Number.isFinite(booked) || typeof e.amount !== "number" ||
            Math.round(booked * 100) !== Math.round(e.amount * 100)) {
          throw new HttpsError("failed-precondition", "Held amount does not match the booked price");
        }
      }
      // Delivery and Gas: only while their wallet payment is available, and
      // never for an order that carries its completion code where the driver
      // can read it (deliveryOtp, written by Passenger builds before 1.0.1).
      if (!actor && CODE_VERIFIED_TYPES.has(referenceType)) {
        if (!codeServiceOpen) return { refused: "wallet_delivery_gas_unavailable" };
        if (o.deliveryOtp != null && String(o.deliveryOtp).trim() !== "") {
          return { refused: "completion_code_on_order" };
        }
      }
      // A Delivery hold pays the order's own server quote (delivery_quotes.js):
      // the customer's, not used by another order, at exactly its total.
      if (referenceType === "delivery") {
        const qid = typeof o.deliveryQuoteId === "string" && o.deliveryQuoteId && !o.deliveryQuoteId.includes("/")
          ? o.deliveryQuoteId : null;
        const quote = qid ? await tx.get(getDb().collection(QUOTES).doc(qid)) : null;
        const problem = quotedHoldProblem(o, quote?.exists ? quote.data() : null, e.amount, referenceId);
        if (problem) return actor ? { adminRefused: problem } : { refused: problem };
      }
      if (priceChecked) {
        const check = verifyHeldAmount({ referenceType, order: o, escrowAmount: e.amount, settings });
        if (!check.ok) return actor ? { adminRefused: check.reason } : { refused: check.reason };
      }

      tx.update(escrowRef, { referenceId, referenceType });
      tx.set(linkRef, {
        escrowId, referenceType, referenceId, userId: uid,
        linkedAt: FieldValue.serverTimestamp(),
        ...(actor ? { linkedBy: actor.adminUid } : {}),
      });
      // Settlement finds the payment through the order's escrowId: a
      // recovered order without one would be charged again from the wallet.
      // Deliveries and Gas orders are dispatched once it is recorded (rides
      // carry it from creation).
      if (o.escrowId == null && (referenceType === "delivery" || referenceType === "gas_order" || actor)) {
        tx.update(orderRef, { escrowId });
      }
      if (actor) {
        tx.set(getDb().collection("admin_escrow_actions").doc(), {
          action: "attach_escrow", adminUid: actor.adminUid, adminEmail: actor.adminEmail,
          reason: actor.reason, escrowId, referenceType, referenceId, passengerId: uid,
          amount: e.amount, orderStatus: o.status, createdAt: FieldValue.serverTimestamp(),
        });
      }
      return { success: true };
    });

    if (result.adminRefused) {
      throw new HttpsError("failed-precondition",
        `The held amount fails the price check (${result.adminRefused}); nothing was changed.`);
    }
    if (result.refused) {
      await rejectWalletBooking({ collection, orderId: referenceId, referenceType,
        escrowId, passengerId: uid, reason: result.refused });
      const why = result.refused === "wallet_delivery_gas_unavailable" ? WALLET_DELIVERY_GAS_UNAVAILABLE
        : result.refused === "completion_code_on_order"
          ? "Wallet payment for this booking needs the latest version of the app. Please update, or choose cash."
          : "The amount held does not match this booking's price.";
      throw new HttpsError("failed-precondition",
        `${why} The booking was cancelled and any amount held has been returned to your wallet.`,
        { reason: result.refused });
    }
    return result;
  }
  exports.attachEscrowForUser = attachEscrowForUser;


  async function readPlatformSettings() {
    const snap = await getDb().collection("settings").doc("platform").get();
    return snap.exists ? snap.data() : null;
  }

  // Order statuses after which a payment problem no longer cancels the order.
  const ORDER_FINAL_STATUSES = new Set(["completed", "flagged", "cancelled", "cancelledByDriver",
    "cancelledByPassenger", "noDrivers", "noDriversAvailable", "expired", "delivered",
    "pendingOtp", "failed"]);

  /**
   * Cancels an order whose wallet payment could not be established (it is
   * never offered to drivers), unless it already ended. Returns true when
   * this call cancelled it. Ids only in the alert.
   */
  async function cancelOrderForPayment(collection, orderId, reason,
    { onlyIfUnpaidPending = false, cancellationReason = "payment_not_verified",
      alertType = "wallet_payment_rejected", what = "its wallet payment could not be verified" } = {}) {
    const ref = getDb().collection(collection).doc(orderId);
    const cancelled = await getDb().runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists || ORDER_FINAL_STATUSES.has(snap.data().status)) return false;
      if (onlyIfUnpaidPending &&
          (snap.data().status !== UNPAID_OPEN_STATUS[collection] || snap.data().escrowId != null)) {
        return false;
      }
      tx.update(ref, {
        status: "cancelled",
        cancelledAt: FieldValue.serverTimestamp(),
        cancellationReason,
        paymentRejectedReason: reason,
      });
      return true;
    });
    if (cancelled) {
      await getDb().collection("admin_alerts").add(adminAlert(alertType,
        `${collection}/${orderId} was cancelled: ${what} (${reason}).`,
        { collection, orderId, reason }));
    }
    return cancelled;
  }
  exports.cancelOrderForPayment = cancelOrderForPayment;

  /**
   * A wallet Delivery or Gas order that a driver holds before its payment is
   * in place is cancelled, decided on the order and hold as they are now
   * (never on a trigger's possibly stale copy): only while the order is
   * still `driverAssigned`, a wallet order, and its escrowId does not name
   * the customer's HELD hold linked to it. A payment linked meanwhile keeps
   * the order. Returns true when this call cancelled it.
   */
  async function cancelIfAssignedUnpaid(collection, orderId) {
    const referenceType = { deliveries: "delivery", gas_orders: "gas_order" }[collection];
    if (!referenceType) return false;
    const ref = getDb().collection(collection).doc(orderId);
    const cancelled = await getDb().runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const o = snap.exists ? snap.data() : null;
      if (!o || o.status !== "driverAssigned" || o.paymentMethod !== "wallet") return false;
      const escrowId = typeof o.escrowId === "string" && o.escrowId && !o.escrowId.includes("/")
        ? o.escrowId : null;
      const hold = escrowId ? await tx.get(getDb().collection("escrows").doc(escrowId)) : null;
      const e = hold?.exists ? hold.data() : null;
      if (e && e.status === "HELD" && e.userId === o.passengerId &&
          e.referenceId === orderId && e.referenceType === referenceType) {
        return false;
      }
      tx.update(ref, {
        status: "cancelled",
        cancelledAt: FieldValue.serverTimestamp(),
        cancellationReason: "payment_not_verified",
        paymentRejectedReason: "wallet_payment_missing_at_assignment",
      });
      return true;
    });
    if (cancelled) {
      await getDb().collection("admin_alerts").add(adminAlert("wallet_payment_rejected",
        `${collection}/${orderId} was cancelled: it was taken before its wallet payment was in place.`,
        { collection, orderId, reason: "wallet_payment_missing_at_assignment" }));
    }
    return cancelled;
  }
  exports.cancelIfAssignedUnpaid = cancelIfAssignedUnpaid;

  /**
   * A hold that does not match its booking: cancel the order and return the
   * hold to its owner. The hold was never linked, so only its owner check
   * applies; refundEscrow re-checks HELD, so this refunds at most once even
   * alongside the order's cancellation trigger.
   */
  async function rejectWalletBooking({ collection, orderId, referenceType, escrowId, passengerId, reason }) {
    await cancelOrderForPayment(collection, orderId, reason);
    try {
      await refundEscrow(escrowId, `payment_rejected_${reason}`,
        { userId: passengerId, referenceId: orderId, referenceType });
    } catch (err) {
      console.error(`Escrow ${escrowId}: refund after rejected booking failed:`, err.message);
      await getDb().collection("admin_alerts").add(adminAlert("wallet_payment_rejected_refund_failed",
        `Escrow ${escrowId} was not returned after booking ${orderId} was rejected. Needs review.`,
        { escrowId, orderId }));
    }
  }

  /**
   * Establishes a wallet ride's payment before it is offered to drivers:
   * links the hold the trip was created with (the same checks as
   * attachEscrowToOrder, including the price) or cancels the trip. Cash
   * trips, and trips not marked as wallet payments, are left unchanged.
   * Returns true when the trip may be dispatched.
   */
  async function secureTripPayment(tripId, trip) {
    if (trip?.paymentMethod !== "wallet") return true;
    if (typeof trip.escrowId !== "string" || !trip.escrowId) {
      await cancelOrderForPayment("trips", tripId, "wallet_hold_missing");
      return false;
    }
    try {
      await attachEscrowForUser(trip.passengerId, {
        escrowId: trip.escrowId, referenceId: tripId, referenceType: "trip",
      });
      return true;
    } catch (err) {
      if (!(err instanceof HttpsError)) {
        // Not a refusal (e.g. a transient database error): not dispatched
        // now, not cancelled. expireStaleTrips ends the search and its
        // cancellation trigger refunds the hold.
        console.error(`Trip ${tripId}: payment check failed:`, err.message);
        return false;
      }
      // A price refusal has already cancelled the trip and returned the
      // hold. Any other refusal (not the passenger's hold, not held, linked
      // elsewhere) leaves no valid payment: the trip is cancelled and its
      // cancellation trigger refunds the hold only if it is the passenger's.
      console.warn(`Trip ${tripId}: wallet payment not established:`, err.message);
      await cancelOrderForPayment("trips", tripId, err.details?.reason ?? "wallet_hold_invalid");
      return false;
    }
  }
  exports.secureTripPayment = secureTripPayment;

  // ── Unpaid wallet deliveries ─────────────────────────────────────────────────
  // A wallet delivery is created first and linked to its hold a moment
  // later. If that link never happens (the app lost its connection, or the
  // attach was refused), the delivery is not offered to drivers
  // (notifications.js) and, once it is still unpaid after
  // UNPAID_WALLET_DELIVERY_MS, it is cancelled here so it cannot be taken and
  // delivered without payment. A delivery a driver has already taken, or
  // that has its hold by then, is left alone (re-checked in the
  // cancellation transaction). Its unlinked hold, if any, is returned by
  // refundEscrowOnError or by the hourly recovery (abandoned_hold).
  const UNPAID_WALLET_DELIVERY_MS = 10 * 60 * 1000;
  exports.UNPAID_WALLET_DELIVERY_MS = UNPAID_WALLET_DELIVERY_MS;

  // The open, unassigned status of each order type paid after creation
  // (Gas orders work as deliveries do: created, then linked to their hold).
  const UNPAID_OPEN_STATUS = { deliveries: "pending", gas_orders: "pendingApproval" };

  async function cancelUnpaidWalletDeliveries({ now = Date.now() } = {}) {
    let cancelled = 0;
    for (const [collection, open] of Object.entries(UNPAID_OPEN_STATUS)) {
      const snap = await getDb().collection(collection)
        .where("status", "==", open).where("paymentMethod", "==", "wallet").get();
      for (const doc of snap.docs) {
        const d = doc.data();
        if (d.escrowId != null) continue;
        const createdAt = d.createdAt?.toDate?.() ?? null;
        if (!createdAt || now - createdAt.getTime() < UNPAID_WALLET_DELIVERY_MS) continue;
        if (await cancelOrderForPayment(collection, doc.id, "wallet_hold_missing",
          { onlyIfUnpaidPending: true })) {
          cancelled++;
        }
      }
    }
    if (cancelled > 0) console.log(`cancelUnpaidWalletDeliveries: ${cancelled} cancelled`);
    return { cancelled };
  }
  exports.cancelUnpaidWalletDeliveries = cancelUnpaidWalletDeliveries;

  exports.expireUnpaidWalletDeliveries = onSchedule(
    { schedule: "every 5 minutes", region: "europe-west2", minInstances: 0 },
    async () => { await cancelUnpaidWalletDeliveries(); }
  );

  exports.attachEscrowToOrder = onCall(
    { region: "europe-west2", minInstances: 0 },
    async (request) => {
    const uid = requireAuth(request);
    return attachEscrowForUser(uid, request.data ?? {});
  });

  // ── adminAttachEscrow — operations recovery (admin only) ──────────────────────
  // Links a HELD, unattached escrow to the order it was paid for, when the
  // passenger app's own attach failed and completion settlement is blocked
  // (escrow_unattached). Runs the passenger attach transaction as the
  // escrow's owner (read from the escrow, never from the request), so every
  // ownership, one-to-one and price check applies, plus: order in progress
  // or completed-and-unsettled, held amount equal to the booked price, an
  // audit record in admin_escrow_actions. Never releases, refunds, debits or
  // clears a failed settlement; operations retry settlement separately and
  // completion verifies the escrow again.
  exports.adminAttachEscrow = onCall(
    { region: "europe-west2", minInstances: 0 },
    async (request) => {
      const { adminUid, adminEmail } = await requireActiveAdmin(request);
      const { escrowId, referenceId, referenceType, reason } = request.data ?? {};
      if (typeof reason !== "string" || reason.trim().length < 5 || reason.length > 500) {
        throw new HttpsError("invalid-argument", "A reason (5–500 characters) is required");
      }
      if (typeof escrowId !== "string" || !escrowId || escrowId.includes("/")) {
        throw new HttpsError("invalid-argument", "escrowId required");
      }
      const snap = await getDb().collection("escrows").doc(escrowId).get();
      if (!snap.exists) throw new HttpsError("not-found", "Escrow not found");
      const owner = snap.data().userId;
      if (typeof owner !== "string" || !owner) {
        throw new HttpsError("failed-precondition", "Escrow has no owner");
      }
      return attachEscrowForUser(owner, { escrowId, referenceId, referenceType },
        { adminUid, adminEmail, reason: reason.trim() });
    });

  // ── releaseEscrow — used by onTripCompleted CF ────────────────────────────────
  // The HELD check is made inside the transaction, so a release can never run
  // on an escrow that a concurrent refund has already returned (or vice
  // versa). Returns true when this call released it, false when it was not
  // HELD (already released or refunded).
  //
  // [expect] is required: { userId, referenceId, referenceType } of the order
  // being settled, checked inside the same transaction. A missing or
  // incomplete expectation, or a mismatch, throws EscrowMismatchError and
  // nothing is released, so a caller can never release an escrow that
  // belongs to another order (an escrow's HELD status alone proves nothing).
  async function releaseEscrow(escrowId, driverId, reason = "service_completed", expect = null) {
    const fields = ["userId", "referenceId", "referenceType"];
    if (!expect || fields.some((f) => typeof expect[f] !== "string" || !expect[f])) {
      throw new EscrowMismatchError("escrow_expectation_missing", escrowId);
    }
    const escrowRef = getDb().collection("escrows").doc(escrowId);

    return getDb().runTransaction(async (tx) => {
      const escrow = await tx.get(escrowRef);
      if (!escrow.exists) throw new Error("Escrow not found: " + escrowId);
      if (escrow.data().status !== "HELD") {
        console.log(`Escrow ${escrowId} already ${escrow.data().status}`);
        return false;
      }
      for (const field of fields) {
        if (escrow.data()[field] !== expect[field]) {
          throw new EscrowMismatchError(`escrow_${field}_mismatch`, escrowId);
        }
      }

      const { userId, amount, platformFee, driverNet } = escrow.data();

      const walletRef = getDb().collection("wallets").doc(userId);
      const walletDoc = await tx.get(walletRef);
      if (!walletDoc.exists) throw new Error("Passenger wallet not found");
      // Read before any write: the driver is freed only while they still
      // hold this escrow's order (active_job.js), so a late release or the
      // recovery sweep never frees a driver from a newer job.
      const driverRef = driverId ? getDb().collection("drivers").doc(driverId) : null;
      const driverNow = driverRef ? await tx.get(driverRef) : null;

      tx.update(walletRef, { heldBalance: FieldValue.increment(-amount), lastUpdatedAt: FieldValue.serverTimestamp() });

      if (driverId && driverNet > 0) {
        const summaryRef  = getDb().collection("drivers").doc(driverId)
                              .collection("earnings").doc("summary");

        // Update driver document
        tx.update(driverRef, {
          totalEarnings:  FieldValue.increment(driverNet),
          todayEarnings:  FieldValue.increment(driverNet),
          walletBalance:  FieldValue.increment(driverNet),
          completedTrips: FieldValue.increment(1),
          ...releaseFieldsIfCurrent(driverNow?.exists ? driverNow.data() : null, expect.referenceId),
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
  //
  // [expect], when given, is checked inside the same transaction:
  // { userId, referenceId, referenceType }. The owner must match; the order
  // must match only once the escrow is attached (an order whose attach call
  // failed still points at its unattached escrow, and cancelling it returns
  // the money to that same owner). A mismatch throws EscrowMismatchError and
  // nothing is refunded, so cancelling one order can never refund the escrow
  // of another. Callers that do not pass it behave exactly as before.
  async function refundEscrow(escrowId, reason = "cancelled", expect = null) {
    const escrowRef = getDb().collection("escrows").doc(escrowId);

    return getDb().runTransaction(async (tx) => {
      const escrow = await tx.get(escrowRef);
      if (!escrow.exists) throw new Error("Escrow not found: " + escrowId);
      if (escrow.data().status !== "HELD") {
        console.log(`Escrow ${escrowId} already ${escrow.data().status}`);
        return false;
      }
      if (expect) {
        const e = escrow.data();
        if (e.userId !== expect.userId) {
          throw new EscrowMismatchError("escrow_userId_mismatch", escrowId);
        }
        for (const field of ["referenceId", "referenceType"]) {
          if (e[field] != null && e[field] !== expect[field]) {
            throw new EscrowMismatchError(`escrow_${field}_mismatch`, escrowId);
          }
        }
      }

      await writeRefund(tx, escrowRef, escrow.data(), reason);
      return true;
    });
  }
  exports.refundEscrow = refundEscrow;

  /** The refund writes for a HELD escrow, inside the caller's transaction. */
  async function writeRefund(tx, escrowRef, escrow, reason) {
    const { userId, amount } = escrow;
    const walletRef = getDb().collection("wallets").doc(userId);
    tx.update(walletRef, { balance: FieldValue.increment(amount), heldBalance: FieldValue.increment(-amount), lastUpdatedAt: FieldValue.serverTimestamp() });
    tx.update(escrowRef, { status: "REFUNDED", releasedAt: FieldValue.serverTimestamp(), releaseReason: reason });

    await writeLedger(tx, {
      type: "REFUND", status: "COMPLETED", fromType: "escrow",
      toUserId: userId, toType: "passenger", amount, currency: "GHS",
      platformFee: 0, driverNet: 0,
      referenceType: escrow.referenceType,
      referenceId:   escrow.referenceId || escrowRef.id,
      idempotencyKey: `refund_${escrowRef.id}`, processedAt: FieldValue.serverTimestamp(),
    });
  }

  // Wallet top-ups are collected through The Bridge Solutions (bridge.js).
  // The Paystack webhook was removed with the rest of the Paystack
  // integration.

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
  // Before any automatic refund the order must belong to the escrow's owner
  // and must not name a different hold; otherwise, and for every "alert"
  // case above, the escrow is put under review (reviewStatus "pending" on
  // the escrow, one escrow_review_required alert) and recovery never acts
  // on it again: a person resolves it. Refunds are decided a second time
  // inside the refund transaction, from the same documents read again.
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
    // Gas supplier orders (gas_supplier_fulfilment.js payGasSupplierOrder):
    // the hold is bound with referenceType "gas_supplier_order" and
    // referenceId = the order id. Sweep only: attachEscrowToOrder still
    // refuses this type (ESCROW_ORDER_COLLECTIONS is unchanged).
    gas_supplier_order: "gas_supplier_orders",
  };

  // Where each order type records the hold it was paid with. Supplier
  // orders keep it in payment.escrowId (written with the binding, in one
  // transaction); the other order types use a top-level escrowId.
  const ORDER_ESCROW_FIELD = { gas_supplier_orders: "payment.escrowId" };
  const escrowFieldOf = (collection) => ORDER_ESCROW_FIELD[collection] ?? "escrowId";
  function orderEscrowId(collection, order) {
    return escrowFieldOf(collection).split(".").reduce((v, k) => (v == null ? v : v[k]), order) ?? null;
  }

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
    // gas_supplier_fulfilment.js. "awaiting_payment" is deliberately absent:
    // a bound hold on an unpaid order is inconsistent (binding and the move
    // to pendingApproval are one transaction), so it goes to review.
    // A delivered order's hold is CAPTURED, never HELD: still HELD means
    // review ("settled"). Cancellation refunds the hold (refundEscrow); a
    // cancelled order whose hold is still HELD is the case that refund
    // did not finish, which recovery may complete.
    gas_supplier_orders: {
      active: ["pendingApproval", "confirmed", "driverAssigned", "atStation", "outForDelivery"],
      refund: ["cancelled"],
      settled: ["delivered"],
    },
  };

  // Written only by the driver's completion step and by settlement: an
  // order in a refund status that carries it was cancelled after the
  // service was performed, which needs a person, not an automatic refund.
  const COMPLETION_MARKER = { trips: "completedAt", deliveries: "completedAt", gas_orders: "deliveredAt", gas_supplier_orders: "deliveredAt" };

  /**
   * What recovery does with a stale HELD escrow. Pure, for tests.
   * @param {{attached: boolean, orderFound: boolean, collection?: string,
   *          orderStatus?: string, completionMarked?: boolean}} s
   * @returns {{action: "refund"|"keep"|"review", reason: string}}
   */
  function staleEscrowAction({ attached, orderFound, collection, orderStatus, completionMarked = false }) {
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
      if (completionMarked) return { action: "review", reason: "cancelled_after_completion" };
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

  /**
   * Finds the order a HELD escrow belongs to. With [tx], every read is part
   * of that transaction, so a refund decided on them cannot act on an order
   * that changed in the meantime.
   */
  async function findEscrowOrder(escrowId, data, tx = null) {
    const read = (refOrQuery) => (tx ? tx.get(refOrQuery) : refOrQuery.get());
    const attached = data.referenceId != null && data.referenceId !== "";
    if (attached) {
      const collection = ORDER_COLLECTION_BY_REFERENCE[data.referenceType];
      if (!collection) return { attached, collection: null, order: null, unknownType: true };
      const snap = await read(getDb().collection(collection).doc(data.referenceId));
      return { attached, collection, order: snap.exists ? snap : null };
    }
    // Unattached: the order may still exist if attaching failed after it
    // was created (the client also writes escrowId on the order). The hold's
    // referenceType came from the client, so look there first and then in
    // every other order collection: an order missed here would have its
    // payment refunded as an abandoned hold.
    const typed = ORDER_COLLECTION_BY_REFERENCE[data.referenceType];
    const collections = [...new Set([typed, ...Object.values(ORDER_COLLECTION_BY_REFERENCE)])]
      .filter(Boolean);
    for (const collection of collections) {
      const q = await read(getDb().collection(collection)
        .where(escrowFieldOf(collection), "==", escrowId).limit(1));
      if (!q.empty) return { attached, collection, order: q.docs[0] };
    }
    return { attached, collection: null, order: null };
  }

  /**
   * The stale-escrow decision, including the checks the status policy alone
   * cannot make. Recovery never acts on its own when the order does not
   * belong to the escrow's owner, when the order names a different hold, or
   * once the escrow is under review. Pure, for tests.
   * @returns {{action: "refund"|"keep"|"review", reason: string, underReview?: true}}
   */
  function staleEscrowDecision(escrowId, data, found) {
    if (data.reviewStatus === "pending") {
      return { action: "review", reason: data.reviewReason || "under_review", underReview: true };
    }
    if (found.unknownType) return { action: "review", reason: "unknown_reference_type" };
    const order = found.order ? found.order.data() : null;
    // Supplier orders: the order must name this exact hold before recovery
    // keeps or refunds it (an attached hold the order does not name is
    // inconsistent), and a refund the cancellation path already put under
    // review stays with a person.
    // Supplier orders are never deleted, so a bound hold whose order is
    // missing is inconsistent data: a person decides, nothing is refunded.
    if (found.collection === "gas_supplier_orders" && found.attached && !order) {
      return { action: "review", reason: "supplier_order_missing" };
    }
    if (found.collection === "gas_supplier_orders" && order) {
      if (orderEscrowId(found.collection, order) !== escrowId) {
        return { action: "review", reason: "order_names_other_escrow" };
      }
      if (order.refundReview) return { action: "review", reason: "supplier_refund_under_review" };
    }
    const decision = staleEscrowAction({
      attached: found.attached,
      orderFound: order != null,
      collection: found.collection,
      orderStatus: order?.status,
      completionMarked: found.collection != null &&
        order?.[COMPLETION_MARKER[found.collection]] != null,
    });
    // An automatic refund of an existing order's hold also needs that order
    // to be the owner's and to name this hold (keep and review move nothing;
    // with no order at all the hold simply returns to its owner).
    if (decision.action === "refund" && order) {
      if (!order.passengerId || order.passengerId !== data.userId) {
        return { action: "review", reason: "escrow_owner_mismatch" };
      }
      const named = orderEscrowId(found.collection, order);
      if (named != null && named !== escrowId) {
        return { action: "review", reason: "order_names_other_escrow" };
      }
    }
    return decision;
  }
  exports.staleEscrowDecision = staleEscrowDecision;

  /**
   * Refunds one stale escrow only if, read again inside the refund
   * transaction, it is still HELD, still stale, not under review and its
   * order still calls for a refund. Firestore retries the transaction when
   * any of those documents changes, so a concurrent settlement, cancellation
   * or reactivation always wins cleanly.
   * @returns {Promise<{refunded: boolean, action?: string, reason: string}>}
   */
  async function refundStaleEscrow(escrowId, { now = Date.now() } = {}) {
    const escrowRef = getDb().collection("escrows").doc(escrowId);
    return getDb().runTransaction(async (tx) => {
      const snap = await tx.get(escrowRef);
      if (!snap.exists) return { refunded: false, reason: "escrow_missing" };
      const data = snap.data();
      if (data.status !== "HELD") return { refunded: false, reason: "escrow_not_held" };
      const heldAt = data.heldAt?.toDate?.() ?? null;
      if (!heldAt || now - heldAt.getTime() < STALE_ESCROW_MS) {
        return { refunded: false, reason: "not_stale" };
      }
      const found = await findEscrowOrder(escrowId, data, tx);
      const decision = staleEscrowDecision(escrowId, data, found);
      if (decision.action !== "refund") return { refunded: false, ...decision };
      await writeRefund(tx, escrowRef, data, `auto_${decision.reason}`);
      // A cancelled supplier order whose own refund did not finish: record
      // that the refund is now done, in the same transaction.
      if (found.collection === "gas_supplier_orders" && found.order?.data().refundPending === true) {
        tx.update(found.order.ref, {
          refundPending: false, refundedAt: FieldValue.serverTimestamp(), refundedBy: "stale_escrow_recovery",
        });
      }
      return { refunded: true, ...decision };
    });
  }
  exports.refundStaleEscrow = refundStaleEscrow;

  /**
   * Puts a HELD escrow under review: an explicit, durable state on the
   * escrow (reviewStatus "pending", reason, time) plus one alert, written in
   * one transaction. Moves no money. Returns true only for the call that
   * flagged it, so repeated or concurrent runs alert once.
   */
  async function markEscrowForReview(escrowId, reason, { orderCollection = null, orderId = null } = {}) {
    const escrowRef = getDb().collection("escrows").doc(escrowId);
    return getDb().runTransaction(async (tx) => {
      const snap = await tx.get(escrowRef);
      if (!snap.exists || snap.data().status !== "HELD") return false;
      if (snap.data().reviewStatus === "pending") return false;
      tx.update(escrowRef, {
        reviewStatus: "pending",
        reviewReason: reason,
        reviewFlaggedAt: FieldValue.serverTimestamp(),
      });
      tx.set(getDb().collection("admin_alerts").doc(), adminAlert("escrow_review_required",
        `Escrow ${escrowId} needs review (${reason})` +
          (orderId ? ` for ${orderCollection}/${orderId}` : "") +
          ". It stays held; nothing was refunded.",
        { escrowId, reason, orderCollection, orderId }));
      return true;
    });
  }
  exports.markEscrowForReview = markEscrowForReview;

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
        const decision = staleEscrowDecision(doc.id, data, found);
        results.push({ escrowId: doc.id, data, heldAt, ...decision,
          orderCollection: found.collection ?? null, orderId: found.order?.id ?? null });
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

    const summary = { refunded: 0, kept: 0, review: [], underReview: 0, longHeld: [], failed: 0 };
    const flagForReview = async (item, reason) => {
      const flagged = await markEscrowForReview(item.escrowId, reason,
        { orderCollection: item.orderCollection, orderId: item.orderId });
      if (flagged) summary.review.push({ escrowId: item.escrowId, reason });
      else summary.underReview++;
    };
    for (const item of assessed) {
      try {
        if (item.action === "refund") {
          // Decided again inside the refund transaction: a settlement,
          // cancellation or reactivation landing meanwhile wins cleanly.
          const r = await refundStaleEscrow(item.escrowId, { now });
          if (r.refunded) summary.refunded++;
          else if (r.action === "review" && !r.underReview) await flagForReview(item, r.reason);
          else if (r.underReview) summary.underReview++;
          else summary.kept++;
        } else if (item.action === "review") {
          if (item.underReview) summary.underReview++;
          else await flagForReview(item, item.reason);
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
      await getDb().collection("admin_alerts").add(adminAlert("stuck_escrows_released",
        `Stale-escrow recovery returned ${summary.refunded} hold(s) to their owners.`,
        { count: summary.refunded }));
    }
    if (summary.review.length > 0 || summary.longHeld.length > 0) {
      await getDb().collection("admin_alerts").add(adminAlert("escrows_need_review",
        `Stale-escrow recovery: ${summary.review.length} escrow(s) newly under review, ` +
          `${summary.longHeld.length} held over 24 h on orders still in progress.`,
        { review: summary.review.slice(0, 50), longHeld: summary.longHeld.slice(0, 50) }));
    }
    console.log(`recoverStaleEscrows: ${summary.refunded} refunded, ${summary.kept} kept, ` +
      `${summary.review.length} newly in review, ${summary.underReview} already in review, ` +
      `${summary.failed} failed of ${assessed.length}`);
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
      await getDb().collection("admin_alerts").add(adminAlert("reconciliation_anomaly",
        `${report.stuckEscrows} stuck escrows, ` +
          `${report.longHeldEscrows} held over 24 h on active orders, ` +
          `${report.failedWebhooks} failed webhooks`,
        { stuckEscrowDetails: report.stuckEscrowDetails }));
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
  // Called when trip/delivery/gas order creation fails after escrow hold.
  // Returns a hold only while nothing depends on it: not linked to an order
  // and not named by any order's escrowId (a ride names its hold from
  // creation, before the link). An order that names the hold is settled or
  // refunded through that order (completion or cancellation), so a hold can
  // never be returned while its order can still be performed. The checks and
  // the refund run in one transaction; a repeated call refunds nothing more.
  exports.refundEscrowOnError = onCall(
    { region: "europe-west2", minInstances: 0 },
    async (request) => {
      const uid     = requireAuth(request);
      const { escrowId, reason } = request.data ?? {};

      if (typeof escrowId !== "string" || !escrowId || escrowId.includes("/")) {
        throw new HttpsError("invalid-argument", "escrowId required");
      }

      const escrowRef = getDb().collection("escrows").doc(escrowId);
      const orderQueries = Object.values(ESCROW_ORDER_COLLECTIONS).map((c) =>
        getDb().collection(c).where("escrowId", "==", escrowId).limit(1));

      await getDb().runTransaction(async (tx) => {
        const escrow = await tx.get(escrowRef);
        if (!escrow.exists) throw new HttpsError("not-found", "Escrow not found");
        const e = escrow.data();
        if (e.userId !== uid) throw new HttpsError("permission-denied", "Not your escrow");
        if (e.referenceId != null) {
          throw new HttpsError("failed-precondition", "Escrow already attached to an order — cannot refund");
        }
        const named = await Promise.all(orderQueries.map((q) => tx.get(q)));
        if (named.some((s) => !s.empty)) {
          throw new HttpsError("failed-precondition",
            "This payment belongs to a booking. Cancel the booking to get it back.");
        }
        if (e.status !== "HELD") return; // already returned or used: nothing more to do
        await writeRefund(tx, escrowRef, e,
          typeof reason === "string" && reason ? reason : "order_creation_failed");
      });
      return { success: true };
    }
  );
