// Driver job state (drivers.currentTripId) and the legacy client claim
// switch (app_config/dispatch.legacyClientClaims).
//
// currentTripId is server-owned: the acceptance callables set it and the
// status triggers clear it. Installed Driver builds still claim with a
// client transaction, then mark themselves busy in a separate write, and
// free themselves when they cancel; those writes stay allowed only while
// they are true. Once the switch is closed, no client claims a ride or
// delivery or writes currentTripId at all.

const assert = require("node:assert/strict");
const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  doc, getDoc, setDoc, updateDoc, runTransaction, deleteField, serverTimestamp, Timestamp,
} = require("firebase/firestore");
const h = require("./helpers");

const rideDriver = (uid, o = {}) => ({
  uid, role: "driver_hailing", serviceType: "taxi", vehicleType: "taxi",
  isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true,
  location: h.ACCRA, ...o,
});
const goodsDriver = (uid, o = {}) => ({
  uid, role: "driver_delivery", serviceType: "delivery", vehicleType: "motorcycle",
  isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true,
  location: h.ACCRA, ...o,
});

// Cash: a direct claim of a wallet ride needs its linked hold (direct_claims_privacy.test.js).
const trip = (o = {}) => { const t = h.newTripPayload({ paymentMethod: "cash", ...o }); t.createdAt = Timestamp.now(); return t; };
const delivery = (o = {}) => ({
  passengerId: h.PAX, driverId: null, status: "pending", vehicleType: "Okada",
  weightTier: "Small", paymentMethod: "cash", pickupLocation: h.ACCRA,
  estimatedFare: 30, createdAt: Timestamp.now(), ...o,
});

async function seed() {
  await h.seed();
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    await setDoc(doc(fs, "drivers/taxiA"), rideDriver("taxiA"));
    await setDoc(doc(fs, "drivers/taxiB"), rideDriver("taxiB"));
    await setDoc(doc(fs, "drivers/onTrip"), rideDriver("onTrip",
      { isAvailable: false, currentTripId: "mine" }));
    await setDoc(doc(fs, "drivers/bike"), goodsDriver("bike"));
    await setDoc(doc(fs, "trips/open1"), trip({ serviceType: "taxi" }));
    await setDoc(doc(fs, "trips/open2"), trip({ serviceType: "taxi" }));
    await setDoc(doc(fs, "trips/mine"), trip({ serviceType: "taxi", driverId: "onTrip",
      status: "tripStarted" }));
    await setDoc(doc(fs, "trips/someoneElses"), trip({ serviceType: "taxi", driverId: "taxiB",
      status: "tripAccepted" }));
    await setDoc(doc(fs, "trips/mineDone"), trip({ serviceType: "taxi", driverId: "onTrip",
      status: "completed" }));
    await setDoc(doc(fs, "deliveries/dOpen"), delivery());
  });
}

const driverRef = (uid) => doc(h.db(uid), `drivers/${uid}`);
const setSwitch = (open) => h.env().withSecurityRulesDisabled((ctx) =>
  setDoc(doc(ctx.firestore(), "app_config/dispatch"), { legacyClientClaims: open }));
const asAdmin = (fn) => h.env().withSecurityRulesDisabled((ctx) => fn(ctx.firestore()));
/** A document as stored, read with rules disabled. */
async function stored(path) {
  let snap;
  await h.env().withSecurityRulesDisabled(async (ctx) => { snap = await getDoc(doc(ctx.firestore(), path)); });
  return snap;
}

// Installed builds (1.0.2+32 and earlier): claim transaction, then a
// separate busy write.
async function legacyRideClaim(uid, id) {
  const db = h.db(uid);
  await runTransaction(db, async (tx) => {
    const ref = doc(db, `trips/${id}`);
    await tx.get(ref);
    tx.update(ref, { driverId: uid, driverName: uid, driverPhone: "", driverRating: 5,
      driverPlate: "", status: "tripAccepted", acceptedAt: serverTimestamp() });
  });
  await updateDoc(driverRef(uid), { isAvailable: false, currentTripId: id });
}

// The working-tree build before the callables: claim and busy in one transaction.
function atomicRideClaim(uid, id) {
  const db = h.db(uid);
  return runTransaction(db, async (tx) => {
    const ref = doc(db, `trips/${id}`);
    const me = doc(db, `drivers/${uid}`);
    await tx.get(ref);
    await tx.get(me);
    tx.update(ref, { driverId: uid, driverName: uid, driverPhone: "", driverRating: 5,
      driverPlate: "", status: "tripAccepted", acceptedAt: serverTimestamp() });
    tx.update(me, { isAvailable: false, currentTripId: id });
  });
}

describe("driver job state", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(seed);

  describe("while installed builds are supported (switch open or absent)", () => {
    it("JOB-P01 installed build: claim, then mark busy in a separate write", () =>
      assertSucceeds(legacyRideClaim("taxiA", "open1")));

    it("JOB-P02 claim and busy in one transaction", () =>
      assertSucceeds(atomicRideClaim("taxiA", "open1")));

    it("JOB-P03 cleared once the job has ended", () =>
      assertSucceeds(asAdmin((fs) => updateDoc(doc(fs, "drivers/onTrip"), { currentTripId: "mineDone" }))
        .then(() => updateDoc(driverRef("onTrip"), { isAvailable: true, currentTripId: deleteField() }))));

    it("JOB-P04 driver cancels and frees themselves in one transaction", () =>
      assertSucceeds((() => {
        const db = h.db("onTrip");
        const tripRef = doc(db, "trips/mine");
        const me = doc(db, "drivers/onTrip");
        return runTransaction(db, async (tx) => {
          await tx.get(tripRef);
          await tx.get(me);
          tx.update(tripRef, { status: "cancelledByDriver", cancelledAt: serverTimestamp() });
          tx.update(me, { isAvailable: true, currentTripId: deleteField() });
        });
      })()));

    it("JOB-P05 going online while on a job keeps the job", async () => {
      await assertSucceeds(updateDoc(driverRef("onTrip"), {
        isOnline: true, isAvailable: true, lastStatusChange: serverTimestamp() }));
      assert.equal((await stored("drivers/onTrip")).data().currentTripId, "mine");
    });

    it("JOB-S01 a driver cannot clear a job that is still open (self-release)", () =>
      assertFails(updateDoc(driverRef("onTrip"), { isAvailable: true, currentTripId: deleteField() })));

    it("JOB-S02 ... nor by writing null", () =>
      assertFails(updateDoc(driverRef("onTrip"), { currentTripId: null })));

    it("JOB-S03 a driver cannot point at a request they have not claimed", () =>
      assertFails(updateDoc(driverRef("taxiA"), { isAvailable: false, currentTripId: "open1" })));

    it("JOB-S04 ... nor at another driver's job", () =>
      assertFails(updateDoc(driverRef("taxiA"), { currentTripId: "someoneElses" })));

    it("JOB-S05 ... nor at an id that is no job", () =>
      assertFails(updateDoc(driverRef("taxiA"), { currentTripId: "nothing" })));

    it("JOB-S06 a driver cannot switch from one job to another", () =>
      assertFails(updateDoc(driverRef("onTrip"), { currentTripId: "mineDone" })));

    it("JOB-S07 a busy driver who went online again cannot claim another ride", async () => {
      await updateDoc(driverRef("onTrip"), { isOnline: true, isAvailable: true });
      await assertFails(atomicRideClaim("onTrip", "open1"));
    });

    it("JOB-S08 one driver, two claims at once: the second is refused", async () => {
      const results = await Promise.allSettled([
        atomicRideClaim("taxiA", "open1"), atomicRideClaim("taxiA", "open2")]);
      assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
      const d = await stored("drivers/taxiA");
      const t1 = await stored("trips/open1");
      const t2 = await stored("trips/open2");
      const mine = [t1, t2].filter((t) => t.data().driverId === "taxiA").map((t) => t.id);
      assert.deepEqual(mine, [d.data().currentTripId]);
    });

    it("JOB-S09 the switch is unreadable and unwritable for drivers and passengers", async () => {
      await setSwitch(true);
      await assertFails(getDoc(doc(h.db("taxiA"), "app_config/dispatch")));
      await assertFails(setDoc(doc(h.db("taxiA"), "app_config/dispatch"), { legacyClientClaims: true }));
      await assertFails(setDoc(doc(h.db(h.PAX), "app_config/dispatch"), { legacyClientClaims: true }));
      await assertSucceeds(setDoc(doc(h.db(h.ADMIN), "app_config/dispatch"), { legacyClientClaims: false }));
    });
  });

  describe("once installed builds are retired (switch closed)", () => {
    beforeEach(() => setSwitch(false));

    it("JOB-C01 client ride claims are refused (acceptRide only)", () =>
      assertFails(atomicRideClaim("taxiA", "open1")));

    it("JOB-C02 client delivery claims are refused (acceptDelivery only)", () =>
      assertFails(updateDoc(doc(h.db("bike"), "deliveries/dOpen"), {
        driverId: "bike", driverName: "bike", driverPhone: "", driverRating: 5,
        status: "driverAssigned", acceptedAt: serverTimestamp() })));

    it("JOB-C03 a driver cannot write currentTripId at all, even truthfully", async () => {
      await asAdmin((fs) => updateDoc(doc(fs, "drivers/onTrip"), { currentTripId: "mineDone" }));
      await assertFails(updateDoc(driverRef("onTrip"), { currentTripId: deleteField() }));
    });

    it("JOB-C04 going online and other profile writes still work", () =>
      assertSucceeds(updateDoc(driverRef("onTrip"), {
        isOnline: true, isAvailable: true, location: h.ACCRA, currentLocation: h.ACCRA,
        lastLocationUpdate: serverTimestamp() })));

    it("JOB-C05 the driver can still move their own job through its steps", () =>
      assertSucceeds(updateDoc(doc(h.db("onTrip"), "trips/mine"), { status: "completed",
        completedAt: serverTimestamp() })));
  });
});

