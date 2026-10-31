// Release v5 round 3: server-authoritative Delivery pricing — road route from
// a routing provider (stubbed here; Google Routes API v2 in production), the
// approved rate card in integer pesewas, immutable server quotes, and their
// use by order creation, hold linking, offers, acceptance and settlement.
// Firestore emulator only. No real routing request is made.

"use strict";

const { test, describe, after, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");
const { Timestamp, GeoPoint } = require("firebase-admin/firestore");
const h = require("./helpers");
const pricing = require("../../delivery_pricing");
const quotes = require("../../delivery_quotes");
const notifications = require("../../notifications");
const trips = require("../../trips");
const escrow = require("../../escrow");
const { acceptJob } = require("../../accept_job");

const P = "dq-passenger";
const P2 = "dq-other";
const D = "dq-driver";
const A = { latitude: 5.55671, longitude: -0.18234 };
const B = { latitude: 5.60372, longitude: -0.18691 };
const PLATFORM = { platformFeePercent: 15, delivery: h.DELIVERY_RATES };
const card = () => pricing.readRateCard(PLATFORM).card;

const quote = (data, uid = P) => h.callCallable(quotes.quoteDelivery, uid, data);
const hold = (data, uid = P) => h.callCallable(escrow.holdBalance, uid, data);
const attach = (data, uid = P) => h.callCallable(escrow.attachEscrowToOrder, uid, data);
const parcel = (o = {}) => ({ pickup: A, dropoff: B, vehicleType: "Okada", weightTier: "Small",
  isFragile: false, requiresHelpers: false, ...o });
const driver = () => ({ uid: D, role: "driver_delivery", serviceType: "delivery", vehicleType: "motorcycle",
  isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true,
  location: new GeoPoint(A.latitude, A.longitude), lastLocationUpdate: Timestamp.now() });

/** The order Passenger 1.0.1 writes for quote [q] (returned by quoteDelivery). */
const orderFor = (q, p = parcel(), o = {}) => ({ passengerId: P, driverId: null, status: "pending",
  vehicleType: q.vehicleType, weightTier: p.weightTier, isFragile: p.isFragile, requiresHelpers: p.requiresHelpers,
  pickupLocation: new GeoPoint(p.pickup.latitude, p.pickup.longitude),
  dropoffLocation: new GeoPoint(p.dropoff.latitude, p.dropoff.longitude),
  pickupAddress: "12 Oxford St, Osu, Accra", dropoffAddress: "7 Ring Rd, Adabraka, Accra",
  parcelType: "Documents", estimatedFare: q.total, paymentMethod: "cash", deliveryQuoteId: q.quoteId,
  createdAt: Timestamp.now(), ...o });

async function create(id, order) {
  await h.seed(`deliveries/${id}`, order);
  await notifications.onDeliveryCreated.run({ params: { deliveryId: id }, data: { data: () => order } });
  return h.read(`deliveries/${id}`);
}

let routeCalls;
/** Stub provider: [meters] for every route (or a function of the endpoints). */
function routeIs(meters) {
  routeCalls = [];
  quotes._setRouteProviderForTests(async (p, d) => {
    routeCalls.push([p, d]);
    if (meters instanceof Error) throw meters;
    return { distanceMeters: typeof meters === "function" ? meters(p, d) : meters, durationSeconds: 600 };
  });
}

after(() => { quotes._setRouteProviderForTests(null); return h.fft.cleanup(); });
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed("settings/platform", PLATFORM);
  await h.seed(`wallets/${P}`, { balance: 1000, heldBalance: 0 });
  await h.seed(`drivers/${D}`, driver());
  routeIs(10000);
});
afterEach(() => quotes._setRouteProviderForTests(null));

describe("DQ pricing (pure)", () => {
  test("DQ-01 every vehicle and tier, short and long routes, minimum and surcharges, in pesewas", () => {
    // Test rate card = the app's built-in defaults: Okada 5 + 2.50/km, min 10; Aboboya 15 + 4/km, min 20;
    // Mini Truck 40 + 7/km, min 50; Medium +5, Large +15, fragile +5, helpers +10.
    const cases = [
      ["okada", "Small", 500, false, false, 1000, true],     // 5 + 1.25 = 6.25 → minimum 10
      ["okada", "Small", 10000, false, false, 3000, false],  // 5 + 25
      ["okada", "Small", 30000, true, true, 9500, false],    // 5 + 75 + 5 + 10
      ["aboboya", "Medium", 2000, false, false, 2800, false], // 15 + 8 + 5
      ["aboboya", "Medium", 100, false, false, 2040, false],  // 15 + 0.40 + 5 = 20.40 (just above the minimum)
      ["aboboya", "Large", 50000, false, true, 24000, false], // 15 + 200 + 15 + 10
      ["miniTruck", "Bulk", 1000, false, false, 5000, true],  // 40 + 7 = 47 → minimum 50
      ["miniTruck", "Bulk", 120000, true, false, 88500, false], // 40 + 840 + 0 + 5
    ];
    for (const [v, tier, m, fragile, helpers, total, minimumApplied] of cases) {
      const p = pricing.priceDelivery({ vehicleKey: v, weightTier: tier, distanceMeters: m, isFragile: fragile,
        requiresHelpers: helpers }, card());
      assert.equal(p.ok, true);
      assert.deepEqual([p.total, p.minimumApplied], [total, minimumApplied], `${v} ${tier} ${m}`);
      assert.equal(p.commission, Math.floor((total * 1500 * 2 + 10000) / 20000));
      assert.equal(p.driverNet, total - p.commission);
      assert.ok(Number.isInteger(p.total) && Number.isInteger(p.commission));
    }
  });

  test("DQ-02 distance rounding: per-km × metres / 1000, half up to the pesewa; metres never rounded", () => {
    const at = (m) => pricing.priceDelivery({ vehicleKey: "okada", weightTier: "Small", distanceMeters: m,
      isFragile: false, requiresHelpers: false }, card()).items.distance;
    assert.equal(at(9998), 2500, "2499.5 → 2500");
    assert.equal(at(9997), 2499, "2499.25 → 2499");
    assert.equal(at(1), 0, "0.25 → 0");
    assert.equal(at(2), 1, "0.5 → 1");
    assert.equal(at(0), 0);
    assert.equal(pricing.priceDelivery({ vehicleKey: "okada", weightTier: "Small", distanceMeters: 10.5,
      isFragile: false, requiresHelpers: false }, card()).reason, "distance_invalid");
  });

  test("DQ-03 the rate card must be complete and valid; no built-in fallback", () => {
    const d = h.DELIVERY_RATES;
    const bad = [
      [null, "delivery_config_missing"], [{}, "delivery_config_missing"],
      [{ delivery: { ...d, okada: undefined } }, "delivery_rate_invalid:okada"],
      [{ delivery: { ...d, aboboya: { ...d.aboboya, perKmRate: 0 } } }, "delivery_rate_invalid:aboboya"],
      [{ delivery: { ...d, miniTruck: { ...d.miniTruck, minimumFare: 0 } } }, "delivery_rate_invalid:miniTruck"],
      [{ delivery: { ...d, okada: { ...d.okada, baseFare: -1 } } }, "delivery_rate_invalid:okada"],
      [{ delivery: { ...d, okada: { ...d.okada, perKmRate: "2.5km" } } }, "delivery_rate_invalid:okada"],
      [{ delivery: { ...d, okada: { ...d.okada, perKmRate: Infinity } } }, "delivery_rate_invalid:okada"],
      [{ delivery: { ...d, helperSurcharge: undefined } }, "delivery_rate_invalid:helperSurcharge"],
      [{ delivery: { ...d, weightSurchargeLarge: "x" } }, "delivery_rate_invalid:weightSurchargeLarge"],
      [{ delivery: d, platformFeePercent: 150 }, "platform_fee_invalid"],
    ];
    for (const [s, reason] of bad) assert.equal(pricing.readRateCard(s).reason, reason, JSON.stringify(s));
    const strings = pricing.readRateCard({ delivery: { ...d, okada: { baseFare: "5", perKmRate: "2.50", minimumFare: "10" } } });
    assert.equal(strings.ok, true, "numeric strings are read as numbers");
    assert.equal(strings.version, pricing.readRateCard({ delivery: d }).version, "same card, same version");
    assert.notEqual(pricing.readRateCard({ delivery: { ...d, helperSurcharge: 11 } }).version,
      pricing.readRateCard({ delivery: d }).version, "any rate change changes the version");
  });

  test("DQ-04 package and point validation", () => {
    for (const [inputs, reason] of [
      [{ vehicleKey: "okada", weightTier: "Medium" }, "vehicle_not_eligible"],
      [{ vehicleKey: "miniTruck", weightTier: "Small" }, "vehicle_not_eligible"],
      [{ vehicleKey: null, weightTier: "Small" }, "vehicle_invalid"],
      [{ vehicleKey: "okada", weightTier: "small" }, "weight_tier_invalid"],
      [{ vehicleKey: "okada", weightTier: "Small", isFragile: "yes" }, "options_invalid"],
    ]) {
      assert.equal(pricing.inputProblem({ isFragile: false, requiresHelpers: false, ...inputs }), reason);
    }
    for (const p of [null, {}, { latitude: NaN, longitude: 0 }, { latitude: 91, longitude: 0 },
      { latitude: 0, longitude: 181 }, { latitude: 0, longitude: 0 }, { latitude: "5.5", longitude: -0.1 },
      { latitude: Infinity, longitude: 1 }]) {
      assert.equal(pricing.validPoint(p), null, JSON.stringify(p));
    }
    assert.deepEqual(pricing.validPoint({ latitude: -89.9, longitude: 179.9, extra: 1 }),
      { latitude: -89.9, longitude: 179.9 }, "extreme but valid points go to the routing provider");
  });
});

describe("DQ routing provider (Google Routes API v2 request/response handling)", () => {
  const ok = (body, status = 200) => async () => ({ ok: status === 200, status, json: async () => body });
  const route = (fetchImpl, apiKey = "k") => pricing.googleRouteDistance(A, B, { apiKey, fetchImpl });
  const reason = async (p) => { try { await p; return "no error"; } catch (e) { return e.reason; } };

  test("DQ-10 a route's distance is read in whole metres; the key travels in a header, not the URL", async () => {
    let seen;
    const r = await route(async (url, init) => { seen = { url, init }; return ok({ routes: [{ distanceMeters: 12345, duration: "900s" }] })(); });
    assert.deepEqual(r, { distanceMeters: 12345, durationSeconds: 900 });
    assert.equal(seen.url, pricing.ROUTES_URL);
    assert.ok(!seen.url.includes("k"), "no key in the URL");
    assert.equal(seen.init.headers["X-Goog-Api-Key"], "k");
    assert.equal(seen.init.headers["X-Goog-FieldMask"], "routes.distanceMeters,routes.duration");
    const body = JSON.parse(seen.init.body);
    assert.deepEqual([body.travelMode, body.routingPreference], ["DRIVE", "TRAFFIC_UNAWARE"]);
    assert.deepEqual(body.origin.location.latLng, A);
  });

  test("DQ-11 every provider failure is an error, never an estimate", async () => {
    assert.equal(await reason(route(ok({}))), "route_unavailable");
    assert.equal(await reason(route(ok({ routes: [] }))), "route_unavailable");
    assert.equal(await reason(route(ok({ error: {} }, 403))), "routing_http_403");
    assert.equal(await reason(route(ok({}, 500))), "routing_http_500");
    assert.equal(await reason(route(ok({ routes: [{ distanceMeters: -5 }] }))), "route_distance_invalid");
    assert.equal(await reason(route(ok({ routes: [{ distanceMeters: 12.5 }] }))), "route_distance_invalid");
    assert.equal(await reason(route(ok({ routes: [{}] }))), "route_distance_invalid");
    assert.equal(await reason(route(async () => ({ ok: true, status: 200, json: async () => { throw new SyntaxError("x"); } }))),
      "routing_failed");
    assert.equal(await reason(route(async () => { throw Object.assign(new Error("t"), { name: "TimeoutError" }); })),
      "routing_timeout");
    assert.equal(await reason(route(async () => { throw new TypeError("network"); })), "routing_failed");
    assert.equal(await reason(route(ok({ routes: [{ distanceMeters: 1 }] }), "")), "routing_not_configured");
  });

  test("DQ-12 a slow provider is cut off by the timeout", async () => {
    const slow = (url, init) => new Promise((_, reject) =>
      init.signal.addEventListener("abort", () => reject(init.signal.reason)));
    const t0 = Date.now();
    const r = await reason(pricing.googleRouteDistance(A, B, { apiKey: "k", fetchImpl: slow, timeoutMs: 50 }));
    assert.equal(r, "routing_timeout");
    assert.ok(Date.now() - t0 < 2000);
  });
});

describe("DQ quoteDelivery callable", () => {
  test("DQ-20 stores an immutable server quote and returns its itemised price", async () => {
    const q = await quote(parcel());
    assert.deepEqual([q.total, q.distanceKm, q.baseFare, q.distanceCharge, q.minimumApplied], [30, 10, 5, 25, false]);
    const stored = await h.read(`delivery_quotes/${q.quoteId}`);
    assert.equal(stored.passengerId, P);
    assert.equal(stored.distanceMeters, 10000);
    assert.equal(stored.totalPesewas, 3000);
    assert.equal(stored.commissionPesewas, 450);
    assert.equal(stored.pricingVersion, "delivery-v2");
    assert.equal(stored.rateCardVersion, pricing.readRateCard(PLATFORM).version);
    assert.deepEqual([stored.pickup.latitude, stored.dropoff.longitude], [A.latitude, B.longitude]);
    assert.equal(stored.usedBy, null);
    assert.equal(stored.expiresAt.toMillis() - stored.createdAt.toMillis(), pricing.QUOTE_TTL_MS);
    assert.deepEqual(routeCalls, [[A, B]], "the route was measured once, on the server");
  });

  test("DQ-21 routing failures and timeouts return no price and store nothing", async () => {
    for (const r of ["routing_timeout", "routing_http_403", "route_unavailable", "routing_not_configured"]) {
      routeIs(new pricing.RoutingError(r));
      await assert.rejects(quote(parcel()), (e) => e.code === "unavailable" && e.details?.reason === r, r);
    }
    routeIs(() => 12.5);
    await assert.rejects(quote(parcel()), (e) => e.details?.reason === "route_distance_invalid");
    assert.equal((await h.db().collection("delivery_quotes").get()).size, 0);
  });

  test("DQ-22 missing or malformed rates: no quote, and the provider is not even called", async () => {
    for (const s of [{ platformFeePercent: 15 }, { delivery: { ...h.DELIVERY_RATES, okada: { baseFare: 5 } } }]) {
      await h.seed("settings/platform", s);
      routeIs(10000);
      await assert.rejects(quote(parcel()), (e) => e.code === "failed-precondition" &&
        e.details?.reason === "pricing_unavailable");
      assert.equal(routeCalls.length, 0);
    }
    assert.equal((await h.db().collection("delivery_quotes").get()).size, 0);
  });

  test("DQ-23 invalid input and signed-out callers are refused before routing", async () => {
    await assert.rejects(quote(parcel(), null), (e) => e.code === "unauthenticated");
    for (const [o, reason] of [[{ pickup: { latitude: 95, longitude: 0 } }, "point_invalid"],
      [{ dropoff: null }, "point_invalid"], [{ vehicleType: "Okada", weightTier: "Bulk" }, "vehicle_not_eligible"],
      [{ vehicleType: "Helicopter" }, "vehicle_invalid"], [{ isFragile: 1 }, "options_invalid"],
      [{ distanceKm: 0.1, estimatedFare: 1, vehicleType: "Okada" }, null]]) {
      if (reason === null) continue; // client distance/fee fields are simply ignored (DQ-24)
      await assert.rejects(quote(parcel(o)), (e) => e.code === "invalid-argument" && e.details?.reason === reason, reason);
    }
    assert.equal(routeCalls.length, 0);
  });

  test("DQ-24 a client-supplied distance or fee is ignored; concurrent requests give independent identical quotes", async () => {
    const [a, b, c] = await Promise.all([quote(parcel({ distanceKm: 0.1, estimatedFare: 1, total: 1 })),
      quote(parcel()), quote(parcel())]);
    assert.deepEqual([a.total, b.total, c.total], [30, 30, 30]);
    assert.equal(new Set([a.quoteId, b.quoteId, c.quoteId]).size, 3);
  });
});

describe("DQ order creation checks the quote", () => {
  test("DQ-30 a matching order is stamped, its quote marked used, and it is offered at the quote total", async () => {
    const q = await quote(parcel());
    const o = await create("d1", orderFor(q));
    assert.equal(o.status, "pending");
    assert.deepEqual([o.verifiedPrice.version, o.verifiedPrice.quoteId, o.verifiedPrice.totalPesewas,
      o.verifiedPrice.commissionPesewas], ["delivery-v2", q.quoteId, 3000, 450]);
    assert.equal((await h.read(`delivery_quotes/${q.quoteId}`)).usedBy, "d1");
    assert.equal((await h.read("delivery_offers/d1")).fare, 30);
  });

  test("DQ-31 tampered fare, vehicle, weight, options or endpoints are cancelled before anyone sees them", async () => {
    const tamper = {
      fareUp: [{ estimatedFare: 31 }, "price_mismatch"], fareDown: [{ estimatedFare: 29.99 }, "price_mismatch"],
      fragile: [{ isFragile: true }, "quote_mismatch"], helpers: [{ requiresHelpers: true }, "quote_mismatch"],
      pickup: [{ pickupLocation: new GeoPoint(A.latitude + 0.000001, A.longitude) }, "quote_mismatch"],
      dropoff: [{ dropoffLocation: new GeoPoint(B.latitude, B.longitude + 0.01) }, "quote_mismatch"],
      otherPassenger: [{ passengerId: P2 }, "quote_invalid"], missingQuote: [{ deliveryQuoteId: "nope" }, "quote_invalid"],
      badId: [{ deliveryQuoteId: "a/b" }, "quote_invalid"], numberId: [{ deliveryQuoteId: 7 }, "quote_invalid"],
    };
    for (const [name, [o, reason]] of Object.entries(tamper)) {
      const q = await quote(parcel());
      const d = await create(`d-${name}`, orderFor(q, parcel(), o));
      assert.deepEqual([d.status, d.paymentRejectedReason, d.cancellationReason],
        ["cancelled", reason, "quote_not_verified"], name);
      assert.equal(d.verifiedPrice, undefined, name);
      assert.equal(await h.read(`delivery_offers/d-${name}`), null, name);
    }
    // Same vehicle, other tier it also carries (Aboboya Medium quote, Large order).
    const qa = await quote(parcel({ vehicleType: "Aboboya", weightTier: "Medium" }));
    const large = await create("d-tier", orderFor(qa, parcel({ weightTier: "Medium" }), { weightTier: "Large" }));
    assert.deepEqual([large.status, large.paymentRejectedReason], ["cancelled", "quote_mismatch"]);
    // Another vehicle (or tier) than the quote's: one vehicle per tier, so the booking is one
    // no vehicle may carry — ended with that reason before pricing, never stamped or offered.
    for (const [name, o] of [["vehicle", { vehicleType: "Aboboya" }], ["weight", { weightTier: "Medium" }]]) {
      const q = await quote(parcel());
      const d = await create(`d-${name}`, orderFor(q, parcel(), o));
      assert.deepEqual([d.status, d.statusReason], ["cancelled", "vehicle_cannot_carry_weight_tier"], name);
      assert.equal(d.verifiedPrice, undefined, name);
      assert.equal(await h.read(`delivery_offers/d-${name}`), null, name);
      assert.equal((await acceptJob("delivery", D, `d-${name}`)).success, false, name);
    }
  });

  test("DQ-32 an order placed after the quote expired is cancelled", async () => {
    const q = await quote(parcel());
    const late = Timestamp.fromMillis(q.expiresAtMillis + 1000);
    const d = await create("d1", orderFor(q, parcel(), { createdAt: late }));
    assert.equal(d.paymentRejectedReason, "quote_expired");
  });

  test("DQ-33 rates changed after the quote: cancelled 'price_changed', the customer is asked to confirm a new price", async () => {
    const q = await quote(parcel());
    await h.seed("settings/platform", { ...PLATFORM, delivery: { ...h.DELIVERY_RATES,
      okada: { ...h.DELIVERY_RATES.okada, perKmRate: 3 } } });
    const order = orderFor(q);
    const d = await create("d1", order);
    assert.deepEqual([d.status, d.cancellationReason, d.estimatedFare], ["cancelled", "price_changed", 30],
      "never re-priced upward silently");
    await notifications.onDeliveryStatusChanged.run({ params: { deliveryId: "d1" },
      data: { before: { data: () => order }, after: { data: () => d } } });
    const items = (await h.db().collection(`notifications/${P}/items`).get()).docs.map((x) => x.data());
    assert.ok(items.some((i) => /price needs to be confirmed again/.test(i.body) && /Nothing was charged/.test(i.body)));
    // Even a lower new price is not applied silently.
    const q2 = await quote(parcel());
    await h.seed("settings/platform", { ...PLATFORM, delivery: { ...h.DELIVERY_RATES,
      okada: { ...h.DELIVERY_RATES.okada, perKmRate: 2 } } });
    assert.equal((await create("d2", orderFor(q2))).cancellationReason, "price_changed");
  });

  test("DQ-34 one quote, two orders at once: exactly one is placed, the other refused", async () => {
    const q = await quote(parcel());
    const a = orderFor(q); const b = orderFor(q);
    await h.seed("deliveries/a", a); await h.seed("deliveries/b", b);
    await Promise.all([
      notifications.onDeliveryCreated.run({ params: { deliveryId: "a" }, data: { data: () => a } }),
      notifications.onDeliveryCreated.run({ params: { deliveryId: "b" }, data: { data: () => b } }),
    ]);
    const [da, db] = [await h.read("deliveries/a"), await h.read("deliveries/b")];
    const statuses = [da.status, db.status].sort();
    assert.deepEqual(statuses, ["cancelled", "pending"]);
    const loser = da.status === "cancelled" ? da : db;
    assert.equal(loser.paymentRejectedReason, "quote_reused");
    assert.equal((await h.read(`delivery_quotes/${q.quoteId}`)).usedBy, da.status === "pending" ? "a" : "b");
  });

  test("DQ-35 a redelivered create event changes nothing", async () => {
    const q = await quote(parcel());
    const order = orderFor(q);
    const first = await create("d1", order);
    await Promise.all([1, 2].map(() =>
      notifications.onDeliveryCreated.run({ params: { deliveryId: "d1" }, data: { data: () => order } })));
    const again = await h.read("deliveries/d1");
    assert.deepEqual(again.verifiedPrice, first.verifiedPrice);
    assert.equal(again.status, "pending");
    assert.equal((await h.db().collection(`drivers/${D}/notifications`).get()).size, 1);
  });

  test("DQ-36 orders without a quote: refused by default; with the rollout switch only cash at the straight-line floor", async () => {
    const legacy = (o = {}) => ({ ...orderFor({ vehicleType: "Okada", total: 30, quoteId: "x" }), ...o });
    const noQuote = (o) => { const x = legacy(o); delete x.deliveryQuoteId; return x; };
    assert.equal((await create("d0", noQuote())).paymentRejectedReason, "quote_required");
    await h.seed("app_config/pricing", { legacyUnquotedDeliveries: true });
    const ok = await create("d1", noQuote());
    assert.deepEqual([ok.status, ok.verifiedPrice.version], ["pending", "delivery-legacy-floor"]);
    assert.equal((await create("d2", noQuote({ estimatedFare: 1 }))).paymentRejectedReason, "price_below_minimum");
    assert.equal((await create("d3", noQuote({ paymentMethod: "wallet" }))).paymentRejectedReason, "quote_required");
    for (const v of ["true", 1, false]) {
      await h.seed("app_config/pricing", { legacyUnquotedDeliveries: v });
      assert.equal((await create(`d-${v}`, noQuote())).paymentRejectedReason, "quote_required", String(v));
    }
  });
});

describe("DQ acceptance, holds, settlement", () => {
  test("DQ-40 an order without a verified price cannot be accepted", async () => {
    const q = await quote(parcel());
    await h.seed("deliveries/d1", orderFor(q)); // trigger has not run
    assert.equal((await acceptJob("delivery", D, "d1")).detail, "price_not_verified");
    await create("d1", orderFor(q));
    assert.equal((await acceptJob("delivery", D, "d1")).success, true);
  });

  test("DQ-41 a wallet hold links only to its own quote, at exactly its total", async () => {
    await h.enableDeliveryGasWallet();
    const q = await quote(parcel());
    const o = orderFor(q, parcel(), { paymentMethod: "wallet" });
    for (const [name, amount, order, uid, reason] of [
      ["wrong amount", 31, o, P, "hold_amount_mismatch"],
      ["no quote", 30, { ...o, deliveryQuoteId: undefined }, P, "quote_required"],
    ]) {
      await h.seed(`wallets/${uid}`, { balance: 1000, heldBalance: 0 });
      const r = await hold({ amount, serviceType: "x", referenceType: "delivery" }, uid);
      const clean = Object.fromEntries(Object.entries(order).filter(([, v]) => v !== undefined));
      await h.seed(`deliveries/x-${name.replace(" ", "")}`, clean);
      await assert.rejects(attach({ escrowId: r.escrowId, referenceId: `x-${name.replace(" ", "")}`,
        referenceType: "delivery" }, uid), (e) => JSON.stringify(e.details ?? e.message).includes(reason), name);
    }
    // A quote already used by another order.
    await create("used", o);
    const r2 = await hold({ amount: 30, serviceType: "x", referenceType: "delivery" });
    await h.seed("deliveries/second", { ...o });
    await assert.rejects(attach({ escrowId: r2.escrowId, referenceId: "second", referenceType: "delivery" }),
      (e) => JSON.stringify(e.details ?? e.message).includes("quote_reused"));
    // The right one.
    const q3 = await quote(parcel());
    const r3 = await hold({ amount: q3.total, serviceType: "x", referenceType: "delivery" });
    await h.seed("deliveries/good", orderFor(q3, parcel(), { paymentMethod: "wallet" }));
    assert.equal((await attach({ escrowId: r3.escrowId, referenceId: "good", referenceType: "delivery" })).success, true);
  });

  async function complete(id, runs) {
    const before = await h.read(`deliveries/${id}`);
    const afterDoc = { ...before, status: "completed", otpSubmitted: "4821", completedAt: Timestamp.now() };
    await h.seed(`deliveries/${id}`, afterDoc);
    await h.seed(`order_completion_codes/deliveries_${id}`, { code: "4821", passengerId: P });
    const ev = { params: { deliveryId: id }, data: { before: { data: () => ({ ...afterDoc, status: "arrivedAtDropoff" }) },
      after: { data: () => afterDoc } } };
    await Promise.all(Array.from({ length: runs }, () => trips.onDeliveryCompleted.run(ev)));
  }

  test("DQ-42 cash: offer fare = quote total = settled gross; commission from the quote, once", async () => {
    const q = await quote(parcel({ isFragile: true }));
    await create("d1", orderFor(q, parcel({ isFragile: true })));
    const shown = (await h.read("delivery_offers/d1")).fare;
    assert.equal(shown, 35);
    assert.equal((await acceptJob("delivery", D, "d1")).success, true);
    await h.seed("settings/platform", { ...PLATFORM, platformFeePercent: 25 }); // later fee change
    await complete("d1", 3);
    const ledger = await h.read("ledger/commission_delivery_d1");
    assert.ok(ledger, "commission recorded");
    assert.equal(ledger.amount, 5.25, "15 % of the quote total, from the quote (not the later 25 %)");
    const drv = await h.read(`drivers/${D}`);
    assert.deepEqual([drv.totalEarnings, drv.commissionOwed], [shown, 5.25], "credited once over three events");
  });

  test("DQ-43 wallet: hold = quote total = released; cancellation instead refunds exactly the hold, once", async () => {
    await h.enableDeliveryGasWallet();
    for (const [id, cancel] of [["w1", false], ["w2", true]]) {
      const q = await quote(parcel());
      const r = await hold({ amount: q.total, serviceType: "x", referenceType: "delivery" });
      const o = orderFor(q, parcel(), { paymentMethod: "wallet" });
      await create(id, o);
      await attach({ escrowId: r.escrowId, referenceId: id, referenceType: "delivery" });
      const paid = await h.read(`deliveries/${id}`);
      await notifications.onDeliveryPaymentAttached.run({ params: { deliveryId: id },
        data: { before: { data: () => ({ ...paid, escrowId: null }) }, after: { data: () => paid } } });
      assert.equal((await h.read(`delivery_offers/${id}`)).fare, q.total);
      if (cancel) {
        const cancelled = { ...paid, status: "cancelled", cancelledAt: Timestamp.now() };
        await h.seed(`deliveries/${id}`, cancelled);
        const ev = { params: { deliveryId: id }, data: { before: { data: () => paid }, after: { data: () => cancelled } } };
        await trips.onDeliveryCancelled.run(ev);
        await trips.onDeliveryCancelled.run(ev);
        const e = await h.read(`escrows/${r.escrowId}`);
        assert.deepEqual([e.status, e.amount], ["REFUNDED", q.total]);
        assert.equal(await h.count("ledger", "idempotencyKey", `refund_${r.escrowId}`), 1);
      } else {
        await h.db().doc(`drivers/${D}`).update({ isAvailable: true });
        assert.equal((await acceptJob("delivery", D, id)).success, true);
        await complete(id, 3);
        const e = await h.read(`escrows/${r.escrowId}`);
        assert.deepEqual([e.status, e.amount], ["RELEASED", q.total]);
        assert.equal(await h.count("ledger", "idempotencyKey", `capture_${r.escrowId}`), 1);
        assert.equal((await h.read(`deliveries/${id}`)).walletProcessed, true);
      }
    }
  });
});
