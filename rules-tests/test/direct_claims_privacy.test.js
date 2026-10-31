// Direct claims (Driver builds before the acceptance callables) take only a
// cash job or a wallet job whose hold is in place — the customer's HELD hold,
// linked to exactly that job — and never the driver's own booking. Gas orders
// have no direct claim at all. Order details moved to {order}/private/* by
// the create triggers are readable by no client (Cloud Functions copy them to
// the assigned driver). Firestore emulator only.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  collection, doc, getDoc, getDocs, setDoc, updateDoc, query, where, serverTimestamp, Timestamp,
} = require("firebase/firestore");
const h = require("./helpers");

const TAXI = "dcpTaxi";
const BIKE = "dcpBike";
const active = { isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true, location: h.ACCRA };
const DRIVERS = {
  [TAXI]: { uid: TAXI, role: "driver_hailing", serviceType: "taxi", vehicleType: "taxi", ...active },
  [BIKE]: { uid: BIKE, role: "driver_delivery", serviceType: "delivery", vehicleType: "motorcycle", ...active },
};

const trip = (o = {}) => ({ ...h.newTripPayload({ serviceType: "taxi", ...o }), createdAt: Timestamp.now() });
const delivery = (o = {}) => ({ passengerId: h.PAX, driverId: null, status: "pending", vehicleType: "Okada",
  weightTier: "Small", paymentMethod: "cash", estimatedFare: 30, pickupLocation: h.ACCRA,
  dropoffLocation: h.ACCRA, pickupAddress: "A", dropoffAddress: "B", createdAt: Timestamp.now(), ...o });
const gasOrder = (o = {}) => ({ passengerId: h.PAX, driverId: null, status: "pendingApproval",
  paymentMethod: "cash", totalPrice: 100, deliveryLocation: h.ACCRA, createdAt: Timestamp.now(), ...o });
const hold = (o = {}) => ({ userId: h.PAX, amount: 30, status: "HELD", referenceId: null,
  referenceType: "trip", ...o });

const claimTrip = (uid, id) => updateDoc(doc(h.db(uid), `trips/${id}`), {
  driverId: uid, driverName: "D", driverPhone: "+233200000000", driverRating: 5, driverPlate: "GR-1",
  status: "tripAccepted", acceptedAt: serverTimestamp() });
const claimDelivery = (uid, id) => updateDoc(doc(h.db(uid), `deliveries/${id}`), {
  driverId: uid, driverName: "D", driverPhone: "+233200000000", driverRating: 5,
  status: "driverAssigned", acceptedAt: serverTimestamp() });

async function seed(docs) {
  await h.seed();
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    for (const [id, d] of Object.entries(DRIVERS)) await setDoc(doc(fs, `drivers/${id}`), d);
    for (const [path, d] of Object.entries(docs)) await setDoc(doc(fs, path), d);
  });
}

describe("direct claims and private order details", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(() => h.env().clearFirestore());

  describe("rides", () => {
    it("DCP-01 a cash ride is claimed as before", async () => {
      await seed({ "trips/t1": trip({ paymentMethod: "cash" }) });
      await assertSucceeds(claimTrip(TAXI, "t1"));
    });

    it("DCP-02 a ride without a payment method (dispatched as cash) is claimed as before", async () => {
      const t = trip(); delete t.paymentMethod;
      await seed({ "trips/t1": t });
      await assertSucceeds(claimTrip(TAXI, "t1"));
    });

    for (const [id, label, escrow, tripFields] of [
      ["DCP-03", "no hold at all", null, {}],
      ["DCP-04", "a hold not yet linked to it", hold(), { escrowId: "e1" }],
      ["DCP-05", "a hold linked to another ride", hold({ referenceId: "other" }), { escrowId: "e1" }],
      ["DCP-06", "a refunded hold", hold({ referenceId: "t1", status: "REFUNDED" }), { escrowId: "e1" }],
      ["DCP-07", "another customer's hold", hold({ referenceId: "t1", userId: h.STRANGER }), { escrowId: "e1" }],
      ["DCP-08", "a hold for another service", hold({ referenceId: "t1", referenceType: "delivery" }), { escrowId: "e1" }],
      ["DCP-09", "an escrowId naming no hold", null, { escrowId: "missing" }],
    ]) {
      it(`${id} a wallet ride with ${label} cannot be claimed directly`, async () => {
        await seed({ "trips/t1": trip({ paymentMethod: "wallet", ...tripFields }),
          ...(escrow ? { "escrows/e1": escrow } : {}) });
        await assertFails(claimTrip(TAXI, "t1"));
      });
    }

    it("DCP-10 a wallet ride whose HELD hold is linked to it is claimed", async () => {
      await seed({ "trips/t1": trip({ paymentMethod: "wallet", escrowId: "e1" }),
        "escrows/e1": hold({ referenceId: "t1" }) });
      await assertSucceeds(claimTrip(TAXI, "t1"));
    });

    it("DCP-11 a driver cannot claim their own ride", async () => {
      await seed({ "trips/t1": trip({ paymentMethod: "cash", passengerId: TAXI }) });
      await assertFails(claimTrip(TAXI, "t1"));
    });
  });

  describe("deliveries", () => {
    it("DCP-20 a cash delivery is claimed as before", async () => {
      await seed({ "deliveries/d1": delivery() });
      await assertSucceeds(claimDelivery(BIKE, "d1"));
    });

    it("DCP-21 an unpaid wallet delivery cannot be claimed directly", async () => {
      await seed({ "deliveries/d1": delivery({ paymentMethod: "wallet" }) });
      await assertFails(claimDelivery(BIKE, "d1"));
    });

    it("DCP-22 a wallet delivery whose hold is linked elsewhere cannot be claimed", async () => {
      await seed({ "deliveries/d1": delivery({ paymentMethod: "wallet", escrowId: "e1" }),
        "escrows/e1": hold({ referenceId: "d2", referenceType: "delivery" }) });
      await assertFails(claimDelivery(BIKE, "d1"));
    });

    it("DCP-23 a paid wallet delivery is claimed", async () => {
      await seed({ "deliveries/d1": delivery({ paymentMethod: "wallet", escrowId: "e1" }),
        "escrows/e1": hold({ referenceId: "d1", referenceType: "delivery" }) });
      await assertSucceeds(claimDelivery(BIKE, "d1"));
    });

    it("DCP-24 a driver cannot claim their own delivery", async () => {
      await seed({ "deliveries/d1": delivery({ passengerId: BIKE }) });
      await assertFails(claimDelivery(BIKE, "d1"));
    });

    it("DCP-25 the released open-delivery list query is refused (release v5: drivers read delivery_offers)", async () => {
      await seed({ "deliveries/d1": delivery(), "deliveries/d2": delivery({ paymentMethod: "wallet" }) });
      await assertFails(getDocs(query(collection(h.db(BIKE), "deliveries"),
        where("status", "==", "pending"), where("driverId", "==", null))));
    });
  });

  // Rules first (deployment step 0), with today's functions still live: the
  // released apps' wallet flows keep working. Linking is a server write
  // (Admin SDK) of referenceId/referenceType on the hold — what both the live
  // and the new attachEscrowToOrder do — modelled here with rules disabled.
  describe("released-app wallet flows under these rules, before or after the new functions", () => {
    const link = (escrowId, referenceId, referenceType) => h.env().withSecurityRulesDisabled((ctx) =>
      updateDoc(doc(ctx.firestore(), `escrows/${escrowId}`), { referenceId, referenceType }));

    it("DCP-50 ride: the passenger books with its hold; claim refused until linked, then allowed", async () => {
      await seed({ "escrows/e1": hold() });
      await assertSucceeds(setDoc(doc(h.db(h.PAX), "trips/t1"),
        h.newTripPayload({ serviceType: "taxi", paymentMethod: "wallet", escrowId: "e1" })));
      await assertFails(claimTrip(TAXI, "t1"));
      await link("e1", "t1", "trip");
      await assertSucceeds(claimTrip(TAXI, "t1"));
    });

    it("DCP-51 delivery: created, linked, escrowId recorded by the passenger; claimable only then", async () => {
      await seed({ "deliveries/d1": delivery({ paymentMethod: "wallet" }),
        "escrows/e1": hold({ referenceType: "delivery" }) });
      await assertFails(claimDelivery(BIKE, "d1"));
      await link("e1", "d1", "delivery");
      await assertFails(claimDelivery(BIKE, "d1"), "linked but not yet named by the order");
      await assertSucceeds(updateDoc(doc(h.db(h.PAX), "deliveries/d1"), { escrowId: "e1" }));
      await assertSucceeds(claimDelivery(BIKE, "d1"));
    });

    it("DCP-52 a passenger cannot name someone else's hold, or one linked elsewhere, to make a job claimable", async () => {
      await seed({ "deliveries/d1": delivery({ paymentMethod: "wallet" }),
        "escrows/e-other": hold({ userId: h.STRANGER, referenceId: "d1", referenceType: "delivery" }),
        "escrows/e-elsewhere": hold({ referenceId: "d9", referenceType: "delivery" }) });
      await assertFails(updateDoc(doc(h.db(h.PAX), "deliveries/d1"), { escrowId: "e-other" }));
      await assertFails(updateDoc(doc(h.db(h.PAX), "deliveries/d1"), { escrowId: "e-elsewhere" }));
      await assertFails(claimDelivery(BIKE, "d1"));
    });
  });

  describe("gas orders", () => {
    it("DCP-30 a Gas order cannot be claimed directly, cash or paid (acceptGasOrder only)", async () => {
      await seed({ "gas_orders/g1": gasOrder(), "gas_orders/g2": gasOrder({ paymentMethod: "wallet", escrowId: "e1" }),
        "escrows/e1": hold({ referenceId: "g2", referenceType: "gas_order" }) });
      for (const id of ["g1", "g2"]) {
        await assertFails(updateDoc(doc(h.db(BIKE), `gas_orders/${id}`),
          { driverId: BIKE, status: "driverAssigned" }));
      }
    });
  });

  describe("private order details", () => {
    const privateDocs = {
      "deliveries/d1": delivery({ driverId: BIKE, status: "driverAssigned" }),
      "deliveries/d1/private/details": { receiverName: "R", receiverPhone: "+233200000001" },
      "deliveries/d2": delivery(),
      "deliveries/d2/private/details": { receiverName: "R", receiverPhone: "+233200000001" },
      "gas_orders/g1": gasOrder(),
      "gas_orders/g1/private/details": { deliveryInstructions: "Gate code 1234" },
    };

    it("DCP-40 no client reads private details: unassigned driver, assigned driver, customer, stranger", async () => {
      await seed(privateDocs);
      for (const uid of [BIKE, TAXI, h.PAX, h.STRANGER, null]) {
        for (const path of ["deliveries/d1/private/details", "deliveries/d2/private/details",
          "gas_orders/g1/private/details"]) {
          await assertFails(getDoc(doc(h.db(uid), path)));
        }
      }
    });

    it("DCP-41 no client writes private details", async () => {
      await seed(privateDocs);
      for (const uid of [BIKE, h.PAX]) {
        await assertFails(setDoc(doc(h.db(uid), "deliveries/d2/private/details"), { receiverName: "x" }));
        await assertFails(setDoc(doc(h.db(uid), "gas_orders/g1/private/details"), { deliveryInstructions: "x" }));
      }
    });

    it("DCP-42 details copied onto an assigned order are readable only by its parties", async () => {
      await seed(privateDocs);
      await assertSucceeds(getDoc(doc(h.db(BIKE), "deliveries/d1")));
      await assertSucceeds(getDoc(doc(h.db(h.PAX), "deliveries/d1")));
      await assertFails(getDoc(doc(h.db(h.STRANGER), "deliveries/d1")));
    });
  });
});
