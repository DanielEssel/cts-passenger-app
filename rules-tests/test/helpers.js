// Shared setup for the Firestore rules tests.
//
// Runs only against the local emulator under the "demo-" project id, which the
// Firebase CLI never connects to a real project. RULES_FILE selects the rules
// under test (default: this repo's firestore.rules, which is what is deployed
// to ctstransportapp as of 2026-10-02).

const fs = require("fs");
const path = require("path");
const { initializeTestEnvironment } = require("@firebase/rules-unit-testing");
const { doc, setDoc, GeoPoint, serverTimestamp } = require("firebase/firestore");

const PROJECT_ID = "demo-ctsgo-rules";
const RULES_FILE = path.resolve(
  __dirname,
  "..",
  process.env.RULES_FILE || "../firestore.rules",
);

// Actors. Every uid is fake; no production data is used.
const PAX = "pax1"; // passenger who owns the seeded trips
const STRANGER = "pax2"; // unrelated passenger
const DRIVER = "drvA"; // approved driver assigned to seeded trips
const OTHER_DRIVER = "drvB"; // approved driver not assigned to anything
const NEW_DRIVER = "drvNew"; // signed up, not yet approved
const SUSPENDED_DRIVER = "drvSus"; // approved before, now suspended
const ADMIN = "admin1";

const ACCRA = new GeoPoint(5.6037, -0.187);
const AIRPORT = new GeoPoint(5.6052, -0.1668);

let testEnv;

async function setupEnv() {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules: fs.readFileSync(RULES_FILE, "utf8") },
  });
  return testEnv;
}

function env() {
  return testEnv;
}

function db(uid) {
  return uid
    ? testEnv.authenticatedContext(uid).firestore()
    : testEnv.unauthenticatedContext().firestore();
}

// Mirrors TripRequest.toFirestore() in the passenger app
// (lib/features/ride/models/trip_request.dart).
function newTripPayload(overrides = {}) {
  return {
    passengerId: PAX,
    passengerName: null,
    passengerPhotoUrl: null,
    passengerRating: null,
    driverId: null,
    serviceType: "taxi",
    status: "searching",
    pickupLocation: ACCRA,
    dropoffLocation: AIRPORT,
    pickupAddress: "Accra Central",
    dropoffAddress: "Kotoka Airport",
    createdAt: serverTimestamp(),
    scheduledAt: null,
    estimatedFare: 20.5,
    actualFare: null,
    distance: 6.2,
    estimatedDuration: 18,
    actualDuration: null,
    promoCode: null,
    discountAmount: null,
    paymentMethod: "wallet",
    isScheduled: false,
    metadata: {},
    escrowId: "esc1",
    ...overrides,
  };
}

function driverDoc(uid, overrides = {}) {
  return {
    uid,
    phone: "+233200000000",
    role: "driver_hailing",
    displayName: `Driver ${uid}`,
    serviceType: "taxi",
    isApproved: true,
    isOnline: true,
    isAvailable: true,
    signupStep: "approved",
    totalEarnings: 100,
    walletBalance: 50,
    commissionOwed: 5,
    rating: 4.8,
    location: ACCRA,
    ...overrides,
  };
}

// Seeds a known state with rules disabled. Every test starts from this.
async function seed() {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const fs_ = ctx.firestore();
    const put = (p, data) => setDoc(doc(fs_, p), data);

    await put(`admins/${ADMIN}`, { active: true, email: "admin@test" });
    await put(`users/${PAX}`, { role: "passenger", phone: "+233240000001" });
    await put(`users/${STRANGER}`, { role: "passenger", phone: "+233240000002" });

    await put(`drivers/${DRIVER}`, driverDoc(DRIVER));
    await put(`drivers/${OTHER_DRIVER}`, driverDoc(OTHER_DRIVER));
    await put(
      `drivers/${NEW_DRIVER}`,
      driverDoc(NEW_DRIVER, {
        isApproved: false,
        signupStep: "documents",
        totalEarnings: 0,
        walletBalance: 0,
        commissionOwed: 0,
      }),
    );
    await put(
      `drivers/${SUSPENDED_DRIVER}`,
      driverDoc(SUSPENDED_DRIVER, { signupStep: "suspended" }),
    );
    await put(`drivers/${DRIVER}/earnings/summary`, {
      todayEarnings: 10,
      lifetimeEarnings: 100,
      totalBalance: 50,
    });

    await put(`wallets/${PAX}`, {
      userId: PAX,
      balance: 30,
      heldBalance: 20.5,
      currency: "GHS",
      isActive: true,
    });
    await put(`wallets/${STRANGER}`, {
      userId: STRANGER,
      balance: 5,
      heldBalance: 0,
      currency: "GHS",
      isActive: true,
    });
    await put("escrows/esc1", { userId: PAX, amount: 20.5, status: "HELD" });
    await put("ledger/l1", { fromUserId: PAX, type: "HOLD", amount: 20.5 });
    await put(`driver_wallets/${DRIVER}`, { driverId: DRIVER, balance: 50 });
    await put("withdrawals/w1", {
      userId: DRIVER,
      amount: 20,
      status: "pending",
      phone: "233200000000",
      network: "MTN",
    });

    const trip = (overrides) => {
      const t = newTripPayload(overrides);
      delete t.createdAt; // serverTimestamp is fine here, but keep seeds plain
      return t;
    };
    await put("trips/searching", trip());
    await put(
      "trips/assigned",
      trip({ status: "tripAccepted", driverId: DRIVER, driverName: "Driver drvA" }),
    );
    await put(
      "trips/started",
      trip({ status: "tripStarted", driverId: DRIVER, driverName: "Driver drvA" }),
    );
    await put(
      "trips/completed",
      trip({
        status: "completed",
        driverId: DRIVER,
        passengerConfirmed: false,
        walletProcessed: false,
      }),
    );
  });
}

module.exports = {
  setupEnv,
  env,
  db,
  seed,
  newTripPayload,
  RULES_FILE,
  PAX,
  STRANGER,
  DRIVER,
  OTHER_DRIVER,
  NEW_DRIVER,
  SUSPENDED_DRIVER,
  ADMIN,
  ACCRA,
};
