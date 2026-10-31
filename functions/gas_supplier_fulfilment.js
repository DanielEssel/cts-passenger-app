"use strict";

/**
 * Gas supplier-order fulfilment: payment verification, supplier and driver
 * steps, cancellation and completion for gas_supplier_orders.
 *
 * GATED OFF. Every callable reads settings/gas_supplier_fulfilment at call
 * time and refuses unless `enabled === true`; a missing document means off.
 * The two exceptions are passenger and admin cancellation: switching the
 * flag off stops all new work, but an order that already exists can still
 * be cancelled and its hold refunded, so the switch never strands funds.
 * The escrow attach/capture/refund path was approved for implementation by
 * the project owner on 2026-10-24 on the condition that it stays off until
 * the escrow security review and an explicit production go-ahead. The one
 * schedule (every minute) runs the supplier response deadline and the
 * linked-rider offer deadlines, whether or not ordering is switched on.
 *
 * Lifecycle (status names are the existing ones: "awaiting_payment" from
 * gas_supplier_orders.js and the passenger app's GasOrderStatus enum):
 *
 *   awaiting_payment  --pay (passenger)----------------> pendingApproval
 *   pendingApproval   --supplier accepts---------------> confirmed
 *   pendingApproval   --supplier declines--------------> cancelled (+refund)
 *   pendingApproval   --supplier accepts and chooses who delivers (deliveryMode):
 *     "ctsgo_driver"   CTSGo dispatch (the only choice for "ctsgo_dispatch" suppliers)
 *     "supplier_rider" the supplier's own rider ("supplier_riders_ctsgo_fallback"
 *                      suppliers only; never offered to CTSGo drivers)
 *     "linked_rider"   a CTSGo driver linked to the supplier (gas_supplier_riders),
 *                      offered by the supplier to one rider at a time ("supplier_riders_ctsgo_fallback"
 *                      suppliers with at least one active link; never offered to other drivers)
 *   confirmed (supplier_rider) --supplier requests a CTSGo driver-> confirmed (ctsgo_driver)
 *   confirmed (linked_rider, no driver) --supplier requests a CTSGo driver-> confirmed (ctsgo_driver)
 *   confirmed (linked_rider) --supplier assigns a rider (replacesSeq)--> offer riderOfferSeq+1
 *     (the previous offer, if any, is withdrawn; a retry of the same call returns the same offer)
 *   offer --the named rider accepts (offerSeq, before expiresAt, still eligible,
 *     link active, fee == allocation.driverNetPesewas)--> driverAssigned
 *     (linkedSupplierId and acceptedFeePesewas set in the accept transaction)
 *   offer --the named rider declines--> no offer (the rider is not offered it again);
 *     the MAX_RIDER_DECLINES-th decline --> confirmed (ctsgo_driver, "riders_declined")
 *   offer --sweep at or after expiresAt (expireRiderOffers)--> confirmed (ctsgo_driver, "rider_timeout")
 *   no offer --sweep at or after riderDeadlineAt--> confirmed (ctsgo_driver, "no_rider_assigned")
 *     After any fallback, a rider who declined the order or let its offer time
 *     out neither sees nor may accept it as a CTSGo job (poolExclusion);
 *     every other eligible CTSGo driver may.
 *   driverAssigned|atStation (linked_rider) --admin releases the rider-->
 *     confirmed (ctsgo_driver, "admin_release"); the rider may not take it again
 *   confirmed (supplier_rider) --supplier hands to its rider----> outForDelivery
 *   outForDelivery (supplier_rider) --supplier submits customer's code-> delivered (+capture)
 *   confirmed         --driver accepts (dispatch policy)> driverAssigned
 *   driverAssigned    --driver at the station----------> atStation
 *   atStation         --supplier hands over------------> outForDelivery
 *   outForDelivery    --driver submits customer's code-> delivered (+capture)
 *   driverAssigned|atStation --admin releases driver-> confirmed (reassignment:
 *     before the supplier hands the cylinder over; the released driver is
 *     freed if still on it and may not take this order again)
 *   any state before delivered --cancel----------------> cancelled (+refund)
 *     passenger: awaiting_payment, pendingApproval, confirmed
 *     admin (active, with a reason): any state before delivered
 *     A pending rider offer ends as "cancelled". After the hand-over
 *     (outForDelivery) the cancel also raises gas_cylinder_recovery_{orderId}
 *     (F5): the cylinder is recovered offline. Nobody earns the delivery fee
 *     of a cancelled order (F4): nothing is posted.
 *
 * Only station-to-door order types are fulfilled here (exchangeEmpty,
 * newCylinder, commercialBulk). pickupAndReturn needs a customer pickup
 * leg that this lifecycle does not model, so it is refused at payment and
 * no money is taken.
 *
 * Money (escrows are untrusted; every field is checked):
 *   - pay: within the quote's lifetime again after the quote expired, and
 *     only if the supplier, station and product still offer the order at
 *     the same priceVersion, the order's allocation still reconciles with
 *     its price snapshot, and commission terms are still approved and
 *     active (current terms switched off stop new payments; the order keeps
 *     the version it was created under). Then the passenger's own HELD escrow
 *     (escrow.js holdBalance), not
 *     attached anywhere, referenceType null or "gas_supplier_order", amount
 *     equal to priceSnapshot.total (holdMatchesSnapshot). It is bound to
 *     the order server-side (referenceId/referenceType + escrowOrderLinks).
 *     escrow.js attachEscrowToOrder is never used for supplier orders.
 *   - complete: HELD -> CAPTURED in the same transaction that marks the
 *     order delivered, re-reading order and escrow; the passenger's
 *     heldBalance falls by the amount and a CAPTURE row goes to the shared
 *     ledger. No wallet is credited: the captured funds are distributed
 *     only through gas_settlement_ledger.js (supplier entitlement, driver
 *     delivery fee, CTSGo commission), posted right after delivery (a
 *     failure there raises an admin alert; super admins can post by hand).
 *     The existing escrow release (driverNet to a driver wallet) is never used.
 *   - cancel: escrow.js refundEscrow (HELD only, owner and reference
 *     checked). If the refund cannot run, the order keeps refundPending and
 *     a later cancel call retries it.
 *   - order.payment.status records what the escrow did, as written in the
 *     same step: "held" (pay), "captured" (complete), "refunded" (cancel).
 *     It is a display field; every money decision re-reads the escrow.
 *
 * Supplier response deadline: a paid order the supplier has not answered
 * within settings/gas_supplier_fulfilment.supplierResponseMinutes of payment
 * (agreed default 10 minutes, used when the setting is missing or not a
 * whole number from 1 to 1440) is cancelled by expireUnansweredGasSupplierOrders
 * (scheduled) and its hold refunded, exactly as a supplier decline. It runs
 * whether or not ordering is switched on, so switching off never leaves a
 * paid order waiting. A late accept finds the order cancelled and is refused.
 *
 * Completion code: 4 digits, so wrong submissions are counted on the order
 * (completionFailures) and completion locks after MAX_COMPLETION_FAILURES,
 * for the driver and the supplier alike; a locked order needs an admin
 * (cancel and refund, or confirm delivery with the customer). This stops
 * anyone holding the order from guessing the code to capture the payment.
 *
 * Linked-rider eligibility (assignment and acceptance, linkedRiderRejection):
 * an active link to the order's supplier, not released from or declined
 * this order, every driverRejection("gas") check, and a lastLocationUpdate
 * no older than LINKED_RIDER_LOCATION_MAX_AGE_MS. A rider holds at most one
 * pending offer (a transactional query on riderOffer.driverId). Each offer
 * lasts settings/gas_supplier_fulfilment.riderAcceptMinutes (default
 * DEFAULT_RIDER_ACCEPT_MINUTES) and stores its own expiresAt.
 *
 * Rider earnings (listMyGasSupplierEarnings): the caller's own driver
 * entries in gas_settlement_ledger, with the status gas_settlement_ledger's
 * entryStatus gives them (as the admin and portal show it), never the
 * commission, the supplier's amounts or the customer total.
 *
 * Driver job state: accepting sets drivers.currentTripId/currentTripType
 * ("gas_supplier_order") and isAvailable=false in the accept transaction;
 * completion and cancellation clear them only while the driver still holds
 * this order.
 */

const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { holdMatchesSnapshot, QUOTE_TTL_MS, ORDERING_FLAG_DOC, requireOrderingEnabled } = require("./gas_supplier_orders");
const {
  ESCROW_REFERENCE_TYPE, ESCROW_CAPTURED, TERMS_DOC, termsProblem, allocationProblem, allocationRef, postOrderEntitlements,
  LEDGER, CLAIMS, STATEMENTS, DEBTS, entryId, entryStatus,
} = require("./gas_settlement_ledger");
const { driverRejection, distanceKm, validPoint, driverLocationStale, LINKED_RIDER_LOCATION_MAX_AGE_MS } = require("./dispatch_policy");
const { RIDERS, activeRiderLink, riderAcceptMinutes } = require("./gas_supplier_riders");
const { checkCompletionCode } = require("./completion_code");
const { requireActiveAdmin } = require("./admin_auth");
const escrow = require("./escrow");
const { adminAlert } = require("./alert_payload");

const db = () => admin.firestore();
const { FieldValue, Timestamp } = admin.firestore;

const ORDERS = "gas_supplier_orders";
const FLAG_DOC = ORDERING_FLAG_DOC;
const MEMBERS = "gas_supplier_members";
const JOB_TYPE = "gas_supplier_order";
const FULFILLED_TYPES = Object.freeze(["exchangeEmpty", "newCylinder", "commercialBulk"]);
const PASSENGER_CANCELLABLE = Object.freeze(["awaiting_payment", "pendingApproval", "confirmed"]);
/** Who delivers a confirmed order (set by the supplier on accept). */
const DELIVERY_MODES = Object.freeze(["ctsgo_driver", "supplier_rider", "linked_rider"]);
/** The delivery modes each rider arrangement allows. */
const ARRANGEMENT_MODES = Object.freeze({
  ctsgo_dispatch: Object.freeze(["ctsgo_driver"]),
  supplier_riders_ctsgo_fallback: Object.freeze(["supplier_rider", "linked_rider", "ctsgo_driver"]),
});
const MAX_COMPLETION_FAILURES = 5;
/** Declines after which a linked-rider order falls back to CTSGo dispatch. */
const MAX_RIDER_DECLINES = 3;
const ACTIVE = Object.freeze(["awaiting_payment", "pendingApproval", "confirmed", "driverAssigned", "atStation", "outForDelivery"]);
const ID = /^[A-Za-z0-9_-]{1,128}$/;
const isId = (v) => typeof v === "string" && ID.test(v);
/** The clock for offer timing (replaceable in tests only). */
let clock = () => Date.now();

// ── Guards ───────────────────────────────────────────────────────────────────

const refuse = (reason, message = "This action is not allowed.", code = "failed-precondition") =>
  new HttpsError(code, message, { reason });

/** Off unless settings/gas_supplier_fulfilment.enabled === true, read now. */
const requireEnabled = requireOrderingEnabled;

function requireAuth(request) {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  return uid;
}

function readRequest(data, allowed) {
  if (!data || typeof data !== "object" || Array.isArray(data)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const extra = Object.keys(data).filter((k) => !allowed.includes(k));
  if (extra.length) throw new HttpsError("invalid-argument", "Unexpected fields in request.", { reason: "unexpected_fields", fields: extra });
  return data;
}

/**
 * The caller's supplier, from gas_supplier_members/{uid} (the supplier
 * portal's membership model): active, well-formed, approved supplier.
 */
async function requireSupplierMember(uid, tx = null) {
  const read = (ref) => (tx ? tx.get(ref) : ref.get());
  const m = await read(db().collection(MEMBERS).doc(uid));
  const d = m.exists ? m.data() : null;
  if (!d || d.uid !== uid || d.status !== "active" || !isId(d.supplierId)) throw refuse("not_a_supplier_member", "Your login is not linked to an active supplier.", "permission-denied");
  const s = await read(db().collection("gas_suppliers").doc(d.supplierId));
  if (!s.exists || s.data().status !== "approved") throw refuse("supplier_not_approved", "Your supplier account is not approved.", "permission-denied");
  return d.supplierId;
}

function pointOf(v) {
  return v && typeof v.latitude === "number" && typeof v.longitude === "number" ? { latitude: v.latitude, longitude: v.longitude } : null;
}

function event(tx, orderRef, from, to, by, role, extra = {}) {
  tx.create(orderRef.collection("events").doc(), { from, to, by, role, at: FieldValue.serverTimestamp(), ...extra });
}

function newCompletionCode() {
  return String(crypto.randomInt(0, 10000)).padStart(4, "0");
}

function releaseDriver(tx, driverRef, driver, orderId) {
  if (driver && driver.currentTripId === orderId) {
    tx.update(driverRef, { currentTripId: null, currentTripType: null, isAvailable: true });
  }
}

// ── Pure rules (exported for tests) ──────────────────────────────────────────

/** Why this escrow cannot pay this order, or null. Every field is checked. */
function escrowPaymentProblem(orderId, order, e, uid) {
  if (!e) return "escrow_not_found";
  if (e.userId !== uid || order.passengerId !== uid) return "escrow_owner_mismatch";
  if (e.status !== "HELD") return "escrow_not_held";
  if (e.referenceType != null && e.referenceType !== ESCROW_REFERENCE_TYPE) return "escrow_wrong_type";
  if (e.referenceId != null && e.referenceId !== orderId) return "escrow_attached_elsewhere";
  if (!holdMatchesSnapshot(order, e.amount)) return "escrow_amount_mismatch";
  return null;
}

/** Why the catalog no longer supports this order, or null (revalidated at payment). */
function catalogProblem(order, supplier, station, product) {
  if (!supplier || supplier.status !== "approved") return "supplier_not_approved";
  if (supplier.ordersEnabled !== true) return "supplier_orders_disabled";
  if (!station || station.status !== "verified" || station.supplierId !== order.supplierId) return "station_not_verified";
  if (!product || product.verified !== true || product.availability !== "available") return "product_unavailable";
  if (product.priceVersion !== order.priceSnapshot?.priceVersion) return "price_changed";
  return null;
}

// ── Passenger: pay ───────────────────────────────────────────────────────────

async function pay(uid, data) {
  const { orderId, escrowId } = readRequest(data, ["orderId", "escrowId"]);
  if (!isId(orderId) || !isId(escrowId)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const orderRef = db().collection(ORDERS).doc(orderId);
  const escrowRef = db().collection("escrows").doc(escrowId);
  const linkRef = db().collection("escrowOrderLinks").doc(`${ESCROW_REFERENCE_TYPE}:${orderId}`);

  return db().runTransaction(async (tx) => {
    const [o, e, link] = await Promise.all([tx.get(orderRef), tx.get(escrowRef), tx.get(linkRef)]);
    if (!o.exists || o.data().passengerId !== uid) throw refuse("order_not_found", "Order not found.", "not-found");
    const order = o.data();
    // Idempotent: the same escrow paying the same order again.
    if (order.payment?.escrowId === escrowId && order.status !== "awaiting_payment") return { orderId, status: order.status, alreadyPaid: true };
    if (order.status !== "awaiting_payment") throw refuse("order_not_awaiting_payment", "This order is not waiting for payment.");
    if (link.exists && link.data().escrowId !== escrowId) throw refuse("order_already_paid", "This order already has a payment.");
    if (!FULFILLED_TYPES.includes(order.orderType)) throw refuse("order_type_not_supported", "This order type cannot be fulfilled yet.");

    const quote = await tx.get(db().collection("gas_quotes").doc(order.priceSnapshot?.quoteId ?? orderId));
    const expiresAt = quote.exists ? quote.data().expiresAt?.toMillis?.() : null;
    if (!(typeof expiresAt === "number") || Date.now() > expiresAt + QUOTE_TTL_MS) throw refuse("quote_expired", "This price has expired. Please get a new price.");

    const sRef = db().collection("gas_suppliers").doc(order.supplierId);
    const stRef = sRef.collection("stations").doc(order.stationId);
    const pRef = stRef.collection("products").doc(order.productId);
    const [s, st, p, alloc, terms] = await Promise.all([tx.get(sRef), tx.get(stRef), tx.get(pRef), tx.get(allocationRef(orderId)), tx.get(db().doc(TERMS_DOC))]);
    const stale = catalogProblem(order, s.exists ? s.data() : null, st.exists ? st.data() : null, p.exists ? p.data() : null);
    if (stale) throw refuse(stale, "This product is no longer available at this price.");
    const unpriced = termsProblem(terms.exists ? terms.data() : null) ??
      allocationProblem(order.priceSnapshot, alloc.exists && alloc.data().orderId === orderId ? alloc.data() : null);
    if (unpriced) throw refuse(unpriced, "This order cannot be paid right now.");

    const problem = escrowPaymentProblem(orderId, order, e.exists ? e.data() : null, uid);
    if (problem) throw refuse(problem, "The payment could not be verified.");

    tx.update(escrowRef, { referenceId: orderId, referenceType: ESCROW_REFERENCE_TYPE });
    tx.set(linkRef, { escrowId, referenceType: ESCROW_REFERENCE_TYPE, referenceId: orderId, userId: uid, linkedAt: FieldValue.serverTimestamp() });
    tx.update(orderRef, {
      status: "pendingApproval",
      payment: { escrowId, amount: e.data().amount, status: "held", verifiedAt: FieldValue.serverTimestamp() },
      completionCode: newCompletionCode(),
      paidAt: FieldValue.serverTimestamp(),
    });
    event(tx, orderRef, "awaiting_payment", "pendingApproval", uid, "passenger", { escrowId });
    return { orderId, status: "pendingApproval", alreadyPaid: false };
  });
}

// ── Supplier: respond, hand over ─────────────────────────────────────────────

async function supplierRespond(uid, data) {
  const { orderId, decision, reason, deliveryMode } = readRequest(data, ["orderId", "decision", "reason", "deliveryMode"]);
  if (!isId(orderId) || !["accept", "decline"].includes(decision)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  if (deliveryMode != null && !DELIVERY_MODES.includes(deliveryMode)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  if (decision === "decline" && !(typeof reason === "string" && reason.trim().length >= 3 && reason.length <= 500)) throw refuse("reason_required", "A reason is required.", "invalid-argument");
  const orderRef = db().collection(ORDERS).doc(orderId);

  const result = await db().runTransaction(async (tx) => {
    const supplierId = await requireSupplierMember(uid, tx);
    const o = await tx.get(orderRef);
    if (!o.exists || o.data().supplierId !== supplierId) throw refuse("order_not_found", "Order not found.", "not-found");
    const order = o.data();
    const to = decision === "accept" ? "confirmed" : "cancelled";
    if (order.status === to && order.supplierRespondedBy === uid) return { orderId, status: to, refund: false };
    if (order.status !== "pendingApproval") throw refuse("order_not_pending", "This order is not waiting for your answer.");
    let mode = null;
    if (decision === "accept") {
      const sup = await tx.get(db().collection("gas_suppliers").doc(supplierId));
      const allowed = ARRANGEMENT_MODES[sup.exists ? sup.data().riderArrangement : null];
      if (!allowed) throw refuse("supplier_rider_arrangement_unsupported", "Your rider arrangement cannot take orders.");
      // A supplier with its own riders chooses per order; CTSGo dispatch is the only option otherwise.
      mode = deliveryMode ?? (allowed.length === 1 ? allowed[0] : null);
      if (!mode) throw refuse("delivery_mode_required", "Choose who delivers this order.", "invalid-argument");
      if (!allowed.includes(mode)) throw refuse("delivery_mode_not_allowed", "Your rider arrangement does not allow this delivery option.");
    }
    let riderFields = {};
    if (mode === "linked_rider") {
      const [links, flag] = await Promise.all([
        tx.get(db().collection(RIDERS).where("supplierId", "==", supplierId).where("status", "==", "active").limit(1)),
        tx.get(db().doc(FLAG_DOC)),
      ]);
      if (links.empty) throw refuse("no_linked_riders", "You have no linked riders.");
      riderFields = {
        riderOfferSeq: 0, declinedRiderIds: [], riderDeclineCount: 0,
        riderDeadlineAt: Timestamp.fromMillis(clock() + riderAcceptMinutes(flag.exists ? flag.data() : null) * 60 * 1000),
      };
    }
    tx.update(orderRef, decision === "accept"
      ? { status: "confirmed", deliveryMode: mode, supplierRespondedBy: uid, confirmedAt: FieldValue.serverTimestamp(), ...riderFields }
      : { status: "cancelled", supplierRespondedBy: uid, cancelledAt: FieldValue.serverTimestamp(), cancelledBy: uid, cancelledByRole: "supplier", cancelReason: reason.trim(), refundPending: true });
    event(tx, orderRef, "pendingApproval", to, uid, "supplier", decision === "decline" ? { reason: reason.trim() } : { deliveryMode: mode });
    return { orderId, status: to, refund: decision === "decline" };
  });
  if (result.refund) await settleRefund(orderId);
  return { orderId: result.orderId, status: result.status };
}

async function supplierHandOver(uid, data) {
  const { orderId } = readRequest(data, ["orderId"]);
  if (!isId(orderId)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const orderRef = db().collection(ORDERS).doc(orderId);
  return db().runTransaction(async (tx) => {
    const supplierId = await requireSupplierMember(uid, tx);
    const o = await tx.get(orderRef);
    if (!o.exists || o.data().supplierId !== supplierId) throw refuse("order_not_found", "Order not found.", "not-found");
    const order = o.data();
    if (order.status === "outForDelivery") return { orderId, status: order.status };
    if (order.deliveryMode === "supplier_rider") {
      // The supplier's own rider takes it from the station.
      if (order.status !== "confirmed") throw refuse("invalid_transition", "This order cannot be handed over now.");
      tx.update(orderRef, { status: "outForDelivery", handedOverAt: FieldValue.serverTimestamp(), handedOverBy: uid, handedOverTo: "supplier_rider" });
      event(tx, orderRef, "confirmed", "outForDelivery", uid, "supplier", { deliveryMode: "supplier_rider" });
      return { orderId, status: "outForDelivery" };
    }
    if (order.status !== "atStation") throw refuse("driver_not_at_station", "The driver has not arrived at the station.");
    tx.update(orderRef, { status: "outForDelivery", handedOverAt: FieldValue.serverTimestamp(), handedOverBy: uid });
    event(tx, orderRef, "atStation", "outForDelivery", uid, "supplier");
    return { orderId, status: "outForDelivery" };
  });
}

/**
 * CTSGo fallback: the supplier hands an own-rider order to CTSGo dispatch,
 * any time before its rider has taken it from the station, or a linked-rider
 * order before a rider has accepted it (a pending offer is withdrawn). A
 * repeat is a no-op.
 */
async function supplierRequestDriver(uid, data) {
  const { orderId } = readRequest(data, ["orderId"]);
  if (!isId(orderId)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const orderRef = db().collection(ORDERS).doc(orderId);
  return db().runTransaction(async (tx) => {
    const supplierId = await requireSupplierMember(uid, tx);
    const o = await tx.get(orderRef);
    if (!o.exists || o.data().supplierId !== supplierId) throw refuse("order_not_found", "Order not found.", "not-found");
    const order = o.data();
    if (order.status === "confirmed" && order.deliveryMode === "ctsgo_driver") return { orderId, status: "confirmed", deliveryMode: "ctsgo_driver" };
    const linked = order.deliveryMode === "linked_rider" && !order.driverId;
    if (order.status !== "confirmed" || !(order.deliveryMode === "supplier_rider" || linked)) throw refuse("invalid_transition", "This order can no longer be passed to a CTSGo driver.");
    tx.update(orderRef, {
      deliveryMode: "ctsgo_driver", ctsgoFallbackReason: "supplier_request", ctsgoFallbackAt: FieldValue.serverTimestamp(), ctsgoFallbackBy: uid,
      ...(linked ? clearOffer(order, "withdrawn") : {}),
    });
    event(tx, orderRef, "confirmed", "confirmed", uid, "supplier", { deliveryMode: "ctsgo_driver", fallback: true });
    return { orderId, status: "confirmed", deliveryMode: "ctsgo_driver" };
  });
}

/** The supplier completes an own-rider delivery with the customer's code. */
async function supplierComplete(uid, data) {
  const { orderId, code } = readRequest(data, ["orderId", "code"]);
  if (!isId(orderId) || typeof code !== "string") throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const result = await capture(orderId, code, { by: uid, role: "supplier" });
  await postAfterDelivery(orderId);
  return result;
}

// ── Driver: jobs, accept, arrive, complete ───────────────────────────────────

const driverJob = (o) => ({ deliveryLocation: pointOf(o.deliveryLocation), refillType: o.orderType });

/** What a driver is shown of one order: no passenger, payment or completion code. */
async function jobView(id, o, d) {
  const st = await db().collection("gas_suppliers").doc(o.supplierId).collection("stations").doc(o.stationId).get();
  const station = st.exists ? st.data() : {};
  return {
    orderId: id, orderType: o.orderType, cylinderSize: o.cylinderSize, quantity: o.quantity,
    station: { name: station.name ?? null, address: station.address ?? null, location: pointOf(station.location) },
    deliveryAddress: o.deliveryAddress ?? null, deliveryLocation: pointOf(o.deliveryLocation),
    deliveryFee: o.priceSnapshot?.deliveryFee ?? null,
    distanceKm: validPoint(pointOf(d?.location)) && validPoint(pointOf(o.deliveryLocation)) ? Math.round(distanceKm(pointOf(d.location), pointOf(o.deliveryLocation)) * 10) / 10 : null,
  };
}

/**
 * Open CTSGo jobs the caller may take, plus the linked-rider offers naming
 * the caller that have not expired. serverNowMs lets the app count down
 * against the server's clock.
 */
async function listJobs(uid) {
  const serverNowMs = clock();
  const driver = await db().collection("drivers").doc(uid).get();
  const d = driver.exists ? driver.data() : null;
  if (!d) return { jobs: [], offers: [], serverNowMs };
  const [open, offered] = await Promise.all([
    db().collection(ORDERS).where("status", "==", "confirmed").get(),
    db().collection(ORDERS).where("riderOffer.driverId", "==", uid).where("status", "==", "confirmed").get(),
  ]);
  const jobs = [];
  for (const doc of open.docs) {
    const o = doc.data();
    if (o.driverId) continue;
    if (o.deliveryMode === "supplier_rider") continue; // the supplier's own rider delivers it
    if (o.deliveryMode === "linked_rider") continue; // offered by the supplier to one linked rider
    if (poolExclusion(o, uid)) continue;
    if (driverRejection("gas", driverJob(o), d)) continue;
    jobs.push(await jobView(doc.id, o, d));
  }
  const offers = [];
  for (const doc of offered.docs) {
    const o = doc.data();
    const offer = o.riderOffer;
    const expiresAtMs = millisOf(offer?.expiresAt);
    if (o.deliveryMode !== "linked_rider" || o.driverId || offer?.driverId !== uid || !(expiresAtMs > serverNowMs)) continue;
    offers.push({
      ...(await jobView(doc.id, o, d)),
      offerSeq: offer.seq, expiresAtMs, deliveryFeePesewas: offer.deliveryFeePesewas, feePaidBy: "ctsgo",
    });
  }
  return { jobs, offers, serverNowMs };
}

/** Statuses in which an order is a driver's job in progress. */
const DRIVER_ACTIVE = Object.freeze(["driverAssigned", "atStation", "outForDelivery"]);

/**
 * The caller's own supplier jobs still in progress, so the driver app can
 * return to them after leaving the screen or restarting. Selected by the
 * verified caller's uid against each order's server-written driverId; the
 * request carries nothing. Delivered, cancelled, reassigned or other
 * drivers' orders are never returned. One equality query per status (no
 * composite index). onDriverRecord tells whether drivers/{uid} still names
 * the job, as the accept transaction set it.
 */
async function myJobs(uid, data) {
  readRequest(data ?? {}, []);
  const [driver, ...snaps] = await Promise.all([
    db().collection("drivers").doc(uid).get(),
    ...DRIVER_ACTIVE.map((s) => db().collection(ORDERS).where("driverId", "==", uid).where("status", "==", s).get()),
  ]);
  const d = driver.exists ? driver.data() : null;
  const docs = snaps.flatMap((s) => s.docs)
    .filter((doc) => doc.data().driverId === uid && DRIVER_ACTIVE.includes(doc.data().status))
    .sort((a, b) => (a.data().acceptedAt?.toMillis?.() ?? 0) - (b.data().acceptedAt?.toMillis?.() ?? 0));
  const jobs = [];
  for (const doc of docs) {
    const o = doc.data();
    jobs.push({
      ...(await jobView(doc.id, o, d)),
      status: o.status,
      onDriverRecord: d?.currentTripId === doc.id && d?.currentTripType === JOB_TYPE,
    });
  }
  return { jobs };
}

async function acceptJob(uid, data) {
  const { orderId, offerSeq } = readRequest(data, ["orderId", "offerSeq"]);
  if (!isId(orderId) || (offerSeq != null && !Number.isInteger(offerSeq))) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const orderRef = db().collection(ORDERS).doc(orderId);
  const driverRef = db().collection("drivers").doc(uid);
  return db().runTransaction(async (tx) => {
    const [o, dr] = await Promise.all([tx.get(orderRef), tx.get(driverRef)]);
    if (!o.exists) throw refuse("order_not_found", "Order not found.", "not-found");
    const order = o.data();
    if (order.driverId === uid && order.status === "driverAssigned") return { orderId, status: order.status };
    if (order.status !== "confirmed" || order.driverId || order.deliveryMode === "supplier_rider") throw refuse("job_taken", "This job is no longer available.");
    if (order.deliveryMode === "linked_rider") return acceptOffer(tx, orderRef, driverRef, order, uid, offerSeq);
    const excluded = poolExclusion(order, uid);
    if (excluded === "released_from_job") throw refuse(excluded, "This job was reassigned away from you.", "permission-denied");
    // An offerSeq accepts an offer only: a late accept of an offer that fell back to CTSGo is refused.
    if (offerSeq != null) throw refuse("job_taken", "This job is no longer available.");
    if (excluded) throw refuse(excluded, "You passed on this job, so it has gone to other drivers.", "permission-denied");
    const why = driverRejection("gas", driverJob(order), dr.exists ? dr.data() : null);
    if (why) throw refuse(why, "You cannot take this job.", "permission-denied");
    tx.update(orderRef, { status: "driverAssigned", driverId: uid, acceptedAt: FieldValue.serverTimestamp() });
    tx.update(driverRef, { currentTripId: orderId, currentTripType: JOB_TYPE, isAvailable: false });
    event(tx, orderRef, "confirmed", "driverAssigned", uid, "driver");
    return { orderId, status: "driverAssigned" };
  });
}

/**
 * The linked-rider branch of acceptJob, inside its transaction: only the
 * named rider, with the current offerSeq, before expiresAt, still eligible
 * and at the offered fee, which must still be the allocation's driver net.
 */
async function acceptOffer(tx, orderRef, driverRef, order, uid, offerSeq) {
  const nowMs = clock();
  const offer = order.riderOffer;
  if (!offer || offer.driverId !== uid) throw refuse("job_taken", "This job is no longer available.");
  if (offerSeq !== offer.seq) throw refuse("offer_stale", "This offer has changed. Refresh and try again.");
  if (!(nowMs < millisOf(offer.expiresAt))) throw refuse("offer_expired", "This offer has expired.");
  const why = await linkedRiderRejection(tx, order, uid, nowMs);
  if (why) throw refuse(why, "You cannot take this job.", "permission-denied");
  const alloc = await tx.get(allocationRef(orderRef.id));
  const fee = alloc.exists && alloc.data().orderId === orderRef.id ? alloc.data().driverNetPesewas : null;
  if (!Number.isInteger(fee) || offer.deliveryFeePesewas !== fee) throw refuse("rider_fee_changed", "The delivery fee for this offer has changed.");
  tx.update(orderRef, {
    status: "driverAssigned", driverId: uid, acceptedAt: FieldValue.serverTimestamp(),
    linkedSupplierId: order.supplierId, acceptedFeePesewas: fee,
    ...clearOffer(order, "accepted"),
  });
  tx.update(driverRef, { currentTripId: orderRef.id, currentTripType: JOB_TYPE, isAvailable: false });
  event(tx, orderRef, "confirmed", "driverAssigned", uid, "driver", { deliveryMode: "linked_rider", offerSeq: offer.seq });
  return { orderId: orderRef.id, status: "driverAssigned" };
}

async function driverArrived(uid, data) {
  const { orderId } = readRequest(data, ["orderId"]);
  if (!isId(orderId)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const orderRef = db().collection(ORDERS).doc(orderId);
  return db().runTransaction(async (tx) => {
    const o = await tx.get(orderRef);
    if (!o.exists || o.data().driverId !== uid) throw refuse("order_not_found", "Order not found.", "not-found");
    const order = o.data();
    if (order.status === "atStation") return { orderId, status: order.status };
    if (order.status !== "driverAssigned") throw refuse("invalid_transition", "This step is not allowed now.");
    tx.update(orderRef, { status: "atStation", arrivedAtStationAt: FieldValue.serverTimestamp() });
    event(tx, orderRef, "driverAssigned", "atStation", uid, "driver");
    return { orderId, status: "atStation" };
  });
}

async function complete(uid, data) {
  const { orderId, code } = readRequest(data, ["orderId", "code"]);
  if (!isId(orderId) || typeof code !== "string") throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const result = await capture(orderId, code, { by: uid, role: "driver" });
  await postAfterDelivery(orderId);
  return result;
}

/**
 * Posts the delivered order's entitlements (idempotent: deterministic entry
 * ids, an already-posted order is a no-op). Never fails the delivery: a
 * refusal (e.g. terms no longer approved) or error raises one admin alert
 * per order, and a super admin can post by hand once it is resolved.
 */
async function postAfterDelivery(orderId) {
  try {
    await postOrderEntitlements(orderId, { postedBy: "system" });
  } catch (e) {
    console.error("gas supplier entitlements not posted", orderId, e?.details?.reason ?? e?.message);
    try {
      await db().collection("admin_alerts").doc(`gas_entitlements_not_posted_${orderId}`).create(adminAlert("gas_entitlements_not_posted",
        `Delivered Gas supplier order ${orderId}: ledger entries were not posted`,
        { severity: "high", resolved: false, orderId, reason: e?.details?.reason ?? null }));
    } catch (alertErr) {
      if (alertErr?.code !== 6) console.error("gas supplier alert failed", orderId, alertErr?.message); // 6: already alerted
    }
  }
}

/**
 * Delivery with the customer's code, by the assigned driver (role "driver")
 * or, for an own-rider order, by a member of its supplier (role "supplier").
 * Captures the hold in the same transaction that marks the order delivered.
 * A wrong code is counted (its own transaction, so it is kept although the
 * call fails); after MAX_COMPLETION_FAILURES the order is locked for an admin.
 */
async function capture(orderId, code, { by, role }) {
  const orderRef = db().collection(ORDERS).doc(orderId);
  const driverRef = role === "driver" ? db().collection("drivers").doc(by) : null;
  const outcome = await db().runTransaction(async (tx) => {
    const supplierId = role === "supplier" ? await requireSupplierMember(by, tx) : null;
    const [o, dr] = await Promise.all([tx.get(orderRef), driverRef ? tx.get(driverRef) : null]);
    const order = o.exists ? o.data() : null;
    const mine = role === "driver"
      ? order?.driverId === by && order?.deliveryMode !== "supplier_rider"
      : order?.supplierId === supplierId && order?.deliveryMode === "supplier_rider";
    if (!mine) throw refuse("order_not_found", "Order not found.", "not-found");
    if (order.status === "delivered") return { done: { orderId, status: "delivered" } };
    if (order.status !== "outForDelivery") throw refuse("invalid_transition", "This order is not out for delivery.");
    if ((order.completionFailures ?? 0) >= MAX_COMPLETION_FAILURES) {
      throw refuse("completion_code_locked", "Too many wrong codes. CTSGo support must review this delivery.", "permission-denied");
    }
    const check = checkCompletionCode({ stored: order.completionCode, submitted: code, collection: ORDERS, orderId });
    if (!check.ok) {
      if (check.outcome !== "mismatch") throw refuse(`completion_code_${check.outcome}`, "The completion code does not match.", "permission-denied");
      const failures = (order.completionFailures ?? 0) + 1;
      tx.update(orderRef, { completionFailures: failures, lastCompletionFailureAt: FieldValue.serverTimestamp(), lastCompletionFailureBy: by });
      if (failures >= MAX_COMPLETION_FAILURES) {
        tx.set(db().collection("admin_alerts").doc(`gas_completion_locked_${orderId}`), adminAlert("gas_completion_locked",
          `Gas supplier order ${orderId}: completion locked after ${failures} wrong codes`,
          { severity: "high", resolved: false, orderId, role, by }));
      }
      return { mismatch: failures };
    }

    const escrowId = order.payment?.escrowId;
    const escrowRef = db().collection("escrows").doc(escrowId ?? "-");
    const e = escrowId ? await tx.get(escrowRef) : null;
    const problem = escrowPaymentProblem(orderId, order, e?.exists ? e.data() : null, order.passengerId);
    if (problem || e.data().referenceId !== orderId) throw refuse(problem ?? "escrow_not_bound", "The payment for this order needs review.");
    const amount = e.data().amount;

    tx.update(orderRef, {
      status: "delivered", deliveredAt: FieldValue.serverTimestamp(), completedVia: check.via, deliveredByRole: role,
      "payment.status": "captured", "payment.capturedAt": FieldValue.serverTimestamp(),
    });
    tx.update(escrowRef, { status: ESCROW_CAPTURED, capturedAt: FieldValue.serverTimestamp(), captureReason: "gas_supplier_order_delivered" });
    tx.update(db().collection("wallets").doc(order.passengerId), { heldBalance: FieldValue.increment(-amount), lastUpdatedAt: FieldValue.serverTimestamp() });
    tx.create(db().collection("ledger").doc(`capture_${escrowId}`), {
      type: "CAPTURE", status: "COMPLETED", fromUserId: order.passengerId, fromType: "escrow", toType: "gas_settlement",
      amount, currency: "GHS", platformFee: 0, driverNet: 0, referenceType: ESCROW_REFERENCE_TYPE, referenceId: orderId,
      idempotencyKey: `capture_${escrowId}`, processedAt: FieldValue.serverTimestamp(), createdAt: FieldValue.serverTimestamp(),
    });
    if (driverRef) releaseDriver(tx, driverRef, dr.exists ? dr.data() : null, orderId);
    event(tx, orderRef, "outForDelivery", "delivered", by, role, { escrowCaptured: escrowId });
    return { done: { orderId, status: "delivered" } };
  });
  if (outcome.mismatch) {
    throw outcome.mismatch >= MAX_COMPLETION_FAILURES
      ? refuse("completion_code_locked", "Too many wrong codes. CTSGo support must review this delivery.", "permission-denied")
      : refuse("completion_code_mismatch", "The completion code does not match.", "permission-denied");
  }
  return outcome.done;
}

// ── Linked riders: list, assign, decline ─────────────────────────────────────

const millisOf = (t) => (typeof t?.toMillis === "function" ? t.toMillis() : null);

/**
 * Order fields that end the current offer (if any) with [outcome]; the
 * deadline goes too, since the order leaves the offer stage.
 */
function clearOffer(order, outcome) {
  const offer = order.riderOffer;
  return {
    riderOffer: FieldValue.delete(), riderDeadlineAt: FieldValue.delete(),
    ...(offer ? { lastRiderOffer: { driverId: offer.driverId, seq: offer.seq, outcome, at: Timestamp.now() } } : {}),
  };
}

/**
 * Why [driverId] may not take this order from the CTSGo pool (listing and
 * accept), or null: an admin released them from it, or they passed on it as
 * its linked rider, by declining (declinedRiderIds) or by letting the offer
 * time out (lastRiderOffer "timed_out"; a timeout ends the order's offers, so
 * no later offer replaces that record). Other drivers are unaffected.
 */
function poolExclusion(order, driverId) {
  if (Array.isArray(order.releasedDriverIds) && order.releasedDriverIds.includes(driverId)) return "released_from_job";
  if (Array.isArray(order.declinedRiderIds) && order.declinedRiderIds.includes(driverId)) return "rider_passed_on_job";
  const last = order.lastRiderOffer;
  if (last?.outcome === "timed_out" && last.driverId === driverId) return "rider_passed_on_job";
  return null;
}

/**
 * Why this rider may not be offered (or accept) this linked-rider order, or
 * null. Reads inside [tx], in this order: an active link to the order's
 * supplier, not released from this order, not declined it, every
 * driverRejection("gas") check (with location), and a recent location.
 */
async function linkedRiderRejection(tx, order, driverId, nowMs) {
  if (!(await activeRiderLink(tx, driverId, order.supplierId))) return "rider_not_linked";
  if (Array.isArray(order.releasedDriverIds) && order.releasedDriverIds.includes(driverId)) return "released_from_job";
  if (Array.isArray(order.declinedRiderIds) && order.declinedRiderIds.includes(driverId)) return "rider_declined";
  const dr = await tx.get(db().collection("drivers").doc(driverId));
  const d = dr.exists ? dr.data() : null;
  return driverRejection("gas", driverJob(order), d) ?? driverLocationStale(d, nowMs, LINKED_RIDER_LOCATION_MAX_AGE_MS);
}

/** The rider's pending offers (any order still confirmed that names them). */
const pendingOffersQuery = (driverId) =>
  db().collection(ORDERS).where("riderOffer.driverId", "==", driverId).where("status", "==", "confirmed");

/** List reasons (spec §3.2) for the assignment refusals that differ from them. */
const LIST_REASON = Object.freeze({ rider_declined: "declined_this_order" });

/**
 * The caller's supplier's active linked riders. With an order of theirs:
 * whether each may be offered it (and why not), and the fee CTSGo pays the
 * rider. Never the rider's phone, plate, location, distance, rating or money.
 */
async function listRiders(uid, data) {
  const { orderId } = readRequest(data ?? {}, ["orderId"]);
  if (orderId != null && !isId(orderId)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const supplierId = await requireSupplierMember(uid);
  let order = null, deliveryFeePesewas;
  if (orderId != null) {
    const [o, alloc] = await Promise.all([db().collection(ORDERS).doc(orderId).get(), allocationRef(orderId).get()]);
    if (!o.exists || o.data().supplierId !== supplierId) throw refuse("order_not_found", "Order not found.", "not-found");
    order = o.data();
    deliveryFeePesewas = alloc.exists && alloc.data().orderId === orderId ? alloc.data().driverNetPesewas ?? null : null;
  }
  const links = await db().collection(RIDERS).where("supplierId", "==", supplierId).where("status", "==", "active").get();
  const reader = { get: (ref) => ref.get() };
  const nowMs = clock();
  const riders = [];
  for (const l of links.docs) {
    const d = (await db().collection("drivers").doc(l.id).get()).data() ?? {};
    let reason = null;
    if (order) {
      reason = await linkedRiderRejection(reader, order, l.id, nowMs);
      if (!reason && !(await pendingOffersQuery(l.id).get()).empty) reason = "has_pending_offer";
    }
    riders.push({
      riderId: l.id, name: d.displayName ?? d.name ?? null, vehicle: d.vehicleType ?? null,
      eligible: order ? reason == null : null, reason: reason ? LIST_REASON[reason] ?? reason : null,
    });
  }
  riders.sort((a, b) => String(a.name ?? "").localeCompare(String(b.name ?? "")));
  return order ? { riders, deliveryFeePesewas } : { riders };
}

/**
 * Offers a confirmed linked-rider order to one rider, replacing the offer
 * numbered replacesSeq (0: none yet). One transaction: a concurrent change
 * makes the other call fail with offer_changed; a retry of the call that
 * made the current offer returns it unchanged.
 */
async function assignRider(uid, data) {
  const { orderId, riderId, replacesSeq } = readRequest(data, ["orderId", "riderId", "replacesSeq"]);
  if (!isId(orderId) || !isId(riderId) || !Number.isInteger(replacesSeq) || replacesSeq < 0) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const orderRef = db().collection(ORDERS).doc(orderId);
  return db().runTransaction(async (tx) => {
    const supplierId = await requireSupplierMember(uid, tx);
    const o = await tx.get(orderRef);
    if (!o.exists || o.data().supplierId !== supplierId) throw refuse("order_not_found", "Order not found.", "not-found");
    const order = o.data();
    if (order.status !== "confirmed" || order.deliveryMode !== "linked_rider" || order.driverId) {
      throw refuse("invalid_transition", "This order cannot be offered to a rider now.");
    }
    const current = order.riderOffer;
    if (current && current.driverId === riderId && current.seq === replacesSeq + 1) {
      return { orderId, offerSeq: current.seq, expiresAtMs: millisOf(current.expiresAt) };
    }
    const seq = order.riderOfferSeq ?? 0;
    if (replacesSeq !== seq) throw refuse("offer_changed", "This order changed. Refresh and try again.");
    const nowMs = clock();
    const why = await linkedRiderRejection(tx, order, riderId, nowMs);
    if (why) throw refuse(why, "This rider cannot be offered this order.");
    const [pending, alloc, flag] = await Promise.all([
      tx.get(pendingOffersQuery(riderId)), tx.get(allocationRef(orderId)), tx.get(db().doc(FLAG_DOC)),
    ]);
    if (!pending.empty) throw refuse("rider_has_pending_offer", "This rider already has an offer waiting.");
    const fee = alloc.exists && alloc.data().orderId === orderId ? alloc.data().driverNetPesewas : null;
    if (!Number.isInteger(fee)) throw refuse("allocation_missing", "This order cannot be offered right now.");
    const expiresAt = Timestamp.fromMillis(nowMs + riderAcceptMinutes(flag.exists ? flag.data() : null) * 60 * 1000);
    tx.update(orderRef, {
      riderOffer: { driverId: riderId, seq: seq + 1, offeredAt: Timestamp.fromMillis(nowMs), expiresAt, deliveryFeePesewas: fee },
      riderOfferSeq: seq + 1, riderDeadlineAt: expiresAt,
      ...(current ? { lastRiderOffer: { driverId: current.driverId, seq: current.seq, outcome: "withdrawn", at: Timestamp.now() } } : {}),
    });
    event(tx, orderRef, "confirmed", "confirmed", uid, "supplier", { riderOffered: riderId, offerSeq: seq + 1 });
    return { orderId, offerSeq: seq + 1, expiresAtMs: expiresAt.toMillis() };
  });
}

/**
 * The named rider declines the offer. A rider who already declined this
 * order gets the order's state back unchanged. The MAX_RIDER_DECLINES-th
 * decline passes the order to CTSGo dispatch in the same transaction.
 */
async function declineOffer(uid, data) {
  const { orderId, offerSeq } = readRequest(data, ["orderId", "offerSeq"]);
  if (!isId(orderId) || !Number.isInteger(offerSeq)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const orderRef = db().collection(ORDERS).doc(orderId);
  return db().runTransaction(async (tx) => {
    const o = await tx.get(orderRef);
    const order = o.exists ? o.data() : null;
    const offer = order?.riderOffer;
    const named = offer?.driverId === uid && order.status === "confirmed" && order.deliveryMode === "linked_rider";
    if (!named && Array.isArray(order?.declinedRiderIds) && order.declinedRiderIds.includes(uid)) {
      return { orderId, status: order.status, fallback: order.ctsgoFallbackReason === "riders_declined" };
    }
    if (!named) throw refuse("offer_not_found", "This offer is no longer yours.", "not-found");
    if (offer.seq !== offerSeq) throw refuse("offer_stale", "This offer has changed. Refresh and try again.");
    const nowMs = clock();
    // Past expiresAt the offer belongs to the sweep (rider_timeout), so a decline cannot restart the window.
    if (!(nowMs < millisOf(offer.expiresAt))) throw refuse("offer_expired", "This offer has expired.");
    const count = (order.riderDeclineCount ?? 0) + 1;
    const fallback = count >= MAX_RIDER_DECLINES;
    const flag = fallback ? null : await tx.get(db().doc(FLAG_DOC));
    const common = {
      riderOffer: FieldValue.delete(), declinedRiderIds: FieldValue.arrayUnion(uid), riderDeclineCount: count,
      lastRiderOffer: { driverId: uid, seq: offer.seq, outcome: "declined", at: Timestamp.now() },
    };
    tx.update(orderRef, fallback
      ? { ...common, riderDeadlineAt: FieldValue.delete(), deliveryMode: "ctsgo_driver", ctsgoFallbackReason: "riders_declined", ctsgoFallbackAt: FieldValue.serverTimestamp() }
      : { ...common, riderDeadlineAt: Timestamp.fromMillis(nowMs + riderAcceptMinutes(flag.exists ? flag.data() : null) * 60 * 1000) });
    event(tx, orderRef, "confirmed", "confirmed", uid, "driver",
      { riderDeclined: uid, offerSeq: offer.seq, ...(fallback ? { deliveryMode: "ctsgo_driver", fallback: true } : {}) });
    return { orderId, status: "confirmed", fallback };
  });
}

/** The CTSGo-dispatch fallback fields for [reason], ending any offer as [outcome]. */
const fallbackFields = (order, reason, outcome) => ({
  deliveryMode: "ctsgo_driver", ctsgoFallbackReason: reason, ctsgoFallbackAt: FieldValue.serverTimestamp(),
  ...clearOffer(order, outcome),
});

/**
 * Linked-rider deadlines (spec §2.2), from the every-minute schedule; runs
 * whether or not ordering is switched on. One transaction per order, which
 * re-reads it: an offer at or after its own expiresAt falls back as
 * "rider_timeout"; no offer at or after riderDeadlineAt (or none recorded)
 * as "no_rider_assigned". Acceptance needs now < expiresAt in its own
 * transaction, so an accept and the sweep never both succeed. A rerun
 * changes nothing: a fallen-back order is no longer linked_rider. An order
 * whose transaction throws is logged and counted in [failed]; the sweep
 * carries on with the other orders, and the next run retries it.
 */
async function expireRiderOffers({ now = Date.now() } = {}) {
  const open = await db().collection(ORDERS).where("status", "==", "confirmed").where("deliveryMode", "==", "linked_rider").get();
  const fallbacks = [];
  const failed = [];
  for (const doc of open.docs) {
    let reason;
    try {
      reason = await db().runTransaction(async (tx) => {
        const o = await tx.get(doc.ref);
        const order = o.exists ? o.data() : null;
        if (order?.status !== "confirmed" || order.deliveryMode !== "linked_rider" || order.driverId) return null;
        const offer = order.riderOffer;
        const due = offer ? millisOf(offer.expiresAt) : millisOf(order.riderDeadlineAt);
        if (typeof due === "number" && now < due) return null;
        const why = offer ? "rider_timeout" : "no_rider_assigned";
        tx.update(doc.ref, fallbackFields(order, why, "timed_out"));
        event(tx, doc.ref, "confirmed", "confirmed", "system", "system", { deliveryMode: "ctsgo_driver", fallback: true, reason: why });
        return why;
      });
    } catch (e) {
      console.error("linked-rider deadline sweep failed for order", doc.id, e);
      failed.push(doc.id);
      continue;
    }
    if (reason) fallbacks.push({ orderId: doc.id, reason });
  }
  return { fallbacks, failed };
}

/** entryStatus outcomes as the rider sees them (spec §3.2). */
const EARNING_STATUS = Object.freeze({
  pending: "pending", eligible: "owed", settlement_prepared: "owed", payout_in_progress: "owed",
  paid: "credited_to_wallet", // a driver statement is only ever credited to the wallet
  credited_to_wallet: "credited_to_wallet", reversed: "reversed",
  resolved_adjustment: "reversed", outstanding_adjustment: "outstanding_adjustment",
});

/**
 * The caller's own delivery-fee entitlements (party "driver", partyId = the
 * verified uid), one row per order, with the ledger's entryStatus. A
 * reversal held as a debt (claimed original) shows the debt's state; one
 * that nets to zero with its unsettled original shows "reversed".
 */
async function myEarnings(uid, data) {
  readRequest(data ?? {}, []);
  const now = Date.now();
  const [entries, terms] = await Promise.all([
    db().collection(LEDGER).where("party", "==", "driver").where("partyId", "==", uid).get(),
    db().doc(TERMS_DOC).get(),
  ]);
  const holdHours = terms.exists ? terms.data().settlementHoldHours : undefined;
  const all = entries.docs.map((d) => d.data()).filter((x) => x.party === "driver" && x.partyId === uid);
  const byId = new Map(all.map((x) => [x.entryId, x]));
  const read = async (col, id) => {
    if (!isId(id)) return null;
    const snap = await db().collection(col).doc(id).get();
    return snap.exists ? snap.data() : null;
  };
  const suppliers = new Map();
  const earnings = [];
  for (const e of all.filter((x) => x.kind === "entitlement")) {
    const rev = byId.get(entryId(e.orderId, "driver", "reversal")) ?? null;
    const [claim, revClaim, escrowDoc] = await Promise.all([
      read(CLAIMS, e.entryId), rev ? read(CLAIMS, rev.entryId) : null, read("escrows", e.basis?.escrowId),
    ]);
    const statement = claim?.statementId ? await read(STATEMENTS, claim.statementId) : null;
    const debt = revClaim?.debtId ? await read(DEBTS, revClaim.debtId) : null;
    const deliveredAtMs = millisOf(e.deliveredAt);
    const ctx = { reversed: false, claim, statement, debt: null, escrow: escrowDoc, deliveredAtMs, holdHours, now };
    let raw;
    if (rev && revClaim?.debtId) raw = entryStatus(rev, { ...ctx, claim: revClaim, statement: null, debt });
    else if (rev) raw = entryStatus(e, { ...ctx, reversed: true, claim: null }); // nets to zero with the original
    else raw = entryStatus(e, ctx);
    const status = EARNING_STATUS[raw] ?? "pending";
    const sid = e.basis?.linkedSupplierId;
    if (isId(sid) && !suppliers.has(sid)) {
      const sup = await read("gas_suppliers", sid);
      suppliers.set(sid, sup ? sup.tradingName || sup.legalName || null : null);
    }
    earnings.push({
      orderId: e.orderId, amountPesewas: e.amountPesewas, status, deliveredAtMs,
      eligibleFromMs: typeof deliveredAtMs === "number" && typeof holdHours === "number" ? deliveredAtMs + holdHours * 3600e3 : null,
      creditedAtMs: status === "credited_to_wallet" ? millisOf(statement?.paidAt) : null,
      linkedSupplierName: isId(sid) ? suppliers.get(sid) : null,
    });
  }
  earnings.sort((a, b) => (b.deliveredAtMs ?? 0) - (a.deliveredAtMs ?? 0));
  return { earnings };
}

// ── Cancellation ─────────────────────────────────────────────────────────────

async function settleRefund(orderId) {
  const orderRef = db().collection(ORDERS).doc(orderId);
  const order = (await orderRef.get()).data();
  if (!order?.refundPending) return { refunded: false };
  const escrowId = order.payment?.escrowId;
  if (!escrowId) {
    await orderRef.update({ refundPending: false });
    return { refunded: false };
  }
  try {
    const done = await escrow.refundEscrow(escrowId, "gas_supplier_order_cancelled", { userId: order.passengerId, referenceId: orderId, referenceType: ESCROW_REFERENCE_TYPE });
    // refundEscrow returns false without refunding when the escrow is not HELD.
    const status = done ? "REFUNDED" : (await db().collection("escrows").doc(escrowId).get()).data()?.status;
    if (status !== "REFUNDED") {
      await orderRef.update({ refundReview: `escrow_${String(status).toLowerCase()}` });
      return { refunded: false, review: true };
    }
    await orderRef.update({ refundPending: false, refundedAt: FieldValue.serverTimestamp(), "payment.status": "refunded" });
    return { refunded: true };
  } catch (e) {
    console.error("gas supplier refund failed", orderId, e?.message);
    return { refunded: false, retry: true };
  }
}

async function cancel(uid, data, { asAdmin = false } = {}) {
  const { orderId, reason } = readRequest(data, ["orderId", "reason"]);
  if (!isId(orderId)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  if (asAdmin && !(typeof reason === "string" && reason.trim().length >= 3 && reason.length <= 500)) throw refuse("reason_required", "A reason is required.", "invalid-argument");
  const orderRef = db().collection(ORDERS).doc(orderId);
  await db().runTransaction(async (tx) => {
    const o = await tx.get(orderRef);
    if (!o.exists || (!asAdmin && o.data().passengerId !== uid)) throw refuse("order_not_found", "Order not found.", "not-found");
    const order = o.data();
    if (order.status === "cancelled") return;
    const allowed = asAdmin ? ACTIVE : PASSENGER_CANCELLABLE;
    if (!allowed.includes(order.status)) throw refuse("cannot_cancel", "This order can no longer be cancelled.");
    const driverRef = order.driverId ? db().collection("drivers").doc(order.driverId) : null;
    const dr = driverRef ? await tx.get(driverRef) : null;
    tx.update(orderRef, {
      status: "cancelled", cancelledAt: FieldValue.serverTimestamp(), cancelledBy: uid, cancelledByRole: asAdmin ? "admin" : "passenger",
      cancelReason: typeof reason === "string" ? reason.trim().slice(0, 500) : null, refundPending: Boolean(order.payment?.escrowId),
      ...(order.riderOffer || order.riderDeadlineAt ? clearOffer(order, "cancelled") : {}),
    });
    if (driverRef) releaseDriver(tx, driverRef, dr.exists ? dr.data() : null, orderId);
    if (order.status === "outForDelivery") {
      // F5: the cylinder left the station; recovering it is an offline procedure. One alert per order.
      tx.create(db().collection("admin_alerts").doc(`gas_cylinder_recovery_${orderId}`), adminAlert("gas_cylinder_recovery_required",
        `Cancelled Gas supplier order ${orderId} after hand-over: recover the cylinder`,
        { severity: "high", resolved: false, orderId,
          supplierId: order.supplierId ?? null, driverId: order.driverId ?? null, deliveryMode: order.deliveryMode ?? null }));
    }
    event(tx, orderRef, order.status, "cancelled", uid, asAdmin ? "admin" : "passenger");
  });
  // A cancelled order with refundPending (this call or an earlier failed one) is refunded now.
  const refund = await settleRefund(orderId);
  const after = (await orderRef.get()).data();
  return { orderId, status: after.status, refundPending: after.refundPending === true, refunded: refund.refunded };
}

// ── Supplier response deadline ───────────────────────────────────────────────

const RESPONSE_MINUTES_MAX = 24 * 60;
/** The agreed initial supplier response deadline (owner decision, 2026-10-29). */
const DEFAULT_RESPONSE_MINUTES = 10;
/** Whether the setting holds a usable deadline. Pure. */
const validResponseMinutes = (v) => Number.isInteger(v) && v >= 1 && v <= RESPONSE_MINUTES_MAX;
/** The deadline in minutes: the setting when valid, else the agreed default. Pure. */
function responseDeadlineMinutes(flag) {
  const v = flag?.supplierResponseMinutes;
  return validResponseMinutes(v) ? v : DEFAULT_RESPONSE_MINUTES;
}

/**
 * Cancels paid orders still waiting for the supplier past the deadline and
 * refunds their holds. Each order changes in its own transaction that
 * re-reads it, so an accept or decline that lands first wins, and a rerun
 * changes nothing (only "pendingApproval" orders are cancelled). Refunds go
 * through settleRefund, as for any cancellation.
 */
async function expireUnansweredOrders({ now = Date.now() } = {}) {
  const flag = await db().doc(FLAG_DOC).get();
  const raw = flag.exists ? flag.data().supplierResponseMinutes : undefined;
  if (raw !== undefined && !validResponseMinutes(raw)) console.warn("supplierResponseMinutes is not a whole number from 1 to 1440; using the default", DEFAULT_RESPONSE_MINUTES);
  const minutes = responseDeadlineMinutes(flag.exists ? flag.data() : null);
  const cutoff = now - minutes * 60 * 1000;
  const waiting = await db().collection(ORDERS).where("status", "==", "pendingApproval").get();
  const expired = [];
  for (const doc of waiting.docs) {
    const paidAt = doc.data().paidAt?.toMillis?.();
    if (!(typeof paidAt === "number" && paidAt <= cutoff)) continue;
    const changed = await db().runTransaction(async (tx) => {
      const o = await tx.get(doc.ref);
      const order = o.exists ? o.data() : null;
      const at = order?.paidAt?.toMillis?.();
      if (order?.status !== "pendingApproval" || !(typeof at === "number" && at <= cutoff)) return false;
      tx.update(doc.ref, {
        status: "cancelled", cancelledAt: FieldValue.serverTimestamp(), cancelledBy: "system", cancelledByRole: "system",
        cancelReason: "supplier_no_response", refundPending: Boolean(order.payment?.escrowId),
        supplierResponseDeadlineMinutes: minutes,
      });
      event(tx, doc.ref, "pendingApproval", "cancelled", "system", "system", { reason: "supplier_no_response" });
      return true;
    });
    if (!changed) continue;
    const refund = await settleRefund(doc.id);
    expired.push({ orderId: doc.id, refunded: refund.refunded === true });
  }
  return { deadlineMinutes: minutes, expired };
}

exports.expireUnansweredGasSupplierOrders = onSchedule(
  // Every minute: with the 10-minute deadline an unanswered order is cancelled within about 11 minutes.
  { region: "europe-west2", schedule: "every 1 minutes", timeZone: "Africa/Accra" },
  () => runDeadlineSweeps(),
);

/**
 * The schedule's two sweeps, each guarded: one throwing never stops the
 * other (a failing response-deadline sweep must not stop linked-rider
 * fallback, nor the other way round). [sweeps] is for tests only.
 */
async function runDeadlineSweeps({ sweeps = { expireUnansweredOrders, expireRiderOffers } } = {}) {
  const errors = [];
  try {
    const r = await sweeps.expireUnansweredOrders();
    if (r.expired.length) console.log("expired unanswered gas supplier orders", r.deadlineMinutes, JSON.stringify(r.expired));
  } catch (e) {
    console.error("gas supplier response-deadline sweep failed", e);
    errors.push("expireUnansweredOrders");
  }
  try {
    const riders = await sweeps.expireRiderOffers();
    if (riders.fallbacks.length) console.log("linked-rider orders passed to CTSGo dispatch", JSON.stringify(riders.fallbacks));
    if (riders.failed?.length) console.error("linked-rider orders the sweep could not process", JSON.stringify(riders.failed));
  } catch (e) {
    console.error("linked-rider deadline sweep failed", e);
    errors.push("expireRiderOffers");
  }
  return { errors };
}

// ── Callables ────────────────────────────────────────────────────────────────

const OPTS = { region: "europe-west2", minInstances: 0 };
const gated = (fn) => async (request) => {
  await requireEnabled();
  return fn(request);
};

/**
 * Whether supplier ordering is switched on, for the passenger app to check
 * BEFORE holding any wallet funds. Not gated itself; reveals only the flag.
 */
exports.gasSupplierOrderingStatus = onCall(OPTS, async (r) => {
  requireAuth(r);
  const snap = await db().doc(FLAG_DOC).get();
  return { enabled: snap.exists && snap.data().enabled === true };
});
exports.payGasSupplierOrder = onCall(OPTS, gated((r) => pay(requireAuth(r), r.data)));
exports.supplierRespondGasOrder = onCall(OPTS, gated((r) => supplierRespond(requireAuth(r), r.data)));
exports.supplierHandOverGasOrder = onCall(OPTS, gated((r) => supplierHandOver(requireAuth(r), r.data)));
exports.supplierRequestGasDriver = onCall(OPTS, gated((r) => supplierRequestDriver(requireAuth(r), r.data)));
exports.supplierCompleteGasOrder = onCall(OPTS, gated((r) => supplierComplete(requireAuth(r), r.data)));
exports.listGasSupplierJobs = onCall(OPTS, gated((r) => listJobs(requireAuth(r))));
exports.listMyGasSupplierJobs = onCall(OPTS, gated((r) => myJobs(requireAuth(r), r.data)));
exports.acceptGasSupplierJob = onCall(OPTS, gated((r) => acceptJob(requireAuth(r), r.data)));
exports.supplierListGasRiders = onCall(OPTS, gated((r) => listRiders(requireAuth(r), r.data)));
exports.supplierAssignGasRider = onCall(OPTS, gated((r) => assignRider(requireAuth(r), r.data)));
exports.declineGasSupplierRiderOffer = onCall(OPTS, gated((r) => declineOffer(requireAuth(r), r.data)));
exports.listMyGasSupplierEarnings = onCall(OPTS, gated((r) => myEarnings(requireAuth(r), r.data)));
exports.arriveGasSupplierStation = onCall(OPTS, gated((r) => driverArrived(requireAuth(r), r.data)));
exports.completeGasSupplierOrder = onCall(OPTS, gated((r) => complete(requireAuth(r), r.data)));
// Not gated: cancelling (and refunding) an existing order must keep working
// while the flag is off. cancel() moves money only for an order that exists,
// is the caller's, is still cancellable and names a held escrow.
exports.cancelGasSupplierOrder = onCall(OPTS, (r) => cancel(requireAuth(r), r.data));
/** Statuses an admin may take a driver off (before the supplier's hand-over). */
const RELEASABLE = Object.freeze(["driverAssigned", "atStation"]);

/**
 * Reassignment: an active admin takes the assigned driver off an order that
 * the supplier has not yet handed over, with a reason. The order returns to
 * "confirmed" for another eligible driver; the released driver is freed only
 * while their record still names this order, and may not take it again. No
 * money moves (the hold stays bound and HELD) and the completion code is
 * unchanged (no driver has ever seen it). A repeat call is a no-op. A
 * linked-rider order goes to CTSGo dispatch ("admin_release"): its accepted
 * fee and linked supplier no longer apply.
 */
async function adminReleaseDriver(adminUid, data) {
  const { orderId, reason } = readRequest(data, ["orderId", "reason"]);
  if (!isId(orderId)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  if (typeof reason !== "string" || reason.trim().length < 3 || reason.length > 500) {
    throw refuse("reason_required", "Give a reason.", "invalid-argument");
  }
  const orderRef = db().collection(ORDERS).doc(orderId);
  return db().runTransaction(async (tx) => {
    const o = await tx.get(orderRef);
    if (!o.exists) throw refuse("order_not_found", "Order not found.", "not-found");
    const order = o.data();
    if (order.status === "confirmed" && !order.driverId) return { orderId, status: "confirmed", alreadyReleased: true };
    if (!RELEASABLE.includes(order.status) || !isId(order.driverId)) {
      throw refuse(order.status === "outForDelivery" ? "handed_over" : "invalid_transition",
        order.status === "outForDelivery"
          ? "The cylinder is already with the driver: cancel or complete the order instead."
          : "This order has no driver to release.");
    }
    const driverRef = db().collection("drivers").doc(order.driverId);
    const dr = await tx.get(driverRef);
    tx.update(orderRef, {
      status: "confirmed",
      driverId: FieldValue.delete(),
      acceptedAt: FieldValue.delete(),
      arrivedAtStationAt: FieldValue.delete(),
      releasedDriverIds: FieldValue.arrayUnion(order.driverId),
      ...(order.deliveryMode === "linked_rider"
        ? { ...fallbackFields(order, "admin_release", "cancelled"), linkedSupplierId: FieldValue.delete(), acceptedFeePesewas: FieldValue.delete() }
        : {}),
    });
    releaseDriver(tx, driverRef, dr.exists ? dr.data() : null, orderId);
    event(tx, orderRef, order.status, "confirmed", adminUid, "admin",
      { reason: reason.trim(), releasedDriverId: order.driverId });
    return { orderId, status: "confirmed", releasedDriverId: order.driverId };
  });
}

exports.adminReleaseGasSupplierDriver = onCall(OPTS, gated(async (r) => {
  const actor = await requireActiveAdmin(r);
  return adminReleaseDriver(actor.adminUid, r.data);
}));

// Not gated, like the passenger's cancel: the admin's way to unwind orders
// after the flag is switched off.
exports.adminCancelGasSupplierOrder = onCall(OPTS, async (r) => {
  const actor = await requireActiveAdmin(r);
  return cancel(actor.adminUid, r.data, { asAdmin: true });
});

Object.assign(exports, {
  FLAG_DOC, JOB_TYPE, FULFILLED_TYPES, PASSENGER_CANCELLABLE, DRIVER_ACTIVE, RELEASABLE,
  escrowPaymentProblem, catalogProblem, responseDeadlineMinutes, expireUnansweredOrders,
  DELIVERY_MODES, ARRANGEMENT_MODES, MAX_COMPLETION_FAILURES, DEFAULT_RESPONSE_MINUTES,
  MAX_RIDER_DECLINES, linkedRiderRejection, expireRiderOffers, runDeadlineSweeps,
  /** Tests only: replaces the offer clock (null restores Date.now). */
  _setClockForTests: (fn) => { clock = fn ?? (() => Date.now()); },
});
