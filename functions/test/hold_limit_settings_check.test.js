// scripts/check_hold_limit_settings.js: pure evaluation and target guards.
// No Firestore, no network.

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const check = require("../scripts/check_hold_limit_settings");
const { resolveTarget } = require("../scripts/assess_auto_expired_escrows");

test("HLS-01 the script's limits match escrow.js", () => {
  const escrow = require("../escrow");
  assert.equal(check.HOLD_MIN_AMOUNT, escrow.HOLD_MIN_AMOUNT);
  assert.equal(check.HOLD_MAX_DEFAULT, escrow.HOLD_MAX_DEFAULT);
});

test("HLS-02 no settings document: code defaults pass, default maximum applies", () => {
  const r = check.evaluateHoldLimitSettings(null);
  assert.equal(r.ok, true, r.problems.join("; "));
  assert.deepEqual(r.maxEscrowHold, { configured: null, valid: false, effective: 5000, usingDefault: true });
});

test("HLS-03 a configured minimum below GHS 5.00 is reported", () => {
  const r = check.evaluateHoldLimitSettings({ okada: { minimumFare: 4.5 }, gas: { minDeliveryFee: 3 } });
  assert.equal(r.ok, false);
  assert.equal(r.problems.length, 2);
  assert.match(r.problems[0], /ride\.okada\.minimumFare = 4\.5/);
  assert.match(r.problems[1], /gas\.minDeliveryFee = 3/);
});

test("HLS-04 non-numeric minimums and an unusable maxEscrowHold are reported", () => {
  const r = check.evaluateHoldLimitSettings({ taxi: { minimumFare: "10" }, maxEscrowHold: "9999" });
  assert.equal(r.ok, false);
  assert.ok(r.problems.some((p) => p.includes("ride.taxi.minimumFare is set but not a number")));
  assert.ok(r.problems.some((p) => p.includes("maxEscrowHold is set but unusable")));
  assert.equal(r.maxEscrowHold.effective, 5000);
});

test("HLS-05 commercial gas capacity under the effective maximum", () => {
  const r = check.evaluateHoldLimitSettings({
    maxEscrowHold: 20000, gas: { refill45kg: 540, refill6kg: 75, commercialRate: 1, minDeliveryFee: 12 },
  });
  const by = Object.fromEntries(r.commercialGas.sizes.map((s) => [s.size, s]));
  assert.equal(r.maxEscrowHold.effective, 20000);
  assert.equal(by["45kg"].maxQuantityUnderMax, Math.floor((20000 - 12) / 540)); // 37
  assert.equal(by["6kg"].maxQuantityUnderMax, Math.floor((20000 - 12) / 75));
  assert.equal(by["3kg"].maxQuantityUnderMax, null, "unset price: unknown");
  const d = check.evaluateHoldLimitSettings({ gas: { refill45kg: 540 } });
  assert.equal(d.commercialGas.sizes.find((s) => s.size === "45kg").maxQuantityUnderMax, 9);
});

test("HLS-06 remote and production reads need explicit flags", () => {
  assert.throws(() => resolveTarget([], {}), /--project/);
  assert.throws(() => resolveTarget(["--project", "p"], {}), /--allow-remote-read/);
  assert.throws(() => resolveTarget(["--project", "ctstransportapp", "--allow-remote-read"], {}),
    /--production-read-authorized/);
  assert.deepEqual(resolveTarget([], { FIRESTORE_EMULATOR_HOST: "127.0.0.1:8080" }),
    { projectId: "demo-ctsgo-payments", remote: false });
});
