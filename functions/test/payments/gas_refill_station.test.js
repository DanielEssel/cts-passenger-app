"use strict";

// Phase 2B: a legacy Gas order may name a verified refill station
// (refillStationRef). onGasOrderCreated resolves it against the supplier's
// own station and products (gas_refill_station.js) and stamps a trusted
// snapshot, or cancels the order before any driver sees it. Orders without a
// reference (every existing Phase 1 order) are unchanged.
// Runs only under `firebase emulators:exec --only firestore` (demo- project).

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const { Timestamp, GeoPoint } = require("firebase-admin/firestore");
const h = require("./helpers");
const notifications = require("../../notifications");
const { readStationRef } = require("../../gas_refill_station");

const P = "grs-passenger";
const D = "grs-driver";
const PT = new GeoPoint(5.55671, -0.18234); // customer (Osu, Accra)
const STATION_AT = new GeoPoint(5.56, -0.19); // ~1 km away
const S = "sup1", ST = "st1";
const PROD = { platformFeePercent: 15, gas: { refill3kg: 50, full3kg: 100, baseFare: 7.5, perKm: 0.5,
  minDeliveryFee: 12, roundTripFee: 30, commercialRate: 1 }, delivery: h.DELIVERY_RATES };

const supplier = (o = {}) => ({ legalName: "Test Gas Ltd", tradingName: "Test Gas", status: "approved", ordersEnabled: true,
  fulfillment: { exchangeEmpty: true, newCylinder: true }, riderArrangement: "ctsgo_dispatch", ...o });
const station = (o = {}) => ({ name: "Osu Station", supplierId: S, status: "verified", address: "Oxford St, Osu",
  location: STATION_AT, serviceRadiusKm: 8, supportedSizes: ["kg3", "kg6"],
  fulfillment: { exchangeEmpty: true, newCylinder: true }, ...o });
const product = (brand = "goGas", o = {}) => ({ orderType: "exchangeEmpty", cylinderSize: "kg3", brand, price: 50,
  handlingFee: 0, currency: "GHS", priceVersion: 1, availability: "available", verified: true, ...o });
const productPath = (brand = "goGas", st = ST, s = S) => `gas_suppliers/${s}/stations/${st}/products/exchangeEmpty_kg3_${brand}`;
const driver = () => ({ uid: D, role: "driver_delivery", serviceType: "delivery", vehicleType: "motorcycle",
  isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true, location: PT,
  lastLocationUpdate: Timestamp.now() });
const gas = (o = {}) => h.gasPriced({ passengerId: P, driverId: null, status: "pendingApproval",
  refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1, preferredBrand: "goGas", paymentMethod: "cash",
  pickupLocation: PT, deliveryLocation: PT, deliveryAddress: "12 Oxford St, Osu, Accra",
  createdAt: Timestamp.now(), ...o }, PROD);

const created = (id, data) => notifications.onGasOrderCreated.run({ params: { orderId: id }, data: { data: () => data } });
async function place(id, o = {}) {
  const data = gas(o);
  await h.seed(`gas_orders/${id}`, data);
  await created(id, data);
  return h.read(`gas_orders/${id}`);
}
const offer = (id) => h.read(`gas_order_offers/${id}`);
const REF = { supplierId: S, stationId: ST };

async function seedCatalog({ sup = {}, st = {}, pr = {}, brand = "goGas" } = {}) {
  await h.seed(`gas_suppliers/${S}`, supplier(sup));
  await h.seed(`gas_suppliers/${S}/stations/${ST}`, station(st));
  await h.seed(productPath(brand), product(brand, pr));
}

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed("settings/platform", PROD);
  await h.seed(`drivers/${D}`, driver());
});

describe("GRS: refill station reference on legacy Gas orders", () => {
  test("GRS-01 an order without a reference is unchanged: priced, offered, no station", async () => {
    const o = await place("g1");
    assert.equal(o.status, "pendingApproval");
    assert.ok(o.verifiedPrice, "server price stamped");
    assert.equal(o.verifiedRefillStation, undefined);
    assert.ok(await offer("g1"), "offered as before");
  });

  test("GRS-02 a valid reference gets the server's snapshot of the station; the price stays the server's Gas price", async () => {
    await seedCatalog();
    const o = await place("g1", { refillStationRef: REF });
    assert.equal(o.status, "pendingApproval");
    const v = o.verifiedRefillStation;
    assert.deepEqual([v.supplierId, v.stationId, v.productId, v.name, v.address],
      [S, ST, "exchangeEmpty_kg3_goGas", "Osu Station", "Oxford St, Osu"]);
    assert.deepEqual([v.location.latitude, v.location.longitude], [STATION_AT.latitude, STATION_AT.longitude]);
    assert.ok(v.verifiedAt);
    assert.equal(o.verifiedPrice.total, gas().totalPrice, "price unchanged by the station");
    assert.ok(await offer("g1"), "offered");
  });

  test("GRS-03 'any brand' uses an eligible product of that type and size, the same one on every run", async () => {
    await seedCatalog({ brand: "shell" });
    await h.seed(productPath("goGas"), product("goGas", { availability: "out_of_stock" }));
    await h.seed(productPath("totalEnergies"), product("totalEnergies"));
    const o = await place("g1", { refillStationRef: REF, preferredBrand: "any" });
    assert.equal(o.verifiedRefillStation.productId, "exchangeEmpty_kg3_shell", "lowest eligible id; out of stock skipped");
    const n = await place("g2", { refillStationRef: REF, preferredBrand: null });
    assert.equal(n.verifiedRefillStation.productId, "exchangeEmpty_kg3_shell");
  });

  test("GRS-04 an unusable reference cancels the order before dispatch: no offer, no snapshot, no fallback", async () => {
    const cases = [
      [{ sup: { ordersEnabled: false } }, REF, "supplier_orders_disabled"],
      [{ sup: { status: "suspended" } }, REF, "supplier_not_approved"],
      [{ sup: { riderArrangement: "supplier_riders" } }, REF, "supplier_riders_not_supported"],
      [{ st: { status: "draft" } }, REF, "station_not_verified"],
      [{ st: { status: "inactive" } }, REF, "station_not_verified"],
      [{ st: { location: new GeoPoint(0, 0) } }, REF, "station_location_invalid"],
      [{ st: { location: null } }, REF, "station_location_invalid"],
      [{ st: { supportedSizes: ["kg6"] } }, REF, "station_does_not_handle_size"],
      [{ st: { serviceRadiusKm: 0.5 } }, REF, "outside_service_area"],
      [{ st: { supplierId: "another" } }, REF, "station_supplier_mismatch"],
      [{ pr: { availability: "out_of_stock" } }, REF, "product_unavailable"],
      [{ pr: { verified: false } }, REF, "product_not_verified"],
      [{}, { supplierId: S, stationId: "missing" }, "station_not_found"],
      [{}, { supplierId: "missing", stationId: ST }, "supplier_not_found"],
      [{}, { supplierId: S, stationId: ST, price: 1 }, "refill_station_ref_invalid"],
      [{}, { supplierId: S, stationId: "../x" }, "refill_station_ref_invalid"],
      [{}, "sup1/st1", "refill_station_ref_invalid"],
    ];
    for (const [catalog, ref, reason] of cases) {
      await h.clearFirestore(); await h.seed("settings/platform", PROD); await h.seed(`drivers/${D}`, driver());
      await seedCatalog(catalog);
      const o = await place("g1", { refillStationRef: ref });
      assert.equal(o.status, "cancelled", reason);
      assert.equal(o.cancellationReason, "refill_station_unavailable", reason);
      assert.equal(o.verifiedRefillStation, undefined, reason);
      assert.equal(await offer("g1"), null, `${reason}: not offered`);
    }
  });

  test("GRS-05 a repeated creation event changes nothing", async () => {
    await seedCatalog();
    const first = await place("g1", { refillStationRef: REF });
    await created("g1", gas({ refillStationRef: REF }));
    await created("g1", gas({ refillStationRef: REF }));
    const again = await h.read("gas_orders/g1");
    assert.deepEqual(again.verifiedRefillStation, first.verifiedRefillStation);
    assert.equal(again.status, "pendingApproval");
    assert.equal((await h.db().collection(`drivers/${D}/notifications`).get()).size, 1, "driver notified once");
  });

  test("GRS-06 the reference parser accepts only {supplierId, stationId} ids", () => {
    assert.equal(readStationRef({}), null);
    assert.equal(readStationRef({ refillStationRef: null }), null);
    assert.deepEqual(readStationRef({ refillStationRef: { stationId: "b", supplierId: "a" } }), { supplierId: "a", stationId: "b" });
    for (const bad of ["a/b", ["a", "b"], { supplierId: "a" }, { supplierId: "a", stationId: "" }, { supplierId: 1, stationId: "b" },
      { supplierId: "a", stationId: "b", extra: 1 }, { supplierId: "a/b", stationId: "c" }]) {
      assert.deepEqual(readStationRef({ refillStationRef: bad }), { problem: "refill_station_ref_invalid" }, JSON.stringify(bad));
    }
  });
});
