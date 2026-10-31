// Ride claim eligibility (F-03 / F-13) and driver_alerts ownership (F-01).
//
// A searching trip may be claimed only by an approved, non-suspended
// ride-hailing driver registered for the trip's service, who is online,
// available and not already on a job. Open requests are readable by ride
// drivers only. Only a trip's own passenger may write its driver_alerts
// document. Field values mirror the production driver schema (role
// driver_hailing / driver_delivery; serviceType okada / taxi / pragyia /
// delivery) and the Driver App's accept transaction (requests_section.dart).

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  collection, doc, getDoc, getDocs, setDoc, updateDoc, deleteDoc, runTransaction,
  query, where, orderBy, limit, serverTimestamp, Timestamp,
} = require("firebase/firestore");
const h = require("./helpers");

// requests_section.dart: the claim transaction.
const acceptPayload = (uid) => ({
  driverId: uid, driverName: `Driver ${uid}`, driverPhone: "+233200000000",
  driverRating: 4.8, driverPlate: "GR-1234-24", status: "tripAccepted",
  acceptedAt: serverTimestamp(),
});

function acceptTx(uid, id) {
  const db = h.db(uid);
  const ref = doc(db, `trips/${id}`);
  return runTransaction(db, async (tx) => {
    const snap = await tx.get(ref);
    if (snap.data().status !== "searching" || snap.data().driverId != null) {
      throw new Error("taken");
    }
    tx.update(ref, acceptPayload(uid));
  });
}

// The production driver schema (verified 2026-10-16, aggregate only).
const rideDriver = (uid, serviceType, o = {}) => ({
  uid, role: "driver_hailing", serviceType,
  vehicleType: { taxi: "taxi", okada: "motorcycle", pragyia: "pragyia" }[serviceType],
  isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true,
  location: h.ACCRA, ...o,
});

const DRIVERS = {
  taxi1: rideDriver("taxi1", "taxi"),
  taxi2: rideDriver("taxi2", "taxi"),
  okada1: rideDriver("okada1", "okada"),
  pragyia1: rideDriver("pragyia1", "pragyia"),
  deliv1: { uid: "deliv1", role: "driver_delivery", serviceType: "delivery", vehicleType: "motorcycle",
    isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true, location: h.ACCRA },
  unapproved: rideDriver("unapproved", "taxi", { isApproved: false, signupStep: "documentsUploaded" }),
  suspendedFlag: rideDriver("suspendedFlag", "taxi", { signupStep: "suspended" }),
  suspendedAdmin: rideDriver("suspendedAdmin", "taxi",
    { isApproved: false, signupStep: "suspended", isOnline: false, isAvailable: false }),
  offline: rideDriver("offline", "taxi", { isOnline: false }),
  busyFlag: rideDriver("busyFlag", "taxi", { isAvailable: false }),
  onJob: rideDriver("onJob", "taxi", { currentTripId: "someOtherTrip" }),
  // Toggling online sets isAvailable: true without clearing currentTripId.
  onJobOnline: rideDriver("onJobOnline", "taxi", { isAvailable: true, currentTripId: "someOtherTrip" }),
  noService: rideDriver("noService", "taxi", { serviceType: null }),
  noRole: (({ role, ...d }) => d)(rideDriver("noRole", "taxi")),
  noOnline: (({ isOnline, ...d }) => d)(rideDriver("noOnline", "taxi")),
  stillTaxiDefault: { uid: "stillTaxiDefault", role: "driver_delivery", serviceType: "taxi",
    isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true },
};

// Cash: a direct claim of a wallet ride needs its linked hold (direct_claims_privacy.test.js).
const trip = (o = {}) => { const t = h.newTripPayload({ paymentMethod: "cash", ...o }); t.createdAt = Timestamp.now(); return t; };

async function seed() {
  await h.seed();
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    for (const [id, d] of Object.entries(DRIVERS)) await setDoc(doc(fs, `drivers/${id}`), d);
    await setDoc(doc(fs, "trips/taxiTrip"), trip({ serviceType: "taxi" }));
    await setDoc(doc(fs, "trips/okadaTrip"), trip({ serviceType: "okada" }));
    await setDoc(doc(fs, "trips/pragyiaTrip"), trip({ serviceType: "pragyia" }));
    await setDoc(doc(fs, "trips/noServiceTrip"), trip({ serviceType: null }));
    await setDoc(doc(fs, "trips/expiredTrip"), trip({ status: "expired" }));
    await setDoc(doc(fs, "trips/timedOutTrip"), trip({ status: "noDriversAvailable" }));
    await setDoc(doc(fs, "trips/cancelledTrip"), trip({ status: "cancelledByPassenger" }));
    await setDoc(doc(fs, "trips/takenTrip"), trip({ status: "searching", driverId: "taxi2" }));
  });
}

describe("ride claim eligibility", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(seed);

  describe("allowed", () => {
    it("RCE-P01 an eligible driver claims a ride of their service, then marks themselves busy", async () => {
      await assertSucceeds(acceptTx("taxi1", "taxiTrip"));
      await assertSucceeds(updateDoc(doc(h.db("taxi1"), "drivers/taxi1"),
        { isAvailable: false, currentTripId: "taxiTrip" }));
    });

    it("RCE-P02 each ride service accepts its own drivers", async () => {
      await assertSucceeds(acceptTx("okada1", "okadaTrip"));
      await assertSucceeds(acceptTx("pragyia1", "pragyiaTrip"));
    });

    it("RCE-P03 the request-list queries of current and older Driver builds still work", async () => {
      // Current build: status + serviceType + order + limit.
      await assertSucceeds(getDocs(query(collection(h.db("taxi1"), "trips"),
        where("status", "==", "searching"), where("serviceType", "==", "taxi"),
        orderBy("createdAt", "desc"), limit(20))));
      // 2026-05 build: status only.
      await assertSucceeds(getDocs(query(collection(h.db("okada1"), "trips"),
        where("status", "==", "searching"))));
      await assertSucceeds(getDoc(doc(h.db("pragyia1"), "trips/taxiTrip")));
    });
  });

  describe("denied", () => {
    it("RCE-S01 an unapproved driver cannot claim", () =>
      assertFails(acceptTx("unapproved", "taxiTrip")));

    it("RCE-S02 a suspended driver cannot claim (flag only, or as the Admin app suspends)", async () => {
      await assertFails(acceptTx("suspendedFlag", "taxiTrip"));
      await assertFails(acceptTx("suspendedAdmin", "taxiTrip"));
    });

    it("RCE-S03 a delivery driver cannot claim or even list any ride", async () => {
      for (const t of ["taxiTrip", "okadaTrip", "pragyiaTrip"]) {
        await assertFails(acceptTx("deliv1", t), t);
        await assertFails(getDoc(doc(h.db("deliv1"), `trips/${t}`)), t);
      }
      await assertFails(getDocs(query(collection(h.db("deliv1"), "trips"),
        where("status", "==", "searching"))));
      // A delivery driver left with the pre-setup default serviceType 'taxi'.
      await assertFails(acceptTx("stillTaxiDefault", "taxiTrip"));
    });

    it("RCE-S04 a ride driver cannot claim another service's ride", async () => {
      await assertFails(acceptTx("okada1", "taxiTrip"));
      await assertFails(acceptTx("taxi1", "okadaTrip"));
      await assertFails(acceptTx("taxi1", "pragyiaTrip"));
      await assertFails(acceptTx("pragyia1", "taxiTrip"));
    });

    it("RCE-S05 an offline, unavailable or already-assigned driver cannot claim", async () => {
      for (const d of ["offline", "busyFlag", "onJob", "onJobOnline"]) {
        await assertFails(acceptTx(d, "taxiTrip"), d);
      }
    });

    it("RCE-S06 missing eligibility fields fail closed", async () => {
      for (const d of ["noService", "noRole", "noOnline"]) {
        await assertFails(acceptTx(d, "taxiTrip"), d);
      }
      await assertFails(acceptTx("noService", "noServiceTrip"));
      await assertFails(acceptTx("taxi1", "noServiceTrip"));
    });

    it("RCE-S07 expired, timed-out, cancelled or already-assigned trips cannot be claimed", async () => {
      for (const t of ["expiredTrip", "timedOutTrip", "cancelledTrip"]) {
        await assertFails(updateDoc(doc(h.db("taxi1"), `trips/${t}`), acceptPayload("taxi1")), t);
      }
      await assertFails(updateDoc(doc(h.db("taxi1"), "trips/takenTrip"), acceptPayload("taxi1")));
    });

    it("RCE-S08 a claim cannot be made for another driver", () =>
      assertFails(updateDoc(doc(h.db("taxi1"), "trips/taxiTrip"), acceptPayload("taxi2"))));
  });

  describe("concurrency", () => {
    it("RCE-C01 two eligible drivers racing for one ride: exactly one wins", async () => {
      const results = await Promise.allSettled([acceptTx("taxi1", "taxiTrip"), acceptTx("taxi2", "taxiTrip")]);
      const won = results.filter((r) => r.status === "fulfilled");
      if (won.length !== 1) throw new Error(`expected 1 winner, got ${won.length}`);
      let driverId;
      await h.env().withSecurityRulesDisabled(async (ctx) => {
        driverId = (await getDoc(doc(ctx.firestore(), "trips/taxiTrip"))).data().driverId;
      });
      if (!["taxi1", "taxi2"].includes(driverId)) throw new Error(`unexpected driverId ${driverId}`);
    });
  });
});

describe("driver_alerts ownership", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(seed);

  // service_request_manager.dart _broadcastToDrivers payload.
  const alert = (tripId, o = {}) => ({
    tripId, pickupLat: 5.6037, pickupLng: -0.187, serviceType: "taxi",
    timestamp: serverTimestamp(), expiresAt: Timestamp.fromDate(new Date(Date.now() + 120e3)),
    status: "broadcasting", ...o,
  });
  const alertRef = (uid, id) => doc(h.db(uid), `driver_alerts/${id}`);

  it("ALR-P01 the trip's own passenger writes its alert (set, then set again)", async () => {
    await assertSucceeds(setDoc(alertRef(h.PAX, "taxiTrip"), alert("taxiTrip")));
    await assertSucceeds(setDoc(alertRef(h.PAX, "taxiTrip"), alert("taxiTrip", { status: "broadcasting" })));
  });

  it("ALR-S01 another passenger cannot create or overwrite the alert for someone else's trip", async () => {
    await assertFails(setDoc(alertRef(h.STRANGER, "taxiTrip"), alert("taxiTrip", { serviceType: "none" })));
    await assertSucceeds(setDoc(alertRef(h.PAX, "taxiTrip"), alert("taxiTrip")));
    await assertFails(setDoc(alertRef(h.STRANGER, "taxiTrip"), alert("taxiTrip", { serviceType: "none" })));
    await assertFails(updateDoc(alertRef(h.STRANGER, "taxiTrip"), { serviceType: "none" }));
    await assertFails(updateDoc(alertRef("taxi1", "taxiTrip"), { status: "x" }));
  });

  it("ALR-S02 mismatched trip id, unknown trip or extra fields are refused", async () => {
    await assertFails(setDoc(alertRef(h.PAX, "taxiTrip"), alert("okadaTrip")));
    await assertFails(setDoc(alertRef(h.PAX, "noSuchTrip"), alert("noSuchTrip")));
    await assertFails(setDoc(alertRef(h.PAX, "taxiTrip"), alert("taxiTrip", { tripStatus: "noDriversAvailable" })));
  });

  it("ALR-S03 nobody but an admin reads or deletes alerts", async () => {
    await assertSucceeds(setDoc(alertRef(h.PAX, "taxiTrip"), alert("taxiTrip")));
    await assertFails(getDoc(alertRef(h.STRANGER, "taxiTrip")));
    await assertFails(getDoc(alertRef("taxi1", "taxiTrip")));
    await assertFails(deleteDoc(alertRef(h.STRANGER, "taxiTrip")));
    await assertFails(deleteDoc(alertRef(h.PAX, "taxiTrip")));
    await assertSucceeds(getDoc(alertRef(h.ADMIN, "taxiTrip")));
  });

  it("ALR-S04 writing an alert never changes the trip", async () => {
    await assertSucceeds(setDoc(alertRef(h.PAX, "taxiTrip"), alert("taxiTrip", { serviceType: "none" })));
    let status;
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      status = (await getDoc(doc(ctx.firestore(), "trips/taxiTrip"))).data().status;
    });
    if (status !== "searching") throw new Error(`trip status changed to ${status}`);
  });
});
