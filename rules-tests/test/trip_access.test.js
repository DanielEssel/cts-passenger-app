// AUTH-01: trip and trip-location reads are limited to the trip's parties,
// admins, and active drivers browsing open requests. Plus DRV-S01/S02 at
// driver signup, and the Driver App writes that must keep working.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  collection,
  doc,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
  query,
  where,
  orderBy,
  limit,
  serverTimestamp,
  GeoPoint,
} = require("firebase/firestore");
const h = require("./helpers");

// The Driver App request query, exactly as shipped (requests_section.dart).
const openRequests = (uid) =>
  query(
    collection(h.db(uid), "trips"),
    where("status", "==", "searching"),
    where("serviceType", "==", "taxi"),
    orderBy("createdAt", "desc"),
    limit(20),
  );

async function seedLocations() {
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "trips/assigned/locations/l1"), {
      lat: 5.6, lng: -0.18,
    });
  });
}

describe("trip access (AUTH-01)", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await seedLocations();
  });

  // ── Must keep working ─────────────────────────────────────────────────
  it("TRA-P01 passenger reads own trip", () =>
    assertSucceeds(getDoc(doc(h.db(h.PAX), "trips/assigned"))));

  it("TRA-P02 passenger lists own trips (history query)", () =>
    assertSucceeds(
      getDocs(
        query(
          collection(h.db(h.PAX), "trips"),
          where("passengerId", "==", h.PAX),
          orderBy("createdAt", "desc"),
        ),
      ),
    ));

  it("TRA-P03 assigned driver reads the trip", () =>
    assertSucceeds(getDoc(doc(h.db(h.DRIVER), "trips/assigned"))));

  it("TRA-P04 assigned driver lists own completed trips (earnings query)", () =>
    assertSucceeds(
      getDocs(
        query(
          collection(h.db(h.DRIVER), "trips"),
          where("driverId", "==", h.DRIVER),
          where("status", "==", "completed"),
        ),
      ),
    ));

  it("TRA-P05 approved driver runs the open-requests query", () =>
    assertSucceeds(getDocs(openRequests(h.OTHER_DRIVER))));

  it("TRA-P06 approved driver reads one open request (accept transaction)", () =>
    assertSucceeds(getDoc(doc(h.db(h.OTHER_DRIVER), "trips/searching"))));

  it("TRA-P07 admin reads any trip", () =>
    assertSucceeds(getDoc(doc(h.db(h.ADMIN), "trips/assigned"))));

  it("TRA-P08 trip parties read the trip's locations", async () => {
    await assertSucceeds(getDoc(doc(h.db(h.PAX), "trips/assigned/locations/l1")));
    await assertSucceeds(getDoc(doc(h.db(h.DRIVER), "trips/assigned/locations/l1")));
  });

  it("TRA-P09 assigned driver writes a location for the trip", () =>
    assertSucceeds(
      setDoc(doc(h.db(h.DRIVER), "trips/assigned/locations/l2"), { lat: 5.6 }),
    ));

  // ── Must be denied ────────────────────────────────────────────────────
  it("TRA-S01 unrelated passenger cannot read someone else's trip", () =>
    assertFails(getDoc(doc(h.db(h.STRANGER), "trips/assigned"))));

  it("TRA-S02 unrelated passenger cannot list all trips", () =>
    assertFails(getDocs(collection(h.db(h.STRANGER), "trips"))));

  it("TRA-S03 unrelated passenger cannot read open requests", () =>
    assertFails(getDoc(doc(h.db(h.STRANGER), "trips/searching"))));

  it("TRA-S04 unapproved driver cannot read open requests", async () => {
    await assertFails(getDoc(doc(h.db(h.NEW_DRIVER), "trips/searching")));
    await assertFails(getDocs(openRequests(h.NEW_DRIVER)));
  });

  it("TRA-S05 suspended driver cannot read open requests", () =>
    assertFails(getDocs(openRequests(h.SUSPENDED_DRIVER))));

  it("TRA-S06 approved driver cannot read another driver's assigned trip", () =>
    assertFails(getDoc(doc(h.db(h.OTHER_DRIVER), "trips/assigned"))));

  it("TRA-S07 approved driver cannot query other drivers' accepted trips", () =>
    assertFails(
      getDocs(
        query(
          collection(h.db(h.OTHER_DRIVER), "trips"),
          where("status", "==", "tripAccepted"),
        ),
      ),
    ));

  it("TRA-S08 signed-out user cannot read trips", () =>
    assertFails(getDoc(doc(h.db(null), "trips/searching"))));

  it("TRA-S09 non-parties cannot read a trip's locations", async () => {
    await assertFails(getDoc(doc(h.db(h.STRANGER), "trips/assigned/locations/l1")));
    await assertFails(getDoc(doc(h.db(h.OTHER_DRIVER), "trips/assigned/locations/l1")));
    await assertFails(getDocs(collection(h.db(h.STRANGER), "trips/assigned/locations")));
  });

  it("TRA-S10 non-assigned users cannot write a trip's locations", async () => {
    await assertFails(
      setDoc(doc(h.db(h.STRANGER), "trips/assigned/locations/fake"), { lat: 1 }),
    );
    await assertFails(
      setDoc(doc(h.db(h.OTHER_DRIVER), "trips/assigned/locations/fake"), { lat: 1 }),
    );
  });
});

describe("driver signup create (DRV-S01/S02)", () => {
  const NEWBIE = "drvFresh";
  const drv = (uid) => doc(h.db(uid), `drivers/${uid}`);
  // DriverService.createDriverDocument (newDriverDefaults + timestamps).
  const signup = (o = {}) => ({
    uid: NEWBIE, phone: "+233200000099", role: null, displayName: null,
    email: null, photoUrl: null, accountSetupComplete: false,
    vehicleSetupComplete: false, documentsUploaded: false, isApproved: false,
    isOnline: false, isAvailable: false, serviceType: "taxi", location: null,
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(), ...o,
  });

  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(h.seed);

  it("DSC-P01 the app's signup payload is accepted", () =>
    assertSucceeds(setDoc(drv(NEWBIE), signup())));

  it("DSC-P02 older app versions' token-only create still works", () =>
    assertSucceeds(
      setDoc(drv(NEWBIE), {
        fcmToken: "t", fcmTokenUpdatedAt: serverTimestamp(), platform: "android",
      }, { merge: true }),
    ));

  it("DSC-P03 goOnline on a missing doc still works", () =>
    assertSucceeds(
      setDoc(drv(NEWBIE), {
        location: new GeoPoint(5.6, -0.18), currentLocation: new GeoPoint(5.6, -0.18),
        lastSeen: serverTimestamp(), lastLocationUpdate: serverTimestamp(),
        isOnline: true, isAvailable: true, fcmToken: "t",
        lastStatusChange: serverTimestamp(),
      }, { merge: true }),
    ));

  it("DSC-P04 a token-only doc can be completed with owner defaults", async () => {
    await h.env().withSecurityRulesDisabled((ctx) =>
      setDoc(doc(ctx.firestore(), `drivers/${NEWBIE}`), { fcmToken: "t" }));
    await assertSucceeds(
      updateDoc(drv(NEWBIE), {
        phone: "+233200000099", role: null, displayName: null, email: null,
        photoUrl: null, accountSetupComplete: false, vehicleSetupComplete: false,
        documentsUploaded: false, isOnline: false, isAvailable: false,
        serviceType: "taxi", location: null, updatedAt: serverTimestamp(),
      }),
    );
  });

  it("DSC-S01 cannot create own profile already approved", () =>
    assertFails(setDoc(drv(NEWBIE), signup({ isApproved: true }))));

  it("DSC-S02 cannot create own profile with money or rating fields", async () => {
    await assertFails(setDoc(drv(NEWBIE), signup({ walletBalance: 4000 })));
    await assertFails(setDoc(drv(NEWBIE), signup({ totalEarnings: 4000 })));
    await assertFails(setDoc(drv(NEWBIE), signup({ rating: 5 })));
  });

  it("DSC-S03 cannot create own profile with a signupStep or another uid", async () => {
    await assertFails(setDoc(drv(NEWBIE), signup({ signupStep: "approved" })));
    await assertFails(setDoc(drv(NEWBIE), signup({ uid: "someoneElse" })));
  });
});
