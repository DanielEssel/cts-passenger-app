// Firestore rules for the settlement-critical order fields (Phase 1).
//
// Signed-in apps may never point an order at another escrow or touch the
// fields completion settlement relies on (walletProcessed, settlementStatus,
// passengerConfirmed, the booked price, the confirmation code), while every
// write the current Driver App makes along a job stays allowed.
//
// Writes go through the emulator's REST API as an end user (unsigned test
// token, accepted by the emulator only), so the rules in firebase.json are
// enforced; seeding uses the Admin SDK, which bypasses them. Firestore
// emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");

const P = "rul-passenger";
const D = "rul-driver";
const OTHER_DRIVER = "rul-other-driver";

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");

/** Unsigned ID token for [uid]; the emulator accepts it, production never would. */
function token(uid) {
  const now = Math.floor(Date.now() / 1000);
  return `${b64({ alg: "none", typ: "JWT" })}.${b64({
    iss: `https://securetoken.google.com/${h.PROJECT_ID}`, aud: h.PROJECT_ID,
    sub: uid, user_id: uid, iat: now, exp: now + 3600, auth_time: now,
    firebase: { sign_in_provider: "phone" },
  })}.`;
}

function encode(v) {
  if (v === null) return { nullValue: null };
  if (typeof v === "boolean") return { booleanValue: v };
  if (typeof v === "number") return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === "string") return { stringValue: v };
  if (v instanceof h.admin.firestore.GeoPoint) {
    return { geoPointValue: { latitude: v.latitude, longitude: v.longitude } };
  }
  if (Array.isArray(v)) return { arrayValue: { values: v.map(encode) } };
  if (typeof v === "object") {
    return { mapValue: { fields: Object.fromEntries(Object.entries(v).map(([k, x]) => [k, encode(x)])) } };
  }
  throw new Error(`unsupported value ${v}`);
}

/** Puts [value] at a dotted field path ("metadata.reason") in REST fields. */
function setPath(fields, path, value) {
  const [head, ...rest] = path.split(".");
  if (!rest.length) { fields[head] = encode(value); return; }
  fields[head] ??= { mapValue: { fields: {} } };
  setPath(fields[head].mapValue.fields, rest.join("."), value);
}

const SERVER_TIME = Symbol("serverTimestamp");
const DELETE = Symbol("delete");

/**
 * Updates [path] as [uid], like the apps' `update()`. Values may be
 * SERVER_TIME or DELETE. Returns true when the rules allowed the write.
 */
async function clientUpdate(uid, path, data, { create = false } = {}) {
  const name = `projects/${h.PROJECT_ID}/databases/(default)/documents/${path}`;
  const fields = {};
  const mask = [];
  const transforms = [];
  for (const [k, v] of Object.entries(data)) {
    if (v === SERVER_TIME) transforms.push({ fieldPath: k, setToServerValue: "REQUEST_TIME" });
    else {
      mask.push(k);
      if (v !== DELETE) setPath(fields, k, v);
    }
  }
  const res = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/${h.PROJECT_ID}/databases/(default)/documents:commit`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token(uid)}` },
      body: JSON.stringify({ writes: [{
        update: { name, fields }, ...(create ? {} : { updateMask: { fieldPaths: mask } }),
        updateTransforms: transforms, currentDocument: { exists: !create },
      }] }),
    },
  );
  if (res.ok) return true;
  const body = await res.json().catch(() => ({}));
  if (res.status === 403 || body?.error?.status === "PERMISSION_DENIED") return false;
  throw new Error(`Unexpected emulator response ${res.status}: ${JSON.stringify(body)}`);
}

const allowed = async (uid, path, data) =>
  assert.equal(await clientUpdate(uid, path, data), true, `expected allowed: ${JSON.stringify(Object.keys(data))}`);
const denied = async (uid, path, data) =>
  assert.equal(await clientUpdate(uid, path, data), false, `expected denied: ${JSON.stringify(Object.keys(data))}`);

const TRIP = { passengerId: P, driverId: D, status: "tripStarted", estimatedFare: 100,
  serviceType: "taxi", paymentMethod: "wallet", escrowId: "own-e" };
const DELIVERY = { passengerId: P, driverId: D, status: "arrivedAtDropoff", estimatedFare: 100,
  paymentMethod: "wallet", deliveryOtp: "1234", escrowId: "own-e" };
const GAS = { passengerId: P, driverId: D, status: "returning", totalPrice: 100,
  paymentMethod: "wallet", deliveryOtp: "4321", escrowId: "own-e", refillType: "pickupAndReturn" };

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed("escrows/own-e", { userId: P, amount: 100, status: "HELD",
    referenceId: "o1", referenceType: "trip" });
  await h.seed("escrows/victim-e", { userId: "rul-victim", amount: 100, status: "HELD",
    referenceId: "victim-order", referenceType: "trip" });
  await h.seed("trips/o1", TRIP);
  await h.seed("deliveries/o1", DELIVERY);
  await h.seed("gas_orders/o1", GAS);
});

describe("rides: the Driver App's own writes stay allowed", () => {
  test("RUL-T01 arrive, start and complete as the app writes them", async () => {
    await h.seed("trips/o1", { ...TRIP, status: "tripAccepted" });
    await allowed(D, "trips/o1", { status: "driverArrived" });
    await allowed(D, "trips/o1", { status: "tripStarted", startedAt: SERVER_TIME });
    await allowed(D, "trips/o1", { status: "completed", completedAt: SERVER_TIME });
  });

  test("RUL-T02 cancel as the app writes it", async () => {
    await allowed(D, "trips/o1", { status: "cancelledByDriver", cancelledAt: SERVER_TIME });
  });
});

describe("rides: settlement fields are server-only", () => {
  test("RUL-T10 the driver cannot point the trip at another escrow", async () => {
    await denied(D, "trips/o1", { escrowId: "victim-e" });
  });
  test("RUL-T11 ... nor in the completing write", async () => {
    await denied(D, "trips/o1", { status: "completed", completedAt: SERVER_TIME, escrowId: "victim-e" });
  });
  test("RUL-T12 the driver cannot remove the escrow (falls back to a wallet charge)", async () => {
    await denied(D, "trips/o1", { escrowId: DELETE });
  });
  test("RUL-T13 walletProcessed and settlementStatus cannot be set", async () => {
    await denied(D, "trips/o1", { walletProcessed: true });
    await denied(D, "trips/o1", { settlementStatus: "failed" });
    await denied(P, "trips/o1", { walletProcessed: true });
    await denied(P, "trips/o1", { settlementStatus: "completed" });
  });
  test("RUL-T14 the driver cannot confirm on the passenger's behalf", async () => {
    await denied(D, "trips/o1", { passengerConfirmed: true });
  });
  test("RUL-T15 completedAt is written only by the completing step", async () => {
    await denied(D, "trips/o1", { completedAt: SERVER_TIME });
  });
  test("RUL-T16 the booked fare cannot change", async () => {
    await denied(D, "trips/o1", { estimatedFare: 500 });
    await denied(P, "trips/o1", { estimatedFare: 1 });
  });
  test("RUL-T17 the passenger cannot attach someone else's escrow", async () => {
    await h.seed("trips/o1", { passengerId: P, driverId: D, status: "tripStarted",
      estimatedFare: 100, serviceType: "taxi", paymentMethod: "wallet" });
    await denied(P, "trips/o1", { escrowId: "victim-e" });
  });
  test("RUL-T18 another driver cannot write the trip at all", async () => {
    await denied(OTHER_DRIVER, "trips/o1", { status: "completed", completedAt: SERVER_TIME });
  });
});

describe("deliveries", () => {
  test("RUL-D01 completion as the app writes it stays allowed", async () => {
    await allowed(D, "deliveries/o1", { status: "completed", updatedAt: SERVER_TIME,
      otpSubmitted: "1234", otpVerifiedAt: SERVER_TIME, completedAt: SERVER_TIME, actualFare: 100 });
  });
  test("RUL-D02 cancel as the app writes it stays allowed", async () => {
    await h.seed("deliveries/o1", { ...DELIVERY, status: "pickupEnroute" });
    await allowed(D, "deliveries/o1", { status: "cancelled", statusReason: "cancelledByDriver",
      cancelledAt: SERVER_TIME, cancelReason: "Cancelled by driver" });
  });
  test("RUL-D10 settlement fields, escrow, price and code are protected", async () => {
    await denied(D, "deliveries/o1", { escrowId: "victim-e" });
    await denied(D, "deliveries/o1", { escrowId: DELETE });
    await denied(D, "deliveries/o1", { walletProcessed: true });
    await denied(D, "deliveries/o1", { settlementStatus: "failed" });
    await denied(D, "deliveries/o1", { estimatedFare: 500 });
    await denied(D, "deliveries/o1", { deliveryOtp: "0000" });
  });
});

describe("gas orders", () => {
  test("RUL-G01 each step and the hand-over as the app writes them stay allowed", async () => {
    await h.seed("gas_orders/o1", { ...GAS, status: "driverArrived" });
    await allowed(D, "gas_orders/o1", { status: "pickedUp", updatedAt: SERVER_TIME,
      pickupCompletedAt: SERVER_TIME });
    await h.seed("gas_orders/o1", GAS);
    await allowed(D, "gas_orders/o1", { status: "delivered", updatedAt: SERVER_TIME,
      otpSubmitted: "4321", otpVerifiedAt: SERVER_TIME, deliveredAt: SERVER_TIME, actualFare: 100 });
  });
  test("RUL-G02 cancel as the app writes it stays allowed", async () => {
    await h.seed("gas_orders/o1", { ...GAS, status: "driverEnRoute" });
    await allowed(D, "gas_orders/o1", { status: "cancelled", cancelledAt: SERVER_TIME,
      cancelReason: "Cancelled by driver" });
  });
  test("RUL-G10 settlement fields, escrow, price and code are protected", async () => {
    await denied(D, "gas_orders/o1", { escrowId: "victim-e" });
    await denied(D, "gas_orders/o1", { escrowId: DELETE });
    await denied(D, "gas_orders/o1", { walletProcessed: true });
    await denied(D, "gas_orders/o1", { settlementStatus: "failed" });
    await denied(D, "gas_orders/o1", { totalPrice: 500 });
    await denied(D, "gas_orders/o1", { deliveryOtp: "0000" });
  });
});

// ── Phase 1B: every current Passenger App write, the Driver App's live
// location, and an older Driver build's completion stay allowed. ─────────

const SETTLED = { walletProcessed: true, settlementStatus: "completed", actualFare: 100,
  platformFee: 15, driverEarnings: 85 };
const geo = new h.admin.firestore.GeoPoint(5.6037, -0.187);

describe("passenger app: rides", () => {
  test("RUL-P01 confirm arrival after completion", async () => {
    await h.seed("trips/o1", { ...TRIP, status: "completed" });
    await allowed(P, "trips/o1", { passengerConfirmed: true, passengerConfirmedAt: SERVER_TIME });
  });
  test("RUL-P02 dispute after completion", async () => {
    await h.seed("trips/o1", { ...TRIP, status: "completed" });
    await allowed(P, "trips/o1", { disputed: true, disputedAt: SERVER_TIME,
      disputeReason: "Passenger did not confirm arrival" });
  });
  test("RUL-P03 rate a settled trip", async () => {
    await h.seed("trips/o1", { ...TRIP, ...SETTLED, status: "completed", passengerConfirmed: true });
    await allowed(P, "trips/o1", { passengerRating: 5, passengerTags: ["Polite", "Safe driving"],
      passengerFeedback: "Great", ratedAt: SERVER_TIME });
  });
  test("RUL-P04 cancel or time out while searching, cancel after acceptance", async () => {
    const searching = { passengerId: P, driverId: null, status: "searching", estimatedFare: 100,
      serviceType: "taxi", paymentMethod: "wallet", escrowId: "own-e" };
    await h.seed("trips/o1", searching);
    await allowed(P, "trips/o1", { status: "cancelledByPassenger", cancelledAt: SERVER_TIME,
      cancellationReason: "User cancelled while searching" });
    await h.seed("trips/o1", searching);
    await allowed(P, "trips/o1", { status: "noDriversAvailable", expiredAt: SERVER_TIME,
      expiredBy: "passenger_timeout" });
    await h.seed("trips/o1", { ...TRIP, status: "tripAccepted" });
    await allowed(P, "trips/o1", { status: "cancelled", cancelledAt: SERVER_TIME,
      cancelReason: "Cancelled by passenger" });
  });
  test("RUL-P05 the passenger cannot forge settlement either", async () => {
    await h.seed("trips/o1", { ...TRIP, status: "completed" });
    await denied(P, "trips/o1", { escrowId: "victim-e" });
    await denied(P, "trips/o1", { autoConfirmed: true });
  });
});

describe("passenger app: deliveries", () => {
  test("RUL-P10 cancel a pending delivery", async () => {
    await h.seed("deliveries/o1", { ...DELIVERY, driverId: null, status: "pending" });
    await allowed(P, "deliveries/o1", { status: "cancelled", cancelledAt: SERVER_TIME,
      cancelReason: "Changed my mind" });
  });
  test("RUL-P11 rate a settled delivery", async () => {
    await h.seed("deliveries/o1", { ...DELIVERY, ...SETTLED, status: "completed" });
    await allowed(P, "deliveries/o1", { passengerRating: 4.5 });
  });
  test("RUL-P12 the escrowId write after attach (server already set the same id)", async () => {
    await h.seed("escrows/del-e", { userId: P, amount: 100, status: "HELD",
      referenceId: "o1", referenceType: "delivery" });
    await h.seed("deliveries/o1", { ...DELIVERY, driverId: null, status: "pending", escrowId: "del-e" });
    await allowed(P, "deliveries/o1", { escrowId: "del-e" });
  });
  test("RUL-P13 the passenger cannot name an escrow not attached to this delivery", async () => {
    await h.seed("escrows/loose-e", { userId: P, amount: 100, status: "HELD", referenceId: null });
    const pending = { ...DELIVERY, driverId: null, status: "pending" };
    delete pending.escrowId;
    await h.seed("deliveries/o1", pending);
    await denied(P, "deliveries/o1", { escrowId: "loose-e" });
    await denied(P, "deliveries/o1", { escrowId: "victim-e" });
  });
});

describe("passenger app: gas orders", () => {
  const pending = { passengerId: P, driverId: null, status: "pendingApproval", totalPrice: 100,
    paymentMethod: "wallet", deliveryOtp: "4321", refillType: "pickupAndReturn" };
  test("RUL-P20 the escrowId write after a successful attach", async () => {
    await h.seed("escrows/gas-e", { userId: P, amount: 100, status: "HELD",
      referenceId: "o1", referenceType: "gas_order" });
    await h.seed("gas_orders/o1", pending);
    await allowed(P, "gas_orders/o1", { escrowId: "gas-e" });
  });
  test("RUL-P21 no escrowId write for an unattached or someone else's escrow", async () => {
    await h.seed("escrows/loose-e", { userId: P, amount: 100, status: "HELD", referenceId: null });
    await h.seed("gas_orders/o1", pending);
    await denied(P, "gas_orders/o1", { escrowId: "loose-e" });
    await denied(P, "gas_orders/o1", { escrowId: "victim-e" });
  });
  test("RUL-P22 cancel with the nested metadata reason", async () => {
    await h.seed("gas_orders/o1", pending);
    await allowed(P, "gas_orders/o1", { status: "cancelled", cancelledAt: SERVER_TIME,
      "metadata.cancellationReason": "No longer needed" });
  });
  test("RUL-P23 rate a settled order", async () => {
    await h.seed("gas_orders/o1", { ...GAS, ...SETTLED, status: "delivered" });
    await allowed(P, "gas_orders/o1", { passengerRating: 5 });
  });
});

describe("driver app: live location on every job", () => {
  test("RUL-L01 ride, delivery and gas position writes", async () => {
    await allowed(D, "trips/o1", { driverCurrentLocation: geo, driverHeading: 90.5,
      driverSpeed: 8.2, lastLocationUpdate: SERVER_TIME });
    await allowed(D, "deliveries/o1", { driverCurrentLocation: geo, driverHeading: 90.5,
      lastLocationUpdate: SERVER_TIME, driverLocationUpdatedAt: SERVER_TIME });
    await allowed(D, "gas_orders/o1", { driverCurrentLocation: geo,
      lastLocationUpdate: SERVER_TIME, driverLocationUpdatedAt: SERVER_TIME });
  });
});

describe("older driver builds", () => {
  test("RUL-O01 a 2026-06..08 build completes a trip writing walletProcessed: false", async () => {
    await allowed(D, "trips/o1", { status: "completed", completedAt: SERVER_TIME,
      walletProcessed: false, passengerConfirmed: false, disputed: false,
      actualFare: 100, distanceKm: 3.2 });
  });
  test("RUL-O02 ... but never walletProcessed: true, nor false once settled", async () => {
    await denied(D, "trips/o1", { status: "completed", completedAt: SERVER_TIME, walletProcessed: true });
    await h.seed("trips/o1", { ...TRIP, ...SETTLED, status: "completed" });
    await denied(D, "trips/o1", { walletProcessed: false });
  });
});

describe("order creation: no settlement state at birth", () => {
  const created = (uid, path, data) => clientUpdate(uid, path, data, { create: true });
  const NEW = {
    "trips/new1": { passengerId: P, driverId: null, status: "searching", estimatedFare: 100,
      // The ride flow holds first, creates the trip naming the fresh hold, then attaches.
      distance: 3.2, serviceType: "taxi", paymentMethod: "wallet", escrowId: "fresh-e" },
    // Passenger 1.0.1 shapes (release v5): no deliveryOtp on the order (the
    // server keeps the code); Gas with its typed delivery fee and quantity.
    "deliveries/new1": { passengerId: P, driverId: null, status: "pending", estimatedFare: 100,
      paymentMethod: "cash", weightTier: "Small", deliveryQuoteId: "q1" },
    "gas_orders/new1": { passengerId: P, driverId: null, status: "pendingApproval", totalPrice: 100,
      deliveryFee: 12, quantity: 1, paymentMethod: "wallet", refillType: "newCylinder",
      metadata: { appVersion: "1.0.1", platform: "flutter" } },
  };

  test("RUL-C01 the Passenger App's order shapes can be created", async () => {
    await h.seed("escrows/fresh-e", { userId: P, amount: 100, status: "HELD", referenceId: null });
    for (const [path, data] of Object.entries(NEW)) {
      assert.equal(await created(P, path, data), true, `create ${path}`);
    }
  });

  test("RUL-C02 an order cannot be created already settled, failed or confirmed", async () => {
    await h.seed("escrows/fresh-e", { userId: P, amount: 100, status: "HELD", referenceId: null });
    for (const [path, data] of Object.entries(NEW)) {
      for (const forged of [{ walletProcessed: true }, { settlementStatus: "failed" },
        { autoConfirmed: true }, { escrowRefunded: true }]) {
        assert.equal(await created(P, path, { ...data, ...forged }), false,
          `create ${path} with ${Object.keys(forged)}`);
      }
    }
  });
});

// ── Phase 1C: server-only collections, waivers, admin panel flows ─────────

const ADMIN = "rul-admin";

/** GET [path] as [uid]; true when the rules allowed the read. */
async function clientRead(uid, path) {
  const res = await fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/${h.PROJECT_ID}` +
    `/databases/(default)/documents/${path}`, { headers: { Authorization: `Bearer ${token(uid)}` } });
  if (res.ok || res.status === 404) return true;
  if (res.status === 403) return false;
  throw new Error(`Unexpected emulator response ${res.status}`);
}

describe("server-only settlement records", () => {
  const SERVER_ONLY = ["settlement_observations/trips_o1", "admin_escrow_actions/a1",
    "escrowOrderLinks/trip:o1", "completion_code_waivers/gas_orders_o1"];
  test("RUL-S01 drivers and passengers can neither read nor write them", async () => {
    for (const path of SERVER_ONLY) await h.seed(path, { collection: "gas_orders", orderId: "o1" });
    for (const uid of [D, P]) {
      for (const path of SERVER_ONLY) {
        assert.equal(await clientRead(uid, path), false, `read ${path} as ${uid}`);
        assert.equal(await clientUpdate(uid, path, { approvedBy: uid }), false, `write ${path} as ${uid}`);
      }
      assert.equal(await clientUpdate(uid, "completion_code_waivers/gas_orders_o2",
        { collection: "gas_orders", orderId: "o2", approvedBy: uid, reason: "self-approved" },
        { create: true }), false, `create waiver as ${uid}`);
    }
  });
});

describe("admin panel", () => {
  beforeEach(() => h.seed(`admins/${ADMIN}`, { active: true }));
  const waiver = (o = {}) => ({ collection: "gas_orders", orderId: "o1", approvedBy: ADMIN,
    reason: "Delivered before codes existed; confirmed by phone", ...o });
  const create = (uid, path, data) => clientUpdate(uid, path, data, { create: true });

  test("RUL-A01 an admin records a waiver as themselves, once", async () => {
    assert.equal(await create(ADMIN, "completion_code_waivers/gas_orders_o1", waiver()), true);
    assert.equal(await clientUpdate(ADMIN, "completion_code_waivers/gas_orders_o1", { reason: "changed later" }), false);
  });
  test("RUL-A02 ... never on someone else's behalf, for another id, or without a reason", async () => {
    assert.equal(await create(ADMIN, "completion_code_waivers/gas_orders_o1", waiver({ approvedBy: "x" })), false);
    assert.equal(await create(ADMIN, "completion_code_waivers/gas_orders_o9", waiver()), false);
    assert.equal(await create(ADMIN, "completion_code_waivers/gas_orders_o1", waiver({ reason: "" })), false);
    assert.equal(await create(ADMIN, "completion_code_waivers/gas_orders_o1", waiver({ collection: "trips" })), false);
  });
  test("RUL-A03 fare override, alert handling and settlement retry keep working", async () => {
    await h.seed("trips/o1", { ...TRIP, ...SETTLED, status: "completed" });
    await allowed(ADMIN, "trips/o1", { actualFare: 90, fareOverride: true,
      fareOverrideReason: "Admin adjustment", fareOverrideAt: SERVER_TIME });
    await h.seed("gas_orders/o1", { ...GAS, status: "flagged", settlementStatus: "failed" });
    await allowed(ADMIN, "gas_orders/o1", { status: "delivered", settlementStatus: null });
    await h.seed("admin_alerts/al1", { type: "x", read: false });
    await allowed(ADMIN, "admin_alerts/al1", { read: true });
  });
});

describe("completion marker", () => {
  test("RUL-M01 no party can remove or move completedAt after completion", async () => {
    await h.seed("trips/o1", { ...TRIP, status: "completed",
      completedAt: h.admin.firestore.Timestamp.fromDate(new Date(Date.now() - 60e3)) });
    await denied(P, "trips/o1", { completedAt: DELETE });
    await denied(D, "trips/o1", { completedAt: SERVER_TIME });
    await denied(P, "trips/o1", { status: "cancelledByPassenger", completedAt: DELETE });
  });
});
