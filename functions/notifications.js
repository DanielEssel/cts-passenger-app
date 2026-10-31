// functions/notifications.js
const {
  onDocumentUpdated,
  onDocumentCreated,
} = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { jobRejection, selectRecipients } = require("./dispatch_policy");
const { releaseDriverIfCurrent } = require("./active_job");
const { ensureCompletionCode } = require("./completion_codes");
const { secureTripPayment, cancelOrderForPayment, cancelIfAssignedUnpaid } = require("./escrow");
const { verifyGasOrderPrice, verifiedPriceStamp, stampedPrice } = require("./gas_pricing");
const { verifyAndStampDeliveryPrice } = require("./delivery_quotes");
const { publishOffer, withdrawOfferIfTaken, isOpenUnassigned, areaLabel } = require("./order_offers");
const { verifyAndStampRefillStation } = require("./gas_refill_station");

// Lazy getters — avoids calling before admin.initializeApp()
const getDb = () => admin.firestore();
const getFcm = () => admin.messaging();

// ── Offering a request to drivers ────────────────────────────────────────────
// The one path by which Ride, Delivery and Gas requests reach drivers' bells
// and devices. dispatch_policy.js decides who is eligible; a request that
// fails its own checks (no valid location, unknown service, vehicle that
// cannot carry the load) is offered to nobody.

/** FCM errors that mean the token will never work again. */
const DEAD_TOKEN_CODES = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
]);

const DRIVER_QUERIES = {
  ride: (job) => getDb().collection("drivers")
    .where("isAvailable", "==", true)
    .where("isOnline", "==", true)
    .where("isApproved", "==", true)
    .where("role", "==", "driver_hailing")
    .where("serviceType", "==", job.serviceType),
  delivery: () => getDb().collection("drivers")
    .where("isAvailable", "==", true)
    .where("isOnline", "==", true)
    .where("isApproved", "==", true)
    .where("role", "==", "driver_delivery"),
};
DRIVER_QUERIES.gas = DRIVER_QUERIES.delivery;

/** Removes a dead token from a driver, unless the driver has since saved a new one. */
async function dropDeadToken(driverId, token) {
  const ref = getDb().collection("drivers").doc(driverId);
  await getDb().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (snap.exists && snap.get("fcmToken") === token) {
      tx.update(ref, { fcmToken: admin.firestore.FieldValue.delete() });
    }
  });
}

/**
 * Cancels a delivery no vehicle may carry, while it is still pending and
 * unassigned, with the reason in statusReason (the convention driver
 * cancellations use). The existing triggers then do the rest:
 * onDeliveryStatusChanged tells the passenger why, and onDeliveryCancelled
 * returns a wallet hold. Returns true when this call cancelled it.
 */
async function endUndeliverableDelivery(deliveryId, reason) {
  const ref = getDb().collection("deliveries").doc(deliveryId);
  return getDb().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists || snap.get("status") !== "pending" || snap.get("driverId") != null) return false;
    tx.update(ref, {
      status: "cancelled",
      statusReason: reason,
      cancelledBy: "system",
      cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
}

/** What the passenger is told when a delivery ends with `cancelled`. */
function deliveryCancelledMessage(d) {
  if (d.statusReason === "vehicle_cannot_carry_weight_tier") {
    return `${d.vehicleType ?? "That vehicle"} can't carry a ${String(d.weightTier ?? "").toLowerCase()} delivery. ` +
      "Any payment held for it is being returned. Please book again and choose a larger vehicle.";
  }
  if (d.statusReason === "unknown_delivery_vehicle") {
    return "We couldn't match this delivery to a vehicle. Any payment held for it is being returned. Please book again.";
  }
  if (d.cancellationReason === "price_changed" || d.cancellationReason === "quote_not_verified") {
    return "Your delivery was not placed because its price needs to be confirmed again. " +
      "Nothing was charged. Please get a new price and book again.";
  }
  return "Your delivery was cancelled. Contact support if you need help.";
}

/**
 * Notifies the eligible drivers of one request: an inbox entry each, and one
 * push per eligible device. Returns the ids of the drivers notified. Logs
 * counts only (no tokens, names or locations). Never throws.
 */
async function offerToDrivers(service, jobId, job, { inbox, push }) {
  const label = `${service} ${jobId}`;
  try {
    const rejection = jobRejection(service, job);
    if (rejection) {
      console.warn(`${label}: not dispatched (${rejection})`);
      if (rejection === "vehicle_cannot_carry_weight_tier" || rejection === "unknown_delivery_vehicle") {
        // No driver may take it (older Passenger builds offered Okada for
        // Medium): end it now so the passenger is told, rather than left
        // waiting on a request nobody can accept.
        await endUndeliverableDelivery(jobId, rejection)
          .catch((e) => console.error(`${label}: ending it failed:`, e.message));
        await getDb().collection("admin_alerts").add({
          type: "dispatch_rejected", service, jobId, reason: rejection,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }).catch((e) => console.error(`${label}: alert write failed:`, e.message));
      }
      return [];
    }

    const snap = await DRIVER_QUERIES[service](job).get();
    const { recipients, rejected } = selectRecipients(
      service, job, snap.docs.map((d) => ({ id: d.id, data: d.data() })));
    console.log(`${label}: ${recipients.length} eligible of ${snap.size}`, rejected);
    if (recipients.length === 0) return [];

    const batch = getDb().batch();
    for (const r of recipients) {
      batch.set(getDb().collection("drivers").doc(r.id).collection("notifications").doc(), {
        ...inbox,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    await batch.commit()
      .catch((e) => console.error(`${label}: inbox write failed:`, e.message));

    const sendable = recipients.filter((r) => r.token);
    if (sendable.length === 0) return recipients.map((r) => r.id);
    const response = await getFcm().sendEachForMulticast({
      tokens: sendable.map((r) => r.token),
      android: {
        priority: "high", // immediate delivery even in Doze
        notification: { channelId: "driver_trips", sound: "default" },
      },
      apns: { payload: { aps: { sound: "default" } } },
      data: push,
    });
    console.log(`${label}: FCM success=${response.successCount} failure=${response.failureCount}`);
    await Promise.all(response.responses.map((r, i) =>
      !r.success && DEAD_TOKEN_CODES.has(r.error?.code)
        ? dropDeadToken(sendable[i].id, sendable[i].token)
          .catch((e) => console.error(`${label}: token cleanup failed:`, e.message))
        : null));
    return recipients.map((r) => r.id);
  } catch (e) {
    console.error(`${label}: driver notification failed:`, e.message);
    return [];
  }
}

// ── Freeing the driver when a job ends ──────────────────────────────────────
// currentTripId/currentTripType are server-owned (active_job.js): acceptance
// sets them, and these triggers clear both when the job they name ends.
// The driver is freed only while the pointer is still this job, so ending an
// older job never clears a newer one, and a repeat run changes nothing.
// Rides are freed here on completion; Delivery and Gas completion is left to
// settlement (trips.js, escrow.js), which applies the same check.
// 'flagged' (held for review: fraud check, completion code missing or
// mismatched) frees no one: the driver stays on the job until an admin
// resolves it to completed (settlement frees them) or cancelled (freed here).
const ORDER_ENDED_STATUSES = {
  trips: ["completed", "cancelled", "cancelledByDriver", "cancelledByPassenger", "expired"],
  deliveries: ["cancelled", "cancelledByDriver", "cancelledByPassenger"],
  gas_orders: ["cancelled", "failed"],
};

async function releaseDriverFromEndedOrder(collection, orderId, before, after) {
  const ended = ORDER_ENDED_STATUSES[collection];
  if (!after?.driverId || !ended.includes(after.status) || ended.includes(before?.status)) {
    return false;
  }
  return getDb().runTransaction((tx) => releaseDriverIfCurrent(tx, after.driverId, orderId));
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

function statusChanged(before, after) {
  return before.status !== after.status;
}

// ── Send to PASSENGER ────────────────────────────────────────────────────────
// Reads FCM token from users/{uid}

async function notifyPassenger(
  uid,
  { type, title, body, route, metadata = {} },
) {
  if (!uid) return;

  // Write in-app notification
  await getDb()
    .collection("notifications")
    .doc(uid)
    .collection("items")
    .add({
      type,
      title,
      body,
      route: route ?? null,
      metadata,
      isRead: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    })
    .catch((e) => console.error("Passenger notif write error:", e.message));

  // FCM push
  const userDoc = await getDb().collection("users").doc(uid).get();
  const token = userDoc.data()?.fcmToken;
  if (!token) return;

  await _sendFcm(token, { type, title, body, route, metadata });
}

// ── onTripCreatedNotify: broadcast new ride requests to nearby drivers ───────
// Companion to onGasOrderCreated / onDeliveryCreated. The fare-validation
// onTripCreated in trips.js is separate; two create-triggers on trips/ is fine.
exports.onTripCreatedNotify = onDocumentCreated(
  { region: "europe-west2", document: "trips/{tripId}" },
  async (event) => {
    const data = event.data?.data();
    const tripId = event.params.tripId;
    if (!data) return;

    // Only broadcast while unassigned & searching
    if (data.driverId) return;
    if (data.status && data.status !== "searching") return;

    // A wallet ride is offered to drivers only once its hold is linked and
    // matches the booked price; otherwise it is cancelled (escrow.js
    // secureTripPayment). Cash rides are unchanged.
    if (!(await secureTripPayment(tripId, data))) return;

    await offerToDrivers("ride", tripId, data, {
      inbox: {
        type: "rideRequest",
        title: "New Ride Request 🛵",
        body: `${data.pickupAddress ?? "Nearby pickup"} → ${data.dropoffAddress ?? "destination"} · GH₵${Number(data.estimatedFare ?? 0).toFixed(2)}`,
        route: "/driver-shell",
        metadata: { tripId },
      },
      push: {
        type: "NEW_RIDE_REQUEST",
        tripId,
        pickupAddress: data.pickupAddress ?? "",
        dropoffAddress: data.dropoffAddress ?? "",
        estimatedFare: String(data.estimatedFare ?? 0),
        title: "🛵 New Ride Request",
        body: `${data.pickupAddress ?? "Nearby pickup"} → ${data.dropoffAddress ?? "destination"} · GH₵${Number(data.estimatedFare ?? 0).toFixed(2)}`,
      },
    });
  },
);

// ── Send to DRIVER ────────────────────────────────────────────────────────────
// Reads FCM token from drivers/{uid}

async function notifyDriver(uid, { type, title, body, route, metadata = {} }) {
  if (!uid) return;

  // Write in-app notification to driver notifications subcollection
  await getDb()
    .collection("drivers")
    .doc(uid)
    .collection("notifications")
    .add({
      type,
      title,
      body,
      route: route ?? null,
      metadata,
      isRead: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    })
    .catch((e) => console.error("Driver notif write error:", e.message));

  // FCM push — token from drivers/{uid}
  const driverDoc = await getDb().collection("drivers").doc(uid).get();
  const token = driverDoc.data()?.fcmToken;
  if (!token) return;

  await _sendFcm(token, { type, title, body, route, metadata });
}

// ── Linked-rider supplier offers ─────────────────────────────────────────────
// A gas supplier offers an order to one of its linked riders
// (gas_supplier_fulfilment.js). The rider gets an inbox entry and a push.
// The inbox doc id is deterministic and written with create(), so a redelivered
// event finds it and sends nothing. The push only routes the rider to the
// offers screen; accepting is checked again, server-side, at acceptance.

const RIDER_OFFER_ENDED = new Set(["withdrawn", "timed_out", "cancelled", "revoked"]);

/**
 * Writes the rider's inbox entry once. Returns false when it already exists
 * (the event was delivered before), so the caller sends no push.
 */
async function notifyRiderOnce(uid, { inboxId, type, title, body, orderId, channel = "driver_trips" }, { fcm } = {}) {
  if (!uid) return false;
  const ref = getDb().collection("drivers").doc(uid).collection("notifications").doc(inboxId);
  try {
    await ref.create({
      type,
      title,
      body,
      route: "/gas-supplier-jobs",
      metadata: { orderId },
      isRead: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (e) {
    if (e.code === 6 || /already exists/i.test(e.message ?? "")) return false;
    console.error(`rider offer ${orderId}: inbox write failed:`, e.message);
    return false;
  }

  // Read once: the token the send used is the one cleanup may drop, so a
  // token the rider saved after it is never removed.
  let token;
  try {
    token = (await getDb().collection("drivers").doc(uid).get()).data()?.fcmToken;
    if (!token) return true;
    await (fcm ?? getFcm()).send({
      token,
      notification: { title, body },
      data: { type, orderId },
      android: {
        priority: "high",
        notification: { channelId: channel, sound: "default", tag: `gsro_${orderId}` },
      },
      apns: {
        headers: { "apns-collapse-id": `gsro_${orderId}` },
        payload: { aps: { sound: "default" } },
      },
    });
  } catch (e) {
    console.error(`rider offer ${orderId}: FCM send error:`, e.code ?? e.message);
    if (DEAD_TOKEN_CODES.has(e.code) && token) {
      await dropDeadToken(uid, token).catch((x) => console.error("token cleanup failed:", x.message));
    }
  }
  return true;
}

const toMillis = (t) => (t?.toMillis ? t.toMillis() : t instanceof Date ? t.getTime() : Number(t ?? 0));

/**
 * Decides and sends the offer notifications for one order change. `before`
 * and `after` are the order data. Never throws. Returns the inbox ids pushed
 * and the ids skipped (stale, expired, or already sent).
 */
async function handleRiderOfferChange(before, after, orderId, { now = Date.now(), fcm } = {}) {
  const sent = [];
  const skipped = [];
  try {
    const offer = after?.riderOffer;
    if (offer && offer.seq !== before?.riderOffer?.seq) {
      const id = `gas_rider_offer_${orderId}_${offer.seq}_offer`;
      // A delayed event: push only while this offer is still the current one.
      const live = (await getDb().collection("gas_supplier_orders").doc(orderId).get()).data();
      const cur = live?.riderOffer;
      if (!cur || cur.seq !== offer.seq || cur.driverId !== offer.driverId || toMillis(cur.expiresAt) <= now) {
        skipped.push(id);
      } else if (await notifyRiderOnce(offer.driverId, {
        inboxId: id,
        type: "GAS_SUPPLIER_RIDER_OFFER",
        title: "New gas delivery offer",
        body: "A gas supplier has offered you a delivery. Open Supplier jobs to accept or decline.",
        orderId,
      }, { fcm })) sent.push(id);
      else skipped.push(id);
    }

    const last = after?.lastRiderOffer;
    const prev = before?.lastRiderOffer;
    if (last && RIDER_OFFER_ENDED.has(last.outcome) && (last.seq !== prev?.seq || last.outcome !== prev?.outcome)) {
      const id = `gas_rider_offer_${orderId}_${last.seq}_ended`;
      if (await notifyRiderOnce(last.driverId, {
        inboxId: id,
        type: "GAS_SUPPLIER_RIDER_OFFER_ENDED",
        title: "Gas delivery offer ended",
        body: "A gas delivery offer made to you is no longer available.",
        orderId,
      }, { fcm })) sent.push(id);
      else skipped.push(id);
    }
  } catch (e) {
    console.error(`rider offer ${orderId}: notification failed:`, e.message);
  }
  return { sent, skipped };
}

exports.handleRiderOfferChange = handleRiderOfferChange;
exports.notifyRiderOnce = notifyRiderOnce;

exports.onGasSupplierRiderOfferChanged = onDocumentUpdated(
  { region: "europe-west2", document: "gas_supplier_orders/{orderId}" },
  async (event) => {
    await handleRiderOfferChange(
      event.data.before.data(), event.data.after.data(), event.params.orderId);
  },
);

// ── FCM sender ────────────────────────────────────────────────────────────────

async function _sendFcm(token, { type, title, body, route, metadata = {} }) {
  try {
    await getFcm().send({
      token,
      notification: { title, body },
      data: {
        type,
        route: route ?? "",
        ...Object.fromEntries(
          Object.entries(metadata).map(([k, v]) => [k, String(v)]),
        ),
      },
      android: {
        priority: "high",
        notification: {
          channelId: "CTSDriver_general",
          priority: "high",
          sound: "default",
        },
      },
      apns: {
        payload: { aps: { sound: "default", badge: 1 } },
      },
    });
  } catch (e) {
    console.error("FCM send error:", e.message);
  }
}

// ── Document label ────────────────────────────────────────────────────────────

function _docLabel(key) {
  const labels = {
    profile_photo: "Profile Photo",
    national_id: "National ID",
    drivers_license: "Driver's License",
    vehicle_registration: "Vehicle Registration",
    roadworthy_certificate: "Roadworthy Certificate",
    insurance: "Vehicle Insurance",
    police_clearance: "Police Clearance",
    vehicle_photo_front: "Vehicle Front Photo",
    vehicle_photo_side: "Vehicle Side Photo",
  };
  return labels[key] ?? key;
}

// ─────────────────────────────────────────────────────────────────────────────
// TRIPS — Passenger & Driver notifications
// ─────────────────────────────────────────────────────────────────────────────

exports.onTripStatusChanged = onDocumentUpdated(
  { region: "europe-west2", document: "trips/{tripId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const tripId = event.params.tripId;

    if (!statusChanged(before, after)) return;

    const passengerId = after.passengerId;
    const driverId = after.driverId;
    const driverName = after.driverName ?? "Your driver";
    const passengerName = after.passengerName ?? "Passenger";
    const dropoff = after.dropoffAddress ?? "destination";
    const pickup = after.pickupAddress ?? "pickup";
    const fare = (after.actualFare ?? after.estimatedFare ?? 0).toFixed(2);

    const passengerRoute = `/ride-tracking?tripId=${tripId}`;
    const driverRoute = `/driver/trip-active?tripId=${tripId}`;
    const meta = { tripId };

    // Free the driver when the trip ends, only if still on this trip.
    await releaseDriverFromEndedOrder("trips", tripId, before, after)
      .catch((e) => console.error(`Trip ${tripId}: driver release failed:`, e.message));

    switch (after.status) {
      // ── Driver accepted — notify passenger ──
      case "tripAccepted":
        await notifyPassenger(passengerId, {
          type: "ride",
          title: "Driver assigned 🚗",
          body: `${driverName} is on the way to ${pickup}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      // ── Driver arrived — notify passenger ──
      case "driverArrived":
        await notifyPassenger(passengerId, {
          type: "ride",
          title: "Driver has arrived 📍",
          body: `${driverName} is waiting at your pickup point.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      // ── Trip started — notify passenger ──
      case "tripStarted":
        await notifyPassenger(passengerId, {
          type: "ride",
          title: "Trip started 🚦",
          body: `You're on your way to ${dropoff}. Sit back and enjoy!`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      // ── Trip completed — notify both ──
      case "completed":
        await Promise.all([
          // Passenger
          notifyPassenger(passengerId, {
            type: "ride",
            title: "Trip completed ✓",
            body: `Your trip to ${dropoff} was GHS ${fare}. Rate your driver!`,
            route: `/trip-complete?tripId=${tripId}`,
            metadata: { ...meta, fare },
          }),
          // Driver
          driverId
            ? notifyDriver(driverId, {
                type: "ride",
                title: "Trip completed 💰",
                body: `GHS ${fare} earned. Great job!`,
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;

      // ── Cancelled by passenger — notify driver ──
      case "cancelledByPassenger":
        await Promise.all([
          driverId
            ? notifyDriver(driverId, {
                type: "ride",
                title: "Trip cancelled by passenger",
                body: `${passengerName} cancelled the trip. You're available for new requests.`,
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;

      // ── Cancelled by driver — notify passenger ──
      case "cancelledByDriver":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "ride",
            title: "Driver cancelled",
            body: "Your driver cancelled the trip. Please book again.",
            route: "/shell",
            metadata: meta,
          }),
        ]);
        break;

      // ── No drivers — notify passenger ──
      case "noDriversAvailable":
        await notifyPassenger(passengerId, {
          type: "ride",
          title: "No drivers nearby 😔",
          body: "We couldn't find a driver right now. Please try again in a few minutes.",
          route: "/shell",
          metadata: meta,
        });
        break;
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// GAS ORDERS — Passenger & Driver notifications
// ─────────────────────────────────────────────────────────────────────────────

exports.onGasOrderCreated = onDocumentCreated(
  { region: "europe-west2", minInstances: 0, document: "gas_orders/{orderId}" },
  async (event) => {
    const data = event.data.data();
    const orderId = event.params.orderId;
    const uid = data.passengerId;

    // The completion code lives where the assigned driver cannot read it.
    await ensureCompletionCode("gas_orders", orderId, data)
      .catch((e) => console.error(`Gas order ${orderId}: completion code not stored:`, e.message));

    // The app-written total and delivery fee must be the server's Gas price
    // (gas_pricing.js) before the order is offered to anyone; the price is
    // then stamped on the order (verifiedPrice) for acceptance and
    // settlement. Otherwise the order is cancelled now, nothing is charged
    // (a wallet hold is refunded by the cancellation), and the customer is
    // asked to review the current price and order again.
    const priced = await verifyAndStampGasPrice(orderId);
    if (!priced.ok) {
      if (priced.reason === "order_not_open") return;
      console.warn(`Gas order ${orderId}: ${priced.reason}; cancelled before dispatch`);
      await cancelOrderForPayment("gas_orders", orderId, priced.reason, {
        cancellationReason: priced.reason === "price_changed" ? "price_changed" : "price_not_verified",
        alertType: "gas_price_rejected",
        what: priced.reason === "price_changed"
          ? "its total or delivery fee is not the current server Gas price"
          : `it cannot be priced by the server (${priced.detail ?? "no detail"})`,
      });
      return;
    }

    // A requested refill station (refillStationRef) must be the supplier's
    // own verified, in-stock station serving this order (gas_refill_station.js);
    // its trusted snapshot is stamped as verifiedRefillStation. Otherwise the
    // order is cancelled now, before any driver sees it: never another
    // station or a guessed point. Orders without a reference are unchanged.
    const station = await verifyAndStampRefillStation(orderId);
    if (!station.ok) {
      if (station.reason === "order_not_open") return;
      console.warn(`Gas order ${orderId}: refill station ${station.reason}; cancelled before dispatch`);
      await cancelOrderForPayment("gas_orders", orderId, station.reason, {
        cancellationReason: "refill_station_unavailable",
        alertType: "gas_refill_station_rejected",
        what: `its requested refill station cannot serve it (${station.reason})`,
      });
      return;
    }

    // Instructions and condition notes stay server-side until a driver is assigned.
    await sealPrivateDetails("gas_orders", orderId)
      .catch((e) => console.error(`Gas order ${orderId}: details not sealed:`, e.message));

    // ── 1. Notify passenger ───────────────────────────────────────────────
    await notifyPassenger(uid, {
      type: "gas",
      title: "Gas order placed ✓",
      body: `Your ${data.cylinderSize ?? "gas"} order is pending approval.`,
      route: `/gas-tracking?orderId=${orderId}`,
      metadata: { orderId },
    });

    // ── 2. Offer it to eligible nearby Delivery drivers ──────────────────
    // A wallet order is offered once its hold is linked to it (as for
    // deliveries: attachEscrowToOrder checks the price, the app records
    // escrowId, onGasOrderPaymentAttached then dispatches). Cash orders are
    // dispatched now, as before. Read again: the payment may have been
    // linked while the price was checked, before which
    // onGasOrderPaymentAttached could not offer it (no verified price).
    const current = (await getDb().collection("gas_orders").doc(orderId).get()).data() ?? data;
    if (current.paymentMethod === "wallet" && !(await orderPaymentLinked("gas_orders", orderId, current))) {
      console.log(`Gas order ${orderId}: waiting for its wallet payment before dispatch`);
      return;
    }
    await dispatchGasOrderToDrivers(orderId, current);
  },
);

// ── onGasOrderPaymentAttached: dispatch a wallet Gas order once paid ────────
// As onDeliveryPaymentAttached: fires when an open, unassigned wallet order
// first records its escrowId, and dispatches it only if that hold really is
// this order's payment (owner, link and HELD).
exports.onGasOrderPaymentAttached = onDocumentUpdated(
  { region: "europe-west2", document: "gas_orders/{orderId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const orderId = event.params.orderId;
    if (!after || before?.escrowId != null || after.escrowId == null) return;
    if (after.paymentMethod !== "wallet" || after.status !== "pendingApproval" || after.driverId) return;
    if (!(await orderPaymentLinked("gas_orders", orderId, after))) {
      console.warn(`Gas order ${orderId}: escrowId does not name its linked hold; not dispatched`);
      return;
    }
    await dispatchGasOrderToDrivers(orderId, after);
  },
);

/**
 * Offers a legacy Gas order to eligible nearby Delivery drivers: publishes
 * its offer (order_offers.js; only a priced, open, unassigned order has one)
 * and notifies drivers once, by the call that published it.
 */
async function dispatchGasOrderToDrivers(orderId, data) {
  // A job nobody may take is not listed (offerToDrivers handles it below).
  if (!jobRejection("gas", data) && await publishOffer("gas_orders", orderId) !== "published") {
    console.log(`Gas order ${orderId}: no new offer; drivers not notified`);
    return;
  }
  // Drivers see the area only (order_offers.js): never the street address.
  const area = areaLabel(data.deliveryAddress ?? data.pickupAddress) || "Nearby";
  const total = stampedPrice(data)?.total ?? data.totalPrice ?? 0;
  // No route in the push: like ride and delivery requests, a tap opens the
  // app on its request list, where acceptance goes through acceptGasOrder.
  await offerToDrivers("gas", orderId, data, {
    inbox: {
      type: "gasOrder",
      title: "New Gas Order 🔥",
      body: `${data.cylinderSize ?? "Gas cylinder"} delivery — ${area}`,
      route: "/driver-shell",
      metadata: { orderId },
    },
    push: {
      type: "NEW_GAS_REQUEST",
      orderId,
      pickupAddress: area,
      deliveryAddress: area,
      cylinderSize: data.cylinderSize ?? "",
      totalPrice: String(total),
      title: "🔥 New Gas Order",
      body: `${data.cylinderSize ?? "Gas cylinder"} delivery — ${area}`,
    },
  });
}

/**
 * Checks a new Gas order's own amounts against the server price and stamps
 * verifiedPrice on it, in one transaction on the order as it is now (a
 * retry finds its own stamp and agrees). Returns {ok: true} or
 * {ok: false, reason, detail?}; reason "order_not_open" when the order was
 * cancelled or taken meanwhile (nothing to do).
 */
async function verifyAndStampGasPrice(orderId) {
  const ref = getDb().collection("gas_orders").doc(orderId);
  const settingsRef = getDb().collection("settings").doc("platform");
  return getDb().runTransaction(async (tx) => {
    const [snap, settingsSnap] = await Promise.all([tx.get(ref), tx.get(settingsRef)]);
    const order = snap.exists ? snap.data() : null;
    if (!isOpenUnassigned("gas_orders", order)) return { ok: false, reason: "order_not_open" };
    if (stampedPrice(order)) return { ok: true };
    const check = verifyGasOrderPrice(order, settingsSnap.exists ? settingsSnap.data() : null);
    if (!check.ok) return { ok: false, reason: check.reason, detail: check.detail };
    tx.update(ref, {
      verifiedPrice: { ...verifiedPriceStamp(check.quote), verifiedAt: admin.firestore.FieldValue.serverTimestamp() },
    });
    return { ok: true };
  });
}

/**
 * Copies the passenger's name and phone onto a delivery once a driver is
 * assigned to it. Drivers may read the assigned delivery but not passenger
 * user documents; before assignment the order is readable by every active
 * delivery driver, so the contact is not written then.
 */
async function attachPassengerContact(deliveryId, uid) {
  if (!uid) return;
  const passengerSnap = await getDb().collection("users").doc(uid).get();
  if (!passengerSnap.exists) return;
  const passenger = passengerSnap.data() || {};
  const text = (v) => (typeof v === "string" ? v.trim() : "");
  const passengerName = text(passenger.displayName) ||
    `${text(passenger.firstName)} ${text(passenger.lastName)}`.trim();
  const passengerPhone = text(passenger.phoneNumber);
  await getDb().collection("deliveries").doc(deliveryId).update({
    passengerName: passengerName || null,
    passengerPhone: passengerPhone || null,
  });
}

// ── onDeliveryCreated: notify passenger + nearby drivers ─────────────────────
exports.onDeliveryCreated = onDocumentCreated(
  {
    region: "europe-west2",
    minInstances: 0,
    document: "deliveries/{deliveryId}",
  },
  async (event) => {
    const data = event.data.data();
    const deliveryId = event.params.deliveryId;
    const uid = data.passengerId;

    // The completion code lives where the assigned driver cannot read it.
    await ensureCompletionCode("deliveries", deliveryId, data)
      .catch((e) => console.error(`Delivery ${deliveryId}: completion code not stored:`, e.message));

    // The price must be the server's (delivery_quotes.js): the order's own
    // quote, unexpired, unused, for these endpoints and this parcel, at this
    // fare and the current rates; it is stamped as verifiedPrice. Otherwise
    // the delivery is cancelled before anyone sees it or anything is held for
    // it (a wallet hold is refunded by the cancellation) and the customer is
    // asked to get a new price.
    // A booking no vehicle may carry (older Passenger builds) skips this: the
    // dispatch below ends it with that reason and nothing is offered.
    const priced = jobRejection("delivery", data) ? { ok: true } : await verifyAndStampDeliveryPrice(deliveryId);
    if (!priced.ok) {
      if (priced.reason === "order_not_open") return;
      console.warn(`Delivery ${deliveryId}: ${priced.reason}; cancelled before dispatch`);
      await cancelOrderForPayment("deliveries", deliveryId, priced.reason, {
        cancellationReason: priced.reason === "price_changed" ? "price_changed" : "quote_not_verified",
        alertType: "delivery_price_rejected",
        what: `its price could not be verified (${priced.reason})`,
      });
      return;
    }

    // Receiver contact, notes and photo stay server-side until a driver is assigned.
    await sealPrivateDetails("deliveries", deliveryId)
      .catch((e) => console.error(`Delivery ${deliveryId}: details not sealed:`, e.message));

    // Passenger contact details are copied when a driver is assigned
    // (onDeliveryStatusChanged → attachPassengerContact), not now: an open
    // delivery is readable by every active delivery driver.

    // ── 1. Notify passenger ───────────────────────────────────────────────
    await notifyPassenger(uid, {
      type: "delivery",
      title: "Delivery request placed ✓",
      body: `Looking for a driver to deliver your ${data.parcelType ?? "parcel"}.`,
      route: `/delivery-tracking?deliveryId=${deliveryId}`,
      metadata: { deliveryId },
    });

    // ── 2. Notify nearby delivery drivers ─────────────────────────────────
    // A wallet delivery is offered once its hold is linked to it
    // (attachEscrowToOrder records escrowId; onDeliveryPaymentAttached then
    // dispatches). Cash deliveries are dispatched now, as before.
    // Read again: the payment may have been linked while the price was
    // checked, before which onDeliveryPaymentAttached could not offer it.
    const current = (await getDb().collection("deliveries").doc(deliveryId).get()).data() ?? data;
    if (current.paymentMethod === "wallet" && !(await orderPaymentLinked("deliveries", deliveryId, current))) {
      console.log(`Delivery ${deliveryId}: waiting for its wallet payment before dispatch`);
      return;
    }
    await dispatchDeliveryToDrivers(deliveryId, current);
  },
);

// ── onDeliveryPaymentAttached: dispatch a wallet delivery once paid ─────────
// Fires when a pending, unassigned wallet delivery first records its
// escrowId, and dispatches it only if that hold really is this delivery's
// payment (owner, link and HELD), however escrowId was written.
exports.onDeliveryPaymentAttached = onDocumentUpdated(
  { region: "europe-west2", document: "deliveries/{deliveryId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const deliveryId = event.params.deliveryId;
    if (!after || before?.escrowId != null || after.escrowId == null) return;
    if (after.paymentMethod !== "wallet" || after.status !== "pending" || after.driverId) return;
    if (!(await orderPaymentLinked("deliveries", deliveryId, after))) {
      console.warn(`Delivery ${deliveryId}: escrowId does not name its linked hold; not dispatched`);
      return;
    }
    await dispatchDeliveryToDrivers(deliveryId, after);
  },
);

const PAID_ORDER_REFERENCE_TYPE = { deliveries: "delivery", gas_orders: "gas_order" };

/**
 * A wallet Delivery or Gas order that a driver took before its payment was
 * linked (open orders are listed to drivers, and older Driver builds claimed
 * them directly) is cancelled at once, before anyone sets out: settlement
 * would never pay for it. Decided in a transaction on the order and hold as
 * they are now (escrow.js cancelIfAssignedUnpaid), so a stale event never
 * cancels an order paid meanwhile. The cancellation's own status event frees
 * the driver. Returns true when it cancelled the order.
 */
async function cancelUnpaidAssignment(collection, orderId, after) {
  if (after?.status !== "driverAssigned" || after.paymentMethod !== "wallet") return false;
  return cancelIfAssignedUnpaid(collection, orderId);
}

// ── Order details hidden from unassigned drivers ────────────────────────────
// An open order is readable by every active Delivery driver (they list open
// requests from it). The fields below are not needed to decide on a job, and
// every app reads them as optional; the create triggers move them to
// {order}/private/details, which no client may read (firestore.rules has no
// match for it), and the status triggers copy them back once a driver holds
// the job. Addresses and locations stay: the apps require them on the order.
const PRIVATE_FIELDS = Object.freeze({
  deliveries: ["receiverName", "receiverPhone", "notes", "photoUrl"],
  gas_orders: ["pickupInstructions", "deliveryInstructions", "cylinderConditionNotes", "receiptEmail"],
});
const privateRef = (collection, orderId) =>
  getDb().collection(collection).doc(orderId).collection("private").doc("details");

/** Moves the order's private fields out while it is still open and unassigned. Returns true when it did. */
async function sealPrivateDetails(collection, orderId) {
  const fields = PRIVATE_FIELDS[collection];
  const ref = getDb().collection(collection).doc(orderId);
  return getDb().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const o = snap.exists ? snap.data() : null;
    if (!o || o.driverId != null) return false; // already taken: its driver may see them
    const present = fields.filter((k) => o[k] !== undefined);
    if (present.length === 0) return false;
    const held = Object.fromEntries(present.map((k) => [k, o[k]]));
    tx.set(privateRef(collection, orderId), held, { merge: true });
    tx.update(ref, Object.fromEntries(present.map((k) => [k, admin.firestore.FieldValue.delete()])));
    return true;
  });
}

/** Copies the private fields back onto an order its driver now holds. Returns true when it did. */
async function revealPrivateDetails(collection, orderId, driverId) {
  const ref = getDb().collection(collection).doc(orderId);
  return getDb().runTransaction(async (tx) => {
    const [snap, held] = await Promise.all([tx.get(ref), tx.get(privateRef(collection, orderId))]);
    const o = snap.exists ? snap.data() : null;
    if (!o || !held.exists || o.status !== "driverAssigned" || !driverId || o.driverId !== driverId) {
      return false;
    }
    const fields = Object.fromEntries(PRIVATE_FIELDS[collection]
      .filter((k) => held.data()[k] !== undefined && o[k] === undefined)
      .map((k) => [k, held.data()[k]]));
    if (Object.keys(fields).length === 0) return false;
    tx.update(ref, fields);
    return true;
  });
}

/** True when the order's escrowId is its passenger's HELD hold, linked to it. */
async function orderPaymentLinked(collection, orderId, data) {
  if (typeof data.escrowId !== "string" || !data.escrowId) return false;
  const snap = await getDb().collection("escrows").doc(data.escrowId).get();
  const e = snap.exists ? snap.data() : null;
  return !!e && e.status === "HELD" && e.userId === data.passengerId &&
    e.referenceId === orderId && e.referenceType === PAID_ORDER_REFERENCE_TYPE[collection];
}

/**
 * Offers a delivery request to eligible nearby Delivery drivers: publishes
 * its offer (order_offers.js) and notifies drivers once, by the call that
 * published it.
 */
async function dispatchDeliveryToDrivers(deliveryId, data) {
  // A job nobody may take (e.g. a vehicle that cannot carry its weight tier)
  // is not listed; offerToDrivers ends it and alerts operations.
  if (!jobRejection("delivery", data) && await publishOffer("deliveries", deliveryId) !== "published") {
    console.log(`Delivery ${deliveryId}: no new offer; drivers not notified`);
    return;
  }
  // Drivers see areas only (order_offers.js): never the street addresses.
  const pickupArea = areaLabel(data.pickupAddress) || "Nearby";
  const dropoffArea = areaLabel(data.dropoffAddress) || "Nearby";
  await offerToDrivers("delivery", deliveryId, data, {
    inbox: {
      type: "delivery",
      title: "New Delivery Request 📦",
      body: `${data.parcelType ?? "Parcel"} — ${pickupArea}`,
      route: "/driver-shell",
      metadata: { deliveryId },
    },
    push: {
      type: "NEW_DELIVERY_REQUEST",
      deliveryId,
      pickupAddress: pickupArea,
      dropoffAddress: dropoffArea,
      parcelType: data.parcelType ?? "",
      estimatedFare: String(data.estimatedFare ?? 0),
      weightTier: data.weightTier ?? "",
      title: "📦 New Delivery Request",
      body: `${data.parcelType ?? "Parcel"} — ${pickupArea}`,
    },
  });
}

exports.onGasOrderStatusChanged = onDocumentUpdated(
  { region: "europe-west2", document: "gas_orders/{orderId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const orderId = event.params.orderId;

    if (!statusChanged(before, after)) return;
    // No longer open: drivers stop seeing it (acceptance already removed it).
    if (!isOpenUnassigned("gas_orders", after)) {
      await withdrawOfferIfTaken("gas_orders", orderId)
        .catch((e) => console.error(`Gas order ${orderId}: offer not withdrawn:`, e.message));
    }
    if (await cancelUnpaidAssignment("gas_orders", orderId, after)) return;
    if (after.status === "driverAssigned" && after.driverId) {
      await revealPrivateDetails("gas_orders", orderId, after.driverId)
        .catch((e) => console.error(`Gas order ${orderId}: details not copied:`, e.message));
    }

    await releaseDriverFromEndedOrder("gas_orders", orderId, before, after)
      .catch((e) => console.error(`gas_orders ${orderId}: driver release failed:`, e.message));

    const passengerId = after.passengerId;
    const driverId = after.driverId;
    const driverName = after.driverName ?? "Your driver";
    const cylinderSize = after.cylinderSize ?? "gas cylinder";
    const totalPrice = Number(after.totalPrice ?? 0).toFixed(2);

    const passengerRoute = `/gas-tracking?orderId=${orderId}`;
    const driverRoute = `/driver/active-gas?orderId=${orderId}`;
    const meta = { orderId };

    switch (after.status) {
      case "driverAssigned":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "gas",
            title: "Gas order confirmed 🔥",
            body: `${driverName} will pick up your ${cylinderSize} shortly.`,
            route: passengerRoute,
            metadata: meta,
          }),
          driverId
            ? notifyDriver(driverId, {
                type: "gas",
                title: "New gas order 🔥",
                body: `Pick up ${cylinderSize} for delivery.`,
                route: driverRoute,
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;

      case "driverEnRoute":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "Driver en route 🚗",
          body: `${driverName} is heading to your location.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "driverArrived":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "Driver has arrived 📍",
          body: `${driverName} is at your location with your ${cylinderSize}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "pickedUp":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "Cylinder collected 📦",
          body: `${driverName} has collected your ${cylinderSize}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;
      case "atStation":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "At the refill station ⛽",
          body: `Your ${cylinderSize} has reached the station for refilling.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;
      case "refilling":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "Refilling your cylinder 🔥",
          body: `Your ${cylinderSize} is being refilled now.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;
      case "returning":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "On the way back 🔄",
          body: `${driverName} is returning with your refilled ${cylinderSize}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "delivered":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "gas",
            title: "Gas delivered! 🎉",
            body: `Your ${cylinderSize} has been delivered. Total: GHS ${totalPrice}.`,
            route: "/shell",
            metadata: { ...meta, totalPrice },
          }),
          driverId
            ? notifyDriver(driverId, {
                type: "gas",
                title: "Gas order completed 💰",
                body: `GHS ${totalPrice} earned for gas delivery.`,
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;

      case "cancelledByPassenger":
      case "cancelled":
        await Promise.all([
          notifyPassenger(passengerId, after.cancellationReason === "price_changed"
            ? {
                type: "gas",
                title: "Gas price changed",
                body: "Your order was not placed because the gas price has changed. " +
                  "Nothing was charged. Please review the new price and order again.",
                route: "/shell",
                metadata: { ...meta, reason: "price_changed" },
              }
            : {
                type: "gas",
                title: "Gas order cancelled",
                body: "Your gas order was cancelled. Any charges will be refunded.",
                route: "/shell",
                metadata: meta,
              }),
          driverId
            ? notifyDriver(driverId, {
                type: "gas",
                title: "Gas order cancelled",
                body: "The gas order was cancelled by the passenger.",
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// DELIVERIES — Passenger & Driver notifications
// ─────────────────────────────────────────────────────────────────────────────

exports.onDeliveryStatusChanged = onDocumentUpdated(
  { region: "europe-west2", document: "deliveries/{deliveryId}" }, // ✅ Fixed collection name
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const deliveryId = event.params.deliveryId;

    if (!statusChanged(before, after)) return;
    // No longer open: drivers stop seeing it (acceptance already removed it).
    if (!isOpenUnassigned("deliveries", after)) {
      await withdrawOfferIfTaken("deliveries", deliveryId)
        .catch((e) => console.error(`Delivery ${deliveryId}: offer not withdrawn:`, e.message));
    }
    if (await cancelUnpaidAssignment("deliveries", deliveryId, after)) return;

    if (after.status === "driverAssigned" && after.driverId) {
      await attachPassengerContact(deliveryId, after.passengerId ?? after.userId)
        .catch((e) => console.error(`Delivery ${deliveryId}: passenger contact not attached:`, e.message));
      await revealPrivateDetails("deliveries", deliveryId, after.driverId)
        .catch((e) => console.error(`Delivery ${deliveryId}: details not copied:`, e.message));
    }
    await releaseDriverFromEndedOrder("deliveries", deliveryId, before, after)
      .catch((e) => console.error(`deliveries ${deliveryId}: driver release failed:`, e.message));

    const passengerId = after.passengerId ?? after.userId;
    const driverId = after.driverId;
    const driverName = after.driverName ?? "Your rider";
    const dropoff = after.dropoffAddress ?? "destination";
    const fare = (after.actualFare ?? after.estimatedFare ?? 0).toFixed(2);

    const passengerRoute = `/delivery-tracking?deliveryId=${deliveryId}`;
    const driverRoute = `/driver/active-delivery?deliveryId=${deliveryId}`;
    const meta = { deliveryId };

    switch (after.status) {
      case "driverAssigned":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "delivery",
            title: "Rider assigned 🏍️",
            body: `${driverName} will pick up your parcel shortly.`,
            route: passengerRoute,
            metadata: meta,
          }),
          driverId
            ? notifyDriver(driverId, {
                type: "delivery",
                title: "New delivery request 📦",
                body: `Pick up parcel for delivery to ${dropoff}.`,
                route: driverRoute,
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;

      case "pickupEnroute":
        await notifyPassenger(passengerId, {
          type: "delivery",
          title: "Rider on the way 🏍️",
          body: `${driverName} is heading to pick up your parcel.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "arrivedAtPickup":
        await notifyPassenger(passengerId, {
          type: "delivery",
          title: "Rider arrived at pickup 📍",
          body: `${driverName} has arrived to collect your parcel.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "packagePicked":
        await notifyPassenger(passengerId, {
          type: "delivery",
          title: "Parcel picked up 📦",
          body: `${driverName} has collected your parcel and is heading to ${dropoff}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "deliveryEnroute":
        await notifyPassenger(passengerId, {
          type: "delivery",
          title: "Parcel out for delivery 🚀",
          body: `Your parcel is on the way to ${dropoff}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "arrivedAtDropoff":
        await notifyPassenger(passengerId, {
          type: "delivery",
          title: "Rider at drop-off 📍",
          body: `${driverName} has arrived at ${dropoff} with your parcel.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "completed":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "delivery",
            title: "Parcel delivered! ✓",
            body: `Your parcel was delivered to ${dropoff}. Total: GHS ${fare}.`,
            route: "/shell",
            metadata: { ...meta, fare },
          }),
          driverId
            ? notifyDriver(driverId, {
                type: "delivery",
                title: "Delivery completed 💰",
                body: `GHS ${fare} earned for delivery to ${dropoff}.`,
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;

      case "cancelledByPassenger":
      case "cancelledByPassenger":
        await (driverId
          ? notifyDriver(driverId, {
              type: "delivery",
              title: "Delivery cancelled",
              body: "The delivery was cancelled by the passenger.",
              route: "/driver-shell",
              metadata: meta,
            })
          : Promise.resolve());
        break;

      case "cancelledByDriver":
        await notifyPassenger(passengerId, {
          type: "delivery",
          title: "Delivery cancelled",
          body: "Your driver cancelled the delivery. Please book again.",
          route: "/shell",
          metadata: meta,
        });
        break;

      case "cancelled": // legacy — status with no recorded actor
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "delivery",
            title: "Delivery cancelled",
            body: deliveryCancelledMessage(after),
            route: "/shell",
            metadata: meta,
          }),
          driverId
            ? notifyDriver(driverId, {
                type: "delivery",
                title: "Delivery cancelled",
                body: "The delivery was cancelled.",
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// WALLET — Low balance alert (passengers only)
// ─────────────────────────────────────────────────────────────────────────────

exports.onWalletChanged = onDocumentUpdated(
  { region: "europe-west2", document: "wallets/{uid}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const uid = event.params.uid;

    const prevBalance = before.balance ?? 0;
    const newBalance = after.balance ?? 0;
    const diff = newBalance - prevBalance;

    if (Math.abs(diff) < 0.01) return;

    // ✅ Only notify on top-up (credit) or low balance — not every debit
    if (diff > 0) {
      // Wallet topped up
      await notifyPassenger(uid, {
        type: "wallet",
        title: "Wallet topped up 💳",
        body: `GHS ${diff.toFixed(2)} added. Balance: GHS ${newBalance.toFixed(2)}.`,
        route: "/shell?tab=wallet",
        metadata: { amount: diff, balance: newBalance },
      });
    } else if (newBalance < 10 && prevBalance >= 10) {
      // Only notify once when balance drops below threshold
      await notifyPassenger(uid, {
        type: "wallet",
        title: "Low wallet balance ⚠️",
        body: `Your balance is GHS ${newBalance.toFixed(2)}. Top up to keep using CTSTransport.`,
        route: "/shell?tab=wallet",
        metadata: { balance: newBalance },
      });
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// DOCUMENT EXPIRY CHECK — daily at 8am Ghana time
// ─────────────────────────────────────────────────────────────────────────────

exports.checkDocumentExpiry = onSchedule(
  {
    schedule: "0 8 * * *",
    timeZone: "Africa/Accra",
    region: "europe-west2",
    minInstances: 0,
  },
  async () => {
    const now = new Date();

    const drivers = await getDb()
      .collection("drivers")
      .where("isApproved", "==", true)
      .get();

    const promises = [];

    for (const driverDoc of drivers.docs) {
      const data = driverDoc.data();
      const documents = data.documents ?? {};
      const fcmToken = data.fcmToken;
      const uid = driverDoc.id;

      for (const [key, value] of Object.entries(documents)) {
        if (!value?.expiryDate) continue;

        const expiry = value.expiryDate.toDate();
        const daysLeft = Math.ceil((expiry - now) / (1000 * 60 * 60 * 24));
        const label = _docLabel(key);

        let payload = null;

        if (daysLeft <= 0) {
          payload = {
            type: "documentExpiry",
            title: `⚠️ ${label} Expired`,
            body: `Your ${label} has expired. Upload a new one to continue driving.`,
            route: "/driver/documents",
          };
        } else if (daysLeft <= 7) {
          payload = {
            type: "documentExpiry",
            title: `⏰ ${label} Expiring Soon`,
            body: `Your ${label} expires in ${daysLeft} day${daysLeft === 1 ? "" : "s"}. Update it now.`,
            route: "/driver/documents",
          };
        } else if (daysLeft <= 30) {
          payload = {
            type: "documentExpiry",
            title: `📅 ${label} Expiring in ${daysLeft} Days`,
            body: `Your ${label} expires on ${expiry.toDateString()}. Plan to renew it soon.`,
            route: "/driver/documents",
          };
        }

        if (payload) {
          promises.push(notifyDriver(uid, payload));
        }
      }
    }

    await Promise.allSettled(promises);
    console.log(
      `Document expiry check complete. Processed ${drivers.size} drivers.`,
    );
  },
);

// ── Admin broadcast notification ──────────────────────────────────────────────
const { onCall, HttpsError } = require("firebase-functions/v2/https");

exports.broadcastNotification = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
    // Verify admin
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in");

    const adminDoc = await getDb().collection("admins").doc(uid).get();
    if (!adminDoc.exists || !adminDoc.data()?.active) {
      throw new HttpsError("permission-denied", "Admin access required");
    }

    const { title, message, target, userId } = request.data;
    if (!title || !message) {
      throw new HttpsError("invalid-argument", "Title and message required");
    }

    let tokens = [];
    let targetUids = [];

    if (target === "all_passengers") {
      const snap = await getDb()
        .collection("users")
        .where("fcmToken", "!=", null)
        .get();
      snap.docs.forEach((d) => {
        if (d.data().fcmToken) {
          tokens.push(d.data().fcmToken);
          targetUids.push(d.id);
        }
      });
    } else if (target === "all_drivers") {
      const snap = await getDb()
        .collection("drivers")
        .where("fcmToken", "!=", null)
        .get();
      snap.docs.forEach((d) => {
        if (d.data().fcmToken) {
          tokens.push(d.data().fcmToken);
          targetUids.push(d.id);
        }
      });
    } else if (target === "specific_user" && userId) {
      // Try users first, then drivers
      const userDoc = await getDb().collection("users").doc(userId).get();
      const driverDoc = await getDb().collection("drivers").doc(userId).get();
      const token = userDoc.data()?.fcmToken || driverDoc.data()?.fcmToken;
      if (token) {
        tokens.push(token);
        targetUids.push(userId);
      }
    }

    if (tokens.length === 0) {
      return {
        success: false,
        message: "No FCM tokens found for target audience",
      };
    }

    // Send FCM in batches of 500
    const batchSize = 500;
    let successCount = 0;
    let failCount = 0;

    for (let i = 0; i < tokens.length; i += batchSize) {
      const batch = tokens.slice(i, i + batchSize);
      try {
        const response = await getFcm().sendEachForMulticast({
          tokens: batch,
          notification: { title, body: message },
          data: { type: "admin_broadcast", route: "" },
          android: {
            priority: "high",
            notification: {
              channelId: "CTSDriver_general",
              sound: "default",
            },
          },
          apns: {
            payload: { aps: { sound: "default", badge: 1 } },
          },
        });
        successCount += response.successCount;
        failCount += response.failureCount;
      } catch (e) {
        console.error("Batch FCM error:", e.message);
        failCount += batch.length;
      }
    }

    // Write to in-app notifications for all targets
    const batch = getDb().batch();
    for (const uid of targetUids) {
      const collection =
        target === "all_drivers"
          ? getDb().collection("drivers").doc(uid).collection("notifications")
          : getDb().collection("notifications").doc(uid).collection("items");
      const ref = collection.doc();
      batch.set(ref, {
        type: "admin_broadcast",
        title,
        body: message,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    await batch
      .commit()
      .catch((e) => console.error("Batch write error:", e.message));

    console.log(
      `Broadcast: ${successCount} sent, ${failCount} failed to ${tokens.length} devices`,
    );
    return {
      success: true,
      sent: successCount,
      failed: failCount,
      totalTargets: tokens.length,
    };
  },
);
