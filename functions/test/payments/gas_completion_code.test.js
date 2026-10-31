// Gas completion-code integrity (Phase 1C). A gas order settles only with a
// stored code and a matching submitted code, or a recorded waiver for a
// legitimate historical order without one. Missing, malformed or wrong
// codes never settle, duplicate events act once, and code values never
// appear in logs or alerts. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const trips = require("../../trips");
const { checkCompletionCode } = require("../../completion_code");

const P = "gcc-passenger";
const D = "gcc-driver";
const CODE = "4821";

async function seedEscrow() {
  await h.seed("escrows/e1", { userId: P, amount: 100, platformFee: 15, driverNet: 85,
    status: "HELD", referenceId: "g1", referenceType: "gas_order" });
}

/** Fires onGasOrderCompleted for g1 moving returning → [after]. */
async function deliver(fields = {}, { runs = 1 } = {}) {
  const afterDoc = { passengerId: P, driverId: D, paymentMethod: "wallet", escrowId: "e1",
    totalPrice: 100, refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1, deliveryOtp: CODE, otpSubmitted: CODE, ...fields, status: "delivered" };
  for (const k of Object.keys(afterDoc)) if (afterDoc[k] === undefined) delete afterDoc[k];
  await h.seed("gas_orders/g1", afterDoc);
  const ev = { params: { orderId: "g1" },
    data: { before: { data: () => ({ ...afterDoc, status: "returning" }) }, after: { data: () => afterDoc } } };
  await Promise.all(Array.from({ length: runs }, () => trips.onGasOrderCompleted.run(ev)));
}

const order = () => h.read("gas_orders/g1");
const settled = async () => {
  const o = await order();
  return o.walletProcessed === true && (await h.read("escrows/e1")).status === "RELEASED";
};
async function assertHeld(status) {
  const o = await order();
  assert.equal(o.status, status);
  assert.notEqual(o.walletProcessed, true);
  assert.equal((await h.read("escrows/e1")).status, "HELD");
  assert.equal((await h.read(`drivers/${D}`)).walletBalance, 0, "driver not credited");
}

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed("settings/platform", { platformFeePercent: 15 });
  await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
  await h.seed(`drivers/${D}`, { walletBalance: 0, totalEarnings: 0 });
  await seedEscrow();
});

describe("gas completion code", () => {
  test("GCC-01 stored code present and correct: settles once", async () => {
    await deliver();
    assert.equal(await settled(), true);
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 85);
  });

  test("GCC-02 no stored code: held for review, alert, nothing released", async () => {
    await deliver({ deliveryOtp: undefined, otpSubmitted: undefined });
    await assertHeld("flagged");
    assert.equal(await h.count("admin_alerts", "type", "gas_code_missing"), 1);
  });

  test("GCC-03 a stored code that is not a code (empty, number) counts as missing", async () => {
    for (const stored of ["", "  ", 4821, null]) {
      await h.clearFirestore();
      await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
      await h.seed(`drivers/${D}`, { walletBalance: 0 });
      await seedEscrow();
      await deliver({ deliveryOtp: stored, otpSubmitted: "4821" });
      await assertHeld("flagged");
    }
  });

  test("GCC-04 a recorded waiver lets a historical order without a code settle", async () => {
    await h.seed("completion_code_waivers/gas_orders_g1", { collection: "gas_orders", orderId: "g1",
      approvedBy: "admin-1", reason: "pre-code order, delivery confirmed by phone" });
    await deliver({ deliveryOtp: undefined, otpSubmitted: undefined });
    assert.equal(await settled(), true);
  });

  test("GCC-05 a waiver for another order, or without an approver, does not count", async () => {
    await h.seed("completion_code_waivers/gas_orders_g1", { collection: "gas_orders", orderId: "g2",
      approvedBy: "admin-1" });
    await deliver({ deliveryOtp: undefined, otpSubmitted: undefined });
    await assertHeld("flagged");
    await h.seed("completion_code_waivers/gas_orders_g1", { collection: "gas_orders", orderId: "g1" });
    await deliver({ deliveryOtp: undefined, otpSubmitted: undefined });
    await assertHeld("flagged");
  });

  test("GCC-06 a waiver never overrides a stored code that does not match", async () => {
    await h.seed("completion_code_waivers/gas_orders_g1", { collection: "gas_orders", orderId: "g1",
      approvedBy: "admin-1" });
    await deliver({ otpSubmitted: "0000" });
    await assertHeld("flagged");
  });

  test("GCC-07 no submitted code: pendingOtp; resubmitting the right code settles", async () => {
    await deliver({ otpSubmitted: undefined });
    await assertHeld("pendingOtp");
    await deliver({ otpSubmitted: CODE }); // the driver resubmits (pendingOtp → delivered)
    assert.equal(await settled(), true);
  });

  test("GCC-08 a wrong code: flagged with one alert, nothing released", async () => {
    await deliver({ otpSubmitted: "1111" });
    await assertHeld("flagged");
    assert.equal(await h.count("admin_alerts", "type", "otp_mismatch"), 1);
  });

  test("GCC-09 malformed submissions never settle", async () => {
    for (const submitted of [4821, "48 21", "abcd", "48210000000"]) {
      await h.clearFirestore();
      await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
      await h.seed(`drivers/${D}`, { walletBalance: 0 });
      await seedEscrow();
      await deliver({ otpSubmitted: submitted });
      await assertHeld("flagged");
    }
  });

  test("GCC-10 surrounding spaces are tolerated, as the apps trim", async () => {
    await deliver({ otpSubmitted: ` ${CODE} ` });
    assert.equal(await settled(), true);
  });

  test("GCC-11 duplicate events: a wrong code alerts once, a right code releases once", async () => {
    await deliver({ otpSubmitted: "1111" }, { runs: 3 });
    assert.equal(await h.count("admin_alerts", "type", "otp_mismatch"), 1);
    await h.clearFirestore();
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
    await h.seed(`drivers/${D}`, { walletBalance: 0 });
    await seedEscrow();
    await deliver({}, { runs: 3 });
    assert.equal(await h.count("ledger", "idempotencyKey", "capture_e1"), 1);
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 85);
  });

  test("GCC-12 code values never reach logs or alerts", async () => {
    const lines = [];
    const orig = { log: console.log, warn: console.warn, error: console.error };
    for (const k of Object.keys(orig)) console[k] = (...a) => lines.push(a.join(" "));
    try {
      await deliver({ otpSubmitted: "9137" });
      await h.clearFirestore();
      await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
      await h.seed(`drivers/${D}`, { walletBalance: 0 });
      await seedEscrow();
      await deliver({ otpSubmitted: undefined });
    } finally {
      Object.assign(console, orig);
    }
    assert.ok(!lines.some((l) => l.includes(CODE) || l.includes("9137")), "no code in logs");
    const alerts = await h.db().collection("admin_alerts").get();
    assert.ok(!JSON.stringify(alerts.docs.map((d) => d.data())).includes(CODE), "no code in alerts");
  });
});

describe("checkCompletionCode (pure)", () => {
  const c = (stored, submitted, waiver) =>
    checkCompletionCode({ stored, submitted, waiver, collection: "gas_orders", orderId: "g1" });
  test("GCC-20 decision table", () => {
    assert.deepEqual(c("1234", "1234"), { ok: true, via: "code" });
    assert.equal(c("1234", null).outcome, "pending");
    assert.equal(c("1234", "").outcome, "pending");
    assert.equal(c("1234", "1235").reason, "code_mismatch");
    assert.equal(c("1234", 1234).reason, "code_malformed");
    assert.equal(c(undefined, "1234").reason, "stored_code_missing");
    assert.deepEqual(c(undefined, undefined,
      { collection: "gas_orders", orderId: "g1", approvedBy: "a" }), { ok: true, via: "waiver" });
    assert.equal(c(undefined, undefined, { collection: "deliveries", orderId: "g1", approvedBy: "a" }).ok, false);
  });
});
