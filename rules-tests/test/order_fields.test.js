// Order status transitions per party, booked fare / outcome fields, passenger
// confirmation and escrow linking on trips, deliveries and gas orders —
// including create operations and multi-field writes that combine an
// allowed change with a forbidden one.
//
// Allowed cases replay current and older Passenger / Driver app writes.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, setDoc, updateDoc, deleteField, serverTimestamp, GeoPoint } = require("firebase/firestore");
const h = require("./helpers");

const DEL = "drvDelO";
const ACCRA = new GeoPoint(5.6037, -0.187);

const delivery = (o = {}) => ({
  passengerId: h.PAX, driverId: null, status: "pending", pickupLocation: ACCRA,
  dropoffLocation: ACCRA, vehicleType: "motorbike", weightTier: "Small", isFragile: false,
  requiresHelpers: false, deliveryOtp: "1234", estimatedFare: 20, actualFare: null,
  completedAt: null, paymentMethod: "wallet", ...o,
});
const gas = (o = {}) => ({
  passengerId: h.PAX, driverId: null, status: "pendingApproval", refillType: "exchangeEmpty",
  cylinderSize: "6kg", quantity: 1, deliveryLocation: ACCRA, totalPrice: 90,
  paymentMethod: "wallet", deliveryOtp: "4321", deliveredAt: null, ...o,
});
const trip = (o = {}) => { const t = h.newTripPayload(o); delete t.createdAt; return t; };
// What Passenger 1.0.1 creates (release v5 refuses deliveryOtp at creation
// and requires a Gas delivery fee); the fixtures above stay as seeded orders.
const without = (o, k) => { const c = { ...o }; delete c[k]; return c; };
const delivery101 = (o = {}) => without(delivery({ deliveryQuoteId: "q-1", ...o }), "deliveryOtp");
const gas101 = (o = {}) => without(gas({ deliveryFee: 12, ...o }), "deliveryOtp");

async function seed() {
  await h.seed();
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    const put = (p, d) => setDoc(doc(fs, p), d);
    await put(`drivers/${DEL}`, { uid: DEL, role: "driver_delivery", isApproved: true,
      isOnline: true, isAvailable: true, signupStep: "approved", location: ACCRA });
    // Escrows: the passenger's own (unattached / attached to each order),
    // another passenger's, and a refunded one.
    await put("escrows/own_free", { userId: h.PAX, amount: 20, status: "HELD" });
    await put("escrows/own_refunded", { userId: h.PAX, amount: 20, status: "REFUNDED" });
    await put("escrows/other_free", { userId: h.STRANGER, amount: 20, status: "HELD" });
    await put("escrows/own_attached_o_del", { userId: h.PAX, amount: 20, status: "HELD",
      referenceId: "o_del", referenceType: "delivery" });
    await put("escrows/own_attached_o_gas", { userId: h.PAX, amount: 90, status: "HELD",
      referenceId: "o_gas", referenceType: "gas_order" });
    await put("escrows/own_attached_elsewhere", { userId: h.PAX, amount: 20, status: "HELD",
      referenceId: "someOtherOrder", referenceType: "delivery" });
    await put("escrows/other_attached_o_del", { userId: h.STRANGER, amount: 20, status: "HELD",
      referenceId: "o_del", referenceType: "delivery" });

    await put("trips/t_cancelled", trip({ status: "cancelledByPassenger" }));
    await put("trips/t_legacy", trip({ status: "inProgress", driverId: h.DRIVER }));
    await put("deliveries/o_del", delivery());
    await put("deliveries/d_active", delivery({ status: "deliveryEnroute", driverId: DEL, escrowId: "x" }));
    await put("deliveries/d_cancelled", delivery({ status: "cancelled", driverId: DEL }));
    await put("gas_orders/o_gas", gas());
    await put("gas_orders/g_active", gas({ status: "refilling", driverId: DEL, escrowId: "x" }));
    await put("gas_orders/g_cancelled", gas({ status: "cancelled", driverId: DEL }));
  });
}

const upd = (uid, path, data) => updateDoc(doc(h.db(uid), path), data);
const create = (uid, path, data) => setDoc(doc(h.db(uid), path), data);

describe("order status and financial fields", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(seed);

  describe("ride status per party", () => {
    it("ORD-T01 passenger cannot move a ride forward or complete it", async () => {
      for (const s of ["driverArrived", "tripStarted", "inProgress", "completed"]) { // seed is tripAccepted
        await assertFails(upd(h.PAX, "trips/assigned", { status: s }), s);
      }
      await assertFails(upd(h.PAX, "trips/started", { status: "completed", completedAt: serverTimestamp() }));
    });

    it("ORD-T02 driver cannot write the passenger's or the server's statuses", async () => {
      for (const s of ["cancelledByPassenger", "noDriversAvailable", "noDrivers", "searching",
        "flagged", "expired", "pendingOtp"]) {
        await assertFails(upd(h.DRIVER, "trips/started", { status: s }), s);
      }
    });

    it("ORD-T03 passenger cannot write server-only statuses", async () => {
      for (const s of ["flagged", "expired", "pendingOtp"]) {
        await assertFails(upd(h.PAX, "trips/searching", { status: s }), s);
      }
    });

    it("ORD-T04 a cancelled ride cannot be reopened or completed", async () => {
      // t_cancelled has no driver: the passenger is the only party.
      await assertFails(upd(h.PAX, "trips/t_cancelled", { status: "searching" }));
      await assertFails(upd(h.PAX, "trips/t_cancelled", { status: "tripStarted" }));
    });

    it("ORD-T05 allowed: every current and legacy driver step", async () => {
      await assertSucceeds(upd(h.DRIVER, "trips/assigned", { status: "driverArrived" }));
      await assertSucceeds(upd(h.DRIVER, "trips/assigned", { status: "tripStarted", startedAt: serverTimestamp() }));
      // Older builds: complete from tripAccepted / legacy 'inProgress'.
      await assertSucceeds(upd(h.DRIVER, "trips/t_legacy", { status: "completed", completedAt: serverTimestamp(),
        finalFare: 20, actualDistanceKm: 6, distanceKm: 6 }));
    });

    it("ORD-T06 allowed: driver completes straight from tripAccepted (2026-06..08 builds)", () =>
      assertSucceeds(upd(h.DRIVER, "trips/assigned", { status: "completed", completedAt: serverTimestamp(),
        finalFare: 20.5, actualFare: 20.5, actualDistanceKm: 6.2, distanceKm: 6.2,
        passengerConfirmed: false, walletProcessed: false, disputed: false })));
  });

  describe("ride fields", () => {
    it("ORD-T10 booked fields are fixed after creation, for both parties", async () => {
      const fixed = { estimatedFare: 1, distance: 0.1, estimatedDuration: 1, serviceType: "okada",
        paymentMethod: "cash", promoCode: "FREE", discountAmount: 20, scheduledAt: new Date(), isScheduled: true };
      for (const [k, v] of Object.entries(fixed)) {
        await assertFails(upd(h.PAX, "trips/assigned", { [k]: v }), `passenger ${k}`);
        await assertFails(upd(h.DRIVER, "trips/started", { [k]: v }), `driver ${k}`);
      }
    });

    it("ORD-T11 outcome fields only in the driver's completion write", async () => {
      for (const k of ["actualFare", "finalFare", "actualDistanceKm", "distanceKm", "actualDuration"]) {
        await assertFails(upd(h.DRIVER, "trips/started", { [k]: 1 }), `driver ${k} mid-trip`);
        await assertFails(upd(h.PAX, "trips/started", { [k]: 1 }), `passenger ${k}`);
      }
      await assertFails(upd(h.DRIVER, "trips/started", { completedAt: serverTimestamp() }));
      await assertFails(upd(h.DRIVER, "trips/completed", { actualFare: 999 }), "after completion");
    });

    it("ORD-T12 combined writes: an allowed step cannot carry a forbidden change", async () => {
      const done = { status: "completed", completedAt: serverTimestamp() };
      await assertFails(upd(h.DRIVER, "trips/started", { ...done, estimatedFare: 999 }));
      await assertFails(upd(h.DRIVER, "trips/started", { ...done, escrowId: "own_free" }));
      await assertFails(upd(h.DRIVER, "trips/started", { ...done, passengerConfirmed: true }));
      await assertFails(upd(h.DRIVER, "trips/started", { ...done, walletProcessed: true }));
      await assertFails(upd(h.PAX, "trips/started",
        { status: "cancelledByPassenger", cancelledAt: serverTimestamp(), paymentMethod: "cash" }));
      await assertFails(upd(h.PAX, "trips/completed", { passengerRating: 5, actualFare: 1 }));
    });

    it("ORD-T13 confirmation and dispute are the passenger's", async () => {
      await assertFails(upd(h.DRIVER, "trips/completed", { disputed: true }));
      await assertFails(upd(h.DRIVER, "trips/completed", { disputeReason: "x" }));
      await assertFails(upd(h.DRIVER, "trips/completed", { passengerConfirmedAt: serverTimestamp() }));
      // completed seed has passengerConfirmed: false; the driver may not
      // flip it, only re-write false.
      await assertFails(upd(h.DRIVER, "trips/completed", { passengerConfirmed: true }));
      await assertSucceeds(upd(h.DRIVER, "trips/completed", { passengerConfirmed: false }));
      await assertSucceeds(upd(h.PAX, "trips/completed", { disputed: true,
        disputedAt: serverTimestamp(), disputeReason: "Passenger did not confirm arrival" }));
    });

    it("ORD-T14 allowed: location updates on an active ride", () =>
      assertSucceeds(upd(h.DRIVER, "trips/started", { driverCurrentLocation: ACCRA,
        driverHeading: 90, driverSpeed: 3, lastLocationUpdate: serverTimestamp() })));
  });

  describe("escrow linking", () => {
    it("ORD-E01 a ride may be created only with the passenger's own unattached HELD escrow", async () => {
      await assertSucceeds(create(h.PAX, "trips/n1", h.newTripPayload({ escrowId: "own_free" })));
      await assertSucceeds(create(h.PAX, "trips/n2", h.newTripPayload({ escrowId: null, paymentMethod: "cash" })));
      await assertFails(create(h.PAX, "trips/n3", h.newTripPayload({ escrowId: "other_free" })));
      await assertFails(create(h.PAX, "trips/n4", h.newTripPayload({ escrowId: "own_refunded" })));
      await assertFails(create(h.PAX, "trips/n5", h.newTripPayload({ escrowId: "own_attached_elsewhere" })));
      await assertFails(create(h.PAX, "trips/n6", h.newTripPayload({ escrowId: "does_not_exist" })));
    });

    it("ORD-E02 the passenger saves the escrow attached to this order, once", async () => {
      await assertSucceeds(upd(h.PAX, "deliveries/o_del", { escrowId: "own_attached_o_del" }));
      await assertFails(upd(h.PAX, "deliveries/o_del", { escrowId: "own_free" }), "no swap");
      await assertFails(upd(h.PAX, "deliveries/o_del", { escrowId: deleteField() }), "no removal");
      await assertSucceeds(upd(h.PAX, "gas_orders/o_gas", { escrowId: "own_attached_o_gas" }));
    });

    it("ORD-E03 an escrow not attached to this order, or not the passenger's, cannot be saved", async () => {
      for (const id of ["own_free", "own_attached_elsewhere", "other_attached_o_del", "nope"]) {
        await assertFails(upd(h.PAX, "deliveries/o_del", { escrowId: id }), id);
      }
      await assertFails(upd(h.PAX, "gas_orders/o_gas", { escrowId: "own_attached_o_del" }));
    });

    it("ORD-E04 drivers never write escrowId", async () => {
      await assertFails(upd(DEL, "deliveries/d_active", { escrowId: null }));
      await assertFails(upd(DEL, "deliveries/d_active", { escrowId: deleteField() }));
      await assertFails(upd(DEL, "gas_orders/g_active", { escrowId: "own_attached_o_gas" }));
      await assertFails(upd(h.DRIVER, "trips/started", { escrowId: deleteField() }));
    });
  });

  describe("delivery and gas status per party", () => {
    it("ORD-D01 parties never write server-only or by-party delivery statuses", async () => {
      for (const s of ["flagged", "pendingOtp", "cancelledByDriver", "cancelledByPassenger", "pending"]) {
        await assertFails(upd(DEL, "deliveries/d_active", { status: s }), `driver ${s}`);
        await assertFails(upd(h.PAX, "deliveries/d_active", { status: s }), `passenger ${s}`);
      }
    });

    it("ORD-D02 passenger cannot complete a delivery; nothing reopens a cancelled one", async () => {
      await assertFails(upd(h.PAX, "deliveries/d_active", { status: "completed" }));
      await assertFails(upd(DEL, "deliveries/d_cancelled", { status: "deliveryEnroute" }));
      await assertFails(upd(DEL, "deliveries/d_cancelled", { status: "completed" }));
    });

    it("ORD-D03 delivery booked fields fixed; outcome only at completion", async () => {
      for (const [k, v] of Object.entries({ estimatedFare: 999, paymentMethod: "cash",
        vehicleType: "miniTruck", weightTier: "Large", isFragile: true, requiresHelpers: true })) {
        await assertFails(upd(h.PAX, "deliveries/d_active", { [k]: v }), k);
        await assertFails(upd(DEL, "deliveries/d_active", { [k]: v }), k);
      }
      await assertFails(upd(DEL, "deliveries/d_active", { actualFare: 1 }));
      await assertFails(upd(DEL, "deliveries/d_active", { completedAt: serverTimestamp() }));
      await assertSucceeds(upd(DEL, "deliveries/d_active", { status: "arrivedAtDropoff", updatedAt: serverTimestamp() }));
    });

    it("ORD-G01 parties never write 'pendingOtp', 'flagged' or 'failed'", async () => {
      for (const s of ["pendingOtp", "flagged", "failed", "pendingApproval"]) {
        await assertFails(upd(DEL, "gas_orders/g_active", { status: s }), `driver ${s}`);
        await assertFails(upd(h.PAX, "gas_orders/g_active", { status: s }), `passenger ${s}`);
      }
    });

    it("ORD-G02 passenger cannot mark gas delivered; nothing reopens a cancelled order", async () => {
      await assertFails(upd(h.PAX, "gas_orders/g_active", { status: "delivered" }));
      await assertFails(upd(DEL, "gas_orders/g_cancelled", { status: "returning" }));
      await assertFails(upd(DEL, "gas_orders/g_cancelled", { status: "delivered" }));
    });

    it("ORD-G03 gas booked fields fixed; outcome only at hand-over", async () => {
      for (const [k, v] of Object.entries({ totalPrice: 1, paymentMethod: "cash", quantity: 40,
        cylinderSize: "45kg", refillType: "commercialBulk" })) {
        await assertFails(upd(h.PAX, "gas_orders/g_active", { [k]: v }), k);
        await assertFails(upd(DEL, "gas_orders/g_active", { [k]: v }), k);
      }
      await assertFails(upd(DEL, "gas_orders/g_active", { actualFare: 1 }));
      await assertFails(upd(DEL, "gas_orders/g_active", { deliveredAt: serverTimestamp() }));
      await assertFails(upd(DEL, "gas_orders/g_active", { status: "delivered", totalPrice: 1,
        otpSubmitted: "4321", deliveredAt: serverTimestamp() }), "combined");
    });

    it("ORD-G04 allowed: passenger cancels while pending and in progress (existing policy)", async () => {
      await assertSucceeds(upd(h.PAX, "gas_orders/o_gas", { status: "cancelled", cancelledAt: serverTimestamp(),
        "metadata.cancellationReason": "changed my mind" }));
      await assertSucceeds(upd(h.PAX, "gas_orders/g_active", { status: "cancelled", cancelledAt: serverTimestamp() }));
      await assertSucceeds(upd(h.PAX, "deliveries/d_active", { status: "cancelled", cancelledAt: serverTimestamp() }));
    });
  });

  describe("creates", () => {
    it("ORD-C01 orders are created open, unassigned and without an outcome", async () => {
      await assertFails(create(h.PAX, "trips/c1", h.newTripPayload({ status: "completed" })));
      await assertFails(create(h.PAX, "trips/c2", h.newTripPayload({ driverId: h.DRIVER, status: "tripAccepted" })));
      await assertFails(create(h.PAX, "trips/c3", h.newTripPayload({ actualFare: 0.01 })));
      await assertFails(create(h.PAX, "trips/c4", h.newTripPayload({ completedAt: new Date() })));
      await assertFails(create(h.PAX, "deliveries/c5", delivery101({ status: "completed" })));
      await assertFails(create(h.PAX, "deliveries/c6", delivery101({ actualFare: 1 })));
      await assertFails(create(h.PAX, "gas_orders/c7", gas101({ status: "delivered" })));
      await assertFails(create(h.PAX, "gas_orders/c8", gas101({ deliveredAt: new Date() })));
      await assertFails(create(h.PAX, "gas_orders/c9", gas101({ status: "pendingOtp" })));
      await assertSucceeds(create(h.PAX, "deliveries/c10", delivery101()));
      await assertSucceeds(create(h.PAX, "gas_orders/c11", gas101()));
    });
  });
});
