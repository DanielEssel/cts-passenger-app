"use strict";

/**
 * Completion codes for Delivery and legacy Gas orders, kept where the driver
 * cannot read them.
 *
 * The code proves the customer received the order: settlement (trips.js)
 * pays the driver only when the submitted code matches. It used to live only
 * on the order document as `deliveryOtp`, which the assigned driver can read,
 * so a driver could complete (and be paid for) an order never handed over.
 *
 * Now the code lives in order_completion_codes/{collection}_{orderId}
 * (readable by the order's passenger only, written only here):
 *  - created when the order is created (ensureCompletionCode, from the
 *    create triggers), reusing the code an older Passenger build wrote on the
 *    order, or generating one when the order carries none (current builds);
 *  - read by settlement (storedCompletionCode), falling back to the order's
 *    own `deliveryOtp` for orders created before this release;
 *  - checked for the driver by verifyCompletionCode, which never reveals it
 *    and allows MAX_ATTEMPTS wrong tries per order.
 * Supplier Gas orders keep their own server-held code (gas_supplier_fulfilment.js).
 * Code values are never logged or returned.
 */

const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { usableCode } = require("./completion_code");

const SECRETS = "order_completion_codes";
const MAX_ATTEMPTS = 5;

/** Orders a code applies to, and the statuses before the hand-over is final. */
const ORDERS = Object.freeze({
  deliveries: new Set(["driverAssigned", "pickupEnroute", "arrivedAtPickup", "packagePicked",
    "deliveryEnroute", "arrivedAtDropoff"]),
  gas_orders: new Set(["driverAssigned", "driverEnRoute", "driverArrived", "pickedUp", "atStation",
    "refilling", "returning", "pendingOtp"]),
});

const db = () => admin.firestore();
const secretRef = (collection, orderId) => db().collection(SECRETS).doc(`${collection}_${orderId}`);
const newCode = () => String(crypto.randomInt(0, 10000)).padStart(4, "0");

/**
 * An order's own legacy code, as its settlement always read it: any
 * non-empty value for deliveries, a digit code (completion_code.js) for gas.
 */
function legacyCode(collection, order) {
  const v = order?.deliveryOtp;
  if (collection === "gas_orders") return usableCode(v) ? String(v).trim() : null;
  return v != null && String(v).trim() !== "" ? String(v).trim() : null;
}

/**
 * Creates the order's code record once. Returns true when it created it.
 * Idempotent: an existing record is never replaced.
 */
async function ensureCompletionCode(collection, orderId, order) {
  if (!ORDERS[collection] || !order || typeof order.passengerId !== "string") return false;
  const code = usableCode(order.deliveryOtp) ? String(order.deliveryOtp).trim() : newCode();
  try {
    await secretRef(collection, orderId).create({
      collection, orderId, passengerId: order.passengerId, code, attempts: 0,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  } catch (e) {
    if (e.code === 6 || /already exists/i.test(e.message ?? "")) return false;
    throw e;
  }
}

/** The order's stored code (record first, then the order's legacy field), or null. */
async function storedCompletionCode(collection, orderId, order, tx = null) {
  const ref = secretRef(collection, orderId);
  const snap = tx ? await tx.get(ref) : await ref.get();
  if (snap.exists && usableCode(snap.data().code)) return String(snap.data().code).trim();
  return legacyCode(collection, order);
}

/**
 * The assigned driver submits the code the customer gave them. On a match
 * the order records otpSubmitted (what settlement compares) and the Driver
 * App then completes it as before. Wrong codes are counted, never revealed.
 */
async function verify(uid, data) {
  const collection = data?.collection;
  const orderId = data?.orderId;
  const code = typeof data?.code === "string" ? data.code.trim() : "";
  if (!ORDERS[collection] || typeof orderId !== "string" || !orderId || orderId.includes("/")) {
    throw new HttpsError("invalid-argument", "collection and orderId are required.");
  }
  if (!usableCode(code)) return { ok: false, reason: "code_malformed" };

  const orderRef = db().collection(collection).doc(orderId);
  const ref = secretRef(collection, orderId);
  return db().runTransaction(async (tx) => {
    const [orderSnap, secretSnap] = await Promise.all([tx.get(orderRef), tx.get(ref)]);
    if (!orderSnap.exists) return { ok: false, reason: "order_not_found" };
    const order = orderSnap.data();
    if (order.driverId !== uid) {
      throw new HttpsError("permission-denied", "This order is not assigned to you.");
    }
    if (!ORDERS[collection].has(order.status)) return { ok: false, reason: "order_not_open" };

    const secret = secretSnap.exists ? secretSnap.data() : null;
    const stored = secret && usableCode(secret.code) ? String(secret.code).trim()
      : legacyCode(collection, order);
    if (!stored) return { ok: false, reason: "no_code_on_order" };
    const attempts = secret?.attempts ?? 0;
    if (attempts >= MAX_ATTEMPTS) return { ok: false, reason: "too_many_attempts", attemptsLeft: 0 };

    if (code !== stored) {
      if (secretSnap.exists) tx.update(ref, { attempts: attempts + 1 });
      else {
        tx.set(ref, { collection, orderId, passengerId: order.passengerId ?? null, code: stored,
          attempts: 1, createdAt: admin.firestore.FieldValue.serverTimestamp() });
      }
      return { ok: false, reason: "code_mismatch", attemptsLeft: MAX_ATTEMPTS - attempts - 1 };
    }
    tx.update(orderRef, {
      otpSubmitted: stored,
      otpVerifiedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { ok: true };
  });
}

exports.verifyCompletionCode = onCall({ region: "europe-west2" }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  return verify(uid, request.data);
});

exports.SECRETS = SECRETS;
exports.MAX_ATTEMPTS = MAX_ATTEMPTS;
exports.ensureCompletionCode = ensureCompletionCode;
exports.storedCompletionCode = storedCompletionCode;
exports._verify = verify;
