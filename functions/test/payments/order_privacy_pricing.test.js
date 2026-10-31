// Release v5: Delivery and legacy Gas privacy (order_offers.js) and the one
// server Gas price (gas_pricing.js), through the real triggers, acceptance
// and settlement. Firestore emulator only; FCM sends fail closed here (no
// credentials) after the inbox write, as in the other dispatch suites.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const { Timestamp, GeoPoint } = require("firebase-admin/firestore");
const h = require("./helpers");
const notifications = require("../../notifications");
const trips = require("../../trips");
const { acceptJob } = require("../../accept_job");
const offers = require("../../order_offers");
const pricing = require("../../gas_pricing");

const P = "opp-passenger";
const D = "opp-driver";
const D2 = "opp-driver2";
// Exact points (not on the 0.01° grid) and street addresses.
const PICKUP = new GeoPoint(5.55671, -0.18234);
const DROPOFF = new GeoPoint(5.60372, -0.18691);
const ADDR_PICKUP = "12 Oxford St, Osu, Accra";
const ADDR_DROPOFF = "House 7, Ring Rd Central, Adabraka, Accra";
// settings/platform.gas in production (read-only, 2026-10-27).
const PROD = { platformFeePercent: 15, gas: { refill3kg: 50, full3kg: 100, baseFare: 7.5, perKm: 0.5,
  minDeliveryFee: 12, roundTripFee: 30, commercialRate: 1 },
  // Delivery rates (test fixture: the app's built-in defaults) for server quotes.
  delivery: h.DELIVERY_RATES };

const PRIVATE_DELIVERY = { receiverName: "Ama", receiverPhone: "+233240000009", notes: "Leave at gate",
  photoUrl: "https://x/p.jpg" };
const PRIVATE_GAS = { pickupInstructions: "Ring twice", deliveryInstructions: "Gate code 4411",
  cylinderConditionNotes: "dent", receiptEmail: "a@b.c" };

const driver = (uid, o = {}) => ({ uid, role: "driver_delivery", serviceType: "delivery",
  vehicleType: "motorcycle", isApproved: true, signupStep: "approved", isOnline: true,
  isAvailable: true, location: PICKUP, lastLocationUpdate: Timestamp.now(), ...o });
const delivery = (o = {}) => ({ passengerId: P, driverId: null, status: "pending", vehicleType: "Okada",
  weightTier: "Small", parcelType: "Documents", paymentMethod: "cash", pickupLocation: PICKUP,
  dropoffLocation: DROPOFF, pickupAddress: ADDR_PICKUP, dropoffAddress: ADDR_DROPOFF,
  estimatedFare: 30, createdAt: Timestamp.now(), ...PRIVATE_DELIVERY, ...o });
const gas = (o = {}, settings = PROD) => h.gasPriced({ passengerId: P, driverId: null,
  status: "pendingApproval", refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1,
  paymentMethod: "cash", pickupLocation: PICKUP, deliveryLocation: PICKUP, pickupAddress: ADDR_PICKUP,
  deliveryAddress: ADDR_PICKUP, scheduledPickupAt: Timestamp.now(), scheduledDeliveryBy: Timestamp.now(),
  createdAt: Timestamp.now(), ...PRIVATE_GAS, ...o }, settings);

const createdEvent = (id, data) => ({ params: { deliveryId: id, orderId: id }, data: { data: () => data } });
const updateEvent = (id, before, afterDoc) => ({ params: { deliveryId: id, orderId: id },
  data: { before: { data: () => before }, after: { data: () => afterDoc } } });
const inbox = async (uid) => (await h.db().collection("drivers").doc(uid).collection("notifications").get())
  .docs.map((d) => d.data());
const offer = (collection, id) => h.read(`${offers.OFFER_COLLECTION[collection]}/${id}`);

// As Passenger 1.0.1 books it: with the server quote for its route.
async function createDelivery(id, data) {
  // A parcel no vehicle may carry cannot be quoted (only an older build books it).
  const quotable = !require("../../delivery_pricing").inputProblem({
    vehicleKey: require("../../delivery_pricing").vehicleKey(data.vehicleType), weightTier: data.weightTier,
    isFragile: data.isFragile ?? false, requiresHelpers: data.requiresHelpers ?? false });
  const quoted = data.deliveryQuoteId === undefined && quotable
    ? await h.quotedDelivery(data, { quoteId: `q-${id}`, settings: PROD }) : data;
  await h.seed(`deliveries/${id}`, quoted);
  await notifications.onDeliveryCreated.run(createdEvent(id, quoted));
}
async function createGas(id, data) {
  await h.seed(`gas_orders/${id}`, data);
  await notifications.onGasOrderCreated.run(createdEvent(id, data));
}

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed("settings/platform", PROD);
  await h.seed(`drivers/${D}`, driver(D));
  await h.seed(`drivers/${D2}`, driver(D2));
});

// Every value an unassigned driver can read, flattened to text.
const text = (o) => JSON.stringify(o, (k, v) => (v instanceof GeoPoint ? [v.latitude, v.longitude] : v));
const SECRETS = [ADDR_PICKUP, ADDR_DROPOFF, "12 Oxford", "Ring Rd", "House 7", ...Object.values(PRIVATE_DELIVERY),
  ...Object.values(PRIVATE_GAS), String(PICKUP.latitude), String(PICKUP.longitude),
  String(DROPOFF.latitude), String(DROPOFF.longitude), P];

describe("offers: what an unassigned driver can read", () => {
  test("OPV-01 a delivery offer carries only coarse fields", async () => {
    await createDelivery("d1", delivery());
    const o = await offer("deliveries", "d1");
    assert.deepEqual(Object.keys(o).sort(), ["createdAt", "dropoffArea", "dropoffPoint", "fare", "isFragile",
      "parcelType", "paymentMethod", "pickupArea", "pickupPoint", "publishedAt", "requiresHelpers", "schema",
      "service", "vehicleType", "weightTier"].sort());
    assert.equal(o.pickupArea, "Osu, Accra");
    assert.equal(o.dropoffArea, "Adabraka, Accra");
    assert.deepEqual([o.pickupPoint.latitude, o.pickupPoint.longitude], [5.56, -0.18]);
    assert.deepEqual([o.dropoffPoint.latitude, o.dropoffPoint.longitude], [5.6, -0.19]);
    const all = text(o);
    for (const s of SECRETS) assert.ok(!all.includes(s), `offer leaks ${s}`);
  });

  test("OPV-02 a gas offer: area, rounded point, verified amounts; no instructions, times, e-mail or uid", async () => {
    await createGas("g1", gas());
    const o = await offer("gas_orders", "g1");
    assert.equal(o.totalPrice, 62);
    assert.equal(o.fare, 62);
    assert.equal(o.deliveryFee, 12);
    assert.equal(o.pickupArea, "Osu, Accra");
    for (const k of ["scheduledPickupAt", "scheduledDeliveryBy", "deliveryOtp", "passengerId",
      "pickupAddress", "deliveryAddress", "pickupLocation", "deliveryLocation"]) {
      assert.equal(o[k], undefined, k);
    }
    const all = text(o);
    for (const s of SECRETS) assert.ok(!all.includes(s), `offer leaks ${s}`);
  });

  test("OPV-03 inbox entries and push payload builders carry areas, never street addresses", async () => {
    await createDelivery("d1", delivery());
    await createGas("g1", gas());
    const items = await inbox(D);
    assert.ok(items.length >= 2, "both offered");
    for (const s of SECRETS) assert.ok(!text(items).includes(s), `inbox leaks ${s}`);
  });

  test("OPV-04 area labels drop the first part and any part with a number", () => {
    assert.equal(offers.areaLabel("12 Oxford St, Osu, Accra"), "Osu, Accra");
    assert.equal(offers.areaLabel("Kotoka International Airport, Accra"), "Accra");
    assert.equal(offers.areaLabel("House 7, Ring Rd Central, Adabraka, Accra"), "Adabraka, Accra",
      "the street is never kept");
    assert.equal(offers.areaLabel("Oxford Street"), "");
    assert.equal(offers.areaLabel("Shop, 8QX9+2F, Accra, Greater Accra"), "Accra, Greater Accra");
    assert.equal(offers.areaLabel(null), "");
  });

  test("OPV-06 a delivery no vehicle may carry is never listed (ended instead)", async () => {
    await createDelivery("d1", delivery({ vehicleType: "Okada", weightTier: "Medium" }));
    assert.equal(await offer("deliveries", "d1"), null);
    assert.equal((await h.read("deliveries/d1")).status, "cancelled");
  });

  test("OPV-05 an order with no usable location is not offered", async () => {
    await createDelivery("d1", delivery({ pickupLocation: new GeoPoint(0, 0) }));
    assert.equal(await offer("deliveries", "d1"), null);
  });
});

describe("offer lifecycle", () => {
  test("OPV-10 a wallet delivery is offered only once paid, and drivers are notified once", async () => {
    await h.enableDeliveryGasWallet();
    const d = delivery({ paymentMethod: "wallet" });
    await createDelivery("d1", d);
    assert.equal(await offer("deliveries", "d1"), null, "unpaid: no offer");
    await h.seed("escrows/e1", { userId: P, amount: 30, status: "HELD", referenceId: "d1", referenceType: "delivery" });
    const paid = { ...(await h.read("deliveries/d1")), escrowId: "e1" };
    await h.seed("deliveries/d1", paid);
    const ev = updateEvent("d1", d, paid);
    await Promise.all([notifications.onDeliveryPaymentAttached.run(ev), notifications.onDeliveryPaymentAttached.run(ev)]);
    assert.ok(await offer("deliveries", "d1"));
    assert.equal((await inbox(D)).length, 1, "one notification for a duplicated event");
  });

  test("OPV-11 acceptance removes the offer in the same commit; the loser gets no details", async () => {
    await createDelivery("d1", delivery());
    const [a, b] = await Promise.all([acceptJob("delivery", D, "d1"), acceptJob("delivery", D2, "d1")]);
    assert.equal([a, b].filter((r) => r.success).length, 1);
    assert.equal(await offer("deliveries", "d1"), null);
  });

  test("OPV-12 a stale offer (order cancelled, trigger lost) is removed by the next acceptance attempt", async () => {
    await createDelivery("d1", delivery());
    await h.db().collection("deliveries").doc("d1").update({ status: "cancelled" });
    const r = await acceptJob("delivery", D, "d1");
    assert.equal(r.success, false);
    assert.equal(await offer("deliveries", "d1"), null);
  });

  test("OPV-13 cancellation before assignment withdraws the offer (status trigger)", async () => {
    const d = delivery();
    await createDelivery("d1", d);
    const cancelled = { ...d, status: "cancelled" };
    await h.seed("deliveries/d1", cancelled);
    await notifications.onDeliveryStatusChanged.run(updateEvent("d1", d, cancelled));
    assert.equal(await offer("deliveries", "d1"), null);
  });

  test("OPV-14 a replayed create event after assignment never re-publishes", async () => {
    const d = delivery();
    await createDelivery("d1", d);
    assert.equal((await acceptJob("delivery", D, "d1")).success, true);
    await notifications.onDeliveryCreated.run(createdEvent("d1", d));
    assert.equal(await offer("deliveries", "d1"), null);
    const g = gas();
    await createGas("g1", g);
    assert.equal((await acceptJob("gas", D2, "g1")).success, true);
    await notifications.onGasOrderCreated.run(createdEvent("g1", g));
    assert.equal(await offer("gas_orders", "g1"), null);
  });

  test("OPV-15 a gas order is never offered before its price is verified", async () => {
    const g = { ...gas(), totalPrice: 61 };
    await createGas("g1", g);
    assert.equal(await offer("gas_orders", "g1"), null);
    assert.equal((await h.read("gas_orders/g1")).status, "cancelled");
  });

  test("OPV-16 wallet gas whose payment is linked before the price check is offered once", async () => {
    await h.enableDeliveryGasWallet();
    const g = gas({ paymentMethod: "wallet", escrowId: "e1" });
    await h.seed("escrows/e1", { userId: P, amount: 62, status: "HELD", referenceId: "g1", referenceType: "gas_order" });
    await h.seed("gas_orders/g1", g);
    // The attach event arrives first: no verified price yet, so no offer.
    await notifications.onGasOrderPaymentAttached.run(updateEvent("g1", { ...g, escrowId: null }, g));
    assert.equal(await offer("gas_orders", "g1"), null);
    await notifications.onGasOrderCreated.run(createdEvent("g1", { ...g, escrowId: null }));
    assert.ok(await offer("gas_orders", "g1"), "offered after the price was stamped");
    assert.equal((await inbox(D)).length, 1);
  });
});

describe("Gas price authority", () => {
  test("GPR-01 every type, size and production price: the server total is the app formula at 1 km", () => {
    const g = PROD.gas;
    const refill = { kg3: 50, kg6: 75, kg12_5: 150, kg14_5: 177, kg19: 230, kg45: 540 };
    const full = { kg3: 100, kg6: 280, kg12_5: 480, kg14_5: 520, kg19: 620, kg45: 1150 };
    for (const size of Object.keys(refill)) {
      for (const type of pricing.GAS_TYPES) {
        for (const quantity of [1, 2, 5, pricing.MAX_GAS_QUANTITY]) {
          const unit = type === "newCylinder" ? full[size] : refill[size];
          const legs = type === "pickupAndReturn" ? 2 : 1;
          const fee = Math.max(g.minDeliveryFee, g.baseFare + g.perKm * 1 * legs) +
            (type === "pickupAndReturn" ? g.roundTripFee : 0);
          const q = pricing.gasPriceQuote({ refillType: type, cylinderSize: size, quantity }, PROD);
          assert.equal(q.ok, true);
          assert.equal(q.deliveryFee, fee, `${type} ${size}`);
          assert.equal(q.total, Math.round((unit * quantity + fee) * 100) / 100, `${type} ${size} ×${quantity}`);
          assert.equal(q.commission, Math.round(q.total * 15) / 100);
          assert.equal(q.driverNet, Math.round((q.total - q.commission) * 100) / 100);
        }
      }
    }
  });

  test("GPR-02 every brand surcharge applies once, to the product only", () => {
    for (const [brand, m] of Object.entries(pricing.GAS_BRAND_MULTIPLIER)) {
      const q = pricing.gasPriceQuote({ refillType: "exchangeEmpty", cylinderSize: "kg6", quantity: 2,
        preferredBrand: brand }, PROD);
      assert.equal(q.brandPremium, Math.round(150 * (m - 1) * 100) / 100, brand);
      assert.equal(q.deliveryFee, 12, `${brand}: fee untouched`);
      assert.equal(q.total, Math.round((150 * m + 12) * 100) / 100, brand);
    }
  });

  test("GPR-03 settings: numeric strings read as numbers; anything else makes Gas unpriceable", () => {
    const o = { refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1 };
    assert.equal(pricing.gasPriceQuote(o, { gas: { refill3kg: "50", minDeliveryFee: "12.00" } }).total, 62);
    for (const bad of [{ refill3kg: "fifty" }, { refill3kg: -1 }, { refill3kg: 0 }, { perKm: "0.5km" },
      { minDeliveryFee: Infinity }, { commercialRate: 0 }, { baseFare: true }, { roundTripFee: {} }]) {
      assert.equal(pricing.gasPriceQuote(o, { gas: bad }).reason, "gas_config_invalid", JSON.stringify(bad));
    }
    assert.equal(pricing.gasPriceQuote(o, { gas: "x" }).reason, "gas_config_invalid");
    assert.equal(pricing.gasPriceQuote(o, { platformFeePercent: "abc" }).reason, "platform_fee_invalid");
    assert.equal(pricing.gasPriceQuote(o, { platformFeePercent: 150 }).reason, "platform_fee_invalid");
    assert.equal(pricing.gasPriceQuote(o, { platformFeePercent: "15" }).commission, 7.8);
  });

  test("GPR-04 quantity must be a whole number from 1 to the maximum", () => {
    for (const quantity of [0, -1, 1.5, "1", null, pricing.MAX_GAS_QUANTITY + 1]) {
      assert.equal(pricing.gasPriceQuote({ refillType: "exchangeEmpty", cylinderSize: "kg3", quantity }, PROD).ok,
        false, String(quantity));
    }
  });

  test("GPR-05 total and delivery fee must both be the server's", () => {
    const o = { refillType: "pickupAndReturn", cylinderSize: "kg3", quantity: 1 };
    assert.equal(pricing.verifyGasOrderPrice({ ...o, totalPrice: 92, deliveryFee: 42 }, PROD).ok, true);
    assert.equal(pricing.verifyGasOrderPrice({ ...o, totalPrice: 92, deliveryFee: 12 }, PROD).reason, "price_changed",
      "fee inconsistent with the total");
    assert.equal(pricing.verifyGasOrderPrice({ ...o, totalPrice: 117.5, deliveryFee: 67.5 }, PROD).reason,
      "price_changed", "the older app's 30 km round trip");
    assert.equal(pricing.verifyGasOrderPrice({ ...o, totalPrice: NaN, deliveryFee: 42 }, PROD).reason, "price_missing");
  });

  test("GPR-06 creation stamps the verified price once; a re-run changes nothing", async () => {
    const g = gas();
    await createGas("g1", g);
    const first = (await h.read("gas_orders/g1")).verifiedPrice;
    assert.deepEqual({ ...first, verifiedAt: undefined }, { version: "gas-v2", unitPrice: 50, base: 50,
      brandPremium: 0, deliveryFee: 12, total: 62, platformFeePercent: 15, commission: 9.3, driverNet: 52.7,
      verifiedAt: undefined });
    await h.seed("settings/platform", { ...PROD, gas: { ...PROD.gas, refill3kg: 70 } });
    await notifications.onGasOrderCreated.run(createdEvent("g1", g));
    const o = await h.read("gas_orders/g1");
    assert.equal(o.status, "pendingApproval");
    assert.equal(o.verifiedPrice.total, 62);
  });

  test("GPR-07 a price change between quote and order: cancelled, customer told, never charged more", async () => {
    await h.seed("settings/platform", { ...PROD, gas: { ...PROD.gas, refill3kg: 55 } });
    const g = gas(); // priced at the old 50
    await createGas("g1", g);
    const o = await h.read("gas_orders/g1");
    assert.deepEqual([o.status, o.cancellationReason, o.totalPrice], ["cancelled", "price_changed", 62]);
    assert.equal(o.verifiedPrice, undefined);
    const cancelled = { ...g, status: "cancelled", cancellationReason: "price_changed" };
    await notifications.onGasOrderStatusChanged.run(updateEvent("g1", g, cancelled));
    const items = (await h.db().collection("notifications").doc(P).collection("items").get()).docs.map((d) => d.data());
    assert.ok(items.some((n) => n.title === "Gas price changed"), JSON.stringify(items.map((n) => n.title)));
  });

  test("GPR-08 acceptance uses the stamp: a later settings change neither refuses nor re-prices", async () => {
    await createGas("g1", gas());
    await h.seed("settings/platform", { ...PROD, gas: { ...PROD.gas, refill3kg: 90 } });
    const r = await acceptJob("gas", D, "g1");
    assert.equal(r.success, true);
    assert.equal((await h.read("gas_orders/g1")).verifiedPrice.total, 62);
  });

  test("GPR-09 an order accepted before its create trigger ran is verified and stamped in the acceptance", async () => {
    await h.seed("gas_orders/g1", gas());
    assert.equal((await acceptJob("gas", D, "g1")).success, true);
    const o = await h.read("gas_orders/g1");
    assert.equal(o.verifiedPrice.total, 62);
    await h.seed("gas_orders/g2", { ...gas(), totalPrice: 70 });
    assert.equal((await acceptJob("gas", D2, "g2")).detail, "price_changed");
  });
});

describe("Gas settlement on the verified price", () => {
  async function deliver(id, fields, runs = 1) {
    const before = (await h.read(`gas_orders/${id}`));
    const afterDoc = { ...before, ...fields, status: "delivered", otpSubmitted: "4821" };
    await h.seed(`gas_orders/${id}`, afterDoc);
    await h.seed(`order_completion_codes/gas_orders_${id}`, { code: "4821", passengerId: P });
    const ev = updateEvent(id, { ...afterDoc, status: "returning" }, afterDoc);
    await Promise.all(Array.from({ length: runs }, () => trips.onGasOrderCompleted.run(ev)));
  }

  test("GPR-20 cash: commission from the stamp, once, even after the fee setting changed", async () => {
    await createGas("g1", gas());
    assert.equal((await acceptJob("gas", D, "g1")).success, true);
    await h.seed("settings/platform", { ...PROD, platformFeePercent: 25 });
    await deliver("g1", {}, 3);
    const ledger = await h.read("ledger/commission_gas_g1");
    assert.deepEqual([ledger.grossFare, ledger.amount], [62, 9.3]);
    assert.equal((await h.read(`drivers/${D}`)).commissionOwed, 9.3);
    assert.equal(await h.count("ledger", "referenceId", "g1"), 1);
  });

  test("GPR-21 wallet: a hold equal to the stamped total is released once; any other amount moves nothing", async () => {
    await h.enableDeliveryGasWallet();
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 62 });
    for (const [id, amount, released] of [["g1", 62, true], ["g2", 70, false]]) {
      await h.seed(`escrows/e-${id}`, { userId: P, amount, platformFee: 9.3, driverNet: 52.7, status: "HELD",
        referenceId: id, referenceType: "gas_order" });
      const g = gas({ paymentMethod: "wallet", escrowId: `e-${id}` });
      await createGas(id, g);
      await h.db().collection("gas_orders").doc(id).update({ driverId: D, status: "returning" });
      await deliver(id, {}, 2);
      const e = await h.read(`escrows/e-${id}`);
      assert.equal(e.status, released ? "RELEASED" : "HELD", id);
      const o = await h.read(`gas_orders/${id}`);
      assert.equal(o.walletProcessed === true, released, id);
      if (!released) assert.equal(o.settlementFailureReason, "hold_amount_mismatch");
    }
  });

  test("GPR-22 a malformed platform fee blocks delivery settlement instead of settling NaN", async () => {
    await h.seed("settings/platform", { platformFeePercent: "fifteen" });
    const d = { ...delivery({ status: "completed", driverId: D, otpSubmitted: "4821" }) };
    await h.seed("deliveries/d1", d);
    await h.seed("order_completion_codes/deliveries_d1", { code: "4821", passengerId: P });
    await trips.onDeliveryCompleted.run(updateEvent("d1", { ...d, status: "arrivedAtDropoff" }, d));
    const o = await h.read("deliveries/d1");
    assert.notEqual(o.walletProcessed, true);
    assert.equal(await h.read("ledger/commission_delivery_d1"), null);
  });
});
