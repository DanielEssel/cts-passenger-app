// Ride and Gas completion release only the escrow that is this order's own
// payment (same passenger, attached to this order and service, HELD), never
// one merely named on the client-writable order. Settlement is locked,
// idempotent and does not loop on failure. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const trips = require("../../trips");

const P = "rel-passenger";
const OTHER = "rel-other-passenger";
const D = "rel-driver";
const { GeoPoint, Timestamp } = h.admin.firestore;

const SERVICES = {
  ride: {
    fn: () => trips.onTripCompleted, collection: "trips", idParam: "tripId",
    referenceType: "trip", releaseReason: "trip_completed", failedAlert: "trip_settlement_failed",
    before: { status: "tripStarted" },
    // Priced like a real booking (settlement checks the hold against it).
    after: { status: "completed", passengerConfirmed: true, estimatedFare: 100, serviceType: "taxi",
      pickupLocation: new GeoPoint(5.6037, -0.187), dropoffLocation: new GeoPoint(5.62, -0.19) },
  },
  gas: {
    fn: () => trips.onGasOrderCompleted, collection: "gas_orders", idParam: "orderId",
    referenceType: "gas_order", releaseReason: "gas_order_delivered", failedAlert: "gas_settlement_failed",
    before: { status: "returning" },
    // A real legacy Gas order's fields (settlement checks the hold against its price).
    after: { status: "delivered", totalPrice: 100, refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1, deliveryOtp: "4321", otpSubmitted: "4321" },
  },
};

async function seedAccounts() {
  await h.seed("settings/platform", { platformFeePercent: 15 });
  await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
  await h.seed(`wallets/${OTHER}`, { balance: 0, heldBalance: 100 });
  await h.seed(`drivers/${D}`, { walletBalance: 0, totalEarnings: 0 });
}

async function seedEscrow(svc, o = {}) {
  await h.seed("escrows/e1", { userId: P, amount: 100, platformFee: 15, driverNet: 85,
    status: "HELD", referenceId: "o1", referenceType: svc.referenceType, ...o });
}

function event(svc, extra = {}) {
  const base = { passengerId: P, driverId: D, paymentMethod: "wallet", escrowId: "e1" };
  const before = { ...base, ...svc.before };
  const afterDoc = { ...base, ...svc.after, ...extra };
  return { params: { [svc.idParam]: "o1" },
    data: { before: { data: () => before }, after: { data: () => afterDoc } } };
}

async function complete(svc, extra) {
  const ev = event(svc, extra);
  await h.seed(`${svc.collection}/o1`, ev.data.after.data());
  await svc.fn().run(ev);
  return ev;
}

const order = (svc) => h.read(`${svc.collection}/o1`);
const escrow = () => h.read("escrows/e1");
const driver = () => h.read(`drivers/${D}`);
const captures = () => h.count("ledger", "idempotencyKey", "capture_e1");
const alerts = (type) => h.count("admin_alerts", "type", type);

async function assertBlocked(svc, reason, { escrowStatus = "HELD" } = {}) {
  const o = await order(svc);
  assert.notEqual(o.walletProcessed, true, "not marked settled");
  assert.equal(o.settlementStatus, "failed");
  assert.equal(o.settlementFailureReason, reason);
  assert.equal(await alerts(svc.failedAlert), 1);
  assert.equal(await captures(), 0, "nothing released by this settlement");
  assert.equal((await driver()).walletBalance, 0, "driver not credited");
  if (escrowStatus) assert.equal((await escrow())?.status, escrowStatus);
}

after(() => h.fft.cleanup());
beforeEach(async () => { await h.clearFirestore(); await seedAccounts(); });

for (const [name, svc] of Object.entries(SERVICES)) {
  const tag = name === "ride" ? "RREL" : "GREL";

  describe(`${name} completion release`, () => {
    test(`${tag}-01 the order's own escrow is released once and the order settled`, async () => {
      await seedEscrow(svc);
      await complete(svc);
      const e = await escrow();
      assert.equal(e.status, "RELEASED");
      assert.equal(e.releaseReason, svc.releaseReason);
      assert.equal(await captures(), 1);
      assert.equal((await driver()).walletBalance, 85);
      assert.equal((await h.read(`wallets/${P}`)).heldBalance, 0);
      const o = await order(svc);
      assert.equal(o.walletProcessed, true);
      assert.equal(o.settlementStatus, "completed");
      assert.equal(o.actualFare, 100);
      assert.equal(o.driverEarnings, 85);
    });

    test(`${tag}-02 another passenger's escrow is not released`, async () => {
      await seedEscrow(svc, { userId: OTHER });
      await complete(svc);
      await assertBlocked(svc, "escrow_owner_mismatch");
      assert.equal((await h.read(`wallets/${OTHER}`)).heldBalance, 100);
    });

    test(`${tag}-03 an escrow attached to another order is not released`, async () => {
      await seedEscrow(svc, { referenceId: "another-order" });
      await complete(svc);
      await assertBlocked(svc, "escrow_reference_mismatch");
    });

    test(`${tag}-04 an escrow attached for another service is not released`, async () => {
      await seedEscrow(svc, { referenceType: "delivery" });
      await complete(svc);
      await assertBlocked(svc, "escrow_reference_type_mismatch");
    });

    test(`${tag}-05 a missing escrow blocks settlement`, async () => {
      await complete(svc);
      await assertBlocked(svc, "escrow_missing", { escrowStatus: null });
    });

    test(`${tag}-06 an unattached escrow is not released on the order's word`, async () => {
      await seedEscrow(svc, { referenceId: null });
      await complete(svc);
      await assertBlocked(svc, "escrow_unattached");
    });

    test(`${tag}-07 an escrow released elsewhere is not counted as this order's payment`, async () => {
      await seedEscrow(svc, { status: "RELEASED", releaseReason: "delivery_completed" });
      await complete(svc);
      await assertBlocked(svc, "escrow_released_elsewhere", { escrowStatus: "RELEASED" });
    });

    test(`${tag}-08 a refunded escrow is never settled`, async () => {
      await seedEscrow(svc, { status: "REFUNDED" });
      await complete(svc);
      await assertBlocked(svc, "escrow_refunded", { escrowStatus: "REFUNDED" });
    });

    test(`${tag}-09 repeated and concurrent completion events release once`, async () => {
      await seedEscrow(svc);
      const ev = event(svc);
      await h.seed(`${svc.collection}/o1`, ev.data.after.data());
      await Promise.all([svc.fn().run(ev), svc.fn().run(ev), svc.fn().run(ev)]);
      await svc.fn().run(ev);
      assert.equal(await captures(), 1);
      assert.equal((await driver()).walletBalance, 85);
      assert.equal((await order(svc)).walletProcessed, true);
      assert.equal(await alerts(svc.failedAlert), 0);
    });

    test(`${tag}-10 crash recovery: released for this order but not marked — finishes without paying twice`, async () => {
      // An earlier run released the escrow, then died before the final
      // update; operations cleared settlementStatus to retry.
      await seedEscrow(svc, { status: "RELEASED", releaseReason: svc.releaseReason });
      await h.seed(`drivers/${D}`, { walletBalance: 85, totalEarnings: 85 });
      await complete(svc);
      const o = await order(svc);
      assert.equal(o.walletProcessed, true);
      assert.equal(o.settlementStatus, "completed");
      assert.equal((await driver()).walletBalance, 85, "not credited again");
      assert.equal(await captures(), 0, "no second capture");
    });

    test(`${tag}-11 a failed settlement does not re-run on later writes; clearing it retries`, async () => {
      await seedEscrow(svc, { referenceId: null });
      await complete(svc);
      assert.equal((await order(svc)).settlementStatus, "failed");
      // Later events (e.g. a rating) carry settlementStatus "failed".
      await complete(svc, { settlementStatus: "failed", settlementFailureReason: "escrow_unattached" });
      assert.equal(await alerts(svc.failedAlert), 1, "no loop");
      // Operations attach the escrow properly and clear the failure.
      await seedEscrow(svc);
      await complete(svc, { settlementStatus: null });
      assert.equal((await order(svc)).walletProcessed, true);
      assert.equal(await captures(), 1);
    });

    test(`${tag}-12 an order re-pointed at another passenger's escrow (same order id) is not released`, async () => {
      // e2 carries this order's id and service but belongs to someone else.
      await seedEscrow(svc, { userId: P, referenceId: "o1" });
      await h.seed("escrows/e2", { userId: OTHER, amount: 100, platformFee: 15, driverNet: 85,
        status: "HELD", referenceId: "o1", referenceType: svc.referenceType });
      await complete(svc, { escrowId: "e2" });
      await assertBlocked(svc, "escrow_owner_mismatch", { escrowStatus: "HELD" });
      assert.equal((await h.read("escrows/e2")).status, "HELD");
    });
  });
}

describe("ride-specific", () => {
  const svc = SERVICES.ride;

  test("RREL-20 a disputed trip is not auto-confirmed or settled by a later write", async () => {
    await seedEscrow(svc);
    await complete(svc, { passengerConfirmed: false, disputed: true,
      completedAt: Timestamp.fromDate(new Date(Date.now() - 10 * 60e3)) });
    const o = await order(svc);
    assert.notEqual(o.passengerConfirmed, true);
    assert.notEqual(o.autoConfirmed, true);
    assert.equal((await escrow()).status, "HELD");
  });

  test("RREL-21 an undisputed trip is still auto-confirmed after 3 minutes", async () => {
    await seedEscrow(svc);
    // The window runs from the server's first sight of the completion.
    await h.seed("settlement_observations/trips_o1", { collection: "trips", orderId: "o1",
      completionObservedAt: Timestamp.fromDate(new Date(Date.now() - 10 * 60e3)) });
    await complete(svc, { passengerConfirmed: false, disputed: false,
      completedAt: Timestamp.fromDate(new Date(Date.now() - 10 * 60e3)) });
    const o = await order(svc);
    assert.equal(o.passengerConfirmed, true);
    assert.equal(o.autoConfirmed, true);
  });
});

describe("gas-specific", () => {
  const svc = SERVICES.gas;

  test("GREL-20 cash: repeated events record one commission and one credit", async () => {
    const ev = event(svc, { paymentMethod: "cash", escrowId: null });
    await h.seed(`${svc.collection}/o1`, ev.data.after.data());
    await Promise.all([svc.fn().run(ev), svc.fn().run(ev)]);
    await svc.fn().run(ev);
    assert.equal(await h.count("ledger", "idempotencyKey", "commission_o1"), 1);
    const d = await driver();
    assert.equal(d.totalEarnings, 100);
    assert.equal(d.commissionOwed, 15);
  });

  test("GREL-21 cash: the booked totalPrice is used, not a client-written actualFare", async () => {
    await complete(svc, { paymentMethod: "cash", escrowId: null, actualFare: 1 });
    const o = await order(svc);
    assert.equal(o.actualFare, 100);
    assert.equal(o.platformFee, 15);
    assert.equal((await driver()).commissionOwed, 15);
  });

  // 2026-10-28: a wallet order without a hold is never charged at
  // settlement (its total is app-written and has no server price); it was
  // a direct deduction before.
  test("GREL-22 wallet without escrow: no charge, no credit", async () => {
    await h.seed(`wallets/${P}`, { balance: 300, heldBalance: 0 });
    await complete(svc, { escrowId: null });
    const o = await order(svc);
    assert.equal(o.settlementStatus, "failed");
    assert.equal(o.settlementFailureReason, "wallet_order_without_escrow");
    assert.equal((await h.read(`wallets/${P}`)).balance, 300);
    assert.equal((await driver()).walletBalance, 0);
  });

  test("GREL-23 wallet without escrow, repeated and concurrent events: still nothing moves", async () => {
    await h.seed(`wallets/${P}`, { balance: 300, heldBalance: 0 });
    const ev = event(svc, { escrowId: null });
    await h.seed(`${svc.collection}/o1`, ev.data.after.data());
    await Promise.all([svc.fn().run(ev), svc.fn().run(ev)]);
    assert.equal((await h.read(`wallets/${P}`)).balance, 300);
    assert.equal((await driver()).walletBalance, 0);
    assert.equal(await alerts(svc.failedAlert), 1);
  });

  test("GREL-24 the OTP gate still runs first", async () => {
    await seedEscrow(svc);
    await complete(svc, { otpSubmitted: null });
    assert.equal((await order(svc)).status, "pendingOtp");
    assert.equal((await escrow()).status, "HELD");
  });
});
