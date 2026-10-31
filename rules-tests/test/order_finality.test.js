// Completed-service finality and server-owned settlement fields on trips,
// deliveries and gas orders.
//
//  - A party (passenger or assigned driver) cannot change the status of an
//    order that was completed / delivered, or flagged for review after
//    completion; a gas order awaiting its OTP may only go back to delivered.
//  - A party cannot create an order carrying, or add, change or remove,
//    the fields only Cloud Functions write (refund, settlement, fare
//    validation, review).
//
// "allowed" cases replay the exact writes the current Passenger and Driver
// apps make, so the new rules cannot silently break a shipped flow.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, setDoc, updateDoc, runTransaction, deleteField, serverTimestamp, GeoPoint } =
  require("firebase/firestore");
const h = require("./helpers");

const DEL = "drvDelF"; // approved delivery driver assigned to the seeded orders
const ACCRA = new GeoPoint(5.6037, -0.187);

const SERVER_FIELDS = {
  escrowRefunded: true, escrowRefundedAt: new Date(),
  walletProcessed: true, walletProcessedAt: new Date(), walletProcessError: "x",
  settlementStatus: "completed", settlementStartedAt: new Date(),
  settlementCompletedAt: new Date(), settlementFailureReason: "x",
  fareValidated: true, fareValidatedAt: new Date(), originalClientFare: 1,
  flagReason: "x", flaggedAt: new Date(), autoConfirmed: true,
  // Release v5: the Gas price verified at creation (gas_pricing.js).
  verifiedPrice: { version: "gas-v2", total: 1, commission: 0, driverNet: 1 },
};

const delivery = (o = {}) => ({
  passengerId: h.PAX, driverId: null, status: "pending", pickupLocation: ACCRA,
  dropoffLocation: ACCRA, vehicleType: "motorbike", deliveryOtp: "1234",
  estimatedFare: 20, paymentMethod: "wallet", escrowId: "esc1", ...o,
});
const gas = (o = {}) => ({
  passengerId: h.PAX, driverId: null, status: "pendingApproval",
  refillType: "exchangeEmpty", cylinderSize: "6kg", deliveryLocation: ACCRA,
  totalPrice: 90, paymentMethod: "wallet", escrowId: "esc1", deliveryOtp: "4321", ...o,
});
// What Passenger 1.0.1 creates (release v5 refuses deliveryOtp at creation
// and requires typed Gas amounts); the fixtures above stay as seeded orders.
const create101 = (o) => {
  const c = { ...o };
  delete c.deliveryOtp;
  return c;
};
const trip = (o = {}) => {
  const t = h.newTripPayload(o);
  delete t.createdAt;
  return t;
};

async function seed() {
  await h.seed();
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    const put = (p, d) => setDoc(doc(fs, p), d);
    await put(`drivers/${DEL}`, {
      uid: DEL, role: "driver_delivery", serviceType: "delivery", isApproved: true,
      isOnline: true, isAvailable: true, signupStep: "approved", location: ACCRA,
    });
    const T = { driverId: h.DRIVER };
    await put("trips/f_started", trip({ ...T, status: "tripStarted" }));
    await put("trips/f_completed", trip({ ...T, status: "completed", walletProcessed: true }));
    await put("trips/f_flagged", trip({ ...T, status: "flagged", flagReason: "r" }));
    await put("trips/f_refunded", trip({ status: "cancelledByPassenger", escrowRefunded: true }));

    const D = { driverId: DEL };
    await put("deliveries/f_pending", delivery());
    await put("deliveries/f_atDropoff", delivery({ ...D, status: "arrivedAtDropoff" }));
    await put("deliveries/f_completed", delivery({ ...D, status: "completed", settlementStatus: "completed" }));
    await put("deliveries/f_flagged", delivery({ ...D, status: "flagged", flagReason: "r" }));
    await put("deliveries/f_refunded", delivery({ status: "cancelled", escrowRefunded: true }));

    await put("gas_orders/f_pending", gas());
    await put("gas_orders/f_returning", gas({ ...D, status: "returning", refillType: "pickupAndReturn" }));
    await put("gas_orders/f_arrived", gas({ ...D, status: "driverArrived" }));
    await put("gas_orders/f_delivered", gas({ ...D, status: "delivered", walletProcessed: true }));
    await put("gas_orders/f_pendingOtp", gas({ ...D, status: "pendingOtp", flagReason: "r" }));
    await put("gas_orders/f_flagged", gas({ ...D, status: "flagged", flagReason: "r" }));
    await put("gas_orders/f_refunded", gas({ status: "cancelled", escrowRefunded: true }));
  });
}

const ref = (uid, path) => doc(h.db(uid), path);
const upd = (uid, path, data) => updateDoc(ref(uid, path), data);

describe("order finality and server-owned fields", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(seed);

  // ── Completed-service cancellation ─────────────────────────────────────
  describe("trips: status after completion", () => {
    it("FIN-T01 passenger cannot cancel a completed or flagged trip", async () => {
      for (const id of ["f_completed", "f_flagged"]) {
        await assertFails(upd(h.PAX, `trips/${id}`,
          { status: "cancelledByPassenger", cancelledAt: serverTimestamp() }));
        await assertFails(upd(h.PAX, `trips/${id}`, { status: "cancelled" }));
      }
    });

    it("FIN-T02 driver cannot cancel or reopen a completed or flagged trip", async () => {
      for (const id of ["f_completed", "f_flagged"]) {
        await assertFails(upd(h.DRIVER, `trips/${id}`,
          { status: "cancelledByDriver", cancelledAt: serverTimestamp() }));
        await assertFails(upd(h.DRIVER, `trips/${id}`, { status: "tripStarted" }));
      }
      await assertFails(upd(h.DRIVER, "trips/f_flagged", { status: "completed" }));
    });

    it("FIN-T03 neither party can remove the status of a completed trip", async () => {
      await assertFails(upd(h.PAX, "trips/f_completed", { status: deleteField() }));
      await assertFails(upd(h.DRIVER, "trips/f_completed", { status: deleteField() }));
    });

    it("FIN-T04 allowed: rating, confirmation and dispute on a completed trip", async () => {
      // trip_complete_screen.dart, ride_tracking_screen.dart
      await assertSucceeds(upd(h.PAX, "trips/f_completed", {
        passengerRating: 5, passengerTags: ["Polite"], passengerFeedback: "",
        ratedAt: serverTimestamp() }));
      await assertSucceeds(upd(h.PAX, "trips/f_completed",
        { passengerConfirmed: true, passengerConfirmedAt: serverTimestamp() }));
      await assertSucceeds(upd(h.PAX, "trips/f_completed", { disputed: true,
        disputedAt: serverTimestamp(), disputeReason: "Passenger did not confirm arrival" }));
    });

    it("FIN-T05 allowed: driver completes a started trip (ride_lifecycle.dart)", () =>
      assertSucceeds(upd(h.DRIVER, "trips/f_started",
        { status: "completed", completedAt: serverTimestamp() })));

    it("FIN-T07 allowed: the 2026-06..08 Driver build's completion write (walletProcessed: false)", () =>
      // driver app c69158e^: ride completion
      assertSucceeds(upd(h.DRIVER, "trips/f_started", {
        status: "completed", completedAt: serverTimestamp(), finalFare: 20.5,
        actualFare: 20.5, actualDistanceKm: 6.2, distanceKm: 6.2,
        passengerConfirmed: false, walletProcessed: false })));

    it("FIN-T08 walletProcessed may only be written as false while unset or false", async () => {
      await assertFails(upd(h.DRIVER, "trips/f_completed", { walletProcessed: false }));
      await assertFails(upd(h.DRIVER, "trips/f_started", { walletProcessed: true }));
      await assertFails(upd(h.DRIVER, "trips/f_started", { walletProcessed: "false" }));
      await assertSucceeds(upd(h.DRIVER, "trips/f_started", { walletProcessed: false }));
      await assertSucceeds(upd(h.DRIVER, "trips/f_started", { walletProcessed: false, rating: 1 }));
      await assertFails(upd(h.DRIVER, "trips/f_started", { walletProcessed: true }));
    });

    it("FIN-T06 allowed: existing cancellation policy before completion", async () => {
      await assertSucceeds(upd(h.PAX, "trips/f_started",
        { status: "cancelledByPassenger", cancelledAt: serverTimestamp() }));
      await h.env().withSecurityRulesDisabled((ctx) =>
        setDoc(doc(ctx.firestore(), "trips/f_started"), trip({ driverId: h.DRIVER, status: "tripStarted" })));
      await assertSucceeds(upd(h.DRIVER, "trips/f_started",
        { status: "cancelledByDriver", cancelledAt: serverTimestamp() }));
      await assertSucceeds(upd(h.PAX, "trips/searching",
        { status: "noDriversAvailable", expiredAt: serverTimestamp(), expiredBy: "passenger_timeout" }));
    });
  });

  describe("deliveries: status after completion", () => {
    it("FIN-D01 neither party can cancel a completed or flagged delivery", async () => {
      for (const id of ["f_completed", "f_flagged"]) {
        await assertFails(upd(h.PAX, `deliveries/${id}`,
          { status: "cancelled", cancelledAt: serverTimestamp(), cancelReason: "x" }));
        await assertFails(upd(DEL, `deliveries/${id}`, { status: "cancelled",
          statusReason: "cancelledByDriver", cancelledAt: serverTimestamp(),
          cancelReason: "Cancelled by driver" }));
        await assertFails(upd(h.PAX, `deliveries/${id}`, { status: "cancelledByPassenger" }));
      }
      await assertFails(upd(DEL, "deliveries/f_flagged", { status: "completed" }));
    });

    it("FIN-D02 allowed: driver completes at drop-off with the OTP (active_delivery_screen)", () =>
      assertSucceeds(upd(DEL, "deliveries/f_atDropoff", {
        updatedAt: serverTimestamp(), otpSubmitted: "1234", otpVerifiedAt: serverTimestamp(),
        completedAt: serverTimestamp(), actualFare: 20, status: "completed" })));

    it("FIN-D03 allowed: existing cancellations and rating", async () => {
      await assertSucceeds(upd(DEL, "deliveries/f_atDropoff", { status: "cancelled",
        statusReason: "cancelledByDriver", cancelledAt: serverTimestamp(),
        cancelReason: "Cancelled by driver" }));
      await assertSucceeds(upd(h.PAX, "deliveries/f_pending",
        { status: "cancelled", cancelledAt: serverTimestamp(), cancelReason: "x" }));
      await assertSucceeds(upd(h.PAX, "deliveries/f_completed", { passengerRating: 4 }));
    });
  });

  describe("gas orders: status after delivery", () => {
    it("FIN-G01 neither party can cancel a delivered, OTP-pending or flagged order", async () => {
      for (const id of ["f_delivered", "f_pendingOtp", "f_flagged"]) {
        await assertFails(upd(h.PAX, `gas_orders/${id}`,
          { status: "cancelled", cancelledAt: serverTimestamp() }));
        await assertFails(upd(DEL, `gas_orders/${id}`, { status: "cancelled",
          cancelledAt: serverTimestamp(), cancelReason: "Cancelled by driver" }));
      }
    });

    it("FIN-G02 a delivered order cannot be reopened or have its status removed", async () => {
      await assertFails(upd(DEL, "gas_orders/f_delivered", { status: "returning" }));
      await assertFails(upd(DEL, "gas_orders/f_delivered", { status: "pendingOtp" }));
      await assertFails(upd(h.PAX, "gas_orders/f_delivered", { status: deleteField() }));
      await assertFails(upd(DEL, "gas_orders/f_flagged", { status: "delivered" }));
    });

    it("FIN-G03 allowed: OTP resubmission pendingOtp → delivered", () =>
      assertSucceeds(upd(DEL, "gas_orders/f_pendingOtp", {
        updatedAt: serverTimestamp(), otpSubmitted: "4321", otpVerifiedAt: serverTimestamp(),
        deliveredAt: serverTimestamp(), actualFare: 90, status: "delivered" })));

    it("FIN-G04 pendingOtp cannot move anywhere else", async () => {
      await assertFails(upd(DEL, "gas_orders/f_pendingOtp", { status: "returning" }));
      await assertFails(upd(h.PAX, "gas_orders/f_pendingOtp", { status: "failed" }));
    });

    it("FIN-G05 allowed: driver hands over with the OTP (active_gas_order_screen)", async () => {
      for (const id of ["f_returning", "f_arrived"]) {
        await assertSucceeds(upd(DEL, `gas_orders/${id}`, {
          updatedAt: serverTimestamp(), otpSubmitted: "4321", otpVerifiedAt: serverTimestamp(),
          deliveredAt: serverTimestamp(), actualFare: 90, status: "delivered" }));
      }
    });

    it("FIN-G06 allowed: existing cancellations and rating", async () => {
      await assertSucceeds(upd(DEL, "gas_orders/f_returning", { status: "cancelled",
        cancelledAt: serverTimestamp(), cancelReason: "Cancelled by driver" }));
      // gas_order_repository.dart cancel (transaction, pendingApproval only)
      const db = h.db(h.PAX);
      await assertSucceeds(runTransaction(db, async (tx) => {
        const r = doc(db, "gas_orders/f_pending");
        await tx.get(r);
        tx.update(r, { status: "cancelled", cancelledAt: serverTimestamp() });
      }));
      await assertSucceeds(upd(h.PAX, "gas_orders/f_delivered", { passengerRating: 5 }));
    });
  });

  // ── Client-controlled refund / settlement flags ─────────────────────────
  const COLLECTIONS = [
    { name: "trips", active: "trips/f_started", done: "trips/f_completed",
      refunded: "trips/f_refunded", driver: h.DRIVER,
      create: () => h.newTripPayload(),
      permitted: { passengerRating: 5 },
      driverStep: { path: "trips/f_started", data: { status: "completed", completedAt: serverTimestamp() } } },
    { name: "deliveries", active: "deliveries/f_atDropoff", done: "deliveries/f_completed",
      refunded: "deliveries/f_refunded", driver: DEL,
      create: () => create101({ ...delivery({ deliveryQuoteId: "q-1" }), createdAt: serverTimestamp() }),
      permitted: { passengerRating: 4 },
      driverStep: { path: "deliveries/f_atDropoff", data: { status: "completed",
        otpSubmitted: "1234", completedAt: serverTimestamp(), actualFare: 20 } } },
    { name: "gas_orders", active: "gas_orders/f_returning", done: "gas_orders/f_delivered",
      refunded: "gas_orders/f_refunded", driver: DEL,
      create: () => create101({ ...gas({ quantity: 1, deliveryFee: 12 }), createdAt: serverTimestamp() }),
      permitted: { passengerRating: 5 },
      driverStep: { path: "gas_orders/f_returning", data: { status: "delivered",
        otpSubmitted: "4321", deliveredAt: serverTimestamp(), actualFare: 90 } } },
  ];

  for (const c of COLLECTIONS) {
    describe(`${c.name}: server-owned fields`, () => {
      it(`SRV-${c.name}-01 passenger cannot create an order carrying any of them`, async () => {
        for (const [k, v] of Object.entries(SERVER_FIELDS)) {
          await assertFails(setDoc(ref(h.PAX, `${c.name}/new_${k}`), { ...c.create(), [k]: v }));
        }
        await assertSucceeds(setDoc(ref(h.PAX, `${c.name}/new_clean`), c.create()));
      });

      it(`SRV-${c.name}-02 neither party can set any of them on an active order`, async () => {
        for (const uid of [h.PAX, c.driver]) {
          for (const [k, v] of Object.entries(SERVER_FIELDS)) {
            await assertFails(upd(uid, c.active, { [k]: v }), `${uid} ${k}`);
          }
        }
      });

      it(`SRV-${c.name}-03 not even combined with an otherwise permitted update`, async () => {
        await assertFails(upd(h.PAX, c.done, { ...c.permitted, escrowRefunded: true }));
        await assertFails(upd(h.PAX, c.done, { ...c.permitted, settlementStatus: "failed" }));
        await assertSucceeds(upd(h.PAX, c.done, c.permitted));
      });

      it(`SRV-${c.name}-04 not combined with the driver's own completion step`, async () => {
        await assertFails(upd(c.driver, c.driverStep.path, { ...c.driverStep.data, walletProcessed: true }));
        await assertFails(upd(c.driver, c.driverStep.path, { ...c.driverStep.data, escrowRefunded: false }));
        await assertSucceeds(upd(c.driver, c.driverStep.path, c.driverStep.data));
      });

      it(`SRV-${c.name}-05 a party cannot clear or flip an existing server flag`, async () => {
        await assertFails(upd(h.PAX, c.refunded, { escrowRefunded: false }));
        await assertFails(upd(h.PAX, c.refunded, { escrowRefunded: deleteField() }));
        await assertFails(upd(h.PAX, c.done, { walletProcessed: deleteField(), settlementStatus: deleteField() }));
        await assertFails(upd(c.driver, c.done, { walletProcessed: false, settlementStatus: null }));
      });

      it(`SRV-${c.name}-06 an admin (admin panel, signed in) can still write them`, async () => {
        await assertSucceeds(upd(h.ADMIN, c.active, { flagReason: "manual review", flaggedAt: serverTimestamp() }));
        await assertSucceeds(upd(h.ADMIN, c.done, { settlementStatus: deleteField() }));
      });
    });
  }
});
