// Gas supplier-order fulfilment (gas_supplier_fulfilment.js): gated off by
// default; payment is verified server-side against an untrusted escrow;
// supplier, driver and passenger steps are authorized; completion captures
// the hold and frees the driver; cancellation refunds; the ledger posts
// from the captured order. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const g = require("../../gas_supplier_orders");
const f = require("../../gas_supplier_fulfilment");
const ledger = require("../../gas_settlement_ledger");
const escrow = require("../../escrow");

const { GeoPoint } = h.admin.firestore;
const PAX = "gsf-pax", OTHER_PAX = "gsf-pax2";
const SUP_USER = "gsf-supplier-user", SUP_B_USER = "gsf-supplier-b-user", REVOKED = "gsf-revoked";
const DRIVER = "gsf-driver", DRIVER2 = "gsf-driver2", FAR_DRIVER = "gsf-far", PRAGYIA = "gsf-pragyia";
const SUPER = "gsf-super", ADMIN = "gsf-admin";
const S = "sup1", SB = "sup2", ST = "st1", PID = "exchangeEmpty_kg12_5_goGas";
const STATION_AT = { latitude: 5.6698, longitude: -0.0166 };
const HOME = { latitude: 5.6800, longitude: -0.0100 };
const FAR = { latitude: 5.6037, longitude: -0.187 };


// The routing provider (Google Routes API in production) is stubbed: every
// station-to-customer route measures ROAD_M metres unless a test says otherwise.
const dq = require("../../delivery_quotes");
const { RoutingError } = require("../../delivery_pricing");
const ROAD_M = 4300;
let routeCalls = 0;
const routeIs = (fn) => dq._setRouteProviderForTests(async (p, d) => { routeCalls++; return fn(p, d); });
const call = (fn, data, uid) => h.callCallable(fn, uid, data);
async function rejects(promise, code, reason) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, `${e.code}: ${e.message} ${JSON.stringify(e.details)}`);
    if (reason) assert.equal(e.details?.reason, reason, JSON.stringify(e.details));
    return true;
  });
}

function driver(o = {}) {
  return { role: "driver_delivery", isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true,
    currentTripId: null, vehicleType: "motorcycle", location: new GeoPoint(HOME.latitude + 0.01, HOME.longitude), ...o };
}

async function seedWorld({ flag = true } = {}) {
  if (flag) await h.seed(f.FLAG_DOC, { enabled: true });
  await h.seed("settings/platform", { platformFeePercent: 15, gas: { baseFare: 8, perKm: 2, minDeliveryFee: 12, roundTripFee: 30 } });
  for (const [id, legalName] of [[S, "Supplier A"], [SB, "Supplier B"]]) {
    await h.seed(`gas_suppliers/${id}`, { legalName, status: "approved", ordersEnabled: true, fulfillment: { exchangeEmpty: true, pickupAndReturn: true }, riderArrangement: "ctsgo_dispatch" });
    await h.seed(`gas_suppliers/${id}/stations/${ST}`, { name: `${legalName} station`, supplierId: id, status: "verified", address: "Station road",
      location: new GeoPoint(STATION_AT.latitude, STATION_AT.longitude), serviceRadiusKm: 10, supportedSizes: ["kg12_5"], fulfillment: { exchangeEmpty: true, pickupAndReturn: true } });
    for (const orderType of ["exchangeEmpty", "pickupAndReturn"]) {
      await h.seed(`gas_suppliers/${id}/stations/${ST}/products/${orderType}_kg12_5_goGas`, { orderType, cylinderSize: "kg12_5", brand: "goGas", price: 150, handlingFee: 0, currency: "GHS", priceVersion: 1, availability: "available", verified: true });
    }
  }
  const member = (uid, supplierId, status = "active") => h.seed(`gas_supplier_members/${uid}`, { uid, supplierId, role: "owner", status, version: 1, createdBy: SUPER, updatedBy: SUPER, createdAt: new Date(), updatedAt: new Date() });
  await member(SUP_USER, S);
  await member(SUP_B_USER, SB);
  await member(REVOKED, S, "revoked");
  for (const uid of [PAX, OTHER_PAX]) await h.seed(`wallets/${uid}`, { userId: uid, balance: 1000, heldBalance: 0 });
  await h.seed(`drivers/${DRIVER}`, driver());
  await h.seed(`drivers/${DRIVER2}`, driver());
  await h.seed(`drivers/${FAR_DRIVER}`, driver({ location: new GeoPoint(FAR.latitude, FAR.longitude) }));
  await h.seed(`drivers/${PRAGYIA}`, driver({ vehicleType: "pragyia" }));
  await h.seed(`admins/${SUPER}`, { active: true, role: "super_admin" });
  await h.seed(`admins/${ADMIN}`, { active: true, role: "admin" });
  // Test fixture terms, not a commercial rate.
  await h.seedGasCommissionTerms({ rateBps: 1000, approvedBy: SUPER, settlementHoldHours: 0 });
}

/** quote -> order -> hold of `holdAmount` (default: the exact total). */
async function orderAndHold({ uid = PAX, productId = PID, holdAmount } = {}) {
  const q = await call(g.quoteGasSupplierOrder, { supplierId: S, stationId: ST, productId, quantity: 2, location: HOME, address: "My house" }, uid);
  const o = await call(g.createGasSupplierOrder, { quoteId: q.quoteId }, uid);
  const { escrowId } = await call(escrow.holdBalance, { amount: holdAmount ?? o.total, serviceType: "gas", referenceType: "gas_supplier_order" }, uid);
  return { orderId: o.orderId, total: o.total, escrowId };
}

async function paidAndConfirmed() {
  const o = await orderAndHold();
  await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
  await call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, SUP_USER);
  return o;
}

async function delivered() {
  const o = await paidAndConfirmed();
  await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
  await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER);
  await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
  const code = (await h.read(`gas_supplier_orders/${o.orderId}`)).completionCode;
  await call(f.completeGasSupplierOrder, { orderId: o.orderId, code }, DRIVER);
  return o;
}

after(() => { dq._setRouteProviderForTests(null); return h.fft.cleanup(); });
beforeEach(async () => {
  await h.clearFirestore(); await seedWorld();
  routeCalls = 0;
  routeIs(() => ({ distanceMeters: ROAD_M, durationSeconds: 600 }));
});

describe("gate", () => {
  test("GSF-G01 every callable but cancellation refuses while the flag is missing or false", async () => {
    const entries = [f.payGasSupplierOrder, f.supplierRespondGasOrder, f.supplierHandOverGasOrder, f.listGasSupplierJobs, f.listMyGasSupplierJobs,
      f.acceptGasSupplierJob, f.arriveGasSupplierStation, f.completeGasSupplierOrder, f.adminReleaseGasSupplierDriver];
    for (const flag of [null, { enabled: false }, { enabled: "true" }]) {
      if (flag) await h.seed(f.FLAG_DOC, flag); else await h.db().doc(f.FLAG_DOC).delete();
      for (const fn of entries) await rejects(call(fn, { orderId: "x" }, SUPER), "unavailable", "gas_supplier_fulfilment_disabled");
      // Cancellation is not gated: an unknown order is simply not found.
      await rejects(call(f.cancelGasSupplierOrder, { orderId: "x" }, PAX), "not-found", "order_not_found");
      await rejects(call(f.adminCancelGasSupplierOrder, { orderId: "x", reason: "Switched off" }, ADMIN), "not-found", "order_not_found");
    }
  });

  test("GSF-G03 switched off with paid orders in flight: passenger and admin cancel refund the hold; nothing else moves", async () => {
    const before = await h.read(`wallets/${PAX}`);
    const pending = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: pending.orderId, escrowId: pending.escrowId }, PAX);
    const assigned = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: assigned.orderId }, DRIVER);
    await h.seed(f.FLAG_DOC, { enabled: false });

    // New work stays refused.
    await rejects(call(f.supplierRespondGasOrder, { orderId: pending.orderId, decision: "accept" }, SUP_USER), "unavailable", "gas_supplier_fulfilment_disabled");
    await rejects(call(f.arriveGasSupplierStation, { orderId: assigned.orderId }, DRIVER), "unavailable", "gas_supplier_fulfilment_disabled");
    await rejects(call(escrow.holdBalance, { amount: 10, serviceType: "gas", referenceType: "gas_supplier_order" }, PAX), "failed-precondition", "supplier_gas_disabled");

    // The same authorization and status rules still apply.
    await rejects(call(f.cancelGasSupplierOrder, { orderId: pending.orderId }, OTHER_PAX), "not-found");
    await rejects(call(f.cancelGasSupplierOrder, { orderId: assigned.orderId }, PAX), "failed-precondition", "cannot_cancel");
    await rejects(call(f.adminCancelGasSupplierOrder, { orderId: assigned.orderId, reason: "Switched off" }, PAX), "permission-denied");
    await rejects(call(f.adminCancelGasSupplierOrder, { orderId: assigned.orderId }, ADMIN), "invalid-argument", "reason_required");

    const p = await call(f.cancelGasSupplierOrder, { orderId: pending.orderId }, PAX);
    assert.deepEqual([p.status, p.refunded, p.refundPending], ["cancelled", true, false]);
    const a = await call(f.adminCancelGasSupplierOrder, { orderId: assigned.orderId, reason: "Service switched off" }, ADMIN);
    assert.deepEqual([a.status, a.refunded, a.refundPending], ["cancelled", true, false]);

    for (const o of [pending, assigned]) {
      assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "REFUNDED");
      assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).payment.status, "refunded");
    }
    assert.deepEqual(await h.read(`drivers/${DRIVER}`).then((d) => [d.currentTripId, d.isAvailable]), [null, true]);
    const w = await h.read(`wallets/${PAX}`);
    assert.deepEqual([w.balance, w.heldBalance], [before.balance, 0], "both holds came back in full");
    assert.equal(await h.count("ledger", "type", "REFUND"), 2);

    // Repeats while off change nothing.
    await call(f.cancelGasSupplierOrder, { orderId: pending.orderId }, PAX);
    await call(f.adminCancelGasSupplierOrder, { orderId: assigned.orderId, reason: "Service switched off" }, ADMIN);
    assert.equal(await h.count("ledger", "type", "REFUND"), 2);
  });
});

describe("ordering status", () => {
  test("GSF-G02 the status callable reports the flag and needs a signed-in user", async () => {
    assert.deepEqual(await call(f.gasSupplierOrderingStatus, {}, PAX), { enabled: true });
    await h.seed(f.FLAG_DOC, { enabled: false });
    assert.deepEqual(await call(f.gasSupplierOrderingStatus, {}, PAX), { enabled: false });
    await h.db().doc(f.FLAG_DOC).delete();
    assert.deepEqual(await call(f.gasSupplierOrderingStatus, {}, PAX), { enabled: false });
    await rejects(call(f.gasSupplierOrderingStatus, {}, null), "unauthenticated");
  });
});

describe("happy path", () => {
  test("GSF-P01 pay, supplier, driver, hand-over, completion: hold captured, driver freed, ledger posts and reconciles", async () => {
    const before = await h.read(`wallets/${PAX}`);
    const o = await orderAndHold();
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "awaiting_payment");

    assert.deepEqual(await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX), { orderId: o.orderId, status: "pendingApproval", alreadyPaid: false });
    const paid = await h.read(`gas_supplier_orders/${o.orderId}`);
    assert.match(paid.completionCode, /^\d{4}$/);
    assert.equal(paid.payment.escrowId, o.escrowId);
    assert.equal(paid.payment.status, "held");
    assert.deepEqual(await h.read(`escrows/${o.escrowId}`).then((e) => [e.status, e.referenceId, e.referenceType]), ["HELD", o.orderId, "gas_supplier_order"]);

    await call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, SUP_USER);
    const jobs = (await call(f.listGasSupplierJobs, {}, DRIVER)).jobs;
    assert.deepEqual(jobs.map((j) => j.orderId), [o.orderId]);
    assert.ok(!JSON.stringify(jobs).includes(paid.completionCode) || paid.completionCode.length < 4, "job list must not include the completion code");
    assert.equal(jobs[0].completionCode, undefined);

    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    assert.deepEqual(await h.read(`drivers/${DRIVER}`).then((d) => [d.currentTripId, d.currentTripType, d.isAvailable]), [o.orderId, "gas_supplier_order", false]);
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    await call(f.completeGasSupplierOrder, { orderId: o.orderId, code: paid.completionCode }, DRIVER);

    const done = await h.read(`gas_supplier_orders/${o.orderId}`);
    assert.equal(done.status, "delivered");
    assert.equal(done.payment.status, "captured");
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}/finance/allocation`)).settlement.status, "accrued",
      "delivery posts the entitlements from the allocation, and pays nobody by itself");
    assert.equal((await h.db().collection("gas_settlement_ledger").get()).size, 3);
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "CAPTURED");
    const wallet = await h.read(`wallets/${PAX}`);
    assert.equal(Math.round(wallet.balance * 100), Math.round((before.balance - o.total) * 100));
    assert.equal(wallet.heldBalance, 0);
    assert.deepEqual(await h.read(`drivers/${DRIVER}`).then((d) => [d.currentTripId, d.isAvailable]), [null, true]);
    assert.equal((await h.read(`ledger/capture_${o.escrowId}`)).amount, o.total);
    assert.equal(await h.count("ledger", "type", "RELEASE"), 0, "the driverNet release must never run");
    assert.equal(await h.read(`wallets/${DRIVER}`), null, "no driver wallet is credited at completion");

    const events = (await h.db().collection(`gas_supplier_orders/${o.orderId}/events`).get()).docs.map((d) => d.data().to);
    assert.deepEqual(events.sort(), ["atStation", "confirmed", "delivered", "driverAssigned", "outForDelivery", "pendingApproval"].sort());

    // Delivery posted the entitlements; a super admin's manual post is a no-op, and nobody else may post.
    await rejects(call(ledger.adminPostGasSupplierEntitlements, { orderId: o.orderId }, ADMIN), "permission-denied");
    assert.equal((await call(ledger.adminPostGasSupplierEntitlements, { orderId: o.orderId }, SUPER)).alreadyPosted, true);
    assert.equal((await h.db().collection("gas_settlement_ledger").get()).size, 3, "posted once");
    const entries = (await h.db().collection("gas_settlement_ledger").where("orderId", "==", o.orderId).get()).docs.map((d) => d.data());
    const by = Object.fromEntries(entries.map((e) => [e.party, e.amountPesewas]));
    const snap = done.priceSnapshot;
    assert.equal(by.supplier + by.driver + by.platform, Math.round(snap.total * 100));
    assert.equal(by.driver, Math.round(snap.deliveryFee * 100));
    assert.equal(by.platform, Math.floor(Math.round(snap.productAmount * 100) * 1000 / 10000));
    // The ledger posts exactly the allocation the order was created with.
    const alloc = await h.read(`gas_supplier_orders/${o.orderId}/finance/allocation`);
    assert.deepEqual([by.supplier, by.driver, by.platform], [alloc.supplierNetPesewas, alloc.driverNetPesewas, alloc.commissionPesewas]);
    assert.equal(alloc.settlement.status, "accrued");
    assert.equal(await h.count("withdrawals", "userId", DRIVER), 0, "no payout is created");
  });

  test("GSF-P03 a handling fee: the customer pays product + handling + delivery; commission is on the product only", async () => {
    await h.db().doc(`gas_suppliers/${S}/stations/${ST}/products/${PID}`).update({ handlingFee: 2.5 });
    const o = await orderAndHold();
    const order = await h.read(`gas_supplier_orders/${o.orderId}`);
    const p = order.priceSnapshot;
    assert.deepEqual([p.productAmount, p.handlingFee], [300, 5], "2 × 150 and 2 × 2.50");
    assert.equal(Math.round(p.total * 100), 30000 + 500 + Math.round(p.deliveryFee * 100), "no other charge in the total");
    const a = await h.read(`gas_supplier_orders/${o.orderId}/finance/allocation`);
    assert.deepEqual([a.commissionBasePesewas, a.commissionPesewas, a.supplierGrossPesewas, a.supplierNetPesewas, a.driverNetPesewas],
      [30000, 3000, 30500, 27500, Math.round(p.deliveryFee * 100)]);
    assert.equal(a.customerTotalPesewas, Math.round(p.total * 100));
    assert.equal(a.commissionTermsId, "v1");
    // The order document (which its passenger reads) carries no commission or supplier net.
    for (const k of ["allocation", "commission", "commissionPesewas", "supplierNetPesewas", "rateBps"]) assert.equal(order[k], undefined, k);
    assert.ok(!JSON.stringify(order).includes("commission"));
  });

  test("GSF-C01 no usable terms: no quote (and no route request) and no order", async () => {
    await h.db().doc("gas_commission_terms/current").delete();
    await rejects(call(g.quoteGasSupplierOrder, { supplierId: S, stationId: ST, productId: PID, quantity: 1, location: HOME }, PAX), "failed-precondition", "commission_terms_missing");
    assert.equal(routeCalls, 0);
    await h.seedGasCommissionTerms({ approvedBy: SUPER });
    const q = await call(g.quoteGasSupplierOrder, { supplierId: S, stationId: ST, productId: PID, quantity: 1, location: HOME }, PAX);
    await h.db().doc("gas_commission_terms/current").update({ active: false });
    await rejects(call(g.createGasSupplierOrder, { quoteId: q.quoteId }, PAX), "failed-precondition", "commission_terms_inactive");
    assert.equal(await h.read(`gas_supplier_orders/${q.quoteId}`), null);
    assert.equal(await h.read(`gas_supplier_orders/${q.quoteId}/finance/allocation`), null);
  });

  test("GSF-C02 terms switched off after the order: payment refused, the hold stays unbound and refundable", async () => {
    const o = await orderAndHold();
    await h.db().doc("gas_commission_terms/current").update({ active: false });
    await rejects(call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX), "failed-precondition", "commission_terms_inactive");
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "awaiting_payment");
    const e = await h.read(`escrows/${o.escrowId}`);
    assert.deepEqual([e.status, e.referenceId ?? null], ["HELD", null]);
  });

  test("GSF-C03 a missing or altered allocation blocks payment", async () => {
    const o = await orderAndHold();
    const ref = h.db().doc(`gas_supplier_orders/${o.orderId}/finance/allocation`);
    const a = (await ref.get()).data();
    await ref.update({ supplierNetPesewas: a.supplierNetPesewas + 100, commissionPesewas: a.commissionPesewas - 100 });
    await rejects(call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX), "failed-precondition", "allocation_does_not_reconcile");
    await ref.delete();
    await rejects(call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX), "failed-precondition", "allocation_missing");
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "awaiting_payment");
  });

  test("GSF-C04 new terms apply to new orders only", async () => {
    const first = await orderAndHold();
    await h.seedGasCommissionTerms({ version: 2, rateBps: 500, approvedBy: SUPER });
    const second = await orderAndHold();
    const rate = async (id) => (await h.read(`gas_supplier_orders/${id}/finance/allocation`)).commissionRateBps;
    assert.deepEqual([await rate(first.orderId), await rate(second.orderId)], [1000, 500]);
    // The first order still pays at its own (v1) allocation.
    await call(f.payGasSupplierOrder, { orderId: first.orderId, escrowId: first.escrowId }, PAX);
  });

  test("GSF-C05 a driver's job shows the delivery fee only: no commission, supplier amount or customer total", async () => {
    const o = await paidAndConfirmed();
    const [job] = (await call(f.listGasSupplierJobs, {}, DRIVER)).jobs;
    assert.equal(job.orderId, o.orderId);
    assert.ok(job.deliveryFee > 0);
    const text = JSON.stringify(job);
    for (const k of ["commission", "supplierNet", "productAmount", "total", "handling", "unitPrice", "escrow", "payment"]) assert.ok(!text.includes(k), k);
  });

  test("GSF-P02 repeated calls are idempotent", async () => {
    const o = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    assert.equal((await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX)).alreadyPaid, true);
    await call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, SUP_USER);
    await call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, SUP_USER);
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    assert.equal(await h.count(`gas_supplier_orders/${o.orderId}/events`, "to", "confirmed"), 1);
  });
});

describe("payment verification", () => {
  test("GSF-S01 forged amount, foreign or reused escrow, and someone else's order are refused; nothing changes", async () => {
    await h.seed(`wallets/${PAX}`, { userId: PAX, balance: 5000, heldBalance: 0 });
    const short = await orderAndHold({ holdAmount: 10 });
    await rejects(call(f.payGasSupplierOrder, { orderId: short.orderId, escrowId: short.escrowId }, PAX), "failed-precondition", "escrow_amount_mismatch");
    const extra = await orderAndHold({ holdAmount: 900 });
    await rejects(call(f.payGasSupplierOrder, { orderId: extra.orderId, escrowId: extra.escrowId }, PAX), "failed-precondition", "escrow_amount_mismatch");

    const mine = await orderAndHold();
    const theirs = await orderAndHold({ uid: OTHER_PAX });
    await rejects(call(f.payGasSupplierOrder, { orderId: mine.orderId, escrowId: theirs.escrowId }, PAX), "failed-precondition", "escrow_owner_mismatch");
    await rejects(call(f.payGasSupplierOrder, { orderId: theirs.orderId, escrowId: theirs.escrowId }, PAX), "not-found", "order_not_found");

    await call(f.payGasSupplierOrder, { orderId: mine.orderId, escrowId: mine.escrowId }, PAX);
    const second = await orderAndHold();
    await rejects(call(f.payGasSupplierOrder, { orderId: second.orderId, escrowId: mine.escrowId }, PAX), "failed-precondition");
    for (const o of [short, extra, second]) assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "awaiting_payment");
    assert.equal((await h.read(`escrows/${short.escrowId}`)).referenceId, null);
  });

  test("GSF-S02 client-chosen price or status fields are refused", async () => {
    const o = await orderAndHold();
    await rejects(call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId, total: 1 }, PAX), "invalid-argument", "unexpected_fields");
    await rejects(call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId, status: "confirmed" }, PAX), "invalid-argument", "unexpected_fields");
  });

  test("GSF-S03 a failed hold leaves the order unpaid", async () => {
    const q = await call(g.quoteGasSupplierOrder, { supplierId: S, stationId: ST, productId: PID, quantity: 2, location: HOME, address: "x" }, PAX);
    const o = await call(g.createGasSupplierOrder, { quoteId: q.quoteId }, PAX);
    await h.seed(`wallets/${PAX}`, { userId: PAX, balance: 1, heldBalance: 0 });
    await rejects(call(escrow.holdBalance, { amount: o.total, serviceType: "gas", referenceType: "gas_supplier_order" }, PAX), "failed-precondition");
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "awaiting_payment");
  });

  test("GSF-S04 stock, price, supplier status and quote expiry are rechecked at payment", async () => {
    const productPath = `gas_suppliers/${S}/stations/${ST}/products/${PID}`;
    const cases = [
      [() => h.db().doc(productPath).update({ availability: "out_of_stock" }), "product_unavailable"],
      [() => h.db().doc(productPath).update({ priceVersion: 2 }), "price_changed"],
      [() => h.db().doc(`gas_suppliers/${S}`).update({ status: "suspended" }), "supplier_not_approved"],
      [() => h.db().doc(`gas_suppliers/${S}`).update({ ordersEnabled: false }), "supplier_orders_disabled"],
    ];
    for (const [change, reason] of cases) {
      await h.clearFirestore(); await seedWorld();
      const o = await orderAndHold();
      await change();
      await rejects(call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX), "failed-precondition", reason);
    }
    await h.clearFirestore(); await seedWorld();
    const o = await orderAndHold();
    await h.db().doc(`gas_quotes/${o.orderId}`).update({ expiresAt: new Date(Date.now() - 60 * 60 * 1000) });
    await rejects(call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX), "failed-precondition", "quote_expired");
  });

  test("GSF-S05 pickupAndReturn cannot be paid: its pickup leg is not supported", async () => {
    const o = await orderAndHold({ productId: "pickupAndReturn_kg12_5_goGas" });
    await rejects(call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX), "failed-precondition", "order_type_not_supported");
  });

  test("GSF-S06 concurrent payment with the same hold transitions once", async () => {
    const o = await orderAndHold();
    const r = await Promise.allSettled([1, 2, 3].map(() => call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX)));
    assert.equal(r.filter((x) => x.status === "fulfilled").length >= 1, true);
    assert.equal(await h.count(`gas_supplier_orders/${o.orderId}/events`, "to", "pendingApproval"), 1);
  });
});

describe("supplier", () => {
  test("GSF-S10 only an active member of an approved supplier can act, and only on its own orders", async () => {
    const o = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    await rejects(call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, REVOKED), "permission-denied", "not_a_supplier_member");
    await rejects(call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, PAX), "permission-denied", "not_a_supplier_member");
    await rejects(call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, DRIVER), "permission-denied", "not_a_supplier_member");
    await rejects(call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, SUP_B_USER), "not-found", "order_not_found");
    await h.db().doc(`gas_suppliers/${S}`).update({ status: "suspended" });
    await rejects(call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, SUP_USER), "permission-denied", "supplier_not_approved");
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "pendingApproval");
  });

  test("GSF-S11 a supplier decline cancels and refunds the passenger in full", async () => {
    const before = await h.read(`wallets/${PAX}`);
    const o = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    await rejects(call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "decline" }, SUP_USER), "invalid-argument", "reason_required");
    await call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "decline", reason: "Out of 12.5 kg today" }, SUP_USER);
    const order = await h.read(`gas_supplier_orders/${o.orderId}`);
    assert.deepEqual([order.status, order.refundPending], ["cancelled", false]);
    assert.equal(order.payment.status, "refunded");
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "REFUNDED");
    const wallet = await h.read(`wallets/${PAX}`);
    assert.deepEqual([wallet.balance, wallet.heldBalance], [before.balance, 0]);
  });

  test("GSF-S12 hand-over only after the driver is at the station", async () => {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await rejects(call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER), "failed-precondition", "driver_not_at_station");
    await rejects(call(f.supplierHandOverGasOrder, { orderId: o.orderId }, DRIVER), "permission-denied", "not_a_supplier_member");
  });
});

describe("driver", () => {
  test("GSF-S20 eligibility comes from the dispatch policy", async () => {
    const o = await paidAndConfirmed();
    assert.deepEqual((await call(f.listGasSupplierJobs, {}, FAR_DRIVER)).jobs, []);
    assert.deepEqual((await call(f.listGasSupplierJobs, {}, PRAGYIA)).jobs, []);
    await rejects(call(f.acceptGasSupplierJob, { orderId: o.orderId }, FAR_DRIVER), "permission-denied", "outside_radius");
    await rejects(call(f.acceptGasSupplierJob, { orderId: o.orderId }, PRAGYIA), "permission-denied", "vehicle_not_eligible");
    await rejects(call(f.acceptGasSupplierJob, { orderId: o.orderId }, PAX), "permission-denied", "driver_not_found");
    await h.db().doc(`drivers/${DRIVER2}`).update({ currentTripId: "other-trip" });
    await rejects(call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER2), "permission-denied", "driver_on_job");
  });

  test("GSF-S21 two drivers racing for one job: exactly one gets it", async () => {
    const o = await paidAndConfirmed();
    const r = await Promise.allSettled([DRIVER, DRIVER2].map((d) => call(f.acceptGasSupplierJob, { orderId: o.orderId }, d)));
    assert.equal(r.filter((x) => x.status === "fulfilled").length, 1);
    const winner = (await h.read(`gas_supplier_orders/${o.orderId}`)).driverId;
    const loser = winner === DRIVER ? DRIVER2 : DRIVER;
    assert.equal((await h.read(`drivers/${loser}`)).currentTripId, null);
  });

  test("GSF-S22 wrong code, wrong driver or wrong order of steps cannot complete", async () => {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await rejects(call(f.completeGasSupplierOrder, { orderId: o.orderId, code: "0000" }, DRIVER), "failed-precondition", "invalid_transition");
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    const code = (await h.read(`gas_supplier_orders/${o.orderId}`)).completionCode;
    const wrong = code === "1234" ? "4321" : "1234";
    await rejects(call(f.completeGasSupplierOrder, { orderId: o.orderId, code: wrong }, DRIVER), "permission-denied", "completion_code_mismatch");
    await rejects(call(f.completeGasSupplierOrder, { orderId: o.orderId, code }, DRIVER2), "not-found", "order_not_found");
    await rejects(call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER2), "not-found");
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "HELD");
  });

  test("GSF-S23 a tampered hold is not captured", async () => {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    await h.db().doc(`escrows/${o.escrowId}`).update({ amount: 1 });
    const code = (await h.read(`gas_supplier_orders/${o.orderId}`)).completionCode;
    await rejects(call(f.completeGasSupplierOrder, { orderId: o.orderId, code }, DRIVER), "failed-precondition", "escrow_amount_mismatch");
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "outForDelivery");
  });
});

describe("cancellation", () => {
  test("GSF-S30 passengers can cancel only before a driver is assigned; refunds are complete", async () => {
    const unpaid = await orderAndHold();
    assert.equal((await call(f.cancelGasSupplierOrder, { orderId: unpaid.orderId }, PAX)).status, "cancelled");
    const o = await paidAndConfirmed();
    await rejects(call(f.cancelGasSupplierOrder, { orderId: o.orderId }, OTHER_PAX), "not-found");
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await rejects(call(f.cancelGasSupplierOrder, { orderId: o.orderId }, PAX), "failed-precondition", "cannot_cancel");
  });

  test("GSF-S31 admins cancel with a reason, the hold is refunded and the driver freed", async () => {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await rejects(call(f.adminCancelGasSupplierOrder, { orderId: o.orderId, reason: "x" }, PAX), "permission-denied");
    await rejects(call(f.adminCancelGasSupplierOrder, { orderId: o.orderId }, ADMIN), "invalid-argument", "reason_required");
    const r = await call(f.adminCancelGasSupplierOrder, { orderId: o.orderId, reason: "Station closed" }, ADMIN);
    assert.deepEqual([r.status, r.refunded, r.refundPending], ["cancelled", true, false]);
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "REFUNDED");
    assert.deepEqual(await h.read(`drivers/${DRIVER}`).then((d) => [d.currentTripId, d.isAvailable]), [null, true]);
  });

  test("GSF-S33 cancelled before payment: nothing held, nothing refunded, nothing to settle", async () => {
    const q = await call(g.quoteGasSupplierOrder, { supplierId: S, stationId: ST, productId: PID, quantity: 1, location: HOME }, PAX);
    const o = await call(g.createGasSupplierOrder, { quoteId: q.quoteId }, PAX);
    const r = await call(f.cancelGasSupplierOrder, { orderId: o.orderId }, PAX);
    assert.deepEqual([r.status, r.refunded, r.refundPending], ["cancelled", false, false]);
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).payment, undefined);
    await rejects(ledger.postOrderEntitlements(o.orderId), "failed-precondition", "order_not_delivered");
  });

  test("GSF-S34 cancelled after payment: refunded exactly once, never posted; repeats change nothing", async () => {
    const before = await h.read(`wallets/${PAX}`);
    const o = await paidAndConfirmed();
    const runs = await Promise.allSettled([1, 2, 3].map(() => call(f.cancelGasSupplierOrder, { orderId: o.orderId }, PAX)));
    assert.ok(runs.some((x) => x.status === "fulfilled"));
    await call(f.cancelGasSupplierOrder, { orderId: o.orderId }, PAX);
    const w = await h.read(`wallets/${PAX}`);
    assert.deepEqual([w.balance, w.heldBalance], [before.balance, 0], "the full hold came back once");
    assert.equal(await h.count("ledger", "type", "REFUND"), 1);
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).payment.status, "refunded");
    await rejects(ledger.postOrderEntitlements(o.orderId), "failed-precondition", "order_not_delivered");
    assert.equal((await h.db().collection("gas_settlement_ledger").get()).size, 0);
  });

  test("GSF-S32 delivered orders cannot be cancelled or refunded", async () => {
    const o = await delivered();
    await rejects(call(f.adminCancelGasSupplierOrder, { orderId: o.orderId, reason: "after the fact" }, ADMIN), "failed-precondition", "cannot_cancel");
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "CAPTURED");
  });
});

describe("existing escrow sweeps", () => {
  test("GSF-S40 a captured hold is ignored and an attached in-progress hold is never refunded by the stale sweep", async () => {
    const o1 = await delivered();
    const o2 = await paidAndConfirmed();
    const later = Date.now() + 48 * 60 * 60 * 1000;
    const assessed = await escrow.assessStaleEscrows({ now: later });
    assert.equal(assessed.find((a) => a.escrowId === o1.escrowId), undefined);
    const held = assessed.find((a) => a.escrowId === o2.escrowId);
    assert.ok(held, "the attached hold is assessed");
    assert.notEqual(held.action, "refund");
  });
});

// The passenger app's placeAndPay (gas_supplier_repository.dart): create the
// order, hold the server's total, pay; on a refused pay it calls
// refundEscrowOnError for its hold. A lost response or a second tap repeats
// these calls, so each repeat must leave exactly one paid hold.
describe("client retries and duplicate callbacks", () => {
  const refundOnError = (escrowId) => call(escrow.refundEscrowOnError, { escrowId, reason: "gas_supplier_payment_refused" }, PAX);

  test("GSF-R01 a repeated order submission after payment reports the paid status", async () => {
    const o = await orderAndHold();
    assert.equal((await call(g.createGasSupplierOrder, { quoteId: o.orderId }, PAX)).status, "awaiting_payment");
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    const again = await call(g.createGasSupplierOrder, { quoteId: o.orderId }, PAX);
    assert.deepEqual([again.orderId, again.alreadyCreated, again.status, again.total], [o.orderId, true, "pendingApproval", o.total]);
  });

  test("GSF-R02 the rollback cannot refund a hold the server already bound (pay succeeded, response lost)", async () => {
    const before = await h.read(`wallets/${PAX}`);
    const o = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    await rejects(refundOnError(o.escrowId), "failed-precondition");
    // The retried pay with the same hold is the duplicate callback: no second transition.
    assert.equal((await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX)).alreadyPaid, true);
    assert.equal(await h.count(`gas_supplier_orders/${o.orderId}/events`, "to", "pendingApproval"), 1);
    const w = await h.read(`wallets/${PAX}`);
    assert.deepEqual([w.balance, w.heldBalance], [before.balance - o.total, o.total]);
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "HELD");
  });

  test("GSF-R03 a second hold for an already-paid order is refused and returned in full", async () => {
    const before = await h.read(`wallets/${PAX}`);
    const o = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    const { escrowId: second } = await call(escrow.holdBalance, { amount: o.total, serviceType: "gas", referenceType: "gas_supplier_order" }, PAX);
    await rejects(call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: second }, PAX), "failed-precondition", "order_not_awaiting_payment");
    await refundOnError(second);
    assert.equal((await h.read(`escrows/${second}`)).status, "REFUNDED");
    const order = await h.read(`gas_supplier_orders/${o.orderId}`);
    assert.deepEqual([order.status, order.payment.escrowId], ["pendingApproval", o.escrowId]);
    const w = await h.read(`wallets/${PAX}`);
    assert.deepEqual([w.balance, w.heldBalance], [before.balance - o.total, o.total]);
  });

  test("GSF-R04 a refused payment returns the hold and the order stays unpaid and retryable", async () => {
    const before = await h.read(`wallets/${PAX}`);
    const o = await orderAndHold({ holdAmount: 10 });
    await rejects(call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX), "failed-precondition", "escrow_amount_mismatch");
    await refundOnError(o.escrowId);
    let w = await h.read(`wallets/${PAX}`);
    assert.deepEqual([w.balance, w.heldBalance], [before.balance, 0]);
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "awaiting_payment");
    // Retrying with the correct hold pays the same order.
    const { escrowId } = await call(escrow.holdBalance, { amount: o.total, serviceType: "gas", referenceType: "gas_supplier_order" }, PAX);
    assert.equal((await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId }, PAX)).status, "pendingApproval");
  });

  test("GSF-R05 the paid order names its supplier, station and product, matching its price snapshot", async () => {
    const o = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    const order = await h.read(`gas_supplier_orders/${o.orderId}`);
    assert.deepEqual([order.supplierId, order.stationId, order.productId], [S, ST, PID]);
    assert.deepEqual([order.priceSnapshot.supplierId, order.priceSnapshot.stationId, order.priceSnapshot.productId], [S, ST, PID]);
    assert.equal(order.passengerId, PAX);
    // Only the supplier it names can act on it.
    await rejects(call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, SUP_B_USER), "not-found", "order_not_found");
  });
});

// Driver job recovery (listMyGasSupplierJobs): the driver app asks the server
// which supplier job it holds, after leaving the screen or restarting.
describe("driver job recovery", () => {
  const mine = (uid, data = {}) => call(f.listMyGasSupplierJobs, data, uid);

  test("GSF-D01 the assigned driver gets the job back at every step, until it is delivered and the driver is free", async () => {
    const o = await paidAndConfirmed();
    assert.deepEqual((await mine(DRIVER)).jobs, []);
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    let [job] = (await mine(DRIVER)).jobs;
    assert.deepEqual([job.orderId, job.status, job.onDriverRecord, job.station.name, job.deliveryAddress], [o.orderId, "driverAssigned", true, "Supplier A station", "My house"]);
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER);
    assert.equal((await mine(DRIVER)).jobs[0].status, "atStation");
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    [job] = (await mine(DRIVER)).jobs;
    assert.equal(job.status, "outForDelivery");
    // Nothing about the passenger or the payment, and never the customer's code.
    const text = JSON.stringify(job);
    for (const k of ["completionCode", "passengerId", "payment", "escrowId", "priceSnapshot"]) assert.ok(!text.includes(k), k);
    const code = (await h.read(`gas_supplier_orders/${o.orderId}`)).completionCode;
    await call(f.completeGasSupplierOrder, { orderId: o.orderId, code }, DRIVER);
    assert.deepEqual((await mine(DRIVER)).jobs, []);
    const d = await h.read(`drivers/${DRIVER}`);
    assert.deepEqual([d.currentTripId, d.currentTripType, d.isAvailable], [null, null, true]);
  });

  test("GSF-D02 nobody else gets the job: other drivers, the passenger, the supplier; a named driver in the request is refused", async () => {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    for (const uid of [DRIVER2, PAX, SUP_USER, SUPER]) assert.deepEqual((await mine(uid)).jobs, [], uid);
    await rejects(mine(DRIVER2, { driverId: DRIVER }), "invalid-argument", "unexpected_fields");
    await rejects(mine(null), "unauthenticated");
    // And the other driver still cannot act on it.
    await rejects(call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER2), "not-found", "order_not_found");
  });

  test("GSF-D03 a cancelled job disappears and the driver is freed", async () => {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await call(f.adminCancelGasSupplierOrder, { orderId: o.orderId, reason: "customer unreachable" }, ADMIN);
    assert.deepEqual((await mine(DRIVER)).jobs, []);
    const d = await h.read(`drivers/${DRIVER}`);
    assert.deepEqual([d.currentTripId, d.isAvailable], [null, true]);
    await rejects(call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER), "failed-precondition", "invalid_transition");
  });

  test("GSF-D04 a reassigned job moves to the new driver only, and says whether their record names it", async () => {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    // An operator data fix: the order now names another driver.
    await h.db().doc(`gas_supplier_orders/${o.orderId}`).update({ driverId: DRIVER2 });
    assert.deepEqual((await mine(DRIVER)).jobs, []);
    const [job] = (await mine(DRIVER2)).jobs;
    assert.deepEqual([job.orderId, job.status, job.onDriverRecord], [o.orderId, "driverAssigned", false]);
    await rejects(call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER), "not-found", "order_not_found");
  });

  test("GSF-D05 confirmed (unassigned), delivered and missing orders are never a driver's current job", async () => {
    await paidAndConfirmed();
    await h.seed("gas_supplier_orders/stray", { driverId: DRIVER, status: "delivered", supplierId: S, stationId: ST });
    await h.seed("gas_supplier_orders/stray2", { driverId: DRIVER, status: "cancelled", supplierId: S, stationId: ST });
    assert.deepEqual((await mine(DRIVER)).jobs, []);
  });
});

describe("reassignment (admin releases the driver before hand-over)", () => {
  const release = (orderId, reason = "Driver unreachable", uid = ADMIN) =>
    call(f.adminReleaseGasSupplierDriver, { orderId, reason }, uid);

  test("GSF-A01 from driverAssigned or atStation: back to confirmed, driver freed, hold untouched, code unchanged", async () => {
    for (const atStation of [false, true]) {
      await h.clearFirestore(); await seedWorld();
      const o = await paidAndConfirmed();
      await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
      if (atStation) await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER);
      const before = await h.read(`gas_supplier_orders/${o.orderId}`);
      const r = await release(o.orderId);
      assert.deepEqual([r.status, r.releasedDriverId], ["confirmed", DRIVER]);
      const after = await h.read(`gas_supplier_orders/${o.orderId}`);
      assert.deepEqual([after.status, after.driverId, after.releasedDriverIds], ["confirmed", undefined, [DRIVER]]);
      assert.equal(after.completionCode, before.completionCode);
      assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "HELD");
      const d = await h.read(`drivers/${DRIVER}`);
      assert.deepEqual([d.currentTripId, d.isAvailable], [null, true]);
      const evs = (await h.db().collection(`gas_supplier_orders/${o.orderId}/events`).get()).docs.map((x) => x.data());
      assert.ok(evs.some((e) => e.to === "confirmed" && e.role === "admin" && e.reason === "Driver unreachable"));
    }
  });

  test("GSF-A02 the released driver cannot take it again; another eligible driver can and completes it", async () => {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await release(o.orderId);
    assert.ok(!(await call(f.listGasSupplierJobs, {}, DRIVER)).jobs.some((j) => j.orderId === o.orderId));
    await rejects(call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER), "permission-denied", "released_from_job");
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER2);
    await rejects(call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER), "not-found", "order_not_found");
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER2);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    const code = (await h.read(`gas_supplier_orders/${o.orderId}`)).completionCode;
    await call(f.completeGasSupplierOrder, { orderId: o.orderId, code }, DRIVER2);
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "delivered");
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "CAPTURED");
  });

  test("GSF-A03 not after hand-over, not without a reason, not by non-admins; a repeat changes nothing", async () => {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    for (const uid of [PAX, SUP_USER, DRIVER, DRIVER2]) {
      await assert.rejects(call(f.adminReleaseGasSupplierDriver, { orderId: o.orderId, reason: "x x x" }, uid), String(uid));
    }
    await rejects(release(o.orderId, ""), "invalid-argument", "reason_required");
    await rejects(call(f.adminReleaseGasSupplierDriver, { orderId: o.orderId, reason: "ok ok", driverId: DRIVER2 }, ADMIN),
      "invalid-argument", "unexpected_fields");
    await release(o.orderId);
    assert.equal((await release(o.orderId)).alreadyReleased, true);
    assert.deepEqual((await h.read(`gas_supplier_orders/${o.orderId}`)).releasedDriverIds, [DRIVER]);
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER2);
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER2);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    await rejects(release(o.orderId), "failed-precondition", "handed_over");
  });

  test("GSF-A04 a released driver already on another job keeps that job; the switch gates the call", async () => {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await h.db().doc(`drivers/${DRIVER}`).update({ currentTripId: "other-job" }); // operator fix meanwhile
    await release(o.orderId);
    assert.equal((await h.read(`drivers/${DRIVER}`)).currentTripId, "other-job");
    await h.seed(f.FLAG_DOC, { enabled: false });
    await rejects(release(o.orderId), "unavailable", "gas_supplier_fulfilment_disabled");
  });
});


describe("supplier response deadline", () => {
  const MIN = 60 * 1000;
  async function paid() {
    const o = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    return o;
  }
  const setDeadline = (minutes, enabled = true) => h.seed(f.FLAG_DOC, { enabled, supplierResponseMinutes: minutes });

  test("GSF-T01 the deadline is the setting when it is a whole number of minutes from 1 to 1440, else the agreed 10", async () => {
    assert.equal(f.DEFAULT_RESPONSE_MINUTES, 10);
    for (const v of [1, 30, 1440]) assert.equal(f.responseDeadlineMinutes({ supplierResponseMinutes: v }), v);
    for (const v of [undefined, null, 0, -5, 1.5, "30", 1441]) assert.equal(f.responseDeadlineMinutes({ supplierResponseMinutes: v }), 10, String(v));
    assert.equal(f.responseDeadlineMinutes(null), 10);
    // Not configured (seedWorld sets only enabled): 10 minutes.
    const o = await paid();
    assert.deepEqual(await f.expireUnansweredOrders({ now: Date.now() + 9 * MIN }), { deadlineMinutes: 10, expired: [] });
    assert.deepEqual((await f.expireUnansweredOrders({ now: Date.now() + 11 * MIN })).expired, [{ orderId: o.orderId, refunded: true }]);
  });

  test("GSF-T02 unanswered past the deadline: cancelled and refunded once; reruns, late accept and late decline change nothing", async () => {
    const before = await h.read(`wallets/${PAX}`);
    await setDeadline(30);
    const o = await paid();
    assert.deepEqual((await f.expireUnansweredOrders({ now: Date.now() + 10 * MIN })).expired, [], "still inside the deadline");
    const later = Date.now() + 31 * MIN;
    assert.deepEqual((await f.expireUnansweredOrders({ now: later })).expired, [{ orderId: o.orderId, refunded: true }]);
    const order = await h.read(`gas_supplier_orders/${o.orderId}`);
    assert.deepEqual([order.status, order.cancelledByRole, order.cancelReason, order.refundPending, order.payment.status],
      ["cancelled", "system", "supplier_no_response", false, "refunded"]);
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "REFUNDED");

    assert.deepEqual((await f.expireUnansweredOrders({ now: later })).expired, [], "a rerun changes nothing");
    await rejects(call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, SUP_USER), "failed-precondition", "order_not_pending");
    await rejects(call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "decline", reason: "Out of stock" }, SUP_USER), "failed-precondition", "order_not_pending");
    await call(f.cancelGasSupplierOrder, { orderId: o.orderId }, PAX);

    const w = await h.read(`wallets/${PAX}`);
    assert.deepEqual([w.balance, w.heldBalance], [before.balance, 0], "the full hold came back once");
    assert.equal(await h.count("ledger", "type", "REFUND"), 1);
    const events = (await h.db().collection(`gas_supplier_orders/${o.orderId}/events`).get()).docs.map((d) => d.data());
    assert.equal(events.filter((e) => e.to === "cancelled" && e.role === "system").length, 1);
  });

  test("GSF-T03 an order the supplier answered in time is never expired", async () => {
    await setDeadline(30);
    const accepted = await paidAndConfirmed();
    const r = await f.expireUnansweredOrders({ now: Date.now() + 120 * MIN });
    assert.deepEqual(r.expired, []);
    assert.equal((await h.read(`gas_supplier_orders/${accepted.orderId}`)).status, "confirmed");
    assert.equal((await h.read(`escrows/${accepted.escrowId}`)).status, "HELD");
  });

  test("GSF-T04 expiry still runs, and refunds, after ordering is switched off", async () => {
    const o = await paid();
    await setDeadline(30, false);
    assert.deepEqual((await f.expireUnansweredOrders({ now: Date.now() + 31 * MIN })).expired, [{ orderId: o.orderId, refunded: true }]);
  });

  test("GSF-T05 an unpaid order (no payment yet) is not the deadline's business", async () => {
    await setDeadline(30);
    const o = await orderAndHold();
    assert.deepEqual((await f.expireUnansweredOrders({ now: Date.now() + 120 * MIN })).expired, []);
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "awaiting_payment");
  });
});

describe("posting after delivery", () => {
  test("GSF-L01 a delivery whose entitlements cannot be posted still completes, posts nothing and raises one alert", async () => {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    // The terms version the order was created under is no longer approved.
    await h.db().doc("gas_commission_terms/v1").update({ status: "rejected" });
    const code = (await h.read(`gas_supplier_orders/${o.orderId}`)).completionCode;
    assert.equal((await call(f.completeGasSupplierOrder, { orderId: o.orderId, code }, DRIVER)).status, "delivered");
    assert.equal((await h.db().collection("gas_settlement_ledger").get()).size, 0);
    const alert = await h.read(`admin_alerts/gas_entitlements_not_posted_${o.orderId}`);
    assert.equal(alert.type, "gas_entitlements_not_posted");
    // A repeated completion call does not fail on the existing alert.
    assert.equal((await call(f.completeGasSupplierOrder, { orderId: o.orderId, code }, DRIVER)).status, "delivered");
  });
});

describe("settlement to payout", () => {
  test("GSF-M01 delivered → posted → daily statements → supplier paid by Mobile Money on confirmation, driver credited; every pesewa accounted for once", async () => {
    const payouts = require("../../gas_supplier_payouts");
    const sent = [];
    payouts._setTransportForTests(async (req) => { sent.push(req); return { data: { response_code: "000" } }; });
    try {
      await h.seed(payouts.PAYOUT_FLAG_DOC, { enabled: true });
      const o = await delivered();
      const alloc = await h.read(`gas_supplier_orders/${o.orderId}/finance/allocation`);
      const today = new Date().toISOString().slice(0, 10);
      const r = await ledger.prepareStatements(today, { now: Date.now() + 2 * 24 * 3600e3 });
      assert.deepEqual(r.exceptions, []);
      const supplierStmt = `${today}__supplier__${S}`, driverStmt = `${today}__driver__${DRIVER}`;
      assert.equal((await h.read(`gas_settlement_statements/${supplierStmt}`)).netPesewas, alloc.supplierNetPesewas);
      assert.equal((await h.read(`gas_settlement_statements/${driverStmt}`)).netPesewas, alloc.driverNetPesewas);
      assert.equal(await h.read(`gas_settlement_statements/${today}__platform__ctsgo`), null, "commission is never paid out");

      await h.db().doc(`gas_suppliers/${S}`).update({ payoutPreference: { method: "mtn_momo", accountNumber: "0241234567", accountName: "Supplier A" } });
      await call(payouts.adminApproveGasSupplierPayout, { statementId: supplierStmt }, SUPER);
      assert.equal(sent[0].amount * 100, alloc.supplierNetPesewas);
      assert.equal((await h.read(`gas_settlement_statements/${supplierStmt}`)).payoutStatus, "payout_in_progress");
      await call(payouts.adminResolveGasSupplierPayout, { statementId: supplierStmt, outcome: "paid", evidence: "Bridge ref CTS-1" }, SUPER);
      assert.equal((await h.read(`gas_settlement_statements/${supplierStmt}`)).payoutStatus, "paid");

      const driverBefore = (await h.read(`drivers/${DRIVER}`)).walletBalance ?? 0;
      await call(payouts.adminSettleGasDriverStatement, { statementId: driverStmt }, SUPER);
      const driverAfter = (await h.read(`drivers/${DRIVER}`)).walletBalance;
      assert.equal(Math.round((driverAfter - driverBefore) * 100), alloc.driverNetPesewas);
      assert.equal(alloc.supplierNetPesewas + alloc.driverNetPesewas + alloc.commissionPesewas, alloc.customerTotalPesewas);

      // A rerun of the day prepares nothing new: each entry is claimed once.
      const again = await ledger.prepareStatements(today, { now: Date.now() + 2 * 24 * 3600e3 });
      assert.ok(again.statements.every((x) => x.skipped), JSON.stringify(again.statements));
    } finally {
      payouts._setTransportForTests(null);
    }
  });
});

describe("supplier riders first, CTSGo fallback", () => {
  const fallback = () => h.db().doc(`gas_suppliers/${S}`).update({ riderArrangement: "supplier_riders_ctsgo_fallback" });
  async function paidOrder() {
    const o = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    return o;
  }
  const accept = (orderId, deliveryMode, uid = SUP_USER) =>
    call(f.supplierRespondGasOrder, { orderId, decision: "accept", ...(deliveryMode ? { deliveryMode } : {}) }, uid);
  const codeOf = async (orderId) => (await h.read(`gas_supplier_orders/${orderId}`)).completionCode;
  const jobIds = async (uid = DRIVER) => (await call(f.listGasSupplierJobs, {}, uid)).jobs.map((j) => j.orderId);

  test("GSF-F01 a supplier with its own riders chooses per order; a CTSGo-dispatch supplier cannot choose its own rider", async () => {
    const a = await paidOrder();
    await rejects(accept(a.orderId, "supplier_rider"), "failed-precondition", "delivery_mode_not_allowed");
    await rejects(accept(a.orderId, "drone"), "invalid-argument", "invalid_request");
    await accept(a.orderId);
    assert.equal((await h.read(`gas_supplier_orders/${a.orderId}`)).deliveryMode, "ctsgo_driver");

    await fallback();
    const b = await paidOrder();
    await rejects(accept(b.orderId), "invalid-argument", "delivery_mode_required");
    await accept(b.orderId, "supplier_rider");
    assert.deepEqual(await h.read(`gas_supplier_orders/${b.orderId}`).then((o) => [o.status, o.deliveryMode]), ["confirmed", "supplier_rider"]);
    await h.db().doc(`gas_suppliers/${S}`).update({ riderArrangement: "supplier_riders" });
    const c = await paidOrder().catch(() => null);
    assert.equal(c, null, "a supplier-riders-only supplier is not offered at all");
  });

  test("GSF-F02 an own-rider order is never a CTSGo job; the supplier hands it to its rider and completes it with the customer's code", async () => {
    await fallback();
    const o = await paidOrder();
    await accept(o.orderId, "supplier_rider");
    assert.ok(!(await jobIds()).includes(o.orderId));
    await rejects(call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER), "failed-precondition", "job_taken");
    await rejects(call(f.supplierCompleteGasOrder, { orderId: o.orderId, code: await codeOf(o.orderId) }, SUP_USER), "failed-precondition", "invalid_transition");
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "outForDelivery");
    await rejects(call(f.supplierRequestGasDriver, { orderId: o.orderId }, SUP_USER), "failed-precondition", "invalid_transition");
    // Nobody else completes it: a driver, another supplier, the passenger.
    for (const uid of [DRIVER, SUP_B_USER, PAX]) {
      const fn = uid === DRIVER ? f.completeGasSupplierOrder : f.supplierCompleteGasOrder;
      await rejects(call(fn, { orderId: o.orderId, code: await codeOf(o.orderId) }, uid), uid === PAX ? "permission-denied" : "not-found");
    }
    assert.equal((await call(f.supplierCompleteGasOrder, { orderId: o.orderId, code: await codeOf(o.orderId) }, SUP_USER)).status, "delivered");
    assert.equal((await call(f.supplierCompleteGasOrder, { orderId: o.orderId, code: await codeOf(o.orderId) }, SUP_USER)).status, "delivered", "a repeat is a no-op");

    const done = await h.read(`gas_supplier_orders/${o.orderId}`);
    assert.deepEqual([done.payment.status, done.deliveredByRole, done.driverId ?? null], ["captured", "supplier", null]);
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "CAPTURED");
    // The delivery fee is the supplier's, in its own uncommissioned entry; no driver entry.
    const alloc = await h.read(`gas_supplier_orders/${o.orderId}/finance/allocation`);
    const entries = (await h.db().collection("gas_settlement_ledger").where("orderId", "==", o.orderId).get()).docs.map((d) => d.data());
    const by = Object.fromEntries(entries.map((e) => [`${e.party}/${e.kind}`, e]));
    assert.deepEqual(Object.keys(by).sort(), ["platform/commission", "supplier/delivery_fee", "supplier/entitlement"]);
    assert.equal(by["supplier/delivery_fee"].amountPesewas, alloc.driverNetPesewas);
    assert.equal(by["supplier/delivery_fee"].partyId, S);
    assert.equal(by["platform/commission"].amountPesewas, Math.floor(alloc.productSubtotalPesewas * 1000 / 10000), "10% of the product only");
    assert.equal(alloc.supplierNetPesewas + alloc.driverNetPesewas + alloc.commissionPesewas, alloc.customerTotalPesewas);
    assert.equal(await h.count("ledger", "type", "RELEASE"), 0);

    // One daily statement for the supplier: product net plus its delivery fee. No driver statement.
    const today = new Date().toISOString().slice(0, 10);
    const r = await ledger.prepareStatements(today, { now: Date.now() + 2 * 24 * 3600e3 });
    assert.deepEqual(r.exceptions, []);
    assert.equal((await h.read(`gas_settlement_statements/${today}__supplier__${S}`)).netPesewas, alloc.supplierNetPesewas + alloc.driverNetPesewas);
    assert.equal((await h.db().collection("gas_settlement_statements").where("party", "==", "driver").get()).size, 0);
  });

  test("GSF-F03 CTSGo fallback: the supplier passes an own-rider order to CTSGo dispatch before it leaves the station", async () => {
    await fallback();
    const o = await paidOrder();
    await accept(o.orderId, "supplier_rider");
    await rejects(call(f.supplierRequestGasDriver, { orderId: o.orderId }, SUP_B_USER), "not-found");
    await call(f.supplierRequestGasDriver, { orderId: o.orderId }, SUP_USER);
    await call(f.supplierRequestGasDriver, { orderId: o.orderId }, SUP_USER); // repeat: no-op
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).deliveryMode, "ctsgo_driver");
    assert.ok((await jobIds()).includes(o.orderId));
    // Now the supplier cannot complete it; the CTSGo driver does, and earns the delivery fee.
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    await rejects(call(f.supplierCompleteGasOrder, { orderId: o.orderId, code: await codeOf(o.orderId) }, SUP_USER), "not-found");
    await call(f.completeGasSupplierOrder, { orderId: o.orderId, code: await codeOf(o.orderId) }, DRIVER);
    const driverEntry = await h.read(`gas_settlement_ledger/${o.orderId}__driver__entitlement`);
    assert.equal(driverEntry.partyId, DRIVER);
    assert.equal(await h.read(`gas_settlement_ledger/${o.orderId}__supplier__delivery_fee`), null);
  });

  test("GSF-F04 a reversal of an own-rider order negates its delivery fee in its own slot, once", async () => {
    await fallback();
    const o = await paidOrder();
    await accept(o.orderId, "supplier_rider");
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    await call(f.supplierCompleteGasOrder, { orderId: o.orderId, code: await codeOf(o.orderId) }, SUP_USER);
    await call(ledger.adminReverseGasSupplierEntitlements, { orderId: o.orderId, reason: "Wrong cylinder delivered" }, SUPER);
    await call(ledger.adminReverseGasSupplierEntitlements, { orderId: o.orderId, reason: "Wrong cylinder delivered" }, SUPER);
    const rev = await h.read(`gas_settlement_ledger/${o.orderId}__supplier_delivery__reversal`);
    assert.equal(rev.reversesEntryId, `${o.orderId}__supplier__delivery_fee`);
    assert.equal(rev.amountPesewas, -(await h.read(`gas_settlement_ledger/${o.orderId}__supplier__delivery_fee`)).amountPesewas);
    const all = (await h.db().collection("gas_settlement_ledger").where("orderId", "==", o.orderId).get()).docs.map((d) => d.data());
    assert.equal(all.length, 6);
    assert.equal(all.reduce((s, e) => s + e.amountPesewas, 0), 0, "everything nets to zero");
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "CAPTURED", "a reversal refunds nobody");
  });
});

describe("completion code attempts", () => {
  async function outForDelivery() {
    const o = await paidAndConfirmed();
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER);
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    return o;
  }
  const wrong = (code) => String((Number(code) + 1) % 10000).padStart(4, "0");

  test("GSF-K01 wrong codes are counted; after 5 the order locks for an admin, even with the right code", async () => {
    const o = await outForDelivery();
    const code = (await h.read(`gas_supplier_orders/${o.orderId}`)).completionCode;
    for (let i = 1; i <= 4; i++) {
      await rejects(call(f.completeGasSupplierOrder, { orderId: o.orderId, code: wrong(code) }, DRIVER), "permission-denied", "completion_code_mismatch");
      assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).completionFailures, i);
    }
    await rejects(call(f.completeGasSupplierOrder, { orderId: o.orderId, code: wrong(code) }, DRIVER), "permission-denied", "completion_code_locked");
    await rejects(call(f.completeGasSupplierOrder, { orderId: o.orderId, code }, DRIVER), "permission-denied", "completion_code_locked");
    const locked = await h.read(`gas_supplier_orders/${o.orderId}`);
    assert.deepEqual([locked.status, locked.completionFailures], ["outForDelivery", 5]);
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "HELD", "nothing captured");
    assert.equal((await h.read(`admin_alerts/gas_completion_locked_${o.orderId}`)).type, "gas_completion_locked");
    // The admin can still unwind it.
    assert.equal((await call(f.adminCancelGasSupplierOrder, { orderId: o.orderId, reason: "Code locked; customer not reached" }, ADMIN)).refunded, true);
  });

  test("GSF-K02 concurrent guesses are all counted: no more than 5 wrong codes are ever checked", async () => {
    const o = await outForDelivery();
    const code = (await h.read(`gas_supplier_orders/${o.orderId}`)).completionCode;
    const guesses = Array.from({ length: 12 }, (_, i) => String((Number(code) + 1 + i) % 10000).padStart(4, "0")).filter((g) => g !== code);
    await Promise.allSettled(guesses.map((g) => call(f.completeGasSupplierOrder, { orderId: o.orderId, code: g }, DRIVER)));
    const after = await h.read(`gas_supplier_orders/${o.orderId}`);
    assert.equal(after.completionFailures, 5);
    assert.equal(after.status, "outForDelivery");
  });

  test("GSF-K03 the right code within the limit still completes", async () => {
    const o = await outForDelivery();
    const code = (await h.read(`gas_supplier_orders/${o.orderId}`)).completionCode;
    await rejects(call(f.completeGasSupplierOrder, { orderId: o.orderId, code: wrong(code) }, DRIVER), "permission-denied", "completion_code_mismatch");
    assert.equal((await call(f.completeGasSupplierOrder, { orderId: o.orderId, code }, DRIVER)).status, "delivered");
  });
});

describe("deadline concurrency", () => {
  const MIN = 60 * 1000;
  async function paid() {
    const o = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    return o;
  }

  test("GSF-T06 expiry racing the supplier's accept: exactly one outcome, money consistent with it", async () => {
    for (let round = 0; round < 4; round++) {
      await h.clearFirestore(); await seedWorld();
      const before = await h.read(`wallets/${PAX}`);
      const o = await paid();
      const [accept] = await Promise.allSettled([
        call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept" }, SUP_USER),
        f.expireUnansweredOrders({ now: Date.now() + 11 * MIN }),
      ]);
      const order = await h.read(`gas_supplier_orders/${o.orderId}`);
      const escrowStatus = (await h.read(`escrows/${o.escrowId}`)).status;
      const w = await h.read(`wallets/${PAX}`);
      const refunds = await h.count("ledger", "type", "REFUND");
      if (order.status === "confirmed") {
        assert.equal(accept.status, "fulfilled");
        assert.deepEqual([escrowStatus, refunds, w.heldBalance > 0], ["HELD", 0, true], `round ${round}: accepted, still held`);
      } else {
        assert.equal(order.status, "cancelled", `round ${round}`);
        assert.equal(accept.status, "rejected", "a late accept is refused");
        assert.deepEqual([escrowStatus, refunds, w.heldBalance, w.balance], ["REFUNDED", 1, 0, before.balance], `round ${round}: expired, refunded once`);
      }
    }
  });

  test("GSF-T07 overlapping expiry runs cancel and refund once", async () => {
    const before = await h.read(`wallets/${PAX}`);
    const o = await paid();
    const later = Date.now() + 11 * MIN;
    const runs = await Promise.all([1, 2, 3].map(() => f.expireUnansweredOrders({ now: later })));
    assert.equal(runs.flatMap((r) => r.expired).length, 1, "one run expired it");
    assert.equal(await h.count("ledger", "type", "REFUND"), 1);
    assert.equal((await h.read(`wallets/${PAX}`)).balance, before.balance);
    const events = (await h.db().collection(`gas_supplier_orders/${o.orderId}/events`).get()).docs.map((d) => d.data());
    assert.equal(events.filter((e) => e.to === "cancelled").length, 1);
  });

  test("GSF-T08 expiry racing the passenger's own cancel: one cancellation, one refund", async () => {
    const before = await h.read(`wallets/${PAX}`);
    const o = await paid();
    await Promise.allSettled([
      call(f.cancelGasSupplierOrder, { orderId: o.orderId }, PAX),
      f.expireUnansweredOrders({ now: Date.now() + 11 * MIN }),
    ]);
    assert.equal((await h.read(`gas_supplier_orders/${o.orderId}`)).status, "cancelled");
    assert.equal(await h.count("ledger", "type", "REFUND"), 1);
    assert.equal((await h.read(`wallets/${PAX}`)).balance, before.balance);
  });
});

// Linked riders (spec §2, §3.2): the supplier accepts as "linked_rider",
// offers the order to one of its CTSGo-linked riders at a time, and only the
// named rider can accept (at the fee CTSGo pays) or decline it.
describe("linked riders", () => {
  const { Timestamp, FieldValue } = h.admin.firestore;
  const RA = "gsf-rider-a", RB = "gsf-rider-b", RC = "gsf-rider-c", RX = "gsf-rider-x"; // RX is Supplier B's
  const MIN = 60 * 1000;
  const rider = (name, o = {}) => driver({ displayName: name, lastLocationUpdate: Timestamp.now(), ...o });
  const link = (driverId, supplierId = S, status = "active") =>
    h.seed(`gas_supplier_riders/${driverId}`, { driverId, supplierId, status, version: 1, linkedBy: SUPER, linkedAt: new Date() });
  const readOrder = (id) => h.read(`gas_supplier_orders/${id}`);
  const codeOf = async (id) => (await readOrder(id)).completionCode;
  const feeOf = async (id) => (await h.read(`gas_supplier_orders/${id}/finance/allocation`)).driverNetPesewas;
  const assign = (orderId, riderId, replacesSeq, uid = SUP_USER) => call(f.supplierAssignGasRider, { orderId, riderId, replacesSeq }, uid);
  const acceptOffer = (orderId, offerSeq, uid) => call(f.acceptGasSupplierJob, { orderId, offerSeq }, uid);
  const decline = (orderId, offerSeq, uid) => call(f.declineGasSupplierRiderOffer, { orderId, offerSeq }, uid);
  const listRiders = (data, uid = SUP_USER) => call(f.supplierListGasRiders, data, uid);
  const jobsOf = (uid) => call(f.listGasSupplierJobs, {}, uid);
  const resetRider = (id = RA, name = "Rider A") => h.seed(`drivers/${id}`, rider(name));
  const eventCount = async (id) => (await h.db().collection(`gas_supplier_orders/${id}/events`).get()).size;

  /** Each rider state and the refusal it gives (at assignment and at acceptance). */
  const RIDER_STATES = () => [
    [{ isOnline: false }, "driver_unavailable"],
    [{ isAvailable: false }, "driver_unavailable"],
    [{ currentTripId: "other-trip" }, "driver_on_job"],
    [{ role: "driver_hailing" }, "wrong_service"],
    [{ vehicleType: "pragyia" }, "vehicle_not_eligible"],
    [{ location: new GeoPoint(HOME.latitude + 0.1, HOME.longitude) }, "outside_radius"], // about 11 km
    [{ location: FieldValue.delete() }, "driver_location_invalid"],
    [{ lastLocationUpdate: Timestamp.fromMillis(Date.now() - 11 * MIN) }, "driver_location_stale"],
    [{ isApproved: false }, "driver_not_approved"],
  ];

  beforeEach(async () => {
    for (const id of [S, SB]) await h.db().doc(`gas_suppliers/${id}`).update({ riderArrangement: "supplier_riders_ctsgo_fallback" });
    await h.seed(`wallets/${PAX}`, { userId: PAX, balance: 5000, heldBalance: 0 });
    for (const [id, name] of [[RA, "Rider A"], [RB, "Rider B"], [RC, "Rider C"], [RX, "Rider X"]]) await resetRider(id, name);
    await h.db().doc(`drivers/${DRIVER2}`).update({ lastLocationUpdate: Timestamp.now() });
    for (const id of [RA, RB, RC]) await link(id);
    await link(RX, SB);
  });

  async function linkedOrder(deliveryMode = "linked_rider") {
    const o = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    await call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept", deliveryMode }, SUP_USER);
    return o;
  }
  async function accepted(riderId = RA) {
    const o = await linkedOrder();
    const { offerSeq } = await assign(o.orderId, riderId, 0);
    await acceptOffer(o.orderId, offerSeq, riderId);
    return o;
  }

  test("GSF-LR00 accepting as linked rider needs the fallback arrangement and an active link", async () => {
    const o = await orderAndHold();
    await call(f.payGasSupplierOrder, { orderId: o.orderId, escrowId: o.escrowId }, PAX);
    const accept = () => call(f.supplierRespondGasOrder, { orderId: o.orderId, decision: "accept", deliveryMode: "linked_rider" }, SUP_USER);
    await h.db().doc(`gas_suppliers/${S}`).update({ riderArrangement: "ctsgo_dispatch" });
    await rejects(accept(), "failed-precondition", "delivery_mode_not_allowed");
    await h.db().doc(`gas_suppliers/${S}`).update({ riderArrangement: "supplier_riders_ctsgo_fallback" });
    for (const id of [RA, RB]) await h.db().doc(`gas_supplier_riders/${id}`).delete();
    await link(RC, S, "revoked");
    await rejects(accept(), "failed-precondition", "no_linked_riders");
    assert.equal((await readOrder(o.orderId)).status, "pendingApproval");
    await link(RA);
    assert.equal((await accept()).status, "confirmed");
  });

  test("GSF-LR01 accept as linked rider, list, assign; the rider accepts and delivers; the ledger pays the rider", async () => {
    const o = await linkedOrder();
    const confirmed = await readOrder(o.orderId);
    assert.deepEqual([confirmed.status, confirmed.deliveryMode, confirmed.riderOfferSeq, confirmed.riderDeclineCount, confirmed.declinedRiderIds],
      ["confirmed", "linked_rider", 0, 0, []]);
    assert.ok(confirmed.riderDeadlineAt.toMillis() > Date.now(), "the supplier has M minutes to offer it");
    const fee = await feeOf(o.orderId);

    const listed = await listRiders({ orderId: o.orderId });
    assert.equal(listed.deliveryFeePesewas, fee);
    const a = listed.riders.find((r) => r.riderId === RA);
    assert.deepEqual([a.name, a.vehicle, a.eligible, a.reason], ["Rider A", "motorcycle", true, null]);

    const r = await assign(o.orderId, RA, 0);
    assert.equal(r.orderId, o.orderId);
    assert.equal(r.offerSeq, 1);
    assert.ok(r.expiresAtMs > Date.now());
    const offered = await readOrder(o.orderId);
    assert.deepEqual([offered.riderOffer.driverId, offered.riderOffer.seq, offered.riderOffer.deliveryFeePesewas, offered.riderOfferSeq], [RA, 1, fee, 1]);
    assert.equal(offered.riderOffer.expiresAt.toMillis(), r.expiresAtMs);
    assert.equal(offered.riderDeadlineAt.toMillis(), r.expiresAtMs);

    // The rider sees an offer, not an open job; nobody's job list has the order.
    const mine = await jobsOf(RA);
    assert.deepEqual(mine.jobs.map((j) => j.orderId), []);
    assert.deepEqual(mine.offers.map((j) => [j.orderId, j.offerSeq, j.expiresAtMs, j.deliveryFeePesewas, j.feePaidBy]), [[o.orderId, 1, r.expiresAtMs, fee, "ctsgo"]]);
    assert.equal(mine.offers[0].station.name, "Supplier A station");
    assert.ok(!JSON.stringify(mine.offers).includes(confirmed.completionCode) || confirmed.completionCode.length < 4);
    assert.equal(typeof mine.serverNowMs, "number");
    assert.deepEqual((await jobsOf(RB)).offers, []);

    await acceptOffer(o.orderId, 1, RA);
    const taken = await readOrder(o.orderId);
    assert.deepEqual([taken.status, taken.driverId, taken.acceptedFeePesewas, taken.linkedSupplierId, taken.riderOffer],
      ["driverAssigned", RA, fee, S, undefined]);
    assert.deepEqual([taken.lastRiderOffer.driverId, taken.lastRiderOffer.seq, taken.lastRiderOffer.outcome], [RA, 1, "accepted"]);
    assert.deepEqual(await h.read(`drivers/${RA}`).then((d) => [d.currentTripId, d.currentTripType, d.isAvailable]), [o.orderId, "gas_supplier_order", false]);
    assert.equal((await acceptOffer(o.orderId, 1, RA)).status, "driverAssigned", "a repeat is a no-op");

    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, RA);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    await call(f.completeGasSupplierOrder, { orderId: o.orderId, code: await codeOf(o.orderId) }, RA);
    const done = await readOrder(o.orderId);
    assert.deepEqual([done.status, done.payment.status], ["delivered", "captured"]);
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "CAPTURED");

    const entry = await h.read(`gas_settlement_ledger/${o.orderId}__driver__entitlement`);
    assert.deepEqual([entry.party, entry.kind, entry.partyId, entry.amountPesewas, entry.basis.linkedSupplierId], ["driver", "entitlement", RA, fee, S]);
    assert.equal(await h.read(`gas_settlement_ledger/${o.orderId}__supplier__delivery_fee`), null);
    assert.equal(await h.read(`admin_alerts/gas_entitlements_not_posted_${o.orderId}`), null);
    assert.deepEqual(await h.read(`drivers/${RA}`).then((d) => [d.currentTripId, d.isAvailable]), [null, true]);
  });

  test("GSF-LR02 linked-rider and own-rider orders are never open CTSGo jobs, and other drivers cannot take them", async () => {
    const o = await linkedOrder();
    const own = await linkedOrder("supplier_rider");
    const ids = async (uid) => (await jobsOf(uid)).jobs.map((j) => j.orderId);
    for (const uid of [DRIVER2, RA]) {
      const jobs = await ids(uid);
      assert.ok(!jobs.includes(o.orderId) && !jobs.includes(own.orderId), uid);
    }
    await rejects(call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER2), "failed-precondition", "job_taken");
    await rejects(call(f.acceptGasSupplierJob, { orderId: o.orderId }, RA), "failed-precondition", "job_taken");

    const { offerSeq } = await assign(o.orderId, RA, 0);
    assert.ok(!(await ids(DRIVER2)).includes(o.orderId));
    assert.deepEqual((await jobsOf(DRIVER2)).offers, []);
    await rejects(call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER2), "failed-precondition", "job_taken");
    await rejects(acceptOffer(o.orderId, offerSeq, DRIVER2), "failed-precondition", "job_taken");
    await rejects(acceptOffer(own.orderId, 1, DRIVER2), "failed-precondition", "job_taken");
    const after = await readOrder(o.orderId);
    assert.deepEqual([after.status, after.driverId, after.riderOffer.driverId], ["confirmed", undefined, RA]);
  });

  test("GSF-LR03 assignment is refused for another supplier's order or rider, an unlinked or revoked rider, and other modes", async () => {
    const o = await linkedOrder();
    await rejects(assign(o.orderId, RA, 0, SUP_B_USER), "not-found", "order_not_found");
    await rejects(assign(o.orderId, RX, 0), "failed-precondition", "rider_not_linked");
    await rejects(assign(o.orderId, DRIVER2, 0), "failed-precondition", "rider_not_linked");
    await link(RB, S, "revoked");
    await rejects(assign(o.orderId, RB, 0), "failed-precondition", "rider_not_linked");
    await rejects(assign(o.orderId, RA, 0, PAX), "permission-denied", "not_a_supplier_member");
    await rejects(call(f.supplierAssignGasRider, { orderId: o.orderId, riderId: RA, replacesSeq: 0, deliveryFeePesewas: 1 }, SUP_USER), "invalid-argument", "unexpected_fields");
    await rejects(assign(o.orderId, RA, -1), "invalid-argument", "invalid_request");
    for (const mode of ["ctsgo_driver", "supplier_rider"]) {
      const x = await linkedOrder(mode);
      await rejects(assign(x.orderId, RA, 0), "failed-precondition", "invalid_transition");
    }
    const after = await readOrder(o.orderId);
    assert.deepEqual([after.riderOfferSeq, after.riderOffer], [0, undefined]);
  });

  test("GSF-LR04 each rider state gives its refusal at assignment, and the list shows the same reason", async () => {
    const o = await linkedOrder();
    for (const [patch, code] of RIDER_STATES()) {
      await resetRider();
      await h.db().doc(`drivers/${RA}`).update(patch);
      await rejects(assign(o.orderId, RA, 0), "failed-precondition", code);
      const listed = (await listRiders({ orderId: o.orderId })).riders.find((r) => r.riderId === RA);
      assert.deepEqual([listed.eligible, listed.reason], [false, code], code);
    }
    const after = await readOrder(o.orderId);
    assert.deepEqual([after.riderOfferSeq, after.riderOffer], [0, undefined]);
    await resetRider();
    assert.equal((await assign(o.orderId, RA, 0)).offerSeq, 1);
  });

  test("GSF-LR05 the same changes between the offer and the accept give the same refusals; the order is unchanged", async () => {
    const o = await linkedOrder();
    const { offerSeq } = await assign(o.orderId, RA, 0);
    const before = await readOrder(o.orderId);
    for (const [patch, code] of RIDER_STATES()) {
      await resetRider();
      await h.db().doc(`drivers/${RA}`).update(patch);
      await rejects(acceptOffer(o.orderId, offerSeq, RA), "permission-denied", code);
      assert.deepEqual(await readOrder(o.orderId), before, code);
    }
    await resetRider();
    await link(RA, S, "revoked");
    await rejects(acceptOffer(o.orderId, offerSeq, RA), "permission-denied", "rider_not_linked");
    assert.deepEqual(await readOrder(o.orderId), before);
    await link(RA);
    assert.equal((await acceptOffer(o.orderId, offerSeq, RA)).status, "driverAssigned");
  });

  test("GSF-LR06 two concurrent assignments from the same state: exactly one wins; the winner's retry returns its offer", async () => {
    const o = await linkedOrder();
    const r = await Promise.allSettled([RA, RB].map((id) => assign(o.orderId, id, 0)));
    const won = r.filter((x) => x.status === "fulfilled");
    assert.equal(won.length, 1);
    assert.equal(r.find((x) => x.status === "rejected").reason.details?.reason, "offer_changed");
    const order = await readOrder(o.orderId);
    assert.deepEqual([order.riderOfferSeq, won[0].value.offerSeq], [1, 1]);
    const winner = order.riderOffer.driverId;
    assert.deepEqual(await assign(o.orderId, winner, 0), won[0].value);
    assert.equal((await readOrder(o.orderId)).riderOfferSeq, 1);
    assert.equal(await h.count(`gas_supplier_orders/${o.orderId}/events`, "to", "confirmed"), 2, "the accept and one offer");
  });

  test("GSF-LR07 a rider holding a pending offer cannot be offered another order", async () => {
    const a = await linkedOrder();
    const b = await linkedOrder();
    await assign(a.orderId, RA, 0);
    await rejects(assign(b.orderId, RA, 0), "failed-precondition", "rider_has_pending_offer");
    const listed = (await listRiders({ orderId: b.orderId })).riders.find((r) => r.riderId === RA);
    assert.deepEqual([listed.eligible, listed.reason], [false, "has_pending_offer"]);
    assert.equal((await readOrder(b.orderId)).riderOfferSeq, 0);
    assert.equal((await assign(b.orderId, RB, 0)).offerSeq, 1);
  });

  test("GSF-LR08 after a re-offer from A to B: A can neither accept nor decline; B needs the current seq", async () => {
    const o = await linkedOrder();
    const first = await assign(o.orderId, RA, 0);
    const second = await assign(o.orderId, RB, first.offerSeq);
    assert.equal(second.offerSeq, 2);
    const order = await readOrder(o.orderId);
    assert.deepEqual([order.lastRiderOffer.driverId, order.lastRiderOffer.seq, order.lastRiderOffer.outcome], [RA, 1, "withdrawn"]);
    assert.deepEqual((await jobsOf(RA)).offers, []);
    await rejects(acceptOffer(o.orderId, first.offerSeq, RA), "failed-precondition", "job_taken");
    await rejects(decline(o.orderId, first.offerSeq, RA), "not-found", "offer_not_found");
    await rejects(acceptOffer(o.orderId, first.offerSeq, RB), "failed-precondition", "offer_stale");
    await rejects(decline(o.orderId, first.offerSeq, RB), "failed-precondition", "offer_stale");
    await rejects(assign(o.orderId, RC, first.offerSeq), "failed-precondition", "offer_changed");
    assert.deepEqual(await readOrder(o.orderId), order);
    assert.equal((await acceptOffer(o.orderId, second.offerSeq, RB)).status, "driverAssigned");
  });

  test("GSF-LR09 declines: a decliner is not offered again, a repeat is a no-op, the third decline falls back to CTSGo", async () => {
    const o = await linkedOrder();
    const first = await assign(o.orderId, RA, 0);
    const d = await decline(o.orderId, first.offerSeq, RA);
    assert.deepEqual(d, { orderId: o.orderId, status: "confirmed", fallback: false });
    const declined = await readOrder(o.orderId);
    assert.deepEqual([declined.riderOffer, declined.declinedRiderIds, declined.riderDeclineCount, declined.lastRiderOffer.outcome, declined.deliveryMode],
      [undefined, [RA], 1, "declined", "linked_rider"]);
    assert.ok(declined.riderDeadlineAt.toMillis() > Date.now(), "the window restarts");
    await rejects(assign(o.orderId, RA, 1), "failed-precondition", "rider_declined");
    const listed = (await listRiders({ orderId: o.orderId })).riders.find((r) => r.riderId === RA);
    assert.deepEqual([listed.eligible, listed.reason], [false, "declined_this_order"]);
    const second = await assign(o.orderId, RB, 1);
    await acceptOffer(o.orderId, second.offerSeq, RB);
    const before = await readOrder(o.orderId);
    const events = await eventCount(o.orderId);
    assert.deepEqual(await decline(o.orderId, first.offerSeq, RA), { orderId: o.orderId, status: "driverAssigned", fallback: false });
    assert.deepEqual(await readOrder(o.orderId), before, "a repeated decline changes nothing");
    assert.equal(await eventCount(o.orderId), events);

    // A fresh order; Rider B is on the first one, so a fourth rider makes three free ones.
    const RD = "gsf-rider-d";
    await resetRider(RD, "Rider D");
    await link(RD);
    const x = await linkedOrder();
    let seq = 0;
    for (const id of [RA, RC, RD]) {
      seq = (await assign(x.orderId, id, seq)).offerSeq;
      const res = await decline(x.orderId, seq, id);
      assert.equal(res.fallback, id === RD, id);
    }
    const fell = await readOrder(x.orderId);
    assert.deepEqual([fell.status, fell.deliveryMode, fell.ctsgoFallbackReason, fell.riderOffer, fell.riderDeclineCount],
      ["confirmed", "ctsgo_driver", "riders_declined", undefined, 3]);
    assert.ok((await jobsOf(DRIVER2)).jobs.some((j) => j.orderId === x.orderId), "an ordinary CTSGo job from here on");
    assert.deepEqual(await decline(x.orderId, seq, RD), { orderId: x.orderId, status: "confirmed", fallback: true });
  });

  test("GSF-LR16 completion for the linked rider: codes counted and locked; the supplier cannot complete; hand-over waits for the station", async () => {
    const o = await accepted(RA);
    await rejects(call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER), "failed-precondition", "driver_not_at_station");
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, RA);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    const code = await codeOf(o.orderId);
    await rejects(call(f.supplierCompleteGasOrder, { orderId: o.orderId, code }, SUP_USER), "not-found", "order_not_found");
    const wrong = String((Number(code) + 1) % 10000).padStart(4, "0");
    for (let i = 1; i <= 4; i++) {
      await rejects(call(f.completeGasSupplierOrder, { orderId: o.orderId, code: wrong }, RA), "permission-denied", "completion_code_mismatch");
      assert.equal((await readOrder(o.orderId)).completionFailures, i);
    }
    await rejects(call(f.completeGasSupplierOrder, { orderId: o.orderId, code: wrong }, RA), "permission-denied", "completion_code_locked");
    await rejects(call(f.completeGasSupplierOrder, { orderId: o.orderId, code }, RA), "permission-denied", "completion_code_locked");
    assert.deepEqual(await readOrder(o.orderId).then((x) => [x.status, x.completionFailures]), ["outForDelivery", 5]);
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "HELD");
  });

  test("GSF-LR17 the fee is fixed: an offer whose fee differs from the allocation cannot be accepted", async () => {
    const o = await linkedOrder();
    const { offerSeq } = await assign(o.orderId, RA, 0);
    const fee = await feeOf(o.orderId);
    await h.db().doc(`gas_supplier_orders/${o.orderId}`).update({ "riderOffer.deliveryFeePesewas": fee + 100 });
    const before = await readOrder(o.orderId);
    await rejects(acceptOffer(o.orderId, offerSeq, RA), "failed-precondition", "rider_fee_changed");
    assert.deepEqual(await readOrder(o.orderId), before);
    assert.equal((await h.read(`drivers/${RA}`)).currentTripId, null);
  });

  test("GSF-LR19 the supplier passes a pending-offer order to CTSGo; not after the rider accepted", async () => {
    const o = await linkedOrder();
    await assign(o.orderId, RA, 0);
    assert.deepEqual(await call(f.supplierRequestGasDriver, { orderId: o.orderId }, SUP_USER), { orderId: o.orderId, status: "confirmed", deliveryMode: "ctsgo_driver" });
    const fell = await readOrder(o.orderId);
    assert.deepEqual([fell.deliveryMode, fell.ctsgoFallbackReason, fell.riderOffer, fell.riderDeadlineAt], ["ctsgo_driver", "supplier_request", undefined, undefined]);
    assert.deepEqual([fell.lastRiderOffer.driverId, fell.lastRiderOffer.seq, fell.lastRiderOffer.outcome], [RA, 1, "withdrawn"]);
    assert.deepEqual((await jobsOf(RA)).offers, []);
    assert.ok((await jobsOf(DRIVER2)).jobs.some((j) => j.orderId === o.orderId));
    await call(f.supplierRequestGasDriver, { orderId: o.orderId }, SUP_USER); // repeat: no-op

    const taken = await accepted(RB);
    await rejects(call(f.supplierRequestGasDriver, { orderId: taken.orderId }, SUP_USER), "failed-precondition", "invalid_transition");
    assert.equal((await readOrder(taken.orderId)).deliveryMode, "linked_rider");
  });

  test("GSF-LR20 the rider list: the caller's active links only, no private driver data; other suppliers see none", async () => {
    await link(RC, S, "revoked");
    const all = await listRiders({});
    assert.deepEqual(all.riders.map((r) => r.riderId).sort(), [RA, RB].sort());
    assert.equal(all.deliveryFeePesewas, undefined);
    const o = await linkedOrder();
    const withOrder = await listRiders({ orderId: o.orderId });
    assert.deepEqual(withOrder.riders.map((r) => [r.riderId, r.eligible]).sort(), [[RA, true], [RB, true]].sort());
    for (const res of [all, withOrder]) {
      const text = JSON.stringify(res);
      for (const k of ["phone", "vehiclePlate", "location", "rating", "walletBalance", "distanceKm", "driverId"]) assert.ok(!text.includes(k), k);
    }
    await h.db().doc(`gas_supplier_riders/${RX}`).delete();
    assert.deepEqual((await listRiders({}, SUP_B_USER)).riders, []);
    await rejects(listRiders({ orderId: o.orderId }, SUP_B_USER), "not-found", "order_not_found");
    await rejects(listRiders({}, RA), "permission-denied", "not_a_supplier_member");
  });

  test("GSF-LR21 with the fulfilment flag off, every new callable is refused", async () => {
    for (const flag of [null, { enabled: false }]) {
      if (flag) await h.seed(f.FLAG_DOC, flag); else await h.db().doc(f.FLAG_DOC).delete();
      for (const fn of [f.supplierListGasRiders, f.supplierAssignGasRider, f.declineGasSupplierRiderOffer, f.listMyGasSupplierEarnings]) {
        await rejects(call(fn, { orderId: "x" }, SUP_USER), "unavailable", "gas_supplier_fulfilment_disabled");
      }
    }
  });

  // ── Deadlines, fallback, cancellation, release, earnings (Task 6) ──
  afterEach(() => f._setClockForTests(null));
  const sweep = async (now) => (await f.expireRiderOffers({ now })).fallbacks;
  async function delivered(riderId) {
    const o = await accepted(riderId);
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, riderId);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    await call(f.completeGasSupplierOrder, { orderId: o.orderId, code: await codeOf(o.orderId) }, riderId);
    return o;
  }

  test("GSF-LR10 an offer not accepted in time falls back to CTSGo once; the late accept is refused; a CTSGo driver delivers and is paid", async () => {
    const o = await linkedOrder();
    const { offerSeq, expiresAtMs } = await assign(o.orderId, RA, 0);
    assert.deepEqual(await sweep(expiresAtMs - 1), []);
    assert.deepEqual(await sweep(expiresAtMs), [{ orderId: o.orderId, reason: "rider_timeout" }]);
    const fell = await readOrder(o.orderId);
    assert.deepEqual([fell.status, fell.deliveryMode, fell.ctsgoFallbackReason, fell.riderOffer, fell.riderDeadlineAt],
      ["confirmed", "ctsgo_driver", "rider_timeout", undefined, undefined]);
    assert.deepEqual([fell.lastRiderOffer.driverId, fell.lastRiderOffer.seq, fell.lastRiderOffer.outcome], [RA, offerSeq, "timed_out"]);
    const events = await eventCount(o.orderId);
    assert.deepEqual(await sweep(expiresAtMs + 60 * MIN), [], "a rerun changes nothing");
    assert.deepEqual(await readOrder(o.orderId), fell);
    assert.equal(await eventCount(o.orderId), events);

    await rejects(acceptOffer(o.orderId, offerSeq, RA), "failed-precondition", "job_taken");
    assert.equal((await h.read(`drivers/${RA}`)).currentTripId, null);
    assert.ok((await jobsOf(DRIVER2)).jobs.some((j) => j.orderId === o.orderId));
    await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER2);
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER2);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    await call(f.completeGasSupplierOrder, { orderId: o.orderId, code: await codeOf(o.orderId) }, DRIVER2);
    const entry = await h.read(`gas_settlement_ledger/${o.orderId}__driver__entitlement`);
    assert.deepEqual([entry.partyId, entry.amountPesewas, entry.basis.deliveryMode, entry.basis.linkedSupplierId], [DRIVER2, await feeOf(o.orderId), "ctsgo_driver", undefined]);
  });

  test("GSF-LR11 an accept just before expiry racing the sweep at expiry: exactly one outcome, in either order", async () => {
    for (let round = 0; round < 6; round++) {
      f._setClockForTests(null);
      await resetRider();
      const o = await linkedOrder();
      const { offerSeq, expiresAtMs } = await assign(o.orderId, RA, 0);
      f._setClockForTests(() => expiresAtMs - 1);
      const calls = [() => acceptOffer(o.orderId, offerSeq, RA), () => f.expireRiderOffers({ now: expiresAtMs })];
      const ordered = round % 2 ? [calls[1], calls[0]] : calls;
      const settled = await Promise.allSettled(ordered.map((c) => c()));
      const [acc, sw] = round % 2 ? [settled[1], settled[0]] : settled;
      assert.equal(sw.status, "fulfilled");
      const order = await readOrder(o.orderId);
      const d = await h.read(`drivers/${RA}`);
      if (order.status === "driverAssigned") {
        assert.equal(acc.status, "fulfilled", `round ${round}`);
        assert.deepEqual(sw.value.fallbacks, [], `round ${round}`);
        assert.deepEqual([order.driverId, order.deliveryMode, d.currentTripId], [RA, "linked_rider", o.orderId], `round ${round}`);
      } else {
        assert.deepEqual([order.status, order.deliveryMode, order.ctsgoFallbackReason, order.driverId], ["confirmed", "ctsgo_driver", "rider_timeout", undefined], `round ${round}`);
        assert.equal(acc.status, "rejected", `round ${round}`);
        assert.equal(acc.reason.details?.reason, "job_taken");
        assert.deepEqual(sw.value.fallbacks, [{ orderId: o.orderId, reason: "rider_timeout" }]);
        assert.equal(d.currentTripId, null, `round ${round}`);
      }
    }
  });

  test("GSF-LR11b at or after expiresAt, before the sweep, the offer can be neither accepted nor declined", async () => {
    const o = await linkedOrder();
    const { offerSeq, expiresAtMs } = await assign(o.orderId, RA, 0);
    const before = await readOrder(o.orderId);
    f._setClockForTests(() => expiresAtMs);
    await rejects(acceptOffer(o.orderId, offerSeq, RA), "failed-precondition", "offer_expired");
    await rejects(decline(o.orderId, offerSeq, RA), "failed-precondition", "offer_expired");
    assert.deepEqual(await readOrder(o.orderId), before);
    assert.deepEqual((await jobsOf(RA)).offers, [], "an expired offer is not shown");
    assert.equal((await h.read(`drivers/${RA}`)).currentTripId, null);
    assert.deepEqual(await sweep(expiresAtMs), [{ orderId: o.orderId, reason: "rider_timeout" }]);
  });

  test("GSF-LR11c one malformed order does not stop the sweep: the others still fall back, and a failing sweep never stops the other", async () => {
    const good1 = await linkedOrder();
    const bad = await linkedOrder();
    const good2 = await linkedOrder();
    // A malformed offer (no driverId, seq or expiresAt): ending it would write undefined fields, so its transaction throws.
    await h.db().doc(`gas_supplier_orders/${bad.orderId}`).update({ riderOffer: { note: "corrupt" } });
    const errors = console.error;
    const logged = [];
    console.error = (...a) => logged.push(a);
    let r;
    try {
      r = await f.expireRiderOffers({ now: Date.now() + 24 * 60 * MIN });
    } finally {
      console.error = errors;
    }
    assert.deepEqual(r.failed, [bad.orderId]);
    assert.deepEqual(r.fallbacks.map((x) => x.orderId).sort(), [good1.orderId, good2.orderId].sort());
    for (const o of [good1, good2]) assert.equal((await readOrder(o.orderId)).deliveryMode, "ctsgo_driver");
    assert.equal((await readOrder(bad.orderId)).deliveryMode, "linked_rider");
    assert.ok(logged.some((a) => a.includes(bad.orderId)), "the failing order is logged");

    // The schedule runs each sweep guarded.
    const ran = [];
    const boom = (name) => async () => { ran.push(name); throw new Error(`${name} failed`); };
    const ok = (name, out) => async () => { ran.push(name); return out; };
    console.error = () => {};
    try {
      assert.deepEqual(await f.runDeadlineSweeps({ sweeps: { expireUnansweredOrders: boom("unanswered"), expireRiderOffers: ok("riders", { fallbacks: [] }) } }),
        { errors: ["expireUnansweredOrders"] });
      assert.deepEqual(await f.runDeadlineSweeps({ sweeps: { expireUnansweredOrders: ok("unanswered", { expired: [] }), expireRiderOffers: boom("riders") } }),
        { errors: ["expireRiderOffers"] });
    } finally {
      console.error = errors;
    }
    assert.deepEqual(ran, ["unanswered", "riders", "unanswered", "riders"]);
  });

  test("GSF-LR12 no offer within M minutes falls back; a decline restarts the window; an accepted order is never swept", async () => {
    const o = await linkedOrder();
    const deadline = (await readOrder(o.orderId)).riderDeadlineAt.toMillis();
    assert.deepEqual(await sweep(deadline - 1), []);
    assert.deepEqual(await sweep(deadline), [{ orderId: o.orderId, reason: "no_rider_assigned" }]);
    const fell = await readOrder(o.orderId);
    assert.deepEqual([fell.deliveryMode, fell.ctsgoFallbackReason, fell.riderDeadlineAt, fell.lastRiderOffer], ["ctsgo_driver", "no_rider_assigned", undefined, undefined]);

    const x = await linkedOrder();
    const first = (await readOrder(x.orderId)).riderDeadlineAt.toMillis();
    const { offerSeq, expiresAtMs } = await assign(x.orderId, RA, 0);
    const at = expiresAtMs - 1000;
    f._setClockForTests(() => at);
    await decline(x.orderId, offerSeq, RA);
    const restarted = (await readOrder(x.orderId)).riderDeadlineAt.toMillis();
    assert.equal(restarted, at + 5 * MIN, "M minutes from the decline");
    assert.ok(restarted > first);
    assert.deepEqual(await sweep(first + 1), [], "the confirmation deadline no longer applies");
    assert.deepEqual(await sweep(restarted - 1), []);
    assert.deepEqual(await sweep(restarted), [{ orderId: x.orderId, reason: "no_rider_assigned" }]);

    f._setClockForTests(null);
    const y = await accepted(RB);
    assert.deepEqual(await sweep(Date.now() + 24 * 60 * MIN), []);
    assert.equal((await readOrder(y.orderId)).status, "driverAssigned");
  });

  test("GSF-LR13 the offer window is riderAcceptMinutes when valid, else 5; an offer keeps its own expiresAt", async (t) => {
    const windowOf = async () => {
      await resetRider();
      const o = await linkedOrder();
      const r = await assign(o.orderId, RA, 0);
      const offer = (await readOrder(o.orderId)).riderOffer;
      await decline(o.orderId, r.offerSeq, RA); // frees RA for the next offer
      return offer.expiresAt.toMillis() - offer.offeredAt.toMillis();
    };
    for (const m of [1, 60]) {
      await h.seed(f.FLAG_DOC, { enabled: true, riderAcceptMinutes: m });
      assert.equal(await windowOf(), m * MIN, String(m));
    }
    const warn = t.mock.method(console, "warn", () => {});
    for (const v of [0, 61, 2.5, "5", undefined]) {
      await h.seed(f.FLAG_DOC, v === undefined ? { enabled: true } : { enabled: true, riderAcceptMinutes: v });
      const calls = warn.mock.callCount();
      assert.equal(await windowOf(), 5 * MIN, String(v));
      const warned = warn.mock.calls.slice(calls).some((c) => String(c.arguments[0]).includes("riderAcceptMinutes"));
      assert.equal(warned, v !== undefined, `warning for ${String(v)}`);
    }
    await h.seed(f.FLAG_DOC, { enabled: true });
    await resetRider();
    const o = await linkedOrder();
    const { expiresAtMs } = await assign(o.orderId, RA, 0);
    await h.seed(f.FLAG_DOC, { enabled: true, riderAcceptMinutes: 1 });
    const offeredAt = (await readOrder(o.orderId)).riderOffer.offeredAt.toMillis();
    // (The earlier orders, declined under a 1-minute window, may fall back here; this one must not.)
    assert.ok(!(await sweep(offeredAt + MIN + 1)).some((x) => x.orderId === o.orderId), "a later setting does not shorten an offer");
    assert.equal((await readOrder(o.orderId)).riderOffer.expiresAt.toMillis(), expiresAtMs);
  });

  test("GSF-LR14 passenger and admin cancel with an offer pending: refunded once, offer cleared as cancelled, the rider can no longer act", async () => {
    for (const asAdmin of [false, true]) {
      const before = await h.read(`wallets/${PAX}`);
      const o = await linkedOrder();
      const { offerSeq } = await assign(o.orderId, RA, 0);
      const cancelIt = () => (asAdmin
        ? call(f.adminCancelGasSupplierOrder, { orderId: o.orderId, reason: "Customer asked to cancel" }, ADMIN)
        : call(f.cancelGasSupplierOrder, { orderId: o.orderId }, PAX));
      const r = await cancelIt();
      assert.deepEqual([r.status, r.refunded], ["cancelled", true]);
      await cancelIt();
      const c = await readOrder(o.orderId);
      assert.deepEqual([c.riderOffer, c.riderDeadlineAt, c.lastRiderOffer.driverId, c.lastRiderOffer.seq, c.lastRiderOffer.outcome],
        [undefined, undefined, RA, offerSeq, "cancelled"]);
      assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "REFUNDED");
      const w = await h.read(`wallets/${PAX}`);
      assert.deepEqual([w.balance, w.heldBalance], [before.balance, before.heldBalance]);
      await rejects(acceptOffer(o.orderId, offerSeq, RA), "failed-precondition", "job_taken");
      await rejects(decline(o.orderId, offerSeq, RA), "not-found", "offer_not_found");
      assert.deepEqual((await jobsOf(RA)).offers, []);
      assert.equal((await h.read(`drivers/${RA}`)).currentTripId, null);
      assert.deepEqual(await sweep(Date.now() + 60 * MIN), [], "a cancelled order is never swept");
    }
    assert.equal(await h.count("ledger", "type", "REFUND"), 2);
  });

  test("GSF-LR15 admin release of a linked rider falls back to CTSGo; the rider is freed and cannot retake it", async () => {
    for (const atStation of [false, true]) {
      await resetRider();
      const o = await accepted(RA);
      if (atStation) await call(f.arriveGasSupplierStation, { orderId: o.orderId }, RA);
      const before = await readOrder(o.orderId);
      const r = await call(f.adminReleaseGasSupplierDriver, { orderId: o.orderId, reason: "Rider unreachable" }, ADMIN);
      assert.deepEqual([r.status, r.releasedDriverId], ["confirmed", RA]);
      const after = await readOrder(o.orderId);
      assert.deepEqual(
        [after.status, after.deliveryMode, after.ctsgoFallbackReason, after.driverId, after.releasedDriverIds, after.linkedSupplierId, after.acceptedFeePesewas, after.riderDeadlineAt],
        ["confirmed", "ctsgo_driver", "admin_release", undefined, [RA], undefined, undefined, undefined]);
      assert.equal(after.completionCode, before.completionCode);
      assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "HELD");
      assert.deepEqual(await h.read(`drivers/${RA}`).then((d) => [d.currentTripId, d.isAvailable]), [null, true]);
      await rejects(call(f.acceptGasSupplierJob, { orderId: o.orderId }, RA), "permission-denied", "released_from_job");
      await rejects(acceptOffer(o.orderId, 1, RA), "permission-denied", "released_from_job");
      assert.ok(!(await jobsOf(RA)).jobs.some((j) => j.orderId === o.orderId));
      assert.ok((await jobsOf(DRIVER2)).jobs.some((j) => j.orderId === o.orderId));
      assert.equal((await call(f.adminReleaseGasSupplierDriver, { orderId: o.orderId, reason: "Rider unreachable" }, ADMIN)).alreadyReleased, true);
    }
  });

  test("GSF-LR18 admin cancel after hand-over: refunded, nothing posted, rider freed, one cylinder-recovery alert (F4/F5)", async () => {
    const recovery = (id) => h.read(`admin_alerts/gas_cylinder_recovery_${id}`);
    const o = await accepted(RA);
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, RA);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    const cancelIt = (id) => call(f.adminCancelGasSupplierOrder, { orderId: id, reason: "Customer refused the cylinder" }, ADMIN);
    const r = await cancelIt(o.orderId);
    assert.deepEqual([r.status, r.refunded], ["cancelled", true]);
    assert.equal((await h.read(`escrows/${o.escrowId}`)).status, "REFUNDED");
    assert.equal((await h.db().collection("gas_settlement_ledger").get()).size, 0, "no entitlement (F4)");
    assert.deepEqual(await h.read(`drivers/${RA}`).then((d) => [d.currentTripId, d.isAvailable]), [null, true]);
    const alert = await recovery(o.orderId);
    assert.deepEqual([alert.type, alert.severity, alert.resolved, alert.orderId, alert.supplierId, alert.driverId, alert.deliveryMode],
      ["gas_cylinder_recovery_required", "high", false, o.orderId, S, RA, "linked_rider"]);
    assert.equal(alert.read, false, "the admin bell lists only unread alerts");
    assert.equal(typeof alert.message, "string");
    await cancelIt(o.orderId);
    assert.equal(await h.count("admin_alerts", "type", "gas_cylinder_recovery_required"), 1, "a repeat creates nothing");

    const early = await accepted(RB);
    await cancelIt(early.orderId);
    assert.equal(await recovery(early.orderId), null, "not handed over: nothing to recover");

    const cts = await linkedOrder("ctsgo_driver");
    await call(f.acceptGasSupplierJob, { orderId: cts.orderId }, DRIVER2);
    await call(f.arriveGasSupplierStation, { orderId: cts.orderId }, DRIVER2);
    await call(f.supplierHandOverGasOrder, { orderId: cts.orderId }, SUP_USER);
    await cancelIt(cts.orderId);
    const a2 = await recovery(cts.orderId);
    assert.deepEqual([a2.type, a2.driverId, a2.deliveryMode], ["gas_cylinder_recovery_required", DRIVER2, "ctsgo_driver"]);
    assert.equal(await h.count("admin_alerts", "type", "gas_cylinder_recovery_required"), 2);
  });

  test("GSF-LR22 rider earnings: own driver entries only, pending → owed → credited_to_wallet; a debt-held reversal is outstanding_adjustment", async () => {
    const payouts = require("../../gas_supplier_payouts");
    const earn = async (uid = RA) => (await call(f.listMyGasSupplierEarnings, {}, uid)).earnings;
    const terms = h.db().doc("gas_commission_terms/current");
    assert.deepEqual(await earn(), []);
    const o = await delivered(RA);
    const fee = await feeOf(o.orderId);

    await terms.update({ settlementHoldHours: 24 });
    let [row] = await earn();
    assert.deepEqual(Object.keys(row).sort(), ["amountPesewas", "creditedAtMs", "deliveredAtMs", "eligibleFromMs", "linkedSupplierName", "orderId", "status"]);
    assert.deepEqual([row.orderId, row.amountPesewas, row.status, row.linkedSupplierName, row.creditedAtMs], [o.orderId, fee, "pending", "Supplier A", null]);
    assert.equal(typeof row.deliveredAtMs, "number");
    assert.equal(row.eligibleFromMs, row.deliveredAtMs + 24 * 3600e3);
    await terms.update({ settlementHoldHours: 0 });
    assert.equal((await earn())[0].status, "owed");

    const today = new Date().toISOString().slice(0, 10);
    await ledger.prepareStatements(today, { now: Date.now() + 2 * 24 * 3600e3 });
    assert.equal((await earn())[0].status, "owed", "settlement prepared is still owed");
    await call(payouts.adminSettleGasDriverStatement, { statementId: `${today}__driver__${RA}` }, SUPER);
    [row] = await earn();
    assert.equal(row.status, "credited_to_wallet");
    assert.equal(typeof row.creditedAtMs, "number");
    const text = JSON.stringify(await call(f.listMyGasSupplierEarnings, {}, RA));
    for (const k of ["commission", "customerTotal", "supplierNet", "supplierGross", "productSubtotal", "partyId", "statementId"]) assert.ok(!text.includes(k), k);

    // Another driver's entries never appear; theirs are their own.
    assert.deepEqual(await earn(DRIVER2), []);
    const cts = await linkedOrder("ctsgo_driver");
    await call(f.acceptGasSupplierJob, { orderId: cts.orderId }, DRIVER2);
    await call(f.arriveGasSupplierStation, { orderId: cts.orderId }, DRIVER2);
    await call(f.supplierHandOverGasOrder, { orderId: cts.orderId }, SUP_USER);
    await call(f.completeGasSupplierOrder, { orderId: cts.orderId, code: await codeOf(cts.orderId) }, DRIVER2);
    assert.deepEqual((await earn(DRIVER2)).map((e) => [e.orderId, e.status, e.linkedSupplierName]), [[cts.orderId, "owed", null]]);
    assert.deepEqual((await earn()).map((e) => e.orderId), [o.orderId]);
    await rejects(call(f.listMyGasSupplierEarnings, { driverId: DRIVER2 }, RA), "invalid-argument", "unexpected_fields");

    // Reversals: after settlement a debt holds it; before settlement it nets to zero.
    await call(ledger.adminReverseGasSupplierEntitlements, { orderId: o.orderId, reason: "Wrong cylinder delivered" }, SUPER);
    assert.equal((await earn())[0].status, "outstanding_adjustment");
    await call(ledger.adminReverseGasSupplierEntitlements, { orderId: cts.orderId, reason: "Wrong cylinder delivered" }, SUPER);
    assert.equal((await earn(DRIVER2))[0].status, "reversed");
  });

  // ── A rider who passed on an order (timed out or declined) does not get it back from the CTSGo pool ──
  const inPool = async (orderId, uid) => (await jobsOf(uid)).jobs.some((j) => j.orderId === orderId);
  const escrowStatus = async (o) => (await h.read(`escrows/${o.escrowId}`)).status;

  test("GSF-LR23 a timed-out rider never sees or takes the order from the CTSGo pool; another driver takes and delivers it", async () => {
    const o = await linkedOrder();
    const orders = await h.count("gas_supplier_orders", "passengerId", PAX);
    const { offerSeq, expiresAtMs } = await assign(o.orderId, RA, 0);
    assert.deepEqual(await sweep(expiresAtMs), [{ orderId: o.orderId, reason: "rider_timeout" }]);
    const fell = await readOrder(o.orderId);
    const events = await eventCount(o.orderId);
    for (let i = 0; i < 3; i++) {
      const mine = await jobsOf(RA);
      assert.deepEqual([mine.offers, mine.jobs.some((j) => j.orderId === o.orderId)], [[], false], `refresh ${i}`);
    }
    await rejects(call(f.acceptGasSupplierJob, { orderId: o.orderId }, RA), "permission-denied", "rider_passed_on_job");
    await rejects(acceptOffer(o.orderId, offerSeq, RA), "failed-precondition", "job_taken");
    assert.ok(await inPool(o.orderId, RB), "a rider with the same profile who was not offered it sees it");
    assert.ok(await inPool(o.orderId, DRIVER2));
    assert.deepEqual(await readOrder(o.orderId), fell, "listing and refusals change nothing");
    assert.equal(await eventCount(o.orderId), events);
    assert.deepEqual(await h.read(`drivers/${RA}`).then((d) => [d.currentTripId, d.isAvailable]), [null, true]);
    assert.deepEqual([fell.payment.status, await escrowStatus(o)], ["held", "HELD"]);

    assert.equal((await call(f.acceptGasSupplierJob, { orderId: o.orderId }, DRIVER2)).status, "driverAssigned");
    assert.deepEqual(await h.read(`drivers/${DRIVER2}`).then((d) => [d.currentTripId, d.isAvailable]), [o.orderId, false]);
    assert.ok(!(await inPool(o.orderId, RB)), "taken");
    assert.equal(await escrowStatus(o), "HELD", "held until completion");
    await call(f.arriveGasSupplierStation, { orderId: o.orderId }, DRIVER2);
    await call(f.supplierHandOverGasOrder, { orderId: o.orderId }, SUP_USER);
    await call(f.completeGasSupplierOrder, { orderId: o.orderId, code: await codeOf(o.orderId) }, DRIVER2);
    const done = await readOrder(o.orderId);
    assert.deepEqual([done.status, done.supplierId, done.driverId, done.riderOfferSeq, done.payment.status], ["delivered", S, DRIVER2, 1, "captured"]);
    assert.equal(await escrowStatus(o), "CAPTURED");
    assert.equal(await h.count("gas_supplier_orders", "passengerId", PAX), orders, "no order was added");
  });

  test("GSF-LR24 declining riders never see or take the order from the CTSGo pool, whatever the fallback; cancelling still refunds", async () => {
    // One decline, then the rider deadline passes with no offer: no_rider_assigned.
    const x = await linkedOrder();
    const first = await assign(x.orderId, RA, 0);
    await decline(x.orderId, first.offerSeq, RA);
    assert.deepEqual(await sweep((await readOrder(x.orderId)).riderDeadlineAt.toMillis()), [{ orderId: x.orderId, reason: "no_rider_assigned" }]);
    for (let i = 0; i < 3; i++) assert.ok(!(await inPool(x.orderId, RA)), `refresh ${i}`);
    await rejects(call(f.acceptGasSupplierJob, { orderId: x.orderId }, RA), "permission-denied", "rider_passed_on_job");
    assert.ok(await inPool(x.orderId, RB));
    assert.equal((await call(f.acceptGasSupplierJob, { orderId: x.orderId }, RB)).status, "driverAssigned");
    assert.equal(await escrowStatus(x), "HELD");

    // Every rider declines: riders_declined. None of them gets it; another driver would.
    const y = await linkedOrder();
    let seq = 0;
    for (const id of [RA, RC, "gsf-rider-d"]) {
      if (id === "gsf-rider-d") { await resetRider(id, "Rider D"); await link(id); }
      seq = (await assign(y.orderId, id, seq)).offerSeq;
      await decline(y.orderId, seq, id);
    }
    const fell = await readOrder(y.orderId);
    assert.deepEqual([fell.deliveryMode, fell.ctsgoFallbackReason, fell.riderOfferSeq], ["ctsgo_driver", "riders_declined", 3]);
    for (const id of [RA, RC, "gsf-rider-d"]) {
      assert.ok(!(await inPool(y.orderId, id)), id);
      await rejects(call(f.acceptGasSupplierJob, { orderId: y.orderId }, id), "permission-denied", "rider_passed_on_job");
    }
    assert.ok(await inPool(y.orderId, DRIVER2));
    assert.deepEqual(await readOrder(y.orderId), fell, "listing and refusals change nothing");
    assert.equal(await escrowStatus(y), "HELD");
    await call(f.cancelGasSupplierOrder, { orderId: y.orderId }, PAX);
    assert.deepEqual([(await readOrder(y.orderId)).payment.status, await escrowStatus(y)], ["refunded", "REFUNDED"]);
    assert.ok(!(await inPool(y.orderId, DRIVER2)), "a cancelled order leaves the pool");
  });

  test("GSF-LR25 only declines and timeouts exclude: a rider whose offer the supplier withdrew can still take the order", async () => {
    const o = await linkedOrder();
    await assign(o.orderId, RA, 0);
    await call(f.supplierRequestGasDriver, { orderId: o.orderId }, SUP_USER);
    assert.equal((await readOrder(o.orderId)).lastRiderOffer.outcome, "withdrawn");
    assert.ok(await inPool(o.orderId, RA));
    assert.equal((await call(f.acceptGasSupplierJob, { orderId: o.orderId }, RA)).status, "driverAssigned");
  });
});
