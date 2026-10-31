// Escrow containment (Phase 1). An order's completion may release only that
// order's own escrow, whatever escrowId the order document names, and
// releaseEscrow itself refuses to release without the order it settles.
// Covers the cross-order chain found in production (a driver pointing their
// own order at another passenger's HELD escrow) for Ride, Delivery and Gas,
// and that the confirmation-code gates still run before any money moves.
// Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const trips = require("../../trips");
const { releaseEscrow, EscrowMismatchError } = require("../../escrow");

const VICTIM = "con-victim";      // passenger of another, open order
const P = "con-passenger";        // passenger of the driver's own order
const D = "con-driver";

const SERVICES = {
  ride: {
    fn: () => trips.onTripCompleted, collection: "trips", idParam: "tripId",
    referenceType: "trip", failedAlert: "trip_settlement_failed",
    before: { status: "tripStarted" },
    after: { status: "completed", passengerConfirmed: true, estimatedFare: 100, serviceType: "taxi" },
  },
  delivery: {
    fn: () => trips.onDeliveryCompleted, collection: "deliveries", idParam: "deliveryId",
    referenceType: "delivery", failedAlert: "delivery_settlement_failed",
    before: { status: "arrivedAtDropoff" },
    after: { status: "completed", estimatedFare: 100, deliveryOtp: "1234", otpSubmitted: "1234" },
  },
  gas: {
    fn: () => trips.onGasOrderCompleted, collection: "gas_orders", idParam: "orderId",
    referenceType: "gas_order", failedAlert: "gas_settlement_failed",
    before: { status: "returning" },
    after: { status: "delivered", totalPrice: 100, deliveryOtp: "4321", otpSubmitted: "4321" },
  },
};

/** The victim's escrow: HELD for their own open order "victim-order". */
async function seedVictimEscrow(svc, o = {}) {
  await h.seed("escrows/victim-e", {
    userId: VICTIM, amount: 100, platformFee: 15, driverNet: 85, status: "HELD",
    referenceId: "victim-order", referenceType: svc.referenceType, ...o,
  });
}

/** Completion of the driver's own order "own", naming [escrowId]. */
async function completeOwn(svc, extra = {}) {
  const base = { passengerId: P, driverId: D, paymentMethod: "wallet", escrowId: "victim-e" };
  const afterDoc = { ...base, ...svc.after, ...extra };
  const beforeDoc = { ...base, ...svc.before };
  await h.seed(`${svc.collection}/own`, afterDoc);
  await svc.fn().run({
    params: { [svc.idParam]: "own" },
    data: { before: { data: () => beforeDoc }, after: { data: () => afterDoc } },
  });
}

/** Nothing moved: escrow HELD, victim's hold intact, driver unpaid, no capture. */
async function assertNothingMoved() {
  assert.equal((await h.read("escrows/victim-e")).status, "HELD", "escrow still held");
  assert.equal((await h.read(`wallets/${VICTIM}`)).heldBalance, 100, "victim's hold intact");
  const d = await h.read(`drivers/${D}`);
  assert.equal(d.walletBalance, 0, "driver not credited");
  assert.equal(d.totalEarnings, 0, "no earnings recorded");
  assert.equal(await h.count("ledger", "idempotencyKey", "capture_victim-e"), 0, "no capture");
}

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed("settings/platform", { platformFeePercent: 15 });
  await h.seed(`wallets/${VICTIM}`, { balance: 0, heldBalance: 100 });
  await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 0 });
  await h.seed(`drivers/${D}`, { walletBalance: 0, totalEarnings: 0 });
});

describe("releaseEscrow requires the order it settles", () => {
  const expect = { userId: VICTIM, referenceId: "victim-order", referenceType: "trip" };

  test("CON-01 without an expectation nothing is released", async () => {
    await seedVictimEscrow(SERVICES.ride);
    await assert.rejects(releaseEscrow("victim-e", D, "trip_completed"),
      (e) => e instanceof EscrowMismatchError && e.reason === "escrow_expectation_missing");
    await assertNothingMoved();
  });

  test("CON-02 an incomplete expectation is refused the same way", async () => {
    await seedVictimEscrow(SERVICES.ride);
    for (const partial of [
      { userId: VICTIM, referenceId: "victim-order" },
      { userId: VICTIM, referenceType: "trip" },
      { referenceId: "victim-order", referenceType: "trip" },
      { ...expect, userId: "" },
      { ...expect, referenceId: null },
    ]) {
      await assert.rejects(releaseEscrow("victim-e", D, "trip_completed", partial),
        (e) => e instanceof EscrowMismatchError && e.reason === "escrow_expectation_missing");
    }
    await assertNothingMoved();
  });

  test("CON-03 another order's expectation is refused inside the transaction", async () => {
    await seedVictimEscrow(SERVICES.ride);
    await assert.rejects(
      releaseEscrow("victim-e", D, "trip_completed", { ...expect, referenceId: "own", userId: P }),
      (e) => e instanceof EscrowMismatchError);
    await assert.rejects(
      releaseEscrow("victim-e", D, "trip_completed", { ...expect, referenceId: "own" }),
      (e) => e instanceof EscrowMismatchError && e.reason === "escrow_referenceId_mismatch");
    await assertNothingMoved();
  });

  test("CON-04 the matching expectation releases exactly once", async () => {
    await seedVictimEscrow(SERVICES.ride);
    assert.equal(await releaseEscrow("victim-e", D, "trip_completed", expect), true);
    assert.equal(await releaseEscrow("victim-e", D, "trip_completed", expect), false);
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 85, "credited once");
    assert.equal(await h.count("ledger", "idempotencyKey", "capture_victim-e"), 1);
    assert.equal((await h.read(`wallets/${VICTIM}`)).heldBalance, 0);
  });
});

for (const [name, svc] of Object.entries(SERVICES)) {
  describe(`${name}: the production cross-order chain is blocked`, () => {
    test(`CON-${name}-10 own order naming another passenger's HELD escrow for another order`, async () => {
      await seedVictimEscrow(svc);
      await completeOwn(svc);
      await assertNothingMoved();
      const o = await h.read(`${svc.collection}/own`);
      assert.notEqual(o.walletProcessed, true);
      assert.equal(o.settlementStatus, "failed");
      assert.equal(o.settlementFailureReason, "escrow_owner_mismatch");
      assert.equal(await h.count("admin_alerts", "type", svc.failedAlert), 1);
    });

    test(`CON-${name}-11 an escrow of the same passenger but another order (another driver's job)`, async () => {
      // Same owner, so only the order binding stops it.
      await seedVictimEscrow(svc, { userId: P });
      await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
      await completeOwn(svc);
      assert.equal((await h.read("escrows/victim-e")).status, "HELD");
      assert.equal((await h.read(`wallets/${P}`)).heldBalance, 100);
      assert.equal((await h.read(`drivers/${D}`)).walletBalance, 0);
      assert.equal((await h.read(`${svc.collection}/own`)).settlementFailureReason,
        "escrow_reference_mismatch");
    });

    test(`CON-${name}-12 repeated attempts never move the money`, async () => {
      await seedVictimEscrow(svc);
      await completeOwn(svc);
      // Later writes carry the failure; clearing it (as an attacker could under
      // the live rules) re-runs the checks, which block again.
      await completeOwn(svc, { settlementStatus: null });
      await completeOwn(svc, { settlementStatus: null, walletProcessed: false });
      await assertNothingMoved();
    });
  });
}

describe("confirmation-code gates still run before any money moves", () => {
  test("CON-20 delivery: a wrong code flags the delivery, nothing released", async () => {
    const svc = SERVICES.delivery;
    await h.seed("escrows/own-e", { userId: P, amount: 100, platformFee: 15, driverNet: 85,
      status: "HELD", referenceId: "own", referenceType: "delivery" });
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
    await completeOwn(svc, { escrowId: "own-e", otpSubmitted: "9999" });
    const o = await h.read("deliveries/own");
    assert.equal(o.status, "flagged");
    assert.equal((await h.read("escrows/own-e")).status, "HELD");
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 0);
  });

  test("CON-21 delivery: no submitted code flags the delivery, nothing released", async () => {
    const svc = SERVICES.delivery;
    await h.seed("escrows/own-e", { userId: P, amount: 100, platformFee: 15, driverNet: 85,
      status: "HELD", referenceId: "own", referenceType: "delivery" });
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
    await completeOwn(svc, { escrowId: "own-e", otpSubmitted: null });
    assert.equal((await h.read("deliveries/own")).status, "flagged");
    assert.equal((await h.read("escrows/own-e")).status, "HELD");
  });

  test("CON-22 gas: a wrong code flags the order, nothing released", async () => {
    const svc = SERVICES.gas;
    await h.seed("escrows/own-e", { userId: P, amount: 100, platformFee: 15, driverNet: 85,
      status: "HELD", referenceId: "own", referenceType: "gas_order" });
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
    await completeOwn(svc, { escrowId: "own-e", otpSubmitted: "0000" });
    assert.equal((await h.read("gas_orders/own")).status, "flagged");
    assert.equal((await h.read("escrows/own-e")).status, "HELD");
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 0);
  });

  test("CON-23 gas: a code that was never submitted holds the order, nothing released", async () => {
    const svc = SERVICES.gas;
    await h.seed("escrows/own-e", { userId: P, amount: 100, platformFee: 15, driverNet: 85,
      status: "HELD", referenceId: "own", referenceType: "gas_order" });
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
    await completeOwn(svc, { escrowId: "own-e", otpSubmitted: null });
    assert.equal((await h.read("gas_orders/own")).status, "pendingOtp");
    assert.equal((await h.read("escrows/own-e")).status, "HELD");
  });

  test("CON-24 gas: an order without a stored code is held for review, nothing released", async () => {
    const svc = SERVICES.gas;
    await h.seed("escrows/own-e", { userId: P, amount: 100, platformFee: 15, driverNet: 85,
      status: "HELD", referenceId: "own", referenceType: "gas_order" });
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
    await completeOwn(svc, { escrowId: "own-e", deliveryOtp: null, otpSubmitted: null });
    assert.equal((await h.read("gas_orders/own")).status, "flagged");
    assert.equal((await h.read("escrows/own-e")).status, "HELD");
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 0);
    assert.equal(await h.count("admin_alerts", "type", "gas_code_missing"), 1);
  });
});
