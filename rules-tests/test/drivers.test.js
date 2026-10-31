// Driver profile rules: self-approval, money fields, suspension, and the
// writes the driver app makes during signup and while online.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  doc,
  setDoc,
  updateDoc,
  serverTimestamp,
  GeoPoint,
} = require("firebase/firestore");
const h = require("./helpers");

const driver = (uid, id = uid) => doc(h.db(uid), `drivers/${id}`);
const NEWBIE = "newSignup"; // a user with no driver profile yet

// Mirrors the create in driver app lib/core/services/driver_service.dart.
function signupPayload(overrides = {}) {
  return {
    uid: NEWBIE,
    phone: "+233200000099",
    role: null,
    displayName: null,
    email: null,
    photoUrl: null,
    accountSetupComplete: false,
    vehicleSetupComplete: false,
    documentsUploaded: false,
    isApproved: false,
    isOnline: false,
    isAvailable: false,
    serviceType: "taxi",
    location: null,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

describe("drivers", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(h.seed);

  describe("security: self-approval", () => {
    it("DRV-S01 cannot create own profile already approved", () =>
      assertFails(setDoc(driver(NEWBIE), signupPayload({ isApproved: true }))));

    it("DRV-S02 cannot create own profile with a balance", () =>
      assertFails(
        setDoc(
          driver(NEWBIE),
          signupPayload({ walletBalance: 4000, totalEarnings: 4000 }),
        ),
      ));

    it("DRV-S03 unapproved driver cannot approve themselves", () =>
      assertFails(updateDoc(driver(h.NEW_DRIVER), { isApproved: true })));

    it("DRV-S04 suspended driver cannot lift their own suspension", () =>
      assertFails(updateDoc(driver(h.SUSPENDED_DRIVER), { signupStep: "approved" })));

    it("DRV-S05 cannot create or edit another driver's profile", async () => {
      await assertFails(setDoc(driver(h.STRANGER, "victim"), signupPayload()));
      await assertFails(updateDoc(driver(h.OTHER_DRIVER, h.DRIVER), { isOnline: false }));
    });
  });

  describe("security: money and reputation fields", () => {
    it("DRV-S06 cannot change own walletBalance", () =>
      assertFails(updateDoc(driver(h.DRIVER), { walletBalance: 9999 })));

    it("DRV-S07 cannot change own totalEarnings", () =>
      assertFails(updateDoc(driver(h.DRIVER), { totalEarnings: 9999 })));

    it("DRV-S08 cannot clear commission owed", () =>
      assertFails(updateDoc(driver(h.DRIVER), { commissionOwed: 0 })));

    it("DRV-S09 cannot change own rating", () =>
      assertFails(updateDoc(driver(h.DRIVER), { rating: 5 })));

    it("DRV-S10 cannot write own earnings summary", () =>
      assertFails(
        updateDoc(doc(h.db(h.DRIVER), `drivers/${h.DRIVER}/earnings/summary`), {
          totalBalance: 9999,
        }),
      ));
  });

  describe("app behaviour (must keep working)", () => {
    it("DRV-P01 creates own profile at signup (driver_service)", () =>
      assertSucceeds(setDoc(driver(NEWBIE), signupPayload())));

    it("DRV-P02 goes online (driver_runtime_service)", () =>
      assertSucceeds(
        setDoc(
          driver(h.DRIVER),
          {
            location: new GeoPoint(5.6, -0.18),
            currentLocation: new GeoPoint(5.6, -0.18),
            lastSeen: serverTimestamp(),
            lastLocationUpdate: serverTimestamp(),
            isOnline: true,
            isAvailable: true,
            fcmToken: "fake-token",
            lastStatusChange: serverTimestamp(),
          },
          { merge: true },
        ),
      ));

    it("DRV-P03 streams location (driver_runtime_service)", () =>
      assertSucceeds(
        setDoc(
          driver(h.DRIVER),
          {
            location: new GeoPoint(5.61, -0.19),
            currentLocation: new GeoPoint(5.61, -0.19),
            lastSeen: serverTimestamp(),
            lastLocationUpdate: serverTimestamp(),
          },
          { merge: true },
        ),
      ));

    it("DRV-P04 goes offline (driver_runtime_service)", () =>
      assertSucceeds(
        updateDoc(driver(h.DRIVER), {
          isOnline: false,
          isAvailable: false,
          lastStatusChange: serverTimestamp(),
        }),
      ));

    it("DRV-P05 edits vehicle details", () =>
      assertSucceeds(
        updateDoc(driver(h.DRIVER), {
          vehicleModel: "Toyota Vitz",
          vehiclePlate: "GR-1234-24",
          updatedAt: serverTimestamp(),
        }),
      ));

    // Every build marks itself busy in a separate write right after its
    // claim transaction; only a job now assigned to the driver may be named
    // (driver_job_state.test.js covers the refusals).
    it("DRV-P06 marks itself busy after accepting (requests_section)", () =>
      assertSucceeds(
        updateDoc(driver(h.DRIVER), {
          isAvailable: false,
          currentTripId: "assigned",
        }),
      ));

    it("DRV-P07 streams location with heading (location_service)", () =>
      assertSucceeds(
        updateDoc(driver(h.DRIVER), {
          location: new GeoPoint(5.6, -0.18),
          currentLocation: new GeoPoint(5.6, -0.18),
          lastLocationUpdate: serverTimestamp(),
          locationUpdatedAt: serverTimestamp(),
          heading: 90,
        }),
      ));
  });
});
