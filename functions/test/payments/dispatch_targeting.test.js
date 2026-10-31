// Dispatch targeting for Ride, Delivery and Gas (dispatch_policy.js), run
// through the real triggers (onTripCreatedNotify, onDeliveryCreated,
// onGasOrderCreated), acceptGasOrder and onDriverTokenSaved.
//
// Asserts the actual recipient set: the FCM multicast token list and the
// drivers' inbox entries. Firestore emulator only; FCM is stubbed, no
// message leaves this machine. Fixture tokens are fake strings.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
process.env.GCLOUD_PROJECT = "demo-ctsgo-payments";
process.env.PAYMENTS_MODE = "stub";
process.env.BRIDGE_CLIENT_KEY = "fake-client-key";
process.env.BRIDGE_SECRET_KEY = "fake-secret-key";
process.env.BRIDGE_SERVICE_ID = "1";
const index = require("../../index");
const h = require("./helpers");
const policy = require("../../dispatch_policy");

const { GeoPoint, Timestamp } = h.admin.firestore;
const ACCRA = new GeoPoint(5.6037, -0.187);
const NEAR = new GeoPoint(5.62, -0.19); // ~2 km
const FAR = new GeoPoint(6.69, -1.62); // Kumasi, >150 km

// The last latitude offset still within the radius, and the first beyond it.
function boundaryOffsets() {
  let lo = 0, hi = 0.2;
  for (let i = 0; i < 200; i++) {
    const m = (lo + hi) / 2;
    const d = policy.distanceKm(ACCRA, { latitude: ACCRA.latitude + m, longitude: ACCRA.longitude });
    if (d <= policy.DISPATCH_RADIUS_KM) lo = m; else hi = m;
  }
  return { inside: lo, outside: hi };
}
const B = boundaryOffsets();
const ON_BOUNDARY = new GeoPoint(ACCRA.latitude + B.inside, ACCRA.longitude);
const JUST_OUTSIDE = new GeoPoint(ACCRA.latitude + B.outside, ACCRA.longitude);
const INSIDE_9KM = new GeoPoint(ACCRA.latitude + 0.0809, ACCRA.longitude);

// ── FCM stub ────────────────────────────────────────────────────────────────
const multicasts = [];
const deadTokens = new Set();
Object.defineProperty(h.admin, "messaging", {
  configurable: true, writable: true,
  value: () => ({
    sendEachForMulticast: async (m) => {
      multicasts.push(m);
      const responses = m.tokens.map((t) => deadTokens.has(t)
        ? { success: false, error: { code: "messaging/registration-token-not-registered" } }
        : { success: true });
      const ok = responses.filter((r) => r.success).length;
      return { successCount: ok, failureCount: m.tokens.length - ok, responses };
    },
    send: async () => "stub-id",
  }),
});
const sentTokens = () => multicasts.flatMap((m) => m.tokens).sort();

// ── Fixtures ────────────────────────────────────────────────────────────────
const base = { isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true,
  location: NEAR, lastLocationUpdate: Timestamp.now() };
const rideDriver = (id, serviceType, vehicleType, o = {}) => ({ uid: id, role: "driver_hailing",
  serviceType, vehicleType, fcmToken: `tok-${id}`, ...base, ...o });
const goodsDriver = (id, vehicleType, o = {}) => ({ uid: id, role: "driver_delivery",
  serviceType: "delivery", vehicleType, fcmToken: `tok-${id}`, ...base, ...o });

const FLEET = {
  okadaRide: rideDriver("okadaRide", "okada", "motorcycle"),
  taxiRide: rideDriver("taxiRide", "taxi", "taxi"),
  pragyiaRide: rideDriver("pragyiaRide", "pragyia", "pragyia"),
  pragyiaAsTaxi: rideDriver("pragyiaAsTaxi", "taxi", "pragyia"),
  taxiNoVehicle: rideDriver("taxiNoVehicle", "taxi", null),
  bike: goodsDriver("bike", "motorcycle"),
  trike: goodsDriver("trike", "tricycle"),
  truck: goodsDriver("truck", "miniTruck"),
  // Ineligible whatever the job:
  bikeOffline: goodsDriver("bikeOffline", "motorcycle", { isOnline: false }),
  bikeBusy: goodsDriver("bikeBusy", "motorcycle", { isAvailable: false }),
  bikeUnapproved: goodsDriver("bikeUnapproved", "motorcycle", { isApproved: false }),
  bikeSuspended: goodsDriver("bikeSuspended", "motorcycle", { signupStep: "suspended" }),
  taxiSuspended: rideDriver("taxiSuspended", "taxi", "taxi", { signupStep: "suspended" }),
  bikeFar: goodsDriver("bikeFar", "motorcycle", { location: FAR }),
  taxiFar: rideDriver("taxiFar", "taxi", "taxi", { location: FAR }),
  bikeNoLocation: goodsDriver("bikeNoLocation", "motorcycle", { location: null }),
  bikeZeroLocation: goodsDriver("bikeZeroLocation", "motorcycle", { location: new GeoPoint(0, 0) }),
  taxiZeroLocation: rideDriver("taxiZeroLocation", "taxi", "taxi", { location: new GeoPoint(0, 0) }),
  noRole: (({ role, ...d }) => d)(goodsDriver("noRole", "motorcycle")),
};
const ELIGIBLE_ANYWHERE = new Set(["okadaRide", "taxiRide", "pragyiaRide", "bike", "trike", "truck"]);

const trip = (serviceType, o = {}) => ({ passengerId: "pax1", driverId: null, status: "searching",
  serviceType, paymentMethod: "cash", pickupLocation: ACCRA, pickupAddress: "A",
  dropoffAddress: "B", estimatedFare: 20, createdAt: Timestamp.now(), ...o });
const delivery = (vehicleType, weightTier, o = {}) => ({ passengerId: "pax1", driverId: null,
  status: "pending", vehicleType, weightTier, paymentMethod: "cash", pickupLocation: ACCRA,
  dropoffLocation: NEAR, pickupAddress: "A", dropoffAddress: "B", parcelType: "Package",
  estimatedFare: 30, createdAt: Timestamp.now(), ...o });
// As the app writes it (CylinderSize.name "kg12_5"), at the server's price
// for its type (onGasOrderCreated cancels any other amount; release v5).
const gasOrder = (refillType, o = {}) => ({ ...h.gasPriced({ passengerId: "pax1", driverId: null,
  status: "pendingApproval", refillType, cylinderSize: "kg12_5", quantity: 1,
  paymentMethod: "cash", pickupLocation: ACCRA, deliveryLocation: ACCRA, deliveryAddress: "C",
  createdAt: Timestamp.now() }, null, 600), ...o });

/** An acceptance result without the policy's `detail` (logged, not shown by older builds). */
const outcome = ({ success, reason }) => (success ? { success } : { success, reason });

async function seedFleet(fleet = FLEET) {
  for (const [id, d] of Object.entries(fleet)) await h.seed(`drivers/${id}`, d);
}

// The approved Delivery rates (test fixture) the server prices quotes with.
const PLATFORM = { platformFeePercent: 15, delivery: h.DELIVERY_RATES };
const { inputProblem, vehicleKey } = require("../../delivery_pricing");
/** True when the current Passenger app could have quoted [d] (otherwise only an older build books it). */
const quotable = (d) => !inputProblem({ vehicleKey: vehicleKey(d.vehicleType), weightTier: d.weightTier,
  isFragile: d.isFragile ?? false, requiresHelpers: d.requiresHelpers ?? false });
/** Older Passenger builds (no server quote) admitted for the rollout window (delivery_quotes.js). */
const allowLegacyUnquoted = () => h.seed("app_config/pricing", { legacyUnquotedDeliveries: true });

async function run(kind, id, data) {
  const coll = { ride: "trips", delivery: "deliveries", gas: "gas_orders" }[kind];
  const trigger = { ride: index.onTripCreatedNotify, delivery: index.onDeliveryCreated,
    gas: index.onGasOrderCreated }[kind];
  const param = { ride: "tripId", delivery: "deliveryId", gas: "orderId" }[kind];
  if (kind === "delivery") {
    // As Passenger 1.0.1 books it: with the server quote for its route.
    await h.seed("settings/platform", PLATFORM);
    if (quotable(data) && data.deliveryQuoteId === undefined) {
      // A 3 km route: the fixture's flat 30 is below some vehicles' minimum.
      data = await h.quotedDelivery(data, { quoteId: `q-${id}`, settings: PLATFORM, distanceMeters: 3000 });
    }
  }
  await h.seed(`${coll}/${id}`, data);
  await trigger.run({ params: { [param]: id }, data: { data: () => data } });
}

async function inboxed(maxPerDriver = 1) {
  const ids = [];
  for (const id of Object.keys(FLEET)) {
    const snap = await h.db().collection(`drivers/${id}/notifications`).get();
    if (snap.size > 0) ids.push(id);
    assert.ok(snap.size <= maxPerDriver, `${id} got ${snap.size} inbox entries`);
  }
  return ids.sort();
}

/** Recipients by inbox and by device must agree, and equal `expected`. */
async function assertRecipients(expected, msg) {
  const want = [...expected].sort();
  assert.deepEqual(await inboxed(), want, `${msg}: inbox`);
  assert.deepEqual(sentTokens(), want.map((id) => `tok-${id}`).sort(), `${msg}: devices`);
  assert.ok(multicasts.length <= 1, `${msg}: one multicast per request`);
}

async function reset() {
  multicasts.length = 0;
  deadTokens.clear();
  await h.clearFirestore();
}

after(() => h.fft.cleanup());
beforeEach(async () => { await reset(); await seedFleet(); });

// ── Ride ────────────────────────────────────────────────────────────────────
describe("ride requests", () => {
  for (const [service, expected] of [["okada", ["okadaRide"]], ["taxi", ["taxiRide"]],
    ["pragyia", ["pragyiaRide"]]]) {
    test(`DT-R ${service}: only approved, online, nearby ${service} drivers with a ${service} vehicle`, async () => {
      await run("ride", `t-${service}`, trip(service));
      await assertRecipients(expected, service);
    });
  }

  test("DT-R04 a Pragyia vehicle registered as Taxi, or a driver with no vehicle, gets no Taxi request", async () => {
    await run("ride", "t1", trip("taxi"));
    const got = await inboxed();
    assert.ok(!got.includes("pragyiaAsTaxi") && !got.includes("taxiNoVehicle"));
  });

  test("DT-R05 Delivery drivers never receive ride requests", async () => {
    for (const s of ["okada", "taxi", "pragyia"]) await run("ride", `t-${s}`, trip(s));
    const got = await inboxed();
    for (const d of ["bike", "trike", "truck"]) assert.ok(!got.includes(d), d);
  });

  test("DT-R06 unknown ride service: offered to nobody", async () => {
    await run("ride", "t1", trip("quadricycle"));
    const noService = trip("taxi");
    delete noService.serviceType;
    await run("ride", "t2", noService);
    await assertRecipients([], "unknown service");
  });
});

// ── Delivery ────────────────────────────────────────────────────────────────
describe("delivery requests", () => {
  for (const [vehicle, tier, expected] of [
    ["Okada", "Small", ["bike"]],
    ["Aboboya", "Medium", ["trike"]],
    ["Aboboya", "Large", ["trike"]],
    ["Mini Truck", "Bulk", ["truck"]],
  ]) {
    test(`DT-D ${vehicle}/${tier}: only Delivery drivers with that vehicle`, async () => {
      await run("delivery", "d1", delivery(vehicle, tier));
      await assertRecipients(expected, `${vehicle}/${tier}`);
    });
  }

  test("DT-D05 a vehicle booked beyond its capacity is offered to nobody, ended, and alerted", async () => {
    // Only older Passenger builds book these (no quote is possible for them).
    await allowLegacyUnquoted();
    await run("delivery", "d1", delivery("Okada", "Medium"));
    await run("delivery", "d2", delivery("Mini Truck", "Small"));
    await run("delivery", "d3", delivery("Helicopter", "Small"));
    await assertRecipients([], "capacity");
    for (const [id, reason] of [["d1", "vehicle_cannot_carry_weight_tier"],
      ["d2", "vehicle_cannot_carry_weight_tier"], ["d3", "unknown_delivery_vehicle"]]) {
      const d = await h.read(`deliveries/${id}`);
      assert.deepEqual([d.status, d.statusReason, d.cancelledBy], ["cancelled", reason, "system"], id);
    }
    const alerts = (await h.db().collection("admin_alerts").get()).docs.map((d) => d.data());
    assert.deepEqual(alerts.map((a) => [a.jobId, a.reason]).sort(), [
      ["d1", "vehicle_cannot_carry_weight_tier"],
      ["d2", "vehicle_cannot_carry_weight_tier"],
      ["d3", "unknown_delivery_vehicle"],
    ]);
  });

  test("DT-D06 a Ride driver with a matching vehicle never receives a delivery", async () => {
    await run("delivery", "d1", delivery("Okada", "Small"));
    assert.ok(!(await inboxed()).includes("okadaRide"));
  });
});

// ── Gas ─────────────────────────────────────────────────────────────────────
describe("gas orders", () => {
  test("DT-G01 everyday refills go to Delivery drivers on all three vehicles", async () => {
    await run("gas", "g1", gasOrder("newCylinder"));
    await assertRecipients(["bike", "trike", "truck"], "newCylinder");
    multicasts.length = 0;
    await h.clearFirestore(); await seedFleet();
    await run("gas", "g2", gasOrder("exchangeEmpty"));
    await assertRecipients(["bike", "trike", "truck"], "exchangeEmpty");
  });

  test("DT-G02 refill types follow the vehicle policy (bulk: aboboyaa and mini truck only)", async () => {
    await run("gas", "g1", gasOrder("commercialBulk"));
    await assertRecipients(["trike", "truck"], "commercialBulk");
    multicasts.length = 0;
    await h.clearFirestore(); await seedFleet();
    // Business rule 2026-10-28: Pickup & Return is a standard order, taken by
    // every Gas vehicle (it was motorbike-only before).
    await run("gas", "g2", gasOrder("pickupAndReturn"));
    await assertRecipients(["bike", "trike", "truck"], "pickupAndReturn");
  });

  test("DT-G03 Ride drivers never receive gas orders; unknown refill types reach nobody", async () => {
    await run("gas", "g1", gasOrder("newCylinder"));
    const got = await inboxed();
    for (const d of ["okadaRide", "taxiRide", "pragyiaRide"]) assert.ok(!got.includes(d), d);
    multicasts.length = 0;
    await h.clearFirestore(); await seedFleet();
    await run("gas", "g2", gasOrder("tanker"));
    await assertRecipients([], "unknown refill");
  });

  test("DT-G04 the gas push carries no route (a tap opens the request list)", async () => {
    await run("gas", "g1", gasOrder("newCylinder"));
    assert.equal(multicasts[0].data.route, undefined);
    assert.equal(multicasts[0].data.type, "NEW_GAS_REQUEST");
  });

  test("DT-G05 gas uses the customer's location", async () => {
    await run("gas", "g1", gasOrder("newCylinder", { deliveryLocation: FAR, pickupLocation: ACCRA }));
    await assertRecipients(["bikeFar"], "customer far away: only the driver near them");
  });
});

// ── Status, radius and locations ────────────────────────────────────────────
describe("status, radius and location", () => {
  test("DT-S01 offline, busy, unapproved, suspended or role-less drivers are never notified", async () => {
    await run("ride", "t1", trip("taxi"));
    await run("delivery", "d1", delivery("Okada", "Small"));
    await run("gas", "g1", gasOrder("newCylinder"));
    const got = await inboxed(3); // one entry per job
    for (const d of ["bikeOffline", "bikeBusy", "bikeUnapproved", "bikeSuspended",
      "taxiSuspended", "noRole"]) {
      assert.ok(!got.includes(d), d);
    }
    for (const id of got) assert.ok(ELIGIBLE_ANYWHERE.has(id), id);
  });

  test("DT-S02 radius: inside, on the boundary (inclusive), just outside, far outside", async () => {
    await reset();
    await seedFleet({
      inside: rideDriver("inside", "taxi", "taxi", { location: INSIDE_9KM }),
      boundary: rideDriver("boundary", "taxi", "taxi", { location: ON_BOUNDARY }),
      justOutside: rideDriver("justOutside", "taxi", "taxi", { location: JUST_OUTSIDE }),
      far: rideDriver("far", "taxi", "taxi", { location: FAR }),
    });
    await run("ride", "t1", trip("taxi"));
    assert.deepEqual(sentTokens(), ["tok-boundary", "tok-inside"]);
  });

  test("DT-S03 missing, (0,0) or invalid driver locations are excluded", async () => {
    await run("delivery", "d1", delivery("Okada", "Small"));
    await run("ride", "t1", trip("taxi"));
    const got = await inboxed();
    for (const d of ["bikeNoLocation", "bikeZeroLocation", "taxiZeroLocation"]) assert.ok(!got.includes(d), d);
  });

  test("DT-S04 a request with a missing, (0,0) or invalid location is offered to nobody", async () => {
    await run("ride", "t1", trip("taxi", { pickupLocation: null }));
    await run("ride", "t2", trip("taxi", { pickupLocation: new GeoPoint(0, 0) }));
    await run("delivery", "d1", delivery("Okada", "Small", { pickupLocation: null }));
    await run("gas", "g1", gasOrder("newCylinder", { deliveryLocation: null, pickupLocation: null }));
    await run("gas", "g2", gasOrder("newCylinder",
      { deliveryLocation: { latitude: Number.NaN, longitude: 1 }, pickupLocation: null }));
    await assertRecipients([], "invalid request location");
    assert.equal(multicasts.length, 0);
  });

  test("DT-S05 a driver at (0,0) is not matched by a request missing its location", async () => {
    // Before: a missing pickup defaulted to (0,0), so it matched exactly such drivers.
    const noPickup = trip("taxi");
    delete noPickup.pickupLocation;
    await run("ride", "t1", noPickup);
    assert.ok(!(await inboxed()).includes("taxiZeroLocation"));
  });

  test("DT-S06 a driver who moves after going online is matched where they are now", async () => {
    await run("ride", "t1", trip("taxi", { pickupLocation: FAR }));
    assert.deepEqual(sentTokens(), ["tok-taxiFar"]);
    await h.db().doc("drivers/taxiFar").update({ location: NEAR });
    multicasts.length = 0;
    await run("ride", "t2", trip("taxi", { pickupLocation: FAR }));
    assert.deepEqual(sentTokens(), []);
  });

  test("DT-S07 several eligible drivers inside the radius each get exactly one notification", async () => {
    await run("gas", "g1", gasOrder("newCylinder"));
    assert.equal(multicasts.length, 1);
    assert.equal(new Set(multicasts[0].tokens).size, multicasts[0].tokens.length);
  });

  test("DT-S08 a stale location is used as recorded: it never widens the recipients", async () => {
    // No freshness cutoff exists (no heartbeat while parked): an old position
    // is treated like any other and still has to be inside the radius.
    await h.db().doc("drivers/taxiFar").update({
      lastLocationUpdate: Timestamp.fromMillis(Date.now() - 24 * 3600 * 1000) });
    await run("ride", "t1", trip("taxi"));
    assert.deepEqual(sentTokens(), ["tok-taxiRide"]);
  });
});

// ── Devices ─────────────────────────────────────────────────────────────────
describe("device tokens", () => {
  test("DT-T01 unrelated devices receive nothing", async () => {
    await run("delivery", "d1", delivery("Mini Truck", "Bulk"));
    assert.deepEqual(sentTokens(), ["tok-truck"]);
  });

  test("DT-T02 a token held by two drivers is not used; both still get their inbox entry", async () => {
    await h.db().doc("drivers/trike").update({ fcmToken: "tok-truck" });
    await run("gas", "g1", gasOrder("newCylinder"));
    assert.deepEqual(sentTokens(), ["tok-bike"]);
    assert.deepEqual(await inboxed(), ["bike", "trike", "truck"]);
  });

  test("DT-T03 a driver without a token gets the inbox entry only", async () => {
    await h.db().doc("drivers/truck").update({ fcmToken: h.admin.firestore.FieldValue.delete() });
    await run("delivery", "d1", delivery("Mini Truck", "Bulk"));
    assert.deepEqual(await inboxed(), ["truck"]);
    assert.equal(multicasts.length, 0);
  });

  test("DT-T04 a dead token is removed from its driver only, never widening the next dispatch", async () => {
    deadTokens.add("tok-bike");
    await run("gas", "g1", gasOrder("newCylinder"));
    assert.equal((await h.read("drivers/bike")).fcmToken, undefined);
    assert.equal((await h.read("drivers/trike")).fcmToken, "tok-trike");
    multicasts.length = 0;
    await run("gas", "g2", gasOrder("newCylinder"));
    assert.deepEqual(sentTokens(), ["tok-trike", "tok-truck"]);
  });

  test("DT-T05 a token refreshed meanwhile is not removed", async () => {
    deadTokens.add("tok-bike");
    const orig = h.admin.messaging;
    Object.defineProperty(h.admin, "messaging", { configurable: true, writable: true,
      value: () => ({ ...orig(), sendEachForMulticast: async (m) => {
        await h.db().doc("drivers/bike").update({ fcmToken: "tok-bike-new" });
        return orig().sendEachForMulticast(m);
      } }) });
    try {
      await run("delivery", "d1", delivery("Okada", "Small"));
    } finally {
      Object.defineProperty(h.admin, "messaging", { configurable: true, writable: true, value: orig });
    }
    assert.equal((await h.read("drivers/bike")).fcmToken, "tok-bike-new");
  });

  test("DT-T06 signing in on a device moves its token: the previous account loses it", async () => {
    // bike signed out offline (token left behind); truck signs in on that device.
    const before = await h.read("drivers/truck");
    await h.db().doc("drivers/truck").update({ fcmToken: "tok-bike" });
    const after = await h.read("drivers/truck");
    await index.onDriverTokenSaved.run({ params: { driverId: "truck" },
      data: { before: { data: () => before }, after: { data: () => after } } });
    assert.equal((await h.read("drivers/bike")).fcmToken, undefined);
    assert.equal((await h.read("drivers/truck")).fcmToken, "tok-bike");
    await run("delivery", "d1", delivery("Okada", "Small")); // bike's job
    assert.deepEqual(await inboxed(), ["bike"]);
    assert.deepEqual(sentTokens(), [], "the device now belongs to truck");
  });

  test("DT-T08 a late event for an older save never takes the token from its newer owner", async () => {
    // bike saved the device token at t1, then (offline sign-out left it) truck
    // saved it at t2. bike's t1 event arrives after truck's save.
    const t1 = Timestamp.fromMillis(Date.now() - 60_000);
    const t2 = Timestamp.now();
    await h.db().doc("drivers/bike").update({ fcmToken: "tok-shared", fcmTokenUpdatedAt: t1 });
    await h.db().doc("drivers/truck").update({ fcmToken: "tok-shared", fcmTokenUpdatedAt: t2 });
    const bike = await h.read("drivers/bike");
    await index.onDriverTokenSaved.run({ params: { driverId: "bike" }, time: t1.toDate().toISOString(),
      data: { before: { data: () => ({ ...bike, fcmToken: "tok-bike" }) }, after: { data: () => bike } } });
    assert.equal((await h.read("drivers/truck")).fcmToken, "tok-shared", "newer owner keeps it");
    // truck's own event then removes the stale copy from bike.
    const truck = await h.read("drivers/truck");
    await index.onDriverTokenSaved.run({ params: { driverId: "truck" }, time: t2.toDate().toISOString(),
      data: { before: { data: () => ({ ...truck, fcmToken: "tok-truck" }) }, after: { data: () => truck } } });
    assert.equal((await h.read("drivers/bike")).fcmToken, undefined);
    assert.equal((await h.read("drivers/truck")).fcmToken, "tok-shared");
  });

  test("DT-T09 an owner who has since signed out (token cleared) releases nothing", async () => {
    await h.db().doc("drivers/bike").update({ fcmToken: "tok-shared" });
    const before = await h.read("drivers/truck");
    await h.db().doc("drivers/truck").update({ fcmToken: "tok-shared" });
    const after = await h.read("drivers/truck");
    await h.db().doc("drivers/truck").update({ fcmToken: h.admin.firestore.FieldValue.delete() });
    await index.onDriverTokenSaved.run({ params: { driverId: "truck" },
      data: { before: { data: () => before }, after: { data: () => after } } });
    assert.equal((await h.read("drivers/bike")).fcmToken, "tok-shared");
  });

  test("DT-T07 location pings do not touch other drivers' tokens", async () => {
    const before = await h.read("drivers/truck");
    await h.db().doc("drivers/trike").update({ fcmToken: "tok-truck" });
    await index.onDriverTokenSaved.run({ params: { driverId: "truck" },
      data: { before: { data: () => before }, after: { data: () => ({ ...before, location: ACCRA }) } } });
    assert.equal((await h.read("drivers/trike")).fcmToken, "tok-truck");
  });
});

// ── Gas acceptance (server-authoritative) ───────────────────────────────────
describe("acceptGasOrder", () => {
  const accept = (uid, orderId) => h.callCallable(index.acceptGasOrder, uid, { orderId });

  test("DT-A01 an eligible Delivery driver accepts; the order and driver are updated together", async () => {
    await h.seed("gas_orders/g1", gasOrder("newCylinder"));
    assert.deepEqual(await accept("trike", "g1"), { success: true, orderId: "g1" });
    const o = await h.read("gas_orders/g1");
    assert.equal(o.driverId, "trike");
    assert.equal(o.status, "driverAssigned");
    const d = await h.read("drivers/trike");
    assert.equal(d.isAvailable, false);
    assert.equal(d.currentTripId, "g1");
  });

  test("DT-A02 ineligible drivers are refused, whatever the client shows", async () => {
    await h.seed("gas_orders/g1", gasOrder("commercialBulk"));
    for (const [uid, reason] of [
      ["taxiRide", "driver_not_eligible"],
      ["okadaRide", "driver_not_eligible"],
      ["bikeOffline", "driver_not_eligible"],
      ["bikeBusy", "driver_not_eligible"],
      ["bikeUnapproved", "driver_not_eligible"],
      ["bikeSuspended", "driver_not_eligible"],
      ["noRole", "driver_not_eligible"],
      ["bike", "vehicle_not_eligible"], // a motorcycle cannot do commercial bulk
      ["nobody", "driver_not_found"],
    ]) {
      assert.deepEqual(outcome(await accept(uid, "g1")), { success: false, reason }, uid);
    }
    assert.equal((await h.read("gas_orders/g1")).driverId, null);
  });

  test("DT-A03 concurrent acceptance: exactly one driver gets the order", async () => {
    await h.seed("gas_orders/g1", gasOrder("newCylinder"));
    const results = await Promise.all(["bike", "trike", "truck"].map((d) => accept(d, "g1")));
    const winners = results.filter((r) => r.success);
    assert.equal(winners.length, 1);
    for (const r of results.filter((x) => !x.success)) {
      assert.ok(["order_unavailable", "order_already_assigned"].includes(r.reason), r.reason);
    }
    const o = await h.read("gas_orders/g1");
    const busy = [];
    for (const d of ["bike", "trike", "truck"]) {
      if ((await h.read(`drivers/${d}`)).currentTripId === "g1") busy.push(d);
    }
    assert.deepEqual(busy, [o.driverId]);
  });

  test("DT-A04 an assigned or closed order cannot be accepted", async () => {
    await h.seed("gas_orders/g1", gasOrder("newCylinder", { driverId: "truck", status: "driverAssigned" }));
    await h.seed("gas_orders/g2", gasOrder("newCylinder", { status: "cancelled" }));
    assert.equal((await accept("bike", "g1")).reason, "order_unavailable");
    assert.equal((await accept("bike", "g2")).reason, "order_unavailable");
  });

  test("DT-A05 signed-out callers are refused", async () => {
    await h.seed("gas_orders/g1", gasOrder("newCylinder"));
    await assert.rejects(accept(null, "g1"), /signed in/);
  });
});

// ── Older Passenger builds: undeliverable bookings end, never hang ──────────
describe("undeliverable deliveries", () => {
  /** Applies a server-side status change and runs the status/cancel triggers on it. */
  async function settleStatusTriggers(id, before) {
    const after = await h.read(`deliveries/${id}`);
    const ev = { params: { deliveryId: id },
      data: { before: { data: () => before }, after: { data: () => after } } };
    await index.onDeliveryStatusChanged.run(ev);
    await index.onDeliveryCancelled.run(ev);
  }

  test("DT-U01 a cash Medium/Okada booking is cancelled with its reason and the passenger is told", async () => {
    await allowLegacyUnquoted(); // an older Passenger build's booking
    const d = delivery("Okada", "Medium");
    await run("delivery", "d1", d);
    await settleStatusTriggers("d1", d);
    const items = (await h.db().collection("notifications/pax1/items").get()).docs.map((x) => x.data());
    const told = items.find((i) => i.title === "Delivery cancelled");
    assert.ok(told, "the passenger is notified");
    assert.match(told.body, /Okada can't carry a medium delivery/);
    assert.match(told.body, /book again/);
    assert.deepEqual(sentTokens(), [], "no driver was offered it");
  });

  test("DT-U02 a wallet Medium/Okada booking returns its hold once, when its payment is attached", async () => {
    await h.seed("wallets/pax1", { userId: "pax1", balance: 0, heldBalance: 40 });
    await h.seed("escrows/e1", { userId: "pax1", amount: 40, status: "HELD",
      referenceId: "d1", referenceType: "delivery" });
    await allowLegacyUnquoted(); // an older Passenger build's booking
    const before = delivery("Okada", "Medium", { paymentMethod: "wallet", estimatedFare: 40 });
    await run("delivery", "d1", before); // waits for its payment
    assert.equal((await h.read("deliveries/d1")).status, "pending");
    const paid = { ...before, escrowId: "e1" };
    await h.db().doc("deliveries/d1").update({ escrowId: "e1" });
    await index.onDeliveryPaymentAttached.run({ params: { deliveryId: "d1" },
      data: { before: { data: () => before }, after: { data: () => paid } } });
    await settleStatusTriggers("d1", paid);
    await settleStatusTriggers("d1", paid); // a redelivered event changes nothing
    assert.equal((await h.read("escrows/e1")).status, "REFUNDED");
    const w = await h.read("wallets/pax1");
    assert.deepEqual([w.balance, w.heldBalance], [40, 0]);
    assert.equal(await h.count("ledger", "idempotencyKey", "refund_e1"), 1);
  });

  test("DT-U03 an order already claimed is never cancelled by this path", async () => {
    await h.seed("deliveries/d1", delivery("Okada", "Medium", { driverId: "bike", status: "driverAssigned" }));
    const d = delivery("Okada", "Medium", { driverId: "bike", status: "driverAssigned" });
    await index.onDeliveryCreated.run({ params: { deliveryId: "d1" }, data: { data: () => d } });
    assert.equal((await h.read("deliveries/d1")).status, "driverAssigned");
  });

  test("DT-U05 with the rollout switch off (default), an older build's booking without a quote is refused", async () => {
    for (const [id, legacy] of [["d1", delivery("Okada", "Small")],
      ["d2", delivery("Mini Truck", "Bulk", { estimatedFare: 100, paymentMethod: "cash" })]]) {
      await h.seed("settings/platform", PLATFORM);
      await h.seed(`deliveries/${id}`, legacy); // priceable, but booked without a quote
      await index.onDeliveryCreated.run({ params: { deliveryId: id }, data: { data: () => legacy } });
      const d = await h.read(`deliveries/${id}`);
      assert.deepEqual([d.status, d.paymentRejectedReason, d.cancellationReason],
        ["cancelled", "quote_required", "quote_not_verified"], id);
    }
    await assertRecipients([], "nobody offered");
  });

  test("DT-U04 the current Passenger app's bookings are never ended this way", async () => {
    for (const [i, [v, t]] of [["Okada", "Small"], ["Aboboya", "Medium"], ["Aboboya", "Large"],
      ["Mini Truck", "Bulk"]].entries()) {
      await run("delivery", `ok${i}`, delivery(v, t));
      assert.equal((await h.read(`deliveries/ok${i}`)).status, "pending", `${v}/${t}`);
    }
  });
});

// ── One job at a time ───────────────────────────────────────────────────────
describe("drivers already on a job", () => {
  const accept = (uid, orderId) => h.callCallable(index.acceptGasOrder, uid, { orderId });

  test("DT-J01 a driver back online mid-job (isAvailable true, currentTripId set) is not offered jobs", async () => {
    await h.db().doc("drivers/bike").update({ currentTripId: "d-active" });
    await run("gas", "g1", gasOrder("newCylinder"));
    await run("delivery", "d1", delivery("Okada", "Small"));
    assert.ok(!(await inboxed(2)).includes("bike"));
  });

  test("DT-J02 ... and cannot accept a gas order", async () => {
    await h.db().doc("drivers/trike").update({ currentTripId: "d-active" });
    await h.seed("gas_orders/g1", gasOrder("newCylinder"));
    assert.deepEqual(outcome(await accept("trike", "g1")), { success: false, reason: "driver_on_job" });
    assert.equal((await h.read("gas_orders/g1")).driverId, null);
  });

  test("DT-J03 one driver accepting two gas orders at once gets only one", async () => {
    await h.seed("gas_orders/g1", gasOrder("newCylinder"));
    await h.seed("gas_orders/g2", gasOrder("newCylinder"));
    const r = await Promise.all([accept("truck", "g1"), accept("truck", "g2")]);
    assert.equal(r.filter((x) => x.success).length, 1, JSON.stringify(r));
    const assigned = [];
    for (const g of ["g1", "g2"]) if ((await h.read(`gas_orders/${g}`)).driverId === "truck") assigned.push(g);
    assert.equal(assigned.length, 1);
    assert.equal((await h.read("drivers/truck")).currentTripId, assigned[0]);
  });

  test("DT-J04 cross-service at once: a delivery claim (Driver App transaction) and a gas acceptance", async () => {
    // The Driver App's delivery claim, as requests_section.dart now runs it:
    // order and driver read and written in one transaction. (Rules are
    // tested separately in rules-tests DSP-S16/S17; Admin SDK here.)
    const claimDelivery = () => h.db().runTransaction(async (tx) => {
      const orderRef = h.db().doc("deliveries/d1");
      const meRef = h.db().doc("drivers/bike");
      const [o, me] = [await tx.get(orderRef), await tx.get(meRef)];
      if (o.get("driverId") != null || me.get("currentTripId") != null) return false;
      tx.update(orderRef, { driverId: "bike", status: "driverAssigned" });
      tx.update(meRef, { isAvailable: false, currentTripId: "d1" });
      return true;
    });
    for (let round = 0; round < 5; round++) {
      await reset(); await seedFleet();
      await h.seed("deliveries/d1", delivery("Okada", "Small"));
      await h.seed("gas_orders/g1", gasOrder("newCylinder"));
      const [delivered, gas] = await Promise.all([claimDelivery(), accept("bike", "g1")]);
      assert.equal([delivered, gas.success].filter(Boolean).length, 1, `round ${round}`);
      const me = await h.read("drivers/bike");
      assert.equal(me.currentTripId, delivered ? "d1" : "g1");
    }
  });

  test("DT-J05 a passenger cancelling an assigned delivery or gas order frees its driver", async () => {
    for (const [coll, id, trigger, param, data] of [
      ["deliveries", "d1", index.onDeliveryStatusChanged, "deliveryId", delivery("Okada", "Small")],
      ["gas_orders", "g1", index.onGasOrderStatusChanged, "orderId", gasOrder("newCylinder")],
    ]) {
      await h.db().doc("drivers/bike").update({ isAvailable: false, currentTripId: id });
      const before = { ...data, driverId: "bike", status: "driverAssigned" };
      const after = { ...before, status: "cancelled" };
      await h.seed(`${coll}/${id}`, after);
      await trigger.run({ params: { [param]: id },
        data: { before: { data: () => before }, after: { data: () => after } } });
      const me = await h.read("drivers/bike");
      assert.deepEqual([me.isAvailable, me.currentTripId], [true, undefined], coll);
    }
  });

  test("DT-J07 a delivery or gas order flagged for review keeps its driver on the job until resolved", async () => {
    for (const [coll, id, trigger, param, data, done] of [
      ["deliveries", "d1", index.onDeliveryStatusChanged, "deliveryId", delivery("Okada", "Small"), "completed"],
      ["gas_orders", "g1", index.onGasOrderStatusChanged, "orderId", gasOrder("newCylinder"), "delivered"],
    ]) {
      await h.db().doc("drivers/bike").update({ isAvailable: false, currentTripId: id });
      const before = { ...data, driverId: "bike", status: done };
      const after = { ...before, status: "flagged" };
      await h.seed(`${coll}/${id}`, after);
      await trigger.run({ params: { [param]: id },
        data: { before: { data: () => before }, after: { data: () => after } } });
      const me = await h.read("drivers/bike");
      assert.deepEqual([me.isAvailable, me.currentTripId], [false, id], coll);
    }
  });

  test("DT-J08 a gas order held for its code (pendingOtp) keeps its driver on the job", async () => {
    await h.db().doc("drivers/bike").update({ isAvailable: false, currentTripId: "g1" });
    const before = { ...gasOrder("newCylinder"), driverId: "bike", status: "delivered" };
    const after = { ...before, status: "pendingOtp" };
    await h.seed("gas_orders/g1", after);
    await index.onGasOrderStatusChanged.run({ params: { orderId: "g1" },
      data: { before: { data: () => before }, after: { data: () => after } } });
    assert.equal((await h.read("drivers/bike")).currentTripId, "g1");
  });

  test("DT-J06 ... but never clears a newer job the driver has since taken", async () => {
    await h.db().doc("drivers/bike").update({ isAvailable: false, currentTripId: "g-new" });
    const before = { ...delivery("Okada", "Small"), driverId: "bike", status: "driverAssigned" };
    const after = { ...before, status: "cancelled" };
    await h.seed("deliveries/d1", after);
    await index.onDeliveryStatusChanged.run({ params: { deliveryId: "d1" },
      data: { before: { data: () => before }, after: { data: () => after } } });
    const me = await h.read("drivers/bike");
    assert.deepEqual([me.isAvailable, me.currentTripId], [false, "g-new"]);
  });
});

// ── Ride and Delivery acceptance (server-authoritative, accept_job.js) ──────
describe("acceptRide and acceptDelivery", () => {
  const acceptRide = (uid, tripId) => h.callCallable(index.acceptRide, uid, { tripId });
  const acceptDelivery = (uid, deliveryId) => h.callCallable(index.acceptDelivery, uid, { deliveryId });
  const EXTRA = {
    taxiOffline: rideDriver("taxiOffline", "taxi", "taxi", { isOnline: false }),
    taxiUnavailable: rideDriver("taxiUnavailable", "taxi", "taxi", { isAvailable: false }),
    taxiUnapproved: rideDriver("taxiUnapproved", "taxi", "taxi", { isApproved: false }),
    taxiOnJob: rideDriver("taxiOnJob", "taxi", "taxi", { currentTripId: "t-active" }),
  };

  test("DT-RA01 each Ride vehicle accepts its own service; trip and driver change together", async () => {
    for (const [uid, service] of [["okadaRide", "okada"], ["taxiRide", "taxi"], ["pragyiaRide", "pragyia"]]) {
      await h.seed(`trips/${service}`, trip(service));
      assert.deepEqual(await acceptRide(uid, service), { success: true, tripId: service }, uid);
      const t = await h.read(`trips/${service}`);
      assert.deepEqual([t.driverId, t.status], [uid, "tripAccepted"]);
      assert.ok(t.acceptedAt);
      const d = await h.read(`drivers/${uid}`);
      assert.deepEqual([d.isAvailable, d.currentTripId, d.currentTripType], [false, service, "trips"]);
    }
  });

  test("DT-RA02 incompatible, unapproved, suspended, offline and busy drivers cannot accept a ride", async () => {
    await seedFleet(EXTRA);
    await h.seed("trips/t1", trip("taxi"));
    for (const [uid, reason, detail] of [
      ["okadaRide", "driver_not_eligible", "wrong_ride_service"],
      ["pragyiaAsTaxi", "vehicle_not_eligible", "vehicle_not_eligible"],
      ["taxiNoVehicle", "vehicle_not_eligible", "vehicle_not_eligible"],
      ["bike", "driver_not_eligible", "wrong_service"],
      ["taxiSuspended", "driver_not_eligible", "driver_not_approved"],
      ["taxiUnapproved", "driver_not_eligible", "driver_not_approved"],
      ["taxiOffline", "driver_not_eligible", "driver_unavailable"],
      ["taxiUnavailable", "driver_not_eligible", "driver_unavailable"],
      ["taxiOnJob", "driver_on_job", "driver_on_job"],
      ["nobody", "driver_not_found", undefined],
    ]) {
      const r = await acceptRide(uid, "t1");
      assert.deepEqual([r.success, r.reason, r.detail], [false, reason, detail], uid);
    }
    assert.equal((await h.read("trips/t1")).driverId, null);
  });

  test("DT-RA03 a driver outside the radius, or with no usable location, cannot accept", async () => {
    await h.seed("trips/t1", trip("taxi"));
    await h.seed("deliveries/d1", delivery("Okada", "Small"));
    await h.seed("gas_orders/g1", gasOrder("newCylinder"));
    for (const [call, uid, id] of [
      [acceptRide, "taxiFar", "t1"], [acceptRide, "taxiZeroLocation", "t1"],
      [acceptDelivery, "bikeFar", "d1"], [acceptDelivery, "bikeNoLocation", "d1"],
      [(u, i) => h.callCallable(index.acceptGasOrder, u, { orderId: i }), "bikeFar", "g1"],
    ]) {
      assert.equal((await call(uid, id)).reason, "outside_radius", uid);
    }
    await h.db().doc("drivers/taxiRide").update({ location: JUST_OUTSIDE });
    assert.equal((await acceptRide("taxiRide", "t1")).reason, "outside_radius");
    await h.db().doc("drivers/taxiRide").update({ location: ON_BOUNDARY });
    assert.equal((await acceptRide("taxiRide", "t1")).success, true);
  });

  test("DT-DA01 each Delivery vehicle accepts the tiers it carries", async () => {
    for (const [uid, vehicle, tier] of [["bike", "Okada", "Small"], ["trike", "Aboboya", "Medium"],
      ["trike", "Aboboya", "Large"], ["truck", "Mini Truck", "Bulk"]]) {
      await h.db().doc(`drivers/${uid}`).update({ currentTripId: h.admin.firestore.FieldValue.delete(),
        isAvailable: true });
      const id = `${uid}-${tier}`;
      await h.seed(`deliveries/${id}`, h.deliveryStamped(delivery(vehicle, tier)));
      assert.deepEqual(await acceptDelivery(uid, id), { success: true, deliveryId: id }, id);
      const o = await h.read(`deliveries/${id}`);
      assert.deepEqual([o.driverId, o.status], [uid, "driverAssigned"]);
      assert.equal((await h.read(`drivers/${uid}`)).currentTripId, id);
    }
  });

  test("DT-DA02 parcel limits are enforced at acceptance, not only in the app", async () => {
    // Booked on a vehicle that cannot carry its tier (older Passenger builds):
    // nobody may take it.
    await h.seed("deliveries/over", delivery("Okada", "Large"));
    for (const uid of ["bike", "trike", "truck"]) {
      const r = await acceptDelivery(uid, "over");
      assert.deepEqual([r.reason, r.detail], ["order_unavailable", "vehicle_cannot_carry_weight_tier"], uid);
    }
    // A different vehicle from the one booked, or a Ride driver.
    await h.seed("deliveries/small", delivery("Okada", "Small"));
    for (const [uid, reason] of [["trike", "vehicle_not_eligible"], ["truck", "vehicle_not_eligible"],
      ["okadaRide", "driver_not_eligible"]]) {
      assert.equal((await acceptDelivery(uid, "small")).reason, reason, uid);
    }
    await h.seed("deliveries/bulk", delivery("Mini Truck", "Bulk"));
    assert.equal((await acceptDelivery("trike", "bulk")).reason, "vehicle_not_eligible");
    for (const id of ["over", "small", "bulk"]) assert.equal((await h.read(`deliveries/${id}`)).driverId, null);
  });

  test("DT-DA03 unapproved, suspended, offline and busy Delivery drivers cannot accept", async () => {
    await h.seed("deliveries/d1", delivery("Okada", "Small"));
    for (const [uid, reason] of [["bikeUnapproved", "driver_not_eligible"],
      ["bikeSuspended", "driver_not_eligible"], ["bikeOffline", "driver_not_eligible"],
      ["bikeBusy", "driver_not_eligible"], ["noRole", "driver_not_eligible"]]) {
      assert.equal((await acceptDelivery(uid, "d1")).reason, reason, uid);
    }
    await h.db().doc("drivers/bike").update({ currentTripId: "g-active" });
    assert.equal((await acceptDelivery("bike", "d1")).reason, "driver_on_job");
  });

  test("DT-RA04 two drivers claiming one ride at once: exactly one wins", async () => {
    await h.seed("drivers/taxi2", rideDriver("taxi2", "taxi", "taxi"));
    await h.seed("trips/t1", trip("taxi"));
    const r = await Promise.all([acceptRide("taxiRide", "t1"), acceptRide("taxi2", "t1")]);
    assert.equal(r.filter((x) => x.success).length, 1, JSON.stringify(r));
    const t = await h.read("trips/t1");
    const busy = [];
    for (const d of ["taxiRide", "taxi2"]) if ((await h.read(`drivers/${d}`)).currentTripId === "t1") busy.push(d);
    assert.deepEqual(busy, [t.driverId]);
  });

  test("DT-JB01 one Delivery driver accepting a delivery and a gas order at once gets only one", async () => {
    for (let round = 0; round < 5; round++) {
      await reset(); await seedFleet();
      await h.seed("deliveries/d1", delivery("Okada", "Small"));
      await h.seed("gas_orders/g1", gasOrder("newCylinder"));
      const [d, g] = await Promise.all([acceptDelivery("bike", "d1"),
        h.callCallable(index.acceptGasOrder, "bike", { orderId: "g1" })]);
      assert.equal([d.success, g.success].filter(Boolean).length, 1, `round ${round}`);
      const held = [];
      if ((await h.read("deliveries/d1")).driverId === "bike") held.push("d1");
      if ((await h.read("gas_orders/g1")).driverId === "bike") held.push("g1");
      assert.deepEqual(held, [(await h.read("drivers/bike")).currentTripId], `round ${round}`);
    }
  });

  test("DT-JB02 a driver back online mid-ride is offered no ride and cannot accept one", async () => {
    await h.db().doc("drivers/taxiRide").update({ currentTripId: "t-active", isOnline: true, isAvailable: true });
    await run("ride", "t1", trip("taxi"));
    assert.ok(!(await inboxed()).includes("taxiRide"));
    assert.equal((await acceptRide("taxiRide", "t1")).reason, "driver_on_job");
    assert.equal((await h.read("drivers/taxiRide")).currentTripId, "t-active");
  });

  test("DT-RA05 malformed and signed-out calls are refused", async () => {
    await assert.rejects(acceptRide(null, "t1"), /signed in/);
    await assert.rejects(acceptRide("taxiRide", ""), /tripId is required/);
    await assert.rejects(acceptDelivery("bike", "deliveries/x"), /deliveryId is required/);
    await assert.rejects(h.callCallable(index.acceptRide, "taxiRide", { orderId: "t1" }), /tripId is required/);
  });
});

// ── Notification, list and acceptance agree ─────────────────────────────────
// Every driver dispatch notifies can accept, and every driver it does not
// notify is refused, for each service and each kind of job. (The Driver
// App's list applies the same policy: dispatch_eligibility_test.dart runs
// the same cases from test/fixtures/eligibility_cases.json.)
describe("dispatch and acceptance agree", () => {
  const callables = {
    ride: (uid, id) => h.callCallable(index.acceptRide, uid, { tripId: id }),
    delivery: (uid, id) => h.callCallable(index.acceptDelivery, uid, { deliveryId: id }),
    gas: (uid, id) => h.callCallable(index.acceptGasOrder, uid, { orderId: id }),
  };
  const coll = { ride: "trips", delivery: "deliveries", gas: "gas_orders" };
  const JOBS = [
    ["ride", trip("okada")], ["ride", trip("taxi")], ["ride", trip("pragyia")],
    ["delivery", delivery("Okada", "Small")], ["delivery", delivery("Aboboya", "Medium")],
    ["delivery", delivery("Aboboya", "Large")], ["delivery", delivery("Mini Truck", "Bulk")],
    ["delivery", delivery("Okada", "Medium")],
    ["gas", gasOrder("exchangeEmpty")], ["gas", gasOrder("pickupAndReturn")],
    ["gas", gasOrder("commercialBulk")],
  ];

  for (const [kind, job] of JOBS) {
    const label = `${kind} ${job.serviceType ?? job.vehicleType ?? ""} ${job.weightTier ?? job.refillType ?? ""}`;
    test(`DT-AG ${label}: notified ⇔ may accept`, async () => {
      await run(kind, "j", job);
      const notified = new Set(await inboxed());
      // The order as the create trigger left it (deliveries: quoted and verified).
      const placed = await h.read(`${coll[kind]}/j`);
      for (const uid of Object.keys(FLEET)) {
        await reset(); await seedFleet();
        await h.seed(`${coll[kind]}/j`, placed);
        const r = await callables[kind](uid, "j");
        assert.equal(r.success, notified.has(uid), `${label} ${uid}: ${JSON.stringify(r)}`);
      }
    });
  }
});

// ── Ending a job frees the driver only from that job ───────────────────────
describe("driver release", () => {
  const tripEvent = (before, after) => index.onTripStatusChanged.run({ params: { tripId: "t-old" },
    data: { before: { data: () => before }, after: { data: () => after } } });
  const assigned = { ...trip("taxi"), driverId: "taxiRide", status: "tripStarted" };

  for (const status of ["completed", "cancelledByPassenger", "cancelledByDriver", "cancelled"]) {
    test(`DT-RL ride ${status}: the driver's newer job is kept`, async () => {
      await h.db().doc("drivers/taxiRide").update({ isAvailable: false, currentTripId: "t-new" });
      await tripEvent(assigned, { ...assigned, status });
      const d = await h.read("drivers/taxiRide");
      assert.deepEqual([d.isAvailable, d.currentTripId], [false, "t-new"]);
    });

    test(`DT-RL ride ${status}: the driver is freed from this trip`, async () => {
      await h.db().doc("drivers/taxiRide").update({ isAvailable: false, currentTripId: "t-old" });
      await tripEvent(assigned, { ...assigned, status });
      const d = await h.read("drivers/taxiRide");
      assert.deepEqual([d.isAvailable, d.currentTripId], [true, undefined]);
    });
  }

  test("DT-RL a repeat of an ended status changes nothing", async () => {
    await h.db().doc("drivers/taxiRide").update({ isAvailable: false, currentTripId: "t-old" });
    const done = { ...assigned, status: "completed" };
    await tripEvent(done, { ...done, status: "flagged" });
    assert.equal((await h.read("drivers/taxiRide")).currentTripId, "t-old");
  });

  test("DT-RL a delivery cancelled after the driver moved on keeps the newer job", async () => {
    await h.db().doc("drivers/bike").update({ isAvailable: false, currentTripId: "g-new" });
    const before = { ...delivery("Okada", "Small"), driverId: "bike", status: "packagePicked" };
    await index.onDeliveryStatusChanged.run({ params: { deliveryId: "d-old" },
      data: { before: { data: () => before }, after: { data: () => ({ ...before, status: "cancelled" }) } } });
    assert.equal((await h.read("drivers/bike")).currentTripId, "g-new");
  });
});

describe("driverLocationStale", () => {
  const NOW = 1_800_000_000_000;
  const MAX = policy.LINKED_RIDER_LOCATION_MAX_AGE_MS;
  const at = (ms) => ({ lastLocationUpdate: Timestamp.fromMillis(ms) });

  test("DP-LS01 up to 10 minutes old is fresh, one ms beyond is stale", () => {
    assert.equal(MAX, 600000);
    assert.equal(policy.driverLocationStale(at(NOW - 9 * 60000), NOW, MAX), null);
    assert.equal(policy.driverLocationStale(at(NOW - 600000), NOW, MAX), null);
    assert.equal(policy.driverLocationStale(at(NOW - 600001), NOW, MAX), "driver_location_stale");
  });

  test("DP-LS02 a missing, null, malformed or future timestamp is stale", () => {
    for (const d of [null, {}, { lastLocationUpdate: null }, { lastLocationUpdate: NOW },
      { lastLocationUpdate: "x" }, { lastLocationUpdate: { toMillis: () => NaN } }, at(NOW + 60001)]) {
      assert.equal(policy.driverLocationStale(d, NOW, MAX), "driver_location_stale");
    }
    assert.equal(policy.driverLocationStale(at(NOW + 60000), NOW, MAX), null);
  });
});
