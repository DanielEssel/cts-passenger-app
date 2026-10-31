// holdBalance amount validation: numbers in whole pesewas, from GHS 5.00 to
// settings/platform.maxEscrowHold (default GHS 5,000). A refused request
// leaves the wallet, escrows and ledger untouched and returns a stable
// callable error code. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const escrow = require("../../escrow");

const P = "hold-passenger";
const hold = (data, uid = P) => h.callCallable(escrow.holdBalance, uid, data);
const req = (amount) => ({ amount, serviceType: "delivery", referenceType: "delivery" });

async function snapshot() {
  const out = {};
  for (const c of ["wallets", "escrows", "ledger"]) {
    out[c] = (await h.db().collection(c).get()).docs.map((d) => [d.id, JSON.stringify(d.data())]).sort();
  }
  return out;
}

async function seed({ balance = 100000, settings = { platformFeePercent: 15 } } = {}) {
  await h.seed("settings/platform", settings);
  await h.enableDeliveryGasWallet();
  await h.seed(`wallets/${P}`, { balance, heldBalance: 0 });
}

after(() => h.fft.cleanup());
// Wallet Delivery and Gas are offered once app_config/mobile requires the
// app versions that keep the completion code secret (escrow.js); these tests
// cover that state.
beforeEach(async () => { await h.clearFirestore(); await h.enableDeliveryGasWallet(); });

describe("holdAmountProblem (pure)", () => {
  const p = (a, max) => escrow.holdAmountProblem(a, max);

  test("HAV-01 limits are the agreed ones", () => {
    assert.equal(escrow.HOLD_MIN_AMOUNT, 5);
    assert.equal(escrow.HOLD_MAX_DEFAULT, 5000);
  });

  test("HAV-02 valid two-decimal amounts at and inside the boundaries", () => {
    for (const a of [5, 5.0, 5.01, 10.25, 99.99, 1.13 + 3.87, 4999.99, 5000]) {
      assert.equal(p(a), null, String(a));
    }
  });

  test("HAV-03 each rejection has a stable code and reason", () => {
    const cases = [
      ["100", "invalid-argument", "amount_not_a_finite_number"],
      [true, "invalid-argument", "amount_not_a_finite_number"],
      [null, "invalid-argument", "amount_not_a_finite_number"],
      [undefined, "invalid-argument", "amount_not_a_finite_number"],
      [{}, "invalid-argument", "amount_not_a_finite_number"],
      [NaN, "invalid-argument", "amount_not_a_finite_number"],
      [Infinity, "invalid-argument", "amount_not_a_finite_number"],
      [-Infinity, "invalid-argument", "amount_not_a_finite_number"],
      [0, "invalid-argument", "amount_not_positive"],
      [-10, "invalid-argument", "amount_not_positive"],
      [5.001, "invalid-argument", "amount_more_than_two_decimals"],
      [0.005, "invalid-argument", "amount_more_than_two_decimals"],
      [1e-9, "invalid-argument", "amount_more_than_two_decimals"],
      [5.000000001, "invalid-argument", "amount_more_than_two_decimals"],
      [4.99, "out-of-range", "amount_below_minimum"],
      [1, "out-of-range", "amount_below_minimum"],
      [5000.01, "out-of-range", "amount_above_maximum"],
    ];
    for (const [a, code, reason] of cases) {
      assert.deepEqual(p(a), { code, reason }, `amount ${String(a)}`);
    }
  });
});

describe("holdBalance callable", () => {
  test("HAV-10 every invalid amount is refused with its code and changes nothing", async () => {
    await seed();
    const before = await snapshot();
    const cases = [
      ["100", "invalid-argument"], ["abc", "invalid-argument"], [true, "invalid-argument"],
      [null, "invalid-argument"], [NaN, "invalid-argument"], [Infinity, "invalid-argument"],
      [-Infinity, "invalid-argument"], [0, "invalid-argument"], [-5, "invalid-argument"],
      [0.005, "invalid-argument"], [5.001, "invalid-argument"], [1e-9, "invalid-argument"],
      [4.99, "out-of-range"], [5000.01, "out-of-range"],
    ];
    for (const [amount, code] of cases) {
      await assert.rejects(hold(req(amount)), (e) => {
        assert.equal(e.code, code, `amount ${String(amount)}: ${e.message}`);
        assert.ok(e.details?.reason, "a reason is returned");
        return true;
      });
    }
    assert.deepEqual(await snapshot(), before);
  });

  test("HAV-11 a missing or malformed request body is invalid-argument, not internal", async () => {
    await seed();
    for (const data of [null, undefined, {}, { amount: [] }]) {
      await assert.rejects(hold(data), (e) => e.code === "invalid-argument", JSON.stringify(data));
    }
  });

  test("HAV-12 boundary and two-decimal amounts are held exactly", async () => {
    await seed({ balance: 10000 });
    let expected = 10000;
    for (const amount of [5, 5000, 10.25, 99.99]) {
      const r = await hold(req(amount));
      expected = Math.round((expected - amount) * 100) / 100;
      const e = await h.read(`escrows/${r.escrowId}`);
      assert.equal(e.amount, amount);
    }
    const w = await h.read(`wallets/${P}`);
    assert.equal(Math.round(w.balance * 100) / 100, expected);
    assert.equal(Math.round((w.balance + w.heldBalance) * 100) / 100, 10000);
  });

  test("HAV-13 the maximum comes from settings/platform.maxEscrowHold", async () => {
    await seed({ settings: { platformFeePercent: 15, maxEscrowHold: 20000 } });
    assert.equal((await hold(req(15000))).success, true);
    await assert.rejects(hold(req(20000.01)), (e) => e.code === "out-of-range");
  });

  test("HAV-14 an unusable maxEscrowHold falls back to GHS 5,000", async () => {
    for (const bad of ["9999", -1, 0, 4, NaN]) {
      await h.clearFirestore();
      await seed({ settings: { platformFeePercent: 15, maxEscrowHold: bad } });
      await assert.rejects(hold(req(5000.01)), (e) => e.code === "out-of-range", String(bad));
      assert.equal((await hold(req(5000))).success, true, String(bad));
    }
  });

  test("HAV-15 the existing balance check still applies inside the limits", async () => {
    await seed({ balance: 20 });
    await assert.rejects(hold(req(25)), (e) => e.code === "failed-precondition" && e.details.shortfall === 5);
    assert.deepEqual(await h.read(`wallets/${P}`), { balance: 20, heldBalance: 0 });
  });
});
