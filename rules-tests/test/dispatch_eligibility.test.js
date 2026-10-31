// Dispatch eligibility on direct claims (functions/dispatch_policy.js is the
// reference; firestore.rules rideClaimEligible / deliveryClaimEligible).
//
// Rides: the driver's vehicle must match the ride service (Okada a
// motorcycle, Taxi a taxi, Pragyia a pragyia), as well as its serviceType.
// Deliveries: an active, online, available Delivery driver with the vehicle
// the passenger booked, for a weight tier that vehicle carries (Okada Small,
// Aboboya Medium/Large, Mini Truck Bulk). Gas is never assigned by a client.
// Fixture values mirror what the Driver App's vehicle setup writes
// (driver_vehicle_setup_screen.dart) and older spellings still stored.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, setDoc, updateDoc, runTransaction, serverTimestamp, Timestamp } =
  require("firebase/firestore");
const assert = require("node:assert/strict");
const h = require("./helpers");

const active = { isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true,
  location: h.ACCRA };
const ride = (uid, serviceType, vehicleType, o = {}) =>
  ({ uid, role: "driver_hailing", serviceType, vehicleType, ...active, ...o });
const goods = (uid, vehicleType, o = {}) =>
  ({ uid, role: "driver_delivery", serviceType: "delivery", vehicleType, ...active, ...o });

const DRIVERS = {
  okadaRider: ride("okadaRider", "okada", "motorcycle"),
  okadaLegacy: ride("okadaLegacy", "okada", "motorbike"),
  taxiDriver: ride("taxiDriver", "taxi", "taxi"),
  pragyiaDriver: ride("pragyiaDriver", "pragyia", "pragyia"),
  // An older build mapped Pragyia to the Taxi service.
  pragyiaAsTaxi: ride("pragyiaAsTaxi", "taxi", "pragyia"),
  noVehicle: ride("noVehicle", "taxi", null),
  bike: goods("bike", "motorcycle"),
  bikeLegacy: goods("bikeLegacy", "motorbike"),
  trike: goods("trike", "tricycle"),
  trikeLegacy: goods("trikeLegacy", "aboboyaa"),
  truck: goods("truck", "miniTruck"),
  truckLegacy: goods("truckLegacy", "mini_truck"),
  truckOffline: goods("truckOffline", "miniTruck", { isOnline: false }),
  truckBusy: goods("truckBusy", "miniTruck", { isAvailable: false }),
  truckSuspended: goods("truckSuspended", "miniTruck", { signupStep: "suspended" }),
  truckUnapproved: goods("truckUnapproved", "miniTruck", { isApproved: false, signupStep: "documentsUploaded" }),
  rideBike: ride("rideBike", "okada", "motorcycle"), // a Ride driver with a delivery-capable vehicle
  // Went offline and online during a job: available again, job still set.
  truckOnJob: goods("truckOnJob", "miniTruck", { currentTripId: "activeOrder" }),
  truck2: goods("truck2", "miniTruck"),
  truck3: goods("truck3", "miniTruck"),
  taxi2: ride("taxi2", "taxi", "taxi"),
};

const trip = (serviceType) => {
  const t = h.newTripPayload({ serviceType, paymentMethod: "cash" }); // see direct_claims_privacy
  t.createdAt = Timestamp.now();
  return t;
};
const delivery = (vehicleType, weightTier) => ({
  passengerId: h.PAX, driverId: null, status: "pending", vehicleType, weightTier,
  pickupLocation: h.ACCRA, dropoffLocation: h.ACCRA, estimatedFare: 30, paymentMethod: "cash",
  createdAt: Timestamp.now(),
});

const DELIVERIES = {
  okadaSmall: delivery("Okada", "Small"),
  okadaMedium: delivery("Okada", "Medium"), // offered by older Passenger builds
  aboboyaMedium: delivery("Aboboya", "Medium"),
  aboboyaLarge: delivery("Aboboya", "Large"),
  truckBulk: delivery("Mini Truck", "Bulk"),
  truckBulk2: delivery("Mini Truck", "Bulk"),
  truckSmall: delivery("Mini Truck", "Small"),
};

async function seed() {
  await h.seed();
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    for (const [id, d] of Object.entries(DRIVERS)) await setDoc(doc(fs, `drivers/${id}`), d);
    for (const s of ["okada", "taxi", "pragyia"]) await setDoc(doc(fs, `trips/${s}Trip`), trip(s));
    await setDoc(doc(fs, "trips/taxiTrip2"), trip("taxi"));
    for (const [id, d] of Object.entries(DELIVERIES)) await setDoc(doc(fs, `deliveries/${id}`), d);
    await setDoc(doc(fs, "gas_orders/gas1"), {
      passengerId: h.PAX, driverId: null, status: "pendingApproval", refillType: "newCylinder",
      deliveryLocation: h.ACCRA, pickupLocation: h.ACCRA, createdAt: Timestamp.now(),
    });
  });
}

// requests_section.dart: the ride and delivery claim transactions.
function claimTrip(uid, id) {
  const db = h.db(uid);
  const ref = doc(db, `trips/${id}`);
  return runTransaction(db, async (tx) => {
    const snap = await tx.get(ref);
    if (snap.data().status !== "searching" || snap.data().driverId != null) throw new Error("taken");
    tx.update(ref, { driverId: uid, driverName: "D", driverPhone: "", driverRating: 5,
      driverPlate: "", status: "tripAccepted", acceptedAt: serverTimestamp() });
  });
}

// Deliveries: the claim write of requests_section.dart without its read.
// Open deliveries are no longer readable by unassigned drivers (release v5:
// they browse delivery_offers and accept through acceptDelivery), so the
// released read-first transaction is refused at its read (DSP-S30); the
// claim rule itself still governs a write sent without reading, and these
// tests keep checking it.
function claimDelivery(uid, id) {
  return updateDoc(doc(h.db(uid), `deliveries/${id}`), {
    driverId: uid, driverName: "D", driverPhone: "", driverRating: 5,
    status: "driverAssigned", acceptedAt: serverTimestamp() });
}

// The released read-first delivery claim transaction.
function claimDeliveryReadFirst(uid, id) {
  const db = h.db(uid);
  const ref = doc(db, `deliveries/${id}`);
  return runTransaction(db, async (tx) => {
    const snap = await tx.get(ref);
    if (snap.data().status !== "pending" || snap.data().driverId != null) throw new Error("taken");
    tx.update(ref, { driverId: uid, driverName: "D", driverPhone: "", driverRating: 5,
      status: "driverAssigned", acceptedAt: serverTimestamp() });
  });
}

// The current Driver App claim: the order and the driver's busy flags in one
// transaction (requests_section.dart), so two claims cannot both commit.
// A delivery is not read first (see claimDelivery).
function claimAtomic(uid, coll, id) {
  const db = h.db(uid);
  const ref = doc(db, `${coll}/${id}`);
  const me = doc(db, `drivers/${uid}`);
  const ride = coll === "trips";
  return runTransaction(db, async (tx) => {
    const snap = ride ? await tx.get(ref) : null;
    const mine = await tx.get(me);
    if ((snap && snap.data().driverId != null) || mine.data().currentTripId != null) throw new Error("busy or taken");
    tx.update(ref, { driverId: uid, driverName: "D", driverPhone: "", driverRating: 5,
      ...(ride ? { driverPlate: "", status: "tripAccepted" } : { status: "driverAssigned" }),
      acceptedAt: serverTimestamp() });
    tx.update(me, { isAvailable: false, currentTripId: id });
  });
}

describe("dispatch eligibility on claims", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(seed);

  describe("rides: service and vehicle", () => {
    it("DSP-P01 each ride service is claimed by its own vehicle (and older spellings)", async () => {
      await assertSucceeds(claimTrip("okadaRider", "okadaTrip"));
      await assertSucceeds(claimTrip("taxiDriver", "taxiTrip"));
      await assertSucceeds(claimTrip("pragyiaDriver", "pragyiaTrip"));
    });

    it("DSP-P02 an Okada driver stored as 'motorbike' still claims Okada rides", () =>
      assertSucceeds(claimTrip("okadaLegacy", "okadaTrip")));

    it("DSP-S01 a driver cannot claim another service's ride", async () => {
      await assertFails(claimTrip("okadaRider", "taxiTrip"));
      await assertFails(claimTrip("taxiDriver", "pragyiaTrip"));
      await assertFails(claimTrip("pragyiaDriver", "okadaTrip"));
    });

    it("DSP-S02 a Pragyia vehicle registered as Taxi, or no vehicle, cannot claim a Taxi ride", async () => {
      await assertFails(claimTrip("pragyiaAsTaxi", "taxiTrip"));
      await assertFails(claimTrip("noVehicle", "taxiTrip"));
    });

    it("DSP-S03 Delivery drivers never claim rides, whatever their vehicle", async () => {
      await assertFails(claimTrip("bike", "okadaTrip"));
      await assertFails(claimTrip("truck", "taxiTrip"));
    });
  });

  describe("deliveries: booked vehicle and weight tier", () => {
    it("DSP-P10 each booked vehicle is claimed by that vehicle for its tiers", async () => {
      await assertSucceeds(claimDelivery("bike", "okadaSmall"));
      await assertSucceeds(claimDelivery("trike", "aboboyaMedium"));
      await assertSucceeds(claimDelivery("trikeLegacy", "aboboyaLarge"));
      await assertSucceeds(claimDelivery("truck", "truckBulk"));
    });

    it("DSP-P11 older vehicle spellings still claim", async () => {
      await assertSucceeds(claimDelivery("bikeLegacy", "okadaSmall"));
      await assertSucceeds(claimDelivery("truckLegacy", "truckBulk"));
    });

    it("DSP-S10 a different vehicle cannot claim the booked one's delivery", async () => {
      await assertFails(claimDelivery("trike", "okadaSmall"));
      await assertFails(claimDelivery("truck", "okadaSmall"));
      await assertFails(claimDelivery("bike", "aboboyaMedium"));
      await assertFails(claimDelivery("truck", "aboboyaLarge"));
      await assertFails(claimDelivery("trike", "truckBulk"));
    });

    it("DSP-S11 a vehicle/tier pair beyond the vehicle's capacity is claimable by nobody", async () => {
      for (const d of ["bike", "trike", "truck"]) {
        await assertFails(claimDelivery(d, "okadaMedium"), d);
        await assertFails(claimDelivery(d, "truckSmall"), d);
      }
    });

    it("DSP-S12 a Ride driver with a matching vehicle cannot claim a delivery", () =>
      assertFails(claimDelivery("rideBike", "okadaSmall")));

    it("DSP-S13 offline, busy, suspended or unapproved Delivery drivers cannot claim", async () => {
      for (const d of ["truckOffline", "truckBusy", "truckSuspended", "truckUnapproved"]) {
        await assertFails(claimDelivery(d, "truckBulk"), d);
      }
    });

    it("DSP-S14 a delivery is claimed once: the second eligible driver is refused", async () => {
      await assertSucceeds(claimDelivery("truck", "truckBulk"));
      await assertFails(claimDelivery("truckLegacy", "truckBulk"));
    });

    it("DSP-S30 the released read-first claim transaction is refused: open deliveries are not readable", async () => {
      await assertFails(claimDeliveryReadFirst("truck", "truckBulk"));
      await assertFails(claimDeliveryReadFirst("bike", "okadaSmall"));
    });

    it("DSP-S15 a driver cannot claim by changing their vehicle once approved", async () => {
      await assertFails(updateDoc(doc(h.db("bike"), "drivers/bike"), { vehicleType: "miniTruck" }));
      await assertFails(claimDelivery("bike", "truckBulk"));
    });
  });

  describe("one job at a time", () => {
    it("DSP-S16 a Delivery driver back online mid-job cannot claim another delivery", () =>
      assertFails(claimDelivery("truckOnJob", "truckBulk")));

    it("DSP-P12 the current app's single-transaction claim is allowed (ride and delivery)", async () => {
      await assertSucceeds(claimAtomic("truck", "deliveries", "truckBulk"));
      await assertSucceeds(claimAtomic("taxiDriver", "trips", "taxiTrip"));
    });

    it("DSP-S17 one driver claiming two orders at once with the current app gets one", async () => {
      for (const [uid, coll, a, b] of [["truck", "deliveries", "truckBulk", "truckBulk2"],
        ["taxiDriver", "trips", "taxiTrip", "taxiTrip2"]]) {
        const r = await Promise.allSettled([claimAtomic(uid, coll, a), claimAtomic(uid, coll, b)]);
        assert.equal(r.filter((x) => x.status === "fulfilled").length, 1, uid);
      }
    });

    it("DSP-S18 two drivers claiming one order at once: exactly one wins", async () => {
      const r = await Promise.allSettled([claimAtomic("truck2", "deliveries", "truckBulk"),
        claimAtomic("truck3", "deliveries", "truckBulk")]);
      assert.equal(r.filter((x) => x.status === "fulfilled").length, 1);
    });

    it("DSP-K01 KNOWN, older Driver builds: two claims at once by one driver can both commit", async () => {
      // Released builds mark the driver busy in a separate, later write, so
      // the rules see the driver free for both claims. Recorded for the
      // minimum-version decision; the current app closes it (DSP-S17).
      const r = await Promise.allSettled([claimDelivery("truck", "truckBulk"),
        claimDelivery("truck", "truckBulk2")]);
      assert.equal(r.filter((x) => x.status === "fulfilled").length, 2);
    });
  });

  describe("gas", () => {
    it("DSP-S20 no driver assigns a gas order directly, however eligible", async () => {
      for (const d of ["bike", "trike", "truck"]) {
        await assertFails(updateDoc(doc(h.db(d), "gas_orders/gas1"),
          { driverId: d, status: "driverAssigned" }), d);
      }
    });
  });
});
