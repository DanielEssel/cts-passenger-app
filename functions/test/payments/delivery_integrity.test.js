// Delivery payment integrity: observe-only fare validation and escrow
// verification at delivery completion. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const h = require("./helpers");

const fareCheck = require("../../delivery_fare_validation");
const { verifyDeliveryEscrow } = require("../../delivery_settlement");
const escrow = require("../../escrow");
const trips = require("../../trips");

const { GeoPoint, Timestamp } = h.admin.firestore;
const fixture = JSON.parse(fs.readFileSync(
  path.join(__dirname, "../fixtures/delivery_fare_parity.json"), "utf8"));

// Two points in Accra about 6.6 km apart in a straight line.
const PICKUP = new GeoPoint(5.5560, -0.1969);
const DROPOFF = new GeoPoint(5.6037, -0.1550);
const STRAIGHT_KM = fareCheck.straightLineKm(PICKUP, DROPOFF);

/** What the app charges at [km] with the app's default prices. */
function appFare(km, { vehicle = "Okada", weight = "Small", fragile = false, helpers = false,
  settings = {} } = {}) {
  const { app, surcharges } = fareCheck.deliveryRates(settings, fareCheck.vehicleKey(vehicle));
  return fareCheck.deliveryTotal({
    km, rates: app, surcharges, weightTier: weight, isFragile: fragile, requiresHelpers: helpers,
  });
}

function order(overrides = {}) {
  return {
    passengerId: "p1", driverId: null, status: "pending",
    pickupLocation: PICKUP, dropoffLocation: DROPOFF,
    vehicleType: "Okada", weightTier: "Small", isFragile: false, requiresHelpers: false,
    paymentMethod: "wallet", estimatedFare: appFare(STRAIGHT_KM * 1.3),
    ...overrides,
  };
}

after(() => h.fft.cleanup());
beforeEach(() => h.clearFirestore());

// ── Formula parity with the app ───────────────────────────────────────────────

describe("fare formula parity with the passenger app", () => {
  for (const c of fixture.cases) {
    test(`DFP ${c.settings} ${c.vehicle} ${c.km} km ${c.weight} = ${c.expected}`, () => {
      const settings = fixture.settings[c.settings];
      const { app, legacy, surcharges } =
        fareCheck.deliveryRates(settings, fareCheck.vehicleKey(c.vehicle));
      const inputs = { km: c.km, surcharges, weightTier: c.weight,
        isFragile: c.fragile, requiresHelpers: c.helpers };
      assert.equal(fareCheck.deliveryTotal({ ...inputs, rates: app }), c.expected);
      if (c.legacyExpected !== undefined) {
        assert.equal(fareCheck.deliveryTotal({ ...inputs, rates: legacy }), c.legacyExpected);
      } else {
        assert.equal(legacy, null);
      }
    });
  }
});

// ── assessDeliveryFare (pure) ─────────────────────────────────────────────────

describe("assessDeliveryFare", () => {
  const assess = (o, s = {}) => fareCheck.assessDeliveryFare(o, s);

  test("DFV-01 a road-distance fare is ok", () => {
    const r = assess(order());
    assert.equal(r.status, "ok");
    assert.ok(r.clientFare >= r.serverMinimumFare);
  });

  test("DFV-02 the app's straight-line fallback fare is ok (ellipsoid vs sphere)", () => {
    for (const k of [0.995, 1.0, 1.005]) {
      const r = assess(order({ estimatedFare: appFare(STRAIGHT_KM * k) }));
      assert.equal(r.status, "ok", `distance factor ${k}`);
    }
  });

  test("DFV-03 an underpriced fare is flagged below the minimum", () => {
    const r = assess(order({ estimatedFare: 5 }));
    assert.equal(r.status, "below_minimum");
    assert.equal(r.reason, "fare_below_straight_line_minimum");
    assert.equal(r.clientFare, 5);
    assert.ok(r.serverMinimumFare > 5);
  });

  test("DFV-04 vehicle, weight, fragile and helpers raise the minimum like the app", () => {
    const opts = { vehicle: "Aboboya", weight: "Large", fragile: true, helpers: true };
    const o = order({ vehicleType: "Aboboya", weightTier: "Large", isFragile: true,
      requiresHelpers: true, estimatedFare: appFare(STRAIGHT_KM, opts) });
    assert.equal(assess(o).status, "ok");
    // Priced as the cheapest options instead: flagged.
    const cheap = order({ vehicleType: "Aboboya", weightTier: "Large", isFragile: true,
      requiresHelpers: true, estimatedFare: appFare(STRAIGHT_KM) });
    assert.equal(assess(cheap).status, "below_minimum");
  });

  test("DFV-05 the vehicle minimum fare applies to short trips", () => {
    const near = new GeoPoint(PICKUP.latitude + 0.001, PICKUP.longitude);
    const o = order({ dropoffLocation: near, vehicleType: "Mini Truck", estimatedFare: 50 });
    assert.equal(assess(o).status, "ok");
    assert.equal(assess({ ...o, estimatedFare: 45 }).status, "below_minimum");
  });

  test("DFV-06 Bulk and unknown weight tiers are priced as small, like the app", () => {
    const r = assess(order({ vehicleType: "Mini Truck", weightTier: "Bulk",
      estimatedFare: appFare(STRAIGHT_KM, { vehicle: "Mini Truck" }) }));
    assert.equal(r.status, "ok");
  });

  test("DFV-07 legacy flat settings: the lower reading is used, legit fares pass", () => {
    const legacy = fixture.settings.legacyFlat;
    // The app ignores flat keys and charges its defaults.
    const r = assess(order({ estimatedFare: appFare(STRAIGHT_KM * 1.2) }), legacy);
    assert.equal(r.status, "ok");
    assert.equal(r.settingsFormat, "legacy_flat_present");
  });

  test("DFV-08 legacy order shape (no helpers field, other optional fields absent)", () => {
    const o = order();
    delete o.requiresHelpers;
    delete o.paymentMethod;
    assert.equal(assess(o).status, "ok");
  });

  test("DFV-09 missing settings are insufficient data, not invalid pricing", () => {
    assert.deepEqual(
      [assess(order(), null).status, assess(order(), null).reason],
      ["insufficient_data", "pricing_settings_unavailable"]);
  });

  test("DFV-10 missing or invalid inputs are insufficient data", () => {
    const cases = {
      fare_missing_or_invalid: [{ estimatedFare: undefined }, { estimatedFare: 0 },
        { estimatedFare: "12" }, { estimatedFare: NaN }],
      locations_missing_or_invalid: [{ pickupLocation: null },
        { dropoffLocation: new GeoPoint(0, 0) }],
      unknown_vehicle_type: [{ vehicleType: "Spaceship" }, { vehicleType: undefined }],
    };
    for (const [reason, overrides] of Object.entries(cases)) {
      for (const o of overrides) {
        const r = assess(order(o));
        assert.equal(r.status, "insufficient_data", JSON.stringify(o));
        assert.equal(r.reason, reason, JSON.stringify(o));
      }
    }
  });
});

// ── recordDeliveryFareCheck (emulator) ────────────────────────────────────────

describe("fare check recording", () => {
  async function seedSettings() {
    await h.seed("settings/platform", { platformFeePercent: 15, delivery: {} });
  }
  const docsOf = async (c) => (await h.db().collection(c).get()).docs;

  test("DFR-01 an underpriced delivery is flagged; order and escrow are untouched", async () => {
    await seedSettings();
    const o = order({ estimatedFare: 4, escrowId: "e1" });
    await h.seed("deliveries/d1", o);
    await h.seed("escrows/e1", { userId: "p1", amount: 4, status: "HELD",
      referenceId: "d1", referenceType: "delivery" });
    const before = [await h.read("deliveries/d1"), await h.read("escrows/e1")];

    const r = await fareCheck.recordDeliveryFareCheck("d1", o);

    assert.equal(r.status, "below_minimum");
    assert.deepEqual([await h.read("deliveries/d1"), await h.read("escrows/e1")], before);
    const check = await h.read("deliveryFareChecks/d1");
    assert.equal(check.status, "below_minimum");
    assert.equal(check.clientFare, 4);
    const alerts = await docsOf("admin_alerts");
    assert.equal(alerts.length, 1);
    // Ids and amounts only: no names, phones or addresses.
    assert.deepEqual(Object.keys(alerts[0].data()).sort(),
      ["clientFare", "createdAt", "deliveryId", "serverMinimumFare", "type", "vehicleKey"]);
  });

  test("DFR-02 a legitimate delivery is recorded ok with no alert", async () => {
    await seedSettings();
    const r = await fareCheck.recordDeliveryFareCheck("d2", order());
    assert.equal(r.status, "ok");
    assert.equal((await h.read("deliveryFareChecks/d2")).status, "ok");
    assert.equal((await docsOf("admin_alerts")).length, 0);
  });

  test("DFR-03 without settings the check records insufficient data, no alert", async () => {
    const r = await fareCheck.recordDeliveryFareCheck("d3", order({ estimatedFare: 1 }));
    assert.equal(r.status, "insufficient_data");
    assert.equal((await docsOf("admin_alerts")).length, 0);
  });

  test("DFR-04 a retried trigger records once and alerts once", async () => {
    await seedSettings();
    const o = order({ estimatedFare: 3 });
    assert.notEqual(await fareCheck.recordDeliveryFareCheck("d4", o), null);
    assert.equal(await fareCheck.recordDeliveryFareCheck("d4", o), null);
    await fareCheck.onDeliveryFareValidation.run({
      params: { deliveryId: "d4" }, data: { data: () => o },
    });
    assert.equal((await docsOf("deliveryFareChecks")).length, 1);
    assert.equal((await docsOf("admin_alerts")).length, 1);
  });

  test("DFR-05 the trigger never throws into order creation", async () => {
    await seedSettings();
    await fareCheck.onDeliveryFareValidation.run({
      params: { deliveryId: "d5" }, data: { data: () => order({ pickupLocation: "nonsense" }) },
    });
    assert.equal((await h.read("deliveryFareChecks/d5")).status, "insufficient_data");
  });
});

// ── verifyDeliveryEscrow (pure) ───────────────────────────────────────────────

describe("verifyDeliveryEscrow", () => {
  const good = { userId: "p1", referenceId: "d1", referenceType: "delivery",
    amount: 100, status: "HELD" };
  const v = (escrowOverrides = {}, fare = 100) => verifyDeliveryEscrow({
    deliveryId: "d1", passengerId: "p1", estimatedFare: fare,
    escrow: escrowOverrides === null ? null : { ...good, ...escrowOverrides },
  });

  test("DEV-01 the delivery's own held escrow is released", () => {
    assert.deepEqual(v(), { ok: true, mode: "release", amountMismatch: false });
  });

  test("DEV-02 every mismatch blocks with its own reason", () => {
    const blocked = {
      escrow_missing: null,
      escrow_owner_mismatch: { userId: "someone-else" },
      escrow_unattached: { referenceId: null },
      escrow_reference_mismatch: { referenceId: "d-other" },
      escrow_reference_type_mismatch: { referenceType: "gas_order" },
      escrow_amount_invalid: { amount: 0 },
      escrow_refunded: { status: "REFUNDED" },
      escrow_released_elsewhere: { status: "RELEASED", releaseReason: "trip_completed" },
      escrow_unexpected_status: { status: "WEIRD" },
    };
    for (const [reason, overrides] of Object.entries(blocked)) {
      assert.deepEqual(v(overrides), { ok: false, reason }, reason);
    }
  });

  test("DEV-03 released for this delivery: finish bookkeeping, release nothing", () => {
    assert.deepEqual(v({ status: "RELEASED", releaseReason: "delivery_completed" }),
      { ok: true, mode: "already_released", amountMismatch: false });
  });

  test("DEV-04 a held amount different from the stored fare is flagged, not blocked", () => {
    assert.deepEqual(v({}, 90), { ok: true, mode: "release", amountMismatch: true });
    assert.equal(v({}, "100").amountMismatch, false);
    // A missing or unreadable stored fare is a mismatch (an explicit null:
    // undefined would pick up the helper's default).
    assert.equal(v({}, null).amountMismatch, true);
    assert.equal(v({}, NaN).amountMismatch, true);
  });
});

// ── onDeliveryCompleted (emulator) ────────────────────────────────────────────

describe("delivery completion settles only its own escrow", () => {
  const D = "del-1";

  async function seedCompletion({ escrowData = {}, deliveryData = {}, driverBalance = 0 } = {}) {
    await h.seed("wallets/p1", { balance: 0, heldBalance: 100 });
    await h.seed("drivers/d1", { walletBalance: driverBalance });
    if (escrowData !== null) {
      await h.seed("escrows/e1", {
        id: "e1", userId: "p1", amount: 100, platformFee: 15, driverNet: 85,
        status: "HELD", referenceId: D, referenceType: "delivery",
        heldAt: Timestamp.fromDate(new Date(Date.now() - 30 * 60 * 1000)),
        ...escrowData,
      });
    }
    const after = {
      status: "completed", passengerId: "p1", driverId: "d1", paymentMethod: "wallet",
      deliveryOtp: "1234", otpSubmitted: "1234", estimatedFare: 100, escrowId: "e1",
      // Priced like a real booking (settlement checks the hold against it).
      pickupLocation: PICKUP, dropoffLocation: DROPOFF, vehicleType: "Okada", weightTier: "Small",
      ...deliveryData,
    };
    await h.seed(`deliveries/${D}`, after);
    return after;
  }

  const complete = async (afterData) => trips.onDeliveryCompleted.run({
    params: { deliveryId: D },
    data: {
      before: { data: () => ({ ...afterData, status: "arrivedAtDropoff" }) },
      after: { data: () => afterData },
    },
  });
  const delivery = () => h.read(`deliveries/${D}`);
  const alerts = async (type) => h.count("admin_alerts", "type", type);
  const captures = async () => h.count("ledger", "idempotencyKey", "capture_e1");

  async function expectBlocked(reason) {
    const d = await delivery();
    assert.equal(d.settlementStatus, "failed");
    assert.equal(d.settlementFailureReason, reason);
    assert.notEqual(d.walletProcessed, true);
    assert.equal(await alerts("delivery_settlement_failed"), 1);
    assert.equal(await captures(), 0);
  }

  test("DSC-01 a valid held escrow completes normally", async () => {
    await complete(await seedCompletion());
    const d = await delivery();
    assert.equal(d.walletProcessed, true);
    assert.equal(d.settlementStatus, "completed");
    assert.equal(d.actualFare, 100);
    const e = await h.read("escrows/e1");
    assert.equal(e.status, "RELEASED");
    assert.equal(e.releaseReason, "delivery_completed");
    assert.equal((await h.read("drivers/d1")).walletBalance, 85);
    assert.equal((await h.read("wallets/p1")).heldBalance, 0);
    assert.equal(await captures(), 1);
    assert.equal(await alerts("delivery_settlement_failed"), 0);
  });

  test("DSC-02 an escrow of another delivery is never released", async () => {
    await complete(await seedCompletion({ escrowData: { referenceId: "del-OTHER" } }));
    await expectBlocked("escrow_reference_mismatch");
    assert.equal((await h.read("escrows/e1")).status, "HELD");
    assert.equal((await h.read("drivers/d1")).walletBalance, 0);
  });

  test("DSC-03 an escrow of another service type is never released", async () => {
    await complete(await seedCompletion({ escrowData: { referenceType: "gas_order" } }));
    await expectBlocked("escrow_reference_type_mismatch");
    assert.equal((await h.read("escrows/e1")).status, "HELD");
  });

  test("DSC-04 another passenger's escrow is never released", async () => {
    await complete(await seedCompletion({ escrowData: { userId: "p-other" } }));
    await expectBlocked("escrow_owner_mismatch");
  });

  test("DSC-05 a held amount different from the fare releases nothing (2026-10-28: was settled on the hold)", async () => {
    await complete(await seedCompletion({ deliveryData: { estimatedFare: 90 } }));
    await expectBlocked("hold_amount_mismatch");
    assert.equal((await h.read("escrows/e1")).status, "HELD");
    assert.equal((await h.read("drivers/d1")).walletBalance, 0);
  });

  test("DSC-06 an escrow already released for something else blocks settlement", async () => {
    await complete(await seedCompletion({
      escrowData: { status: "RELEASED", releaseReason: "trip_completed" },
      driverBalance: 0,
    }));
    await expectBlocked("escrow_released_elsewhere");
    assert.equal((await h.read("drivers/d1")).walletBalance, 0);
  });

  test("DSC-07 released for this delivery before a crash: finished without paying twice", async () => {
    await complete(await seedCompletion({
      escrowData: { status: "RELEASED", releaseReason: "delivery_completed" },
      driverBalance: 85, // already credited by the interrupted attempt
    }));
    const d = await delivery();
    assert.equal(d.walletProcessed, true);
    assert.equal((await h.read("drivers/d1")).walletBalance, 85);
    assert.equal(await captures(), 0);
  });

  test("DSC-08 a refunded escrow blocks settlement", async () => {
    await complete(await seedCompletion({ escrowData: { status: "REFUNDED" } }));
    await expectBlocked("escrow_refunded");
  });

  test("DSC-09 a missing escrow blocks settlement", async () => {
    await complete(await seedCompletion({ escrowData: null }));
    await expectBlocked("escrow_missing");
  });

  test("DSC-10 an unattached (legacy) escrow is kept HELD and flagged, not released", async () => {
    await complete(await seedCompletion({ escrowData: { referenceId: null } }));
    await expectBlocked("escrow_unattached");
    assert.equal((await h.read("escrows/e1")).status, "HELD");
    // The hourly recovery later finds its completed order and flags it for
    // review; it does not refund it.
    const summary = await escrow.recoverStaleEscrows({ now: Date.now() + 3 * 60 * 60 * 1000 });
    assert.equal(summary.refunded, 0);
    assert.deepEqual(summary.review, [{ escrowId: "e1", reason: "settled_order_still_held" }]);
  });

  test("DSC-11 duplicate completion triggers settle once", async () => {
    const afterData = await seedCompletion();
    await complete(afterData);
    await complete(afterData);
    await complete({ ...(await delivery()) });
    assert.equal(await captures(), 1);
    assert.equal((await h.read("drivers/d1")).walletBalance, 85);
  });

  test("DSC-12 concurrent completion triggers settle once", async () => {
    const afterData = await seedCompletion();
    await Promise.all([complete(afterData), complete(afterData), complete(afterData)]);
    assert.equal(await captures(), 1);
    assert.equal((await h.read("drivers/d1")).walletBalance, 85);
    assert.equal((await delivery()).walletProcessed, true);
  });

  test("DSC-13 a failed settlement is not retried automatically (no trigger loop)", async () => {
    await complete(await seedCompletion({ escrowData: { referenceId: "del-OTHER" } }));
    // The failure write re-fires the trigger with the new document.
    await complete(await delivery());
    await complete(await delivery());
    assert.equal(await alerts("delivery_settlement_failed"), 1);
    assert.equal((await h.read("escrows/e1")).status, "HELD");
  });

  test("DSC-14 operations can retry once the cause is fixed", async () => {
    await complete(await seedCompletion({ escrowData: { referenceId: null } }));
    await expectBlocked("escrow_unattached");
    // Operations verify the order, attach the escrow and clear the failure.
    await h.db().doc("escrows/e1").update({ referenceId: D });
    await h.db().doc(`deliveries/${D}`).update({
      settlementStatus: h.admin.firestore.FieldValue.delete() });
    await complete(await delivery());
    assert.equal((await delivery()).walletProcessed, true);
    assert.equal((await h.read("drivers/d1")).walletBalance, 85);
  });

  test("DSC-15 a refund racing completion: exactly one moves the money", async () => {
    const afterData = await seedCompletion();
    const [refunded] = await Promise.all([
      escrow.refundEscrow("e1", "delivery_cancelled"),
      complete(afterData),
    ]);
    const w = await h.read("wallets/p1");
    const driver = await h.read("drivers/d1");
    const d = await delivery();
    if (refunded) {
      assert.equal(w.balance, 100);
      assert.equal(driver.walletBalance, 0);
      assert.notEqual(d.walletProcessed, true, "a refunded delivery is never marked settled");
      assert.equal(d.settlementStatus, "failed");
    } else {
      assert.equal(w.balance, 0);
      assert.equal(driver.walletBalance, 85);
      assert.equal(d.walletProcessed, true);
    }
    assert.equal(w.heldBalance, 0);
  });

  test("DSC-16 releaseEscrow refuses a mismatched expectation inside its transaction", async () => {
    await seedCompletion();
    await assert.rejects(
      escrow.releaseEscrow("e1", "d1", "delivery_completed",
        { userId: "p1", referenceId: "del-OTHER", referenceType: "delivery" }),
      (e) => e instanceof escrow.EscrowMismatchError && e.reason === "escrow_referenceId_mismatch");
    assert.equal((await h.read("escrows/e1")).status, "HELD");
    // A caller without an expectation is refused too (rides and gas pass one).
    await assert.rejects(escrow.releaseEscrow("e1", "d1", "trip_completed"),
      (e) => e instanceof escrow.EscrowMismatchError && e.reason === "escrow_expectation_missing");
    assert.equal((await h.read("escrows/e1")).status, "HELD");
  });
});

describe("refunds are unchanged", () => {
  test("DRF-01 cancelling a delivery refunds its held escrow once", async () => {
    await h.seed("wallets/p1", { balance: 0, heldBalance: 100 });
    await h.seed("escrows/e1", { userId: "p1", amount: 100, status: "HELD",
      referenceId: "del-1", referenceType: "delivery" });
    const beforeData = { status: "driverAssigned", escrowId: "e1", passengerId: "p1" };
    const afterData = { ...beforeData, status: "cancelled" };
    await h.seed("deliveries/del-1", afterData);
    const event = { params: { deliveryId: "del-1" },
      data: { before: { data: () => beforeData }, after: { data: () => afterData } } };

    await trips.onDeliveryCancelled.run(event);
    await trips.onDeliveryCancelled.run(event);

    assert.equal((await h.read("escrows/e1")).status, "REFUNDED");
    assert.equal((await h.read("wallets/p1")).balance, 100);
    assert.equal(await h.count("ledger", "idempotencyKey", "refund_e1"), 1);
  });
});
