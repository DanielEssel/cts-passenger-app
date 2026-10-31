// Gas supplier options, quotes and orders (gas_supplier_orders.js): only
// eligible suppliers are offered, every price comes from the verified
// catalog, the order keeps an immutable snapshot, retries create one order,
// and no payment hold can be attached to a supplier order yet.
// Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const g = require("../../gas_supplier_orders");
const escrow = require("../../escrow");

const { GeoPoint, Timestamp } = h.admin.firestore;
const P = "gso-passenger";
const OTHER = "gso-other";
const S = "sup1", ST = "st1", PID = "exchangeEmpty_kg12_5_goGas";
const STATION_AT = { latitude: 5.6698, longitude: -0.0166 }; // Tema
const NEAR = { latitude: 5.6800, longitude: -0.0100 }; // ~1.3 km away
const FAR = { latitude: 5.6037, longitude: -0.187 }; // Accra, ~20 km away


// The routing provider (Google Routes API in production) is stubbed: every
// station-to-customer route measures ROAD_M metres unless a test says otherwise.
const dq = require("../../delivery_quotes");
const { RoutingError } = require("../../delivery_pricing");
const ROAD_M = 4300;
let routeCalls = 0;
const routeIs = (fn) => dq._setRouteProviderForTests(async (p, d) => { routeCalls++; return fn(p, d); });
const call = (fn, data, uid = P) => h.callCallable(fn, uid, data);
const productPath = (id = PID, st = ST, s = S) => `gas_suppliers/${s}/stations/${st}/products/${id}`;

function supplier(o = {}) {
  return { legalName: "Test Gas Ltd", tradingName: "Test Gas", status: "approved", ordersEnabled: true,
    fulfillment: { exchangeEmpty: true, pickupAndReturn: true }, riderArrangement: "ctsgo_dispatch",
    internalNotes: "PRIVATE NOTE", verificationNotes: "PRIVATE VERIFICATION",
    contact: { name: "Owner", phone: "+233200000000" }, registration: { licenceNo: "LIC-1" }, ...o };
}
function station(o = {}) {
  return { name: "Tema Station", supplierId: S, status: "verified", address: "Community 1, Tema",
    location: new GeoPoint(STATION_AT.latitude, STATION_AT.longitude), serviceRadiusKm: 10,
    supportedSizes: ["kg12_5", "kg6"], fulfillment: { exchangeEmpty: true, pickupAndReturn: true },
    contact: { phone: "+233200000001" }, ...o };
}
function product(o = {}) {
  return { orderType: "exchangeEmpty", cylinderSize: "kg12_5", brand: "goGas", price: 150, handlingFee: 5,
    currency: "GHS", priceVersion: 1, availability: "available", verified: true, ...o };
}

async function seedCatalog({ sup = {}, st = {}, pr = {} } = {}) {
  await h.seed(`gas_suppliers/${S}`, supplier(sup));
  await h.seed(`gas_suppliers/${S}/stations/${ST}`, station(st));
  await h.seed(productPath(), product(pr));
  await h.seed("settings/platform", { platformFeePercent: 15, gas: { baseFare: 8, perKm: 2, minDeliveryFee: 12, roundTripFee: 30 } });
  await h.seedGasCommissionTerms(); // test fixture terms, not a commercial rate
  await h.seed(g.ORDERING_FLAG_DOC, { enabled: true }); // supplier ordering switched on
}

async function quoteFor(o = {}, uid = P) {
  return call(g.quoteGasSupplierOrder, { supplierId: S, stationId: ST, productId: PID, quantity: 2, location: NEAR, address: "My house", ...o }, uid);
}

async function rejects(promise, code, reason) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, e.message);
    if (reason) assert.equal(e.details?.reason, reason, JSON.stringify(e.details));
    return true;
  });
}

after(() => { dq._setRouteProviderForTests(null); return h.fft.cleanup(); });
// Wallet Delivery and Gas are offered once app_config/mobile requires the
// app versions that keep the completion code secret (escrow.js); these tests
// cover that state.
beforeEach(async () => {
  await h.clearFirestore(); await h.enableDeliveryGasWallet();
  await h.seed(g.ORDERING_FLAG_DOC, { enabled: true });
  routeCalls = 0;
  routeIs(() => ({ distanceMeters: ROAD_M, durationSeconds: 600 }));
});

describe("pure rules", () => {
  test("GSO-F01 unsupported order types, sizes, quantities and locations are refused", () => {
    const ok = { orderType: "exchangeEmpty", cylinderSize: "kg12_5", quantity: 1, location: NEAR };
    assert.equal(g.requestProblem(ok), null);
    assert.equal(g.requestProblem({ ...ok, orderType: "refillOnly" }), "unsupported_order_type");
    assert.equal(g.requestProblem({ ...ok, cylinderSize: "small" }), "unsupported_cylinder_size");
    for (const q of [0, -1, 1.5, g.MAX_QUANTITY + 1, "2", null]) assert.equal(g.requestProblem({ ...ok, quantity: q }), "invalid_quantity", String(q));
    for (const l of [null, { latitude: 0, longitude: 0 }, { latitude: 91, longitude: 0 }]) assert.equal(g.requestProblem({ ...ok, location: l }), "invalid_location");
  });

  test("GSO-F02 every readiness condition is checked independently", () => {
    // Plain points here: structuredClone drops a GeoPoint's getters.
    const base = () => ({ supplierId: S, supplier: supplier(), stationId: ST, station: station({ location: { ...STATION_AT } }), productId: PID, product: product() });
    const want = { orderType: "exchangeEmpty", cylinderSize: "kg12_5", location: NEAR };
    assert.equal(g.optionProblem(base(), want), null);
    const cases = [
      [(o) => { o.supplier.status = "pending_verification" }, "supplier_not_approved"],
      [(o) => { o.supplier.status = "suspended" }, "supplier_not_approved"],
      [(o) => { o.supplier.ordersEnabled = false }, "supplier_orders_disabled"],
      [(o) => { o.supplier.fulfillment.exchangeEmpty = false }, "supplier_does_not_offer_order_type"],
      [(o) => { o.supplier.riderArrangement = "undecided" }, "supplier_rider_arrangement_undecided"],
      [(o) => { o.station.status = "draft" }, "station_not_verified"],
      [(o) => { o.station.supplierId = "other" }, "station_supplier_mismatch"],
      [(o) => { o.station.location = null }, "station_location_invalid"],
      [(o) => { o.station.supportedSizes = ["kg6"] }, "station_does_not_handle_size"],
      [(o) => { o.station.fulfillment = {} }, "station_does_not_offer_order_type"],
      [(o) => { delete o.station.serviceRadiusKm }, "station_service_area_undefined"],
      [(o) => { o.product.verified = false }, "product_not_verified"],
      [(o) => { o.product.availability = "out_of_stock" }, "product_unavailable"],
      [(o) => { o.product.price = 0 }, "product_price_invalid"],
      [(o) => { o.product.price = 150.555 }, "product_price_invalid"],
      [(o) => { o.product.cylinderSize = "kg6" }, "product_mismatch"],
      [(o) => { o.productId = "exchangeEmpty_kg12_5_shell" }, "product_mismatch"],
      [(o) => { o.product = null }, "product_not_found"],
      [(o) => { o.supplier = null }, "supplier_not_found"],
    ];
    for (const [mutate, reason] of cases) {
      const o = structuredClone(base()); mutate(o)
      assert.equal(g.optionProblem(o, want), reason, reason);
    }
    assert.equal(g.optionProblem(base(), { ...want, location: FAR }), "outside_service_area");
  });

  // Round 4: the delivery charge is on the server-measured ROAD distance in
  // pesewas (was the straight-line distance).
  test("GSO-F03 the quote is the catalog price plus the server's delivery formula on the road distance", () => {
    const settings = { gas: { baseFare: 8, perKm: 2, minDeliveryFee: 12, roundTripFee: 30 } };
    const q = g.computeQuote({ product: product(), quantity: 2, orderType: "exchangeEmpty", routeMeters: 4300, settings });
    assert.equal(q.productAmount, 300);
    assert.equal(q.handlingFee, 10);
    assert.equal(q.deliveryFee, 16.6, "8 + 2 × 4.3 km");
    assert.deepEqual([q.distanceKm, q.routeDistanceMeters, q.routeProvider], [4.3, 4300, "google-routes-v2"]);
    assert.equal(q.total, 326.6);
    assert.equal(q.priceVersion, 1);
    assert.equal(q.pricingRulesVersion, 3);
    // Line amounts are exact pesewa multiples, whatever the binary float of the unit price.
    const odd = g.computeQuote({ product: product({ price: 0.1, handlingFee: 0.07 }), quantity: 3, orderType: "exchangeEmpty", routeMeters: 4300, settings });
    assert.deepEqual([odd.productAmount, odd.handlingFee, odd.total], [0.3, 0.21, 17.11]);
    assert.equal(g.computeQuote({ product: product(), quantity: 1, orderType: "exchangeEmpty", routeMeters: 1000, settings }).deliveryFee, 12, "minimum");
    assert.equal(g.computeQuote({ product: product(), quantity: 1, orderType: "exchangeEmpty", routeMeters: 4302, settings }).deliveryFee, 16.6,
      "200 × 4302 / 1000 = 860.4 → 860 pesewas");
    const pr = g.computeQuote({ product: product({ orderType: "pickupAndReturn" }), quantity: 1, orderType: "pickupAndReturn", routeMeters: 4300, settings });
    assert.equal(pr.deliveryFee, 55.2, "8 + 2 × 4.3 × 2 legs + 30");
    // Missing settings fall back to the app's defaults, not to zero.
    assert.deepEqual(g.computeQuote({ product: product(), quantity: 1, orderType: "exchangeEmpty", routeMeters: 4300, settings: null }).deliveryRates, g.GAS_DELIVERY_DEFAULTS);
    // Malformed ones refuse (as gas_pricing.js), and a non-integer distance is never priced.
    for (const bad of [{ gas: { perKm: "two" } }, { gas: { baseFare: -1 } }, { gas: "x" }]) {
      assert.throws(() => g.computeQuote({ product: product(), quantity: 1, orderType: "exchangeEmpty", routeMeters: 4300, settings: bad }),
        (e) => e.details?.reason === "pricing_unavailable", JSON.stringify(bad));
    }
    assert.throws(() => g.computeQuote({ product: product(), quantity: 1, orderType: "exchangeEmpty", routeMeters: 43.5, settings }),
      (e) => e.details?.reason === "route_distance_invalid");
  });

  test("GSO-F04 a hold must equal the snapshot total exactly", () => {
    const order = { priceSnapshot: { total: 337.62 } };
    assert.equal(g.holdMatchesSnapshot(order, 337.62), true);
    for (const a of [337.61, 337.63, 0, -337.62, NaN, "337.62", 337.625]) assert.equal(g.holdMatchesSnapshot(order, a), false, String(a));
    assert.equal(g.holdMatchesSnapshot({ totalPrice: 337.62 }, 337.62), false); // party-writable field is not the snapshot
  });
});

describe("listGasSupplierOptions", () => {
  test("GSO-E01 offers an eligible option with only public fields", async () => {
    await seedCatalog();
    const { options } = await call(g.listGasSupplierOptions, { orderType: "exchangeEmpty", cylinderSize: "kg12_5", location: NEAR });
    assert.equal(options.length, 1);
    assert.deepEqual(Object.keys(options[0]).sort(), ["brand", "cylinderSize", "distanceKm", "orderType", "priceVersion", "productId",
      "stationId", "stationName", "supplierId", "supplierName", "unitHandlingFee", "unitPrice"]);
    assert.doesNotMatch(JSON.stringify(options), /PRIVATE|LIC-1|\+233|Community 1/);
  });

  test("GSO-E02 nothing is offered unless every condition holds", async () => {
    const variants = [
      { sup: { status: "pending_verification" } }, { sup: { status: "draft" } }, { sup: { status: "suspended" } },
      { sup: { ordersEnabled: false } }, { st: { status: "draft" } }, { st: { supportedSizes: ["kg6"] } },
      { pr: { verified: false, availability: "unavailable" } }, { pr: { availability: "out_of_stock" } },
    ];
    for (const v of variants) {
      await h.clearFirestore(); await seedCatalog(v);
      const { options } = await call(g.listGasSupplierOptions, { orderType: "exchangeEmpty", cylinderSize: "kg12_5", location: NEAR });
      assert.equal(options.length, 0, JSON.stringify(v));
    }
    await h.clearFirestore(); await seedCatalog();
    assert.equal((await call(g.listGasSupplierOptions, { orderType: "exchangeEmpty", cylinderSize: "kg12_5", location: FAR })).options.length, 0, "outside service area");
    assert.equal((await call(g.listGasSupplierOptions, { orderType: "newCylinder", cylinderSize: "kg12_5", location: NEAR })).options.length, 0, "type not offered");
  });

  test("GSO-E03 unsupported requests and signed-out callers are refused", async () => {
    await rejects(call(g.listGasSupplierOptions, { orderType: "refillOnly", cylinderSize: "kg12_5", location: NEAR }), "invalid-argument", "unsupported_order_type");
    await rejects(call(g.listGasSupplierOptions, { orderType: "exchangeEmpty", cylinderSize: "small", location: NEAR }), "invalid-argument", "unsupported_cylinder_size");
    await rejects(call(g.listGasSupplierOptions, { orderType: "exchangeEmpty", cylinderSize: "kg12_5", location: NEAR }, null), "unauthenticated");
  });
});

describe("quote and order", () => {
  test("GSO-F07 a supplier relying only on its own riders is not offered (dispatch has CTSGo drivers only)", async () => {
    await seedCatalog({ sup: { riderArrangement: "supplier_riders" } });
    await rejects(quoteFor(), "failed-precondition", "supplier_riders_not_supported");
    await h.clearFirestore(); await seedCatalog({ sup: { riderArrangement: "supplier_riders_ctsgo_fallback" } });
    assert.ok((await quoteFor()).quoteId, "with the CTSGo fallback it is offered");
  });

  test("GSO-F06 the delivery fee uses the provider's road distance; no route or no usable rates, no quote", async () => {
    await seedCatalog();
    const q = await quoteFor();
    assert.equal(routeCalls, 1, "measured once, on the server");
    const stored = await h.read(`gas_quotes/${q.quoteId}`);
    assert.deepEqual([stored.pricing.routeDistanceMeters, stored.pricing.distanceKm], [ROAD_M, 4.3]);
    assert.equal(stored.pricing.deliveryFee, 16.6);
    const before = (await h.db().collection("gas_quotes").get()).size;
    for (const reason of ["routing_timeout", "route_unavailable", "routing_http_403", "routing_not_configured"]) {
      routeIs(() => { throw new RoutingError(reason); });
      await rejects(quoteFor(), "unavailable", reason);
    }
    routeIs(() => ({ distanceMeters: 12.5 }));
    await rejects(quoteFor(), "unavailable", "route_distance_invalid");
    assert.equal((await h.db().collection("gas_quotes").get()).size, before, "nothing stored");
    routeIs(() => ({ distanceMeters: ROAD_M }));
    routeCalls = 0;
    await h.seed("settings/platform", { gas: { perKm: "two" } });
    await rejects(quoteFor(), "failed-precondition", "pricing_unavailable");
    assert.equal(routeCalls, 0, "no routing request without usable rates");
  });

  test("GSO-E04 the server prices the quote; a client price or total is refused, not used", async () => {
    await seedCatalog();
    for (const extra of [{ price: 1 }, { total: 1 }, { deliveryFee: 0 }, { unitPrice: 1 }, { priceSnapshot: { total: 1 } }]) {
      await rejects(quoteFor(extra), "invalid-argument", "unexpected_fields");
    }
    const q = await quoteFor();
    assert.equal(q.pricing.unitPrice, 150);
    assert.equal(q.pricing.productAmount, 300);
    assert.equal(q.pricing.handlingFee, 10);
    const stored = await h.read(`gas_quotes/${q.quoteId}`);
    assert.equal(stored.userId, P);
    assert.equal(stored.pricing.total, q.pricing.total);
    await rejects(call(g.createGasSupplierOrder, { quoteId: q.quoteId, total: 1 }), "invalid-argument", "unexpected_fields");
  });

  test("GSO-E05 quotes are refused for unverified or unavailable products and bad quantities", async () => {
    await seedCatalog({ pr: { verified: false, availability: "unavailable" } });
    await rejects(quoteFor(), "failed-precondition", "product_not_verified");
    await h.clearFirestore(); await seedCatalog({ pr: { availability: "out_of_stock" } });
    await rejects(quoteFor(), "failed-precondition", "product_unavailable");
    await h.clearFirestore(); await seedCatalog();
    await rejects(quoteFor({ quantity: 0 }), "invalid-argument", "invalid_quantity");
    await rejects(quoteFor({ quantity: undefined }), "invalid-argument", "invalid_quantity");
    await rejects(quoteFor({ productId: "exchangeEmpty_kg12_5_shell" }), "failed-precondition", "product_not_found");
    await rejects(quoteFor({ location: FAR }), "failed-precondition", "outside_service_area");
  });

  test("GSO-E06 an order carries an exact snapshot of the quote and is parked awaiting payment", async () => {
    await seedCatalog();
    const q = await quoteFor();
    const r = await call(g.createGasSupplierOrder, { quoteId: q.quoteId });
    assert.equal(r.alreadyCreated, false);
    assert.equal(r.total, q.pricing.total);
    const order = await h.read(`gas_supplier_orders/${r.orderId}`);
    assert.equal(order.status, "awaiting_payment");
    assert.equal(order.passengerId, P);
    for (const k of ["unitPrice", "unitHandlingFee", "quantity", "productAmount", "handlingFee", "deliveryFee", "distanceKm", "total", "priceVersion", "currency"]) {
      assert.equal(order.priceSnapshot[k], q.pricing[k], k);
    }
    assert.equal(order.priceSnapshot.supplierId, S);
    assert.equal(order.priceSnapshot.stationId, ST);
    assert.equal(order.priceSnapshot.productId, PID);
    assert.equal(order.priceSnapshot.quoteId, q.quoteId);
    assert.ok(order.priceSnapshot.snapshotAt && order.createdAt, "server timestamps");
    assert.equal((await h.read(`gas_quotes/${q.quoteId}`)).status, "used");
    assert.equal(await h.read(`gas_orders/${r.orderId}`), null, "never written to the dispatched gas_orders collection");
    // The allocation is created with the order, at the current terms, and is not on the order document.
    const a = await h.read(`gas_supplier_orders/${r.orderId}/finance/allocation`);
    assert.equal(a.orderId, r.orderId);
    assert.equal(a.supplierId, S);
    assert.equal(a.customerTotalPesewas, Math.round(q.pricing.total * 100));
    assert.equal(a.commissionPesewas, 3000, "10% (test fixture) of the 300.00 product subtotal");
    assert.equal(a.supplierNetPesewas, 30000 + 1000 - 3000, "product + handling − commission");
    assert.equal(a.driverNetPesewas, Math.round(q.pricing.deliveryFee * 100));
    assert.deepEqual(a.settlement, { status: "not_posted", reconciliation: null });
    assert.equal(order.allocation, undefined);
    assert.ok(!JSON.stringify(q).includes("commission"), "the customer's quote shows no commission");
  });

  test("GSO-E07 retries and duplicate submissions create exactly one order", async () => {
    await seedCatalog();
    const q = await quoteFor();
    const results = await Promise.allSettled([1, 2, 3].map(() => call(g.createGasSupplierOrder, { quoteId: q.quoteId })));
    const ok = results.filter((r) => r.status === "fulfilled").map((r) => r.value);
    assert.ok(ok.length >= 1);
    assert.ok(ok.every((r) => r.orderId === q.quoteId && r.total === q.pricing.total));
    assert.equal(ok.filter((r) => !r.alreadyCreated).length <= 1, true);
    const again = await call(g.createGasSupplierOrder, { quoteId: q.quoteId });
    assert.equal(again.alreadyCreated, true);
    assert.equal(await h.count("gas_supplier_orders", "passengerId", P), 1);
  });

  test("GSO-E08 expired, foreign, stale or no-longer-eligible quotes are refused", async () => {
    await seedCatalog();
    const expired = await quoteFor();
    await h.db().doc(`gas_quotes/${expired.quoteId}`).update({ expiresAt: Timestamp.fromMillis(Date.now() - 1000) });
    await rejects(call(g.createGasSupplierOrder, { quoteId: expired.quoteId }), "failed-precondition", "quote_expired");

    const foreign = await quoteFor({}, OTHER);
    await rejects(call(g.createGasSupplierOrder, { quoteId: foreign.quoteId }), "not-found", "quote_not_found");

    const stale = await quoteFor();
    await h.db().doc(productPath()).update({ price: 160, priceVersion: 2 });
    await rejects(call(g.createGasSupplierOrder, { quoteId: stale.quoteId }), "failed-precondition", "quote_stale");

    const unavailable = await quoteFor();
    await h.db().doc(productPath()).update({ availability: "out_of_stock" });
    await rejects(call(g.createGasSupplierOrder, { quoteId: unavailable.quoteId }), "failed-precondition", "product_unavailable");
    await h.db().doc(productPath()).update({ availability: "available" });

    const suspended = await quoteFor();
    await h.db().doc(`gas_suppliers/${S}`).update({ status: "suspended", ordersEnabled: false });
    await rejects(call(g.createGasSupplierOrder, { quoteId: suspended.quoteId }), "failed-precondition", "supplier_not_approved");
    assert.equal(await h.count("gas_supplier_orders", "passengerId", P), 0);
  });

  test("GSO-E09 later catalog changes and suspension leave an existing order's snapshot untouched", async () => {
    await seedCatalog();
    const q = await quoteFor();
    const { orderId } = await call(g.createGasSupplierOrder, { quoteId: q.quoteId });
    const before = (await h.read(`gas_supplier_orders/${orderId}`)).priceSnapshot;
    await h.db().doc(productPath()).update({ price: 999, handlingFee: 50, priceVersion: 7 });
    await h.db().doc(`gas_suppliers/${S}`).update({ status: "suspended", ordersEnabled: false });
    await h.seed("settings/platform", { gas: { baseFare: 100, perKm: 50, minDeliveryFee: 500, roundTripFee: 100 } });
    const afterward = await h.read(`gas_supplier_orders/${orderId}`);
    assert.deepEqual(afterward.priceSnapshot, before);
    assert.equal(afterward.status, "awaiting_payment");
  });
});

describe("ordering switch", () => {
  test("GSO-W01 while off: no options, no quote (and no routing request), no new order", async () => {
    await seedCatalog();
    const q = await quoteFor();
    routeCalls = 0;
    for (const flag of [null, { enabled: false }, { enabled: "true" }]) {
      if (flag) await h.seed(g.ORDERING_FLAG_DOC, flag); else await h.db().doc(g.ORDERING_FLAG_DOC).delete();
      await rejects(call(g.listGasSupplierOptions, { orderType: "exchangeEmpty", cylinderSize: "kg12_5", location: NEAR }), "unavailable", "gas_supplier_fulfilment_disabled");
      await rejects(quoteFor(), "unavailable", "gas_supplier_fulfilment_disabled");
      await rejects(call(g.createGasSupplierOrder, { quoteId: q.quoteId }), "unavailable", "gas_supplier_fulfilment_disabled");
    }
    assert.equal(routeCalls, 0, "no route was measured while off");
    assert.equal(await h.count("gas_supplier_orders", "passengerId", P), 0);
    assert.equal((await h.read(`gas_quotes/${q.quoteId}`)).status, "open", "the quote taken while on was not used");
  });

  test("GSO-W02 while on: options, quote and order work; the switch is the one fulfilment reads", async () => {
    await seedCatalog();
    assert.equal(g.ORDERING_FLAG_DOC, require("../../gas_supplier_fulfilment").FLAG_DOC);
    const { options } = await call(g.listGasSupplierOptions, { orderType: "exchangeEmpty", cylinderSize: "kg12_5", location: NEAR });
    assert.ok(options.length > 0);
    const q = await quoteFor();
    const o = await call(g.createGasSupplierOrder, { quoteId: q.quoteId });
    assert.equal(o.status, "awaiting_payment");
  });

  test("GSO-W03 unauthenticated callers are refused before the switch is read", async () => {
    await h.db().doc(g.ORDERING_FLAG_DOC).delete();
    await rejects(call(g.quoteGasSupplierOrder, {}, null), "unauthenticated");
    await rejects(call(g.createGasSupplierOrder, {}, null), "unauthenticated");
  });
});

describe("payment boundary", () => {
  test("GSO-E10 no wallet hold can be attached to a supplier order yet", async () => {
    await seedCatalog();
    const q = await quoteFor();
    const { orderId, total } = await call(g.createGasSupplierOrder, { quoteId: q.quoteId });
    await h.seed(`wallets/${P}`, { balance: 10000, heldBalance: 0 });
    const { escrowId } = await call(escrow.holdBalance, { amount: total, serviceType: "gas", referenceType: "gas_order" });
    await rejects(call(escrow.attachEscrowToOrder, { escrowId, referenceId: orderId, referenceType: "gas_supplier_order" }), "invalid-argument");
    await rejects(call(escrow.attachEscrowToOrder, { escrowId, referenceId: orderId, referenceType: "gas_order" }), "not-found");
    assert.equal((await h.read(`escrows/${escrowId}`)).referenceId, null);
    assert.equal(g.holdMatchesSnapshot(await h.read(`gas_supplier_orders/${orderId}`), total), true);
  });

  test("GSO-E11 only onGasSupplierRiderOfferChanged listens on supplier orders, none on quotes; Gas dispatch still listens only on gas_orders", () => {
    // Loading index.js here would re-initialise the Admin SDK, so the
    // trigger paths are read from the function sources.
    const fs = require("node:fs");
    const path = require("node:path");
    const dir = path.join(__dirname, "../..");
    const paths = fs.readdirSync(dir).filter((f) => f.endsWith(".js"))
      .flatMap((f) => [...fs.readFileSync(path.join(dir, f), "utf8").matchAll(/document:\s*"([^"]+)"/g)].map((m) => m[1]));
    assert.ok(paths.includes("gas_orders/{orderId}"));
    assert.ok(!paths.some((p) => /gas_quotes|gas_suppliers/.test(p)), JSON.stringify(paths));
    // Exactly one trigger (spec 3.3, rider offer notifications) listens on supplier orders.
    assert.deepEqual(paths.filter((p) => /gas_supplier_orders/.test(p)), ["gas_supplier_orders/{orderId}"], JSON.stringify(paths));
    assert.match(fs.readFileSync(path.join(dir, "notifications.js"), "utf8"),
      /exports\.onGasSupplierRiderOfferChanged = onDocumentUpdated\(\s*\{[^}]*document:\s*"gas_supplier_orders\/\{orderId\}"/);
    for (const name of ["listGasSupplierOptions", "quoteGasSupplierOrder", "createGasSupplierOrder"]) {
      assert.equal(g[name]?.__endpoint?.region?.[0], "europe-west2", name);
      assert.ok(fs.readFileSync(path.join(dir, "index.js"), "utf8").includes(`exports.${name} = gasSupplierOrders.${name};`), name);
    }
  });
});

// ── Phase 2A: station identity, status, coordinates, stock and ownership ────
// A station is offered only while it is the supplier's own, verified station
// with usable coordinates and a defined service area, and only with an
// available, verified product. Anything else is refused, never estimated.
describe("Phase 2A station safety", () => {
  test("GSO-F08 missing, inactive, unlocated or out-of-stock stations are refused independently", () => {
    const base = () => ({ supplierId: S, supplier: supplier(), stationId: ST, station: station({ location: { ...STATION_AT } }), productId: PID, product: product() });
    const want = { orderType: "exchangeEmpty", cylinderSize: "kg12_5", location: NEAR };
    const cases = [
      [(o) => { o.station = null }, "station_not_found"],
      [(o) => { o.station.status = "inactive" }, "station_not_verified"],
      [(o) => { o.station.status = undefined }, "station_not_verified"],
      [(o) => { delete o.station.location }, "station_location_invalid"],
      [(o) => { o.station.location = { latitude: 0, longitude: 0 } }, "station_location_invalid"],
      [(o) => { o.station.location = { latitude: 95, longitude: -0.01 } }, "station_location_invalid"],
      [(o) => { o.station.location = { latitude: "5.6", longitude: "-0.01" } }, "station_location_invalid"],
      [(o) => { o.station.serviceRadiusKm = 0 }, "station_service_area_undefined"],
      [(o) => { o.station.serviceRadiusKm = -5 }, "station_service_area_undefined"],
      [(o) => { o.product.availability = "unavailable" }, "product_unavailable"],
      [(o) => { o.product.availability = undefined }, "product_unavailable"],
      [(o) => { o.supplier.riderArrangement = "supplier_riders" }, "supplier_riders_not_supported"],
    ];
    for (const [mutate, reason] of cases) {
      const o = structuredClone(base()); mutate(o);
      assert.equal(g.optionProblem(o, want), reason, reason);
    }
  });

  test("GSO-E12 inactive, unlocated, out-of-stock and foreign stations are never listed or quoted", async () => {
    const want = { orderType: "exchangeEmpty", cylinderSize: "kg12_5", location: NEAR };
    const variants = [
      [{ st: { status: "inactive" } }, "station_not_verified"],
      [{ st: { location: new GeoPoint(0, 0) } }, "station_location_invalid"],
      [{ st: { location: null } }, "station_location_invalid"],
      [{ st: { supplierId: "another-supplier" } }, "station_supplier_mismatch"],
      [{ pr: { availability: "out_of_stock" } }, "product_unavailable"],
      [{ pr: { availability: "unavailable" } }, "product_unavailable"],
    ];
    for (const [v, reason] of variants) {
      await h.clearFirestore(); await seedCatalog(v);
      const { options } = await call(g.listGasSupplierOptions, want);
      assert.equal(options.length, 0, `listed: ${JSON.stringify(v)}`);
      await rejects(quoteFor(), "failed-precondition", reason);
    }
    // A station id that does not exist under the supplier.
    await h.clearFirestore(); await seedCatalog();
    await rejects(quoteFor({ stationId: "no-such-station" }), "failed-precondition", "station_not_found");
    // A station of another supplier cannot be quoted under this supplier's id.
    await h.seed("gas_suppliers/sup2", supplier({ legalName: "Other Gas Ltd" }));
    await h.seed("gas_suppliers/sup2/stations/st9", station({ supplierId: "sup2" }));
    await h.seed(productPath(PID, "st9", "sup2"), product());
    await rejects(quoteFor({ stationId: "st9" }), "failed-precondition", "station_not_found");
    // The valid catalog is still offered and quoted.
    assert.equal((await call(g.listGasSupplierOptions, want)).options.length, 2);
    assert.ok((await quoteFor()).quoteId);
  });
});
