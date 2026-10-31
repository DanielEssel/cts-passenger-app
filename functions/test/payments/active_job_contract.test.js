// The active-job contract (active_job.js): drivers/{uid}.currentTripId and
// currentTripType are one assignment lock. Server acceptance sets them in
// the claim transaction; every release (status triggers, settlement, escrow
// release and recovery) frees the driver only while the pointer still names
// the job being ended, and clears both fields. A late event for an older job
// never frees a driver from a newer one. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
process.env.GCLOUD_PROJECT = "demo-ctsgo-payments";
process.env.PAYMENTS_MODE = "stub";
process.env.BRIDGE_CLIENT_KEY = "fake-client-key";
process.env.BRIDGE_SECRET_KEY = "fake-secret-key";
process.env.BRIDGE_SERVICE_ID = "1";
const index = require("../../index");
const h = require("./helpers");
const trips = require("../../trips");
const escrow = require("../../escrow");
const { acceptJob, _legacyTripReason } = require("../../accept_job");

const { GeoPoint, Timestamp } = h.admin.firestore;
const ACCRA = new GeoPoint(5.6037, -0.187);
const NEAR = new GeoPoint(5.62, -0.19);
const P = "aj-passenger";
const D = "aj-driver";

Object.defineProperty(h.admin, "messaging", {
  configurable: true, writable: true,
  value: () => ({
    sendEachForMulticast: async (m) => ({ successCount: m.tokens.length, failureCount: 0,
      responses: m.tokens.map(() => ({ success: true })) }),
    send: async () => "stub-id",
  }),
});

const active = { isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true,
  location: NEAR, walletBalance: 0, totalEarnings: 0 };
const rideDriver = (o = {}) => ({ uid: D, role: "driver_hailing", serviceType: "taxi", vehicleType: "taxi",
  ...active, ...o });
const deliveryDriver = (o = {}) => ({ uid: D, role: "driver_delivery", serviceType: "delivery",
  vehicleType: "motorcycle", ...active, ...o });
const searchingTrip = (o = {}) => ({ passengerId: P, driverId: null, status: "searching", serviceType: "taxi",
  paymentMethod: "cash", pickupLocation: ACCRA, estimatedFare: 20, createdAt: Timestamp.now(), ...o });

const driver = () => h.read(`drivers/${D}`);
const holds = async (jobId, type) => {
  const d = await driver();
  assert.equal(d.currentTripId, jobId, "pointer kept on the newer job");
  if (type) assert.equal(d.currentTripType, type);
  assert.equal(d.isAvailable, false, "still busy");
};
const freed = async () => {
  const d = await driver();
  assert.equal(d.currentTripId, undefined, "pointer cleared");
  assert.equal(d.currentTripType, undefined, "type cleared");
  assert.equal(d.isAvailable, true);
};

// ── Settlement events (shapes from confirmation_window / ride_gas_release /
// delivery_integrity tests) ──────────────────────────────────────────────────
function settleRideCash(tripId) {
  const afterDoc = { passengerId: P, driverId: D, paymentMethod: "cash", estimatedFare: 100,
    serviceType: "taxi", status: "completed", passengerConfirmed: true };
  return h.seed(`trips/${tripId}`, afterDoc).then(() => trips.onTripCompleted.run({ params: { tripId },
    data: { before: { data: () => ({ ...afterDoc, status: "tripStarted" }) }, after: { data: () => afterDoc } } }));
}
function settleRideWallet(tripId) {
  const afterDoc = { passengerId: P, driverId: D, paymentMethod: "wallet", escrowId: "e1", estimatedFare: 100,
    serviceType: "taxi", status: "completed", passengerConfirmed: true,
    pickupLocation: ACCRA, dropoffLocation: NEAR }; // priced like a real booking
  return h.seed(`trips/${tripId}`, afterDoc).then(() => trips.onTripCompleted.run({ params: { tripId },
    data: { before: { data: () => ({ ...afterDoc, passengerConfirmed: false }) }, after: { data: () => afterDoc } } }));
}
function settleDeliveryCash(deliveryId) {
  const afterDoc = { passengerId: P, driverId: D, paymentMethod: "cash", estimatedFare: 100, status: "completed",
    deliveryOtp: "1234", otpSubmitted: "1234" };
  return h.seed(`deliveries/${deliveryId}`, afterDoc).then(() => trips.onDeliveryCompleted.run({ params: { deliveryId },
    data: { before: { data: () => ({ ...afterDoc, status: "arrivedAtDropoff" }) }, after: { data: () => afterDoc } } }));
}
function settleGasCash(orderId) {
  const afterDoc = { passengerId: P, driverId: D, paymentMethod: "cash", totalPrice: 100, status: "delivered",
    deliveryOtp: "4321", otpSubmitted: "4321" };
  return h.seed(`gas_orders/${orderId}`, afterDoc).then(() => trips.onGasOrderCompleted.run({ params: { orderId },
    data: { before: { data: () => ({ ...afterDoc, status: "returning" }) }, after: { data: () => afterDoc } } }));
}
const seedEscrow = (referenceId, referenceType = "trip") => h.seed("escrows/e1", { userId: P, amount: 100,
  platformFee: 15, driverNet: 85, status: "HELD", referenceId, referenceType,
  heldAt: Timestamp.fromDate(new Date(Date.now() - 30 * 60 * 1000)) });

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed("settings/platform", { platformFeePercent: 15 });
  await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
});

describe("settlement frees only the job it settles", () => {
  for (const [name, settle, collection] of [
    ["ride (cash)", settleRideCash, "trips"],
    ["delivery (cash)", settleDeliveryCash, "deliveries"],
    ["gas (cash)", settleGasCash, "gas_orders"],
  ]) {
    test(`AJ-01 ${name}: the driver still on this job is freed, both fields cleared`, async () => {
      await h.seed(`drivers/${D}`, rideDriver({ isAvailable: false, currentTripId: "A", currentTripType: collection }));
      await settle("A");
      await freed();
      assert.ok((await driver()).totalEarnings > 0, "earnings recorded");
    });

    test(`AJ-02 ${name}: old-job settlement after a new claim keeps the new job`, async () => {
      await h.seed(`drivers/${D}`, rideDriver({ isAvailable: false, currentTripId: "B", currentTripType: "trips" }));
      await settle("A");
      await holds("B", "trips");
      assert.ok((await driver()).totalEarnings > 0, "the old job is still paid");
    });
  }

  test("AJ-03 late passenger confirmation (escrow release) after a new claim keeps the new job", async () => {
    await h.seed(`drivers/${D}`, rideDriver({ isAvailable: false, currentTripId: "B", currentTripType: "trips" }));
    await seedEscrow("A");
    await settleRideWallet("A");
    assert.equal((await h.read("escrows/e1")).status, "RELEASED");
    assert.equal((await driver()).walletBalance, 85, "the old trip is paid");
    await holds("B", "trips");
  });

  test("AJ-04 a recovery release of an old order's escrow never frees the driver from a newer job", async () => {
    await h.seed(`drivers/${D}`, rideDriver({ isAvailable: false, currentTripId: "B", currentTripType: "trips" }));
    await seedEscrow("A");
    assert.equal(await escrow.releaseEscrow("e1", D, "stuck_escrow_recovery",
      { userId: P, referenceId: "A", referenceType: "trip" }), true);
    await holds("B", "trips");
  });

  test("AJ-05 ... but frees the driver still on that order", async () => {
    await h.seed(`drivers/${D}`, rideDriver({ isAvailable: false, currentTripId: "A", currentTripType: "trips" }));
    await seedEscrow("A");
    await escrow.releaseEscrow("e1", D, "stuck_escrow_recovery", { userId: P, referenceId: "A", referenceType: "trip" });
    await freed();
  });

  test("AJ-06 a repeated settlement event pays once and frees nobody the second time", async () => {
    await h.seed(`drivers/${D}`, rideDriver({ isAvailable: false, currentTripId: "A", currentTripType: "trips" }));
    await settleRideCash("A");
    const once = (await driver()).totalEarnings;
    // The driver takes trip B, then A's event is delivered again.
    await h.db().doc(`drivers/${D}`).update({ isAvailable: false, currentTripId: "B", currentTripType: "trips" });
    await settleRideCash("A");
    assert.equal((await driver()).totalEarnings, once, "paid once");
    await holds("B", "trips");
    assert.equal(await h.count("ledger", "idempotencyKey", "commission_A"), 1);
  });

  test("AJ-07 settlement racing a new claim never leaves a claimed job without its pointer", async () => {
    for (let round = 0; round < 6; round++) {
      await h.clearFirestore();
      await h.seed("settings/platform", { platformFeePercent: 15 });
      await h.seed(`drivers/${D}`, rideDriver({ isAvailable: false, currentTripId: "A", currentTripType: "trips" }));
      await h.seed("trips/B", searchingTrip());
      const [claim] = await Promise.all([acceptJob("ride", D, "B"), settleRideCash("A")]);
      const [d, b] = [await driver(), await h.read("trips/B")];
      if (b.driverId === D) {
        assert.equal(claim.success, true, `round ${round}`);
        assert.deepEqual([d.currentTripId, d.currentTripType, d.isAvailable], ["B", "trips", false], `round ${round}`);
      } else {
        assert.ok(["driver_unavailable", "driver_on_job"].includes(claim.detail), `round ${round}: ${claim.detail}`);
        assert.equal(d.currentTripId, undefined, `round ${round}: freed by A's settlement`);
        assert.equal(b.status, "searching");
      }
    }
  });
});

describe("status triggers", () => {
  async function statusChange(collection, trigger, param, id, from, to, data = {}) {
    const before = { passengerId: P, driverId: D, status: from, ...data };
    const afterDoc = { ...before, status: to };
    await h.seed(`${collection}/${id}`, afterDoc);
    await trigger.run({ params: { [param]: id }, data: { before: { data: () => before }, after: { data: () => afterDoc } } });
  }

  test("AJ-10 a cancellation frees the driver still on that job and clears both fields", async () => {
    for (const [coll, trig, param, from] of [
      ["trips", index.onTripStatusChanged, "tripId", "tripAccepted"],
      ["deliveries", index.onDeliveryStatusChanged, "deliveryId", "driverAssigned"],
      ["gas_orders", index.onGasOrderStatusChanged, "orderId", "driverAssigned"],
    ]) {
      await h.seed(`drivers/${D}`, rideDriver({ isAvailable: false, currentTripId: "A", currentTripType: coll }));
      await statusChange(coll, trig, param, "A", from, "cancelled");
      await freed();
    }
  });

  test("AJ-11 a late cancellation of an older job keeps the newer one", async () => {
    await h.seed(`drivers/${D}`, rideDriver({ isAvailable: false, currentTripId: "B", currentTripType: "trips" }));
    await statusChange("trips", index.onTripStatusChanged, "tripId", "A", "tripAccepted", "cancelledByPassenger");
    await holds("B", "trips");
  });

  test("AJ-12 a job flagged for review does not free its driver", async () => {
    for (const [coll, trig, param, from] of [
      ["trips", index.onTripStatusChanged, "tripId", "completed"],
      ["deliveries", index.onDeliveryStatusChanged, "deliveryId", "completed"],
      ["gas_orders", index.onGasOrderStatusChanged, "orderId", "delivered"],
    ]) {
      await h.seed(`drivers/${D}`, rideDriver({ isAvailable: false, currentTripId: "A", currentTripType: coll }));
      await statusChange(coll, trig, param, "A", from, "flagged");
      await holds("A", coll);
    }
  });

  test("AJ-13 ride completion frees the driver (as before) and clears the type", async () => {
    await h.seed(`drivers/${D}`, rideDriver({ isAvailable: false, currentTripId: "A", currentTripType: "trips" }));
    await statusChange("trips", index.onTripStatusChanged, "tripId", "A", "tripStarted", "completed");
    await freed();
  });
});

describe("acceptTrip (legacy name) enforces the same eligibility as acceptRide", () => {
  const call = (uid, data) => h.callCallable(index.acceptTrip, uid, data);

  test("AJ-20 an eligible ride driver claims it: trip assigned, driver busy with id and type", async () => {
    await h.seed(`drivers/${D}`, rideDriver());
    await h.seed("trips/T", searchingTrip());
    assert.deepEqual(await call(D, { tripId: "T" }), { success: true });
    assert.equal((await h.read("trips/T")).driverId, D);
    await holds("T", "trips");
  });

  test("AJ-21 ineligible callers are refused and the trip stays searching", async () => {
    const cases = {
      delivery: deliveryDriver(),
      wrongService: rideDriver({ serviceType: "okada", vehicleType: "motorcycle" }),
      wrongVehicle: rideDriver({ vehicleType: "pragyia" }),
      unapproved: rideDriver({ isApproved: false }),
      suspended: rideDriver({ signupStep: "suspended" }),
      offline: rideDriver({ isOnline: false }),
      busy: rideDriver({ isAvailable: false }),
      onJob: rideDriver({ currentTripId: "X", currentTripType: "gas_supplier_order" }),
      far: rideDriver({ location: new GeoPoint(6.69, -1.62) }),
    };
    await h.seed("trips/T", searchingTrip());
    for (const [name, doc] of Object.entries(cases)) {
      await h.seed(`drivers/${name}`, { ...doc, uid: name });
      const r = await call(name, { tripId: "T" });
      assert.equal(r.success, false, name);
      assert.ok(r.detail, `${name}: policy reason given`);
    }
    assert.equal((await h.read("trips/T")).status, "searching");
    assert.equal((await h.read("trips/T")).driverId, null);
    await assert.rejects(call("noProfile", { tripId: "T" }).then((r) => {
      if (!r.success) throw new Error(r.reason);
    }), /driver_not_found/);
  });

  test("AJ-22 reasons the May 2026 builds understand", async () => {
    assert.equal(_legacyTripReason("order_already_assigned"), "already_accepted");
    assert.equal(_legacyTripReason("order_unavailable"), "already_accepted");
    assert.equal(_legacyTripReason("order_not_found"), "trip_not_found");
    await h.seed(`drivers/${D}`, rideDriver());
    assert.equal((await call(D, { tripId: "missing" })).reason, "trip_not_found");
    await h.seed("trips/taken", searchingTrip({ driverId: "someone", status: "tripAccepted" }));
    assert.equal((await call(D, { tripId: "taken" })).reason, "already_accepted");
    await assert.rejects(call(null, { tripId: "T" }), /signed in/);
    await assert.rejects(call(D, {}), /tripId/);
  });

  test("AJ-23 two drivers at once: exactly one gets the trip", async () => {
    await h.seed(`drivers/${D}`, rideDriver());
    await h.seed("drivers/D2", { ...rideDriver(), uid: "D2" });
    await h.seed("trips/T", searchingTrip());
    const r = await Promise.all([call(D, { tripId: "T" }), call("D2", { tripId: "T" })]);
    assert.equal(r.filter((x) => x.success).length, 1);
  });
});

describe("no concurrent jobs across job types", () => {
  test("AJ-30 a driver on a supplier Gas job cannot accept a delivery or a legacy Gas order", async () => {
    await h.seed(`drivers/${D}`, deliveryDriver({ currentTripId: "S1", currentTripType: "gas_supplier_order" }));
    await h.seed("deliveries/d1", { passengerId: P, driverId: null, status: "pending", vehicleType: "Okada",
      weightTier: "Small", pickupLocation: ACCRA, dropoffLocation: NEAR, createdAt: Timestamp.now() });
    await h.seed("gas_orders/g1", { passengerId: P, driverId: null, status: "pendingApproval", refillType: "newCylinder",
      deliveryLocation: ACCRA, pickupLocation: ACCRA, createdAt: Timestamp.now() });
    assert.equal((await acceptJob("delivery", D, "d1")).reason, "driver_on_job");
    assert.equal((await acceptJob("gas", D, "g1")).reason, "driver_on_job");
  });

  test("AJ-31 one driver claiming a delivery and a legacy Gas order at once gets one", async () => {
    for (let round = 0; round < 4; round++) {
      await h.clearFirestore();
      await h.seed(`drivers/${D}`, deliveryDriver());
      // Both priced as the server leaves them (release v5): a verified delivery
      // price, and a Gas order at the server's price, so either could be taken.
      await h.seed("deliveries/d1", h.deliveryStamped({ passengerId: P, driverId: null, status: "pending",
        vehicleType: "Okada", weightTier: "Small", estimatedFare: 30, paymentMethod: "cash",
        pickupLocation: ACCRA, dropoffLocation: NEAR, createdAt: Timestamp.now() }));
      await h.seed("gas_orders/g1", h.gasPriced({ passengerId: P, driverId: null, status: "pendingApproval",
        refillType: "newCylinder", cylinderSize: "kg3", quantity: 1, paymentMethod: "cash",
        deliveryLocation: ACCRA, pickupLocation: ACCRA, createdAt: Timestamp.now() }));
      const r = await Promise.all([acceptJob("delivery", D, "d1"), acceptJob("gas", D, "g1")]);
      assert.equal(r.filter((x) => x.success).length, 1, `round ${round}`);
      const d = await driver();
      assert.ok(["d1", "g1"].includes(d.currentTripId));
      assert.equal(d.currentTripType, d.currentTripId === "d1" ? "deliveries" : "gas_orders");
    }
  });
});

