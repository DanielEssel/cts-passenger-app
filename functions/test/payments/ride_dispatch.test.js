// Ride dispatch after retiring onDriverAlertCreated and acceptTrip (F-01,
// F-02, F-12): onTripCreatedNotify is the one ride dispatcher. It reads the
// trip itself, notifies each eligible driver once (FCM + inbox), never
// changes the trip, and no Function listens on driver_alerts any more.
// Firestore emulator only; FCM is stubbed.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
// Load the real entry point first (it calls admin.initializeApp()), with the
// same local-only environment the payment harness sets.
process.env.GCLOUD_PROJECT = "demo-ctsgo-payments";
process.env.PAYMENTS_MODE = "stub";
process.env.BRIDGE_CLIENT_KEY = "fake-client-key";
process.env.BRIDGE_SECRET_KEY = "fake-secret-key";
process.env.BRIDGE_SERVICE_ID = "1";
const index = require("../../index");
const h = require("./helpers");

const { GeoPoint, Timestamp } = h.admin.firestore;
const ACCRA = new GeoPoint(5.6037, -0.187);
const NEAR = new GeoPoint(5.62, -0.19); // ~2 km
const FAR = new GeoPoint(6.69, -1.62); // Kumasi, >150 km

const multicasts = [];
Object.defineProperty(h.admin, "messaging", {
  configurable: true, writable: true,
  value: () => ({
    sendEachForMulticast: async (m) => {
      multicasts.push(m);
      return { successCount: m.tokens.length, failureCount: 0,
        responses: m.tokens.map(() => ({ success: true })) };
    },
    send: async () => "stub-id",
  }),
});

// Vehicle setup writes vehicleType with serviceType (okada → motorcycle).
const RIDE_VEHICLE = { taxi: "taxi", okada: "motorcycle", pragyia: "pragyia" };
const driver = (id, o = {}) => ({ uid: id, role: "driver_hailing", serviceType: "taxi",
  isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true,
  location: NEAR, fcmToken: `token-${id}`, ...o,
  vehicleType: o.vehicleType ?? RIDE_VEHICLE[o.serviceType ?? "taxi"] ?? "motorcycle" });

async function seedDrivers() {
  const drivers = {
    eligible: driver("eligible"),
    far: driver("far", { location: FAR }),
    okada: driver("okada", { serviceType: "okada" }),
    delivery: driver("delivery", { role: "driver_delivery", serviceType: "delivery" }),
    offline: driver("offline", { isOnline: false }),
    busy: driver("busy", { isAvailable: false }),
    unapproved: driver("unapproved", { isApproved: false }),
    noLocation: driver("noLocation", { location: null }),
  };
  for (const [id, d] of Object.entries(drivers)) await h.seed(`drivers/${id}`, d);
}

const trip = (o = {}) => ({ passengerId: "pax1", driverId: null, status: "searching",
  serviceType: "taxi", pickupLocation: ACCRA, pickupAddress: "A", dropoffAddress: "B",
  estimatedFare: 20, createdAt: Timestamp.now(), ...o });

async function dispatch(tripId, data) {
  await h.seed(`trips/${tripId}`, data);
  await index.onTripCreatedNotify.run({ params: { tripId }, data: { data: () => data } });
}

async function inbox(driverId) {
  return (await h.db().collection(`drivers/${driverId}/notifications`).get()).docs.map((d) => d.data());
}

after(() => h.fft.cleanup());
beforeEach(async () => { multicasts.length = 0; await h.clearFirestore(); await seedDrivers(); });

describe("retired paths", () => {
  test("RDP-01 onDriverAlertCreated is not exported; acceptTrip is the policy-checked acceptance", () => {
    // acceptTrip stays for Driver 1.0.0+1 (May 2026), now acceptRide's checks
    // (active_job_contract.test.js AJ-20..23).
    assert.equal(index.acceptTrip, require("../../accept_job").acceptTrip);
    assert.equal(index.onDriverAlertCreated, undefined);
    assert.ok(index.onTripCreatedNotify, "the ride dispatcher is still exported");
    assert.ok(index.acceptGasOrder, "gas acceptance is untouched");
    assert.ok(index.expireStaleTrips, "ride expiry is untouched");
  });

  test("RDP-02 no Function is triggered by driver_alerts", () => {
    for (const [name, fn] of Object.entries(index)) {
      const doc = fn?.__endpoint?.eventTrigger?.eventFilterPathPatterns?.document ?? "";
      assert.ok(!doc.startsWith("driver_alerts"), `${name} listens on ${doc}`);
    }
  });

  test("RDP-03 tripwire: every Firestore trigger declares a document path", () => {
    // A Firestore trigger with no document filter (an invalid call
    // signature) fires on every document created in the database and
    // crashes in the SDK. createPassengerWallet had this defect until
    // 2026-10-16 (see passenger_wallet_trigger.test.js); none may regain it.
    const unfiltered = Object.entries(index)
      .filter(([, fn]) => fn?.__endpoint?.eventTrigger?.eventType?.includes("firestore"))
      .filter(([, fn]) => !fn.__endpoint.eventTrigger.eventFilterPathPatterns?.document)
      .map(([name]) => name);
    assert.deepEqual(unfiltered, []);
  });
});

describe("onTripCreatedNotify", () => {
  test("RDP-10 notifies each eligible driver once: one FCM multicast and one inbox entry", async () => {
    await dispatch("t1", trip());
    assert.equal(multicasts.length, 1);
    assert.deepEqual(multicasts[0].tokens, ["token-eligible"]);
    assert.equal(multicasts[0].data.type, "NEW_RIDE_REQUEST");
    assert.equal(multicasts[0].data.tripId, "t1");
    assert.equal((await inbox("eligible")).length, 1);
    for (const d of ["far", "okada", "delivery", "offline", "busy", "unapproved", "noLocation"]) {
      assert.equal((await inbox(d)).length, 0, `${d} got an inbox entry`);
    }
  });

  test("RDP-11 dispatch never changes the trip", async () => {
    await dispatch("t2", trip());
    assert.equal((await h.read("trips/t2")).status, "searching");
    // No eligible driver at all: still no status change (no false "no drivers").
    await h.clearFirestore();
    await dispatch("t3", trip({ serviceType: "pragyia" }));
    assert.equal(multicasts.length, 1, "only the earlier dispatch sent");
    assert.equal((await h.read("trips/t3")).status, "searching");
  });

  test("RDP-12 an assigned or non-searching trip is not broadcast", async () => {
    await dispatch("t4", trip({ driverId: "eligible", status: "tripAccepted" }));
    await dispatch("t5", trip({ status: "cancelledByPassenger" }));
    assert.equal(multicasts.length, 0);
    assert.equal((await inbox("eligible")).length, 0);
  });

  test("RDP-13 eligibility comes from the trip: service type and pickup", async () => {
    await dispatch("t6", trip({ serviceType: "okada" }));
    assert.deepEqual(multicasts[0].tokens, ["token-okada"]);
    multicasts.length = 0;
    await dispatch("t7", trip({ pickupLocation: FAR }));
    assert.deepEqual(multicasts[0].tokens, ["token-far"]);
  });
});
