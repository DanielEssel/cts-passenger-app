// attachEscrowToOrder: an escrow can only be linked to the caller's own
// order of the right service, once, and an order can have only one escrow.
// Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const escrow = require("../../escrow");
const trips = require("../../trips");

const P = "passenger-1";
const OTHER = "passenger-2";
const { GeoPoint } = h.admin.firestore;

// Orders as the passenger app writes them for a wallet booking: the held
// amount (100 in seedEscrow) is the booked fare, and the route (about 7 km)
// gives a server minimum far below it (payment_verification.js).
const PICKUP = new GeoPoint(5.556, -0.1969);
const DROPOFF = new GeoPoint(5.6037, -0.155);
// Booked with its server quote (release v5 round 3), at the quote's total.
const deliveryOrder = (o = {}) => ({ passengerId: P, status: "pending", paymentMethod: "wallet",
  estimatedFare: 100, pickupLocation: PICKUP, dropoffLocation: DROPOFF, vehicleType: "Okada",
  weightTier: "Small", isFragile: false, requiresHelpers: false, deliveryQuoteId: "q-attach", ...o });
const tripOrder = (o = {}) => ({ passengerId: P, status: "searching", paymentMethod: "wallet",
  serviceType: "taxi", estimatedFare: 100, pickupLocation: PICKUP, dropoffLocation: DROPOFF, ...o });

async function seedEscrow(id, overrides = {}) {
  await h.seed(`escrows/${id}`, {
    id, userId: P, amount: 100, platformFee: 15, driverNet: 85,
    status: "HELD", referenceId: null, referenceType: "delivery",
    ...overrides,
  });
}

const attach = (data, uid = P) => escrow.attachEscrowForUser(uid, data);

async function rejects(promise, code, message) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, e.message);
    if (message) assert.match(e.message, message);
    return true;
  });
}

after(() => h.fft.cleanup());
// Wallet Delivery and Gas are offered once app_config/mobile requires the
// app versions that keep the completion code secret (escrow.js); these tests
// cover that state.
beforeEach(async () => {
  await h.clearFirestore();
  await h.enableDeliveryGasWallet();
  await h.quotedDelivery(deliveryOrder(), { quoteId: "q-attach",
    settings: { platformFeePercent: 15, delivery: h.DELIVERY_RATES } });
});

describe("supported passenger flows", () => {
  test("ATT-01 ride: the trip already carries escrowId at attach time", async () => {
    await seedEscrow("e-trip", { referenceType: "trip" });
    await h.seed("trips/t1", tripOrder({ escrowId: "e-trip" }));

    assert.deepEqual(await attach({ escrowId: "e-trip", referenceId: "t1", referenceType: "trip" }),
      { success: true });
    const e = await h.read("escrows/e-trip");
    assert.equal(e.referenceId, "t1");
    assert.equal(e.referenceType, "trip");
    assert.equal(e.amount, 100, "amount untouched");
    assert.equal((await h.read("escrowOrderLinks/trip:t1")).escrowId, "e-trip");
  });

  test("ATT-02 delivery: order created without escrowId, then attached", async () => {
    await seedEscrow("e-del");
    await h.seed("deliveries/d1", deliveryOrder());
    await attach({ escrowId: "e-del", referenceId: "d1", referenceType: "delivery" });
    assert.equal((await h.read("escrows/e-del")).referenceId, "d1");
  });

  test("ATT-03 gas: order created without escrowId, then attached", async () => {
    await seedEscrow("e-gas", { referenceType: "gas_order" });
    // Priced like a real legacy Gas order (attach checks the hold against it).
    await h.seed("gas_orders/g1", { passengerId: P, status: "pendingApproval", paymentMethod: "wallet",
      totalPrice: 100, refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1 });
    await attach({ escrowId: "e-gas", referenceId: "g1", referenceType: "gas_order" });
    assert.equal((await h.read("escrows/e-gas")).referenceId, "g1");
  });

  test("ATT-04 a driver accepting before the attach does not block it", async () => {
    await seedEscrow("e-fast");
    await h.seed("deliveries/d1", deliveryOrder({ status: "driverAssigned", driverId: "drv" }));
    await attach({ escrowId: "e-fast", referenceId: "d1", referenceType: "delivery" });
    assert.equal((await h.read("escrows/e-fast")).referenceId, "d1");
  });

  test("ATT-05 legacy escrow held without a referenceType can still be attached", async () => {
    await seedEscrow("e-old", { referenceType: null });
    await h.seed("deliveries/d1", deliveryOrder());
    await attach({ escrowId: "e-old", referenceId: "d1", referenceType: "delivery" });
    assert.equal((await h.read("escrows/e-old")).referenceType, "delivery");
  });

  test("ATT-06 the callable requires a signed-in caller", async () => {
    await seedEscrow("e-del");
    await h.seed("deliveries/d1", deliveryOrder());
    await rejects(h.callCallable(escrow.attachEscrowToOrder, null,
      { escrowId: "e-del", referenceId: "d1", referenceType: "delivery" }), "unauthenticated");
    const ok = await h.callCallable(escrow.attachEscrowToOrder, P,
      { escrowId: "e-del", referenceId: "d1", referenceType: "delivery" });
    assert.equal(ok.success, true);
  });
});

describe("rejected attachments", () => {
  beforeEach(async () => {
    await seedEscrow("e1");
    await h.seed("deliveries/d1", deliveryOrder());
  });

  test("ATT-10 someone else's escrow", async () => {
    await rejects(attach({ escrowId: "e1", referenceId: "d1", referenceType: "delivery" }, OTHER),
      "permission-denied", /Not your escrow/);
  });

  test("ATT-11 someone else's order", async () => {
    await h.seed("deliveries/d-other", { passengerId: OTHER, status: "pending" });
    await rejects(attach({ escrowId: "e1", referenceId: "d-other", referenceType: "delivery" }),
      "permission-denied", /Not your order/);
  });

  test("ATT-12 unsupported or missing service type", async () => {
    for (const referenceType of ["deliveries", "parcel", "", undefined, "__proto__", "toString"]) {
      await rejects(attach({ escrowId: "e1", referenceId: "d1", referenceType }),
        "invalid-argument", undefined);
    }
  });

  test("ATT-13 the order is not in that service's collection", async () => {
    await h.seed("gas_orders/g1", { passengerId: P });
    await rejects(attach({ escrowId: "e1", referenceId: "g1", referenceType: "delivery" }),
      "not-found", /Order not found/);
  });

  test("ATT-14 missing order or escrow", async () => {
    await rejects(attach({ escrowId: "e1", referenceId: "nope", referenceType: "delivery" }),
      "not-found", /Order not found/);
    await rejects(attach({ escrowId: "nope", referenceId: "d1", referenceType: "delivery" }),
      "not-found", /Escrow not found/);
  });

  test("ATT-15 the order already names a different escrow", async () => {
    await h.seed("deliveries/d1", { passengerId: P, escrowId: "e-other" });
    await rejects(attach({ escrowId: "e1", referenceId: "d1", referenceType: "delivery" }),
      "failed-precondition", /another escrow/);
  });

  test("ATT-16 an escrow held for gas cannot pay a delivery", async () => {
    await seedEscrow("e-gas", { referenceType: "gas_order" });
    await rejects(attach({ escrowId: "e-gas", referenceId: "d1", referenceType: "delivery" }),
      "failed-precondition", /another service/);
  });

  test("ATT-17 an escrow that is no longer held", async () => {
    await seedEscrow("e-done", { status: "REFUNDED" });
    await rejects(attach({ escrowId: "e-done", referenceId: "d1", referenceType: "delivery" }),
      "failed-precondition", /not active/);
  });

  test("ATT-18 invalid ids", async () => {
    await rejects(attach({ escrowId: "", referenceId: "d1", referenceType: "delivery" }),
      "invalid-argument");
    await rejects(attach({ escrowId: "e1", referenceId: "a/b", referenceType: "delivery" }),
      "invalid-argument");
  });
});

describe("one escrow per order, one order per escrow", () => {
  beforeEach(async () => {
    await seedEscrow("e1");
    // Both holds match the booked price, so ATT-24's race (not a price
    // refusal) decides which one is linked.
    await seedEscrow("e2");
    await h.seed("deliveries/d1", deliveryOrder());
    await h.seed("deliveries/d2", deliveryOrder());
  });

  test("ATT-20 repeating the same attach is accepted and changes nothing", async () => {
    await attach({ escrowId: "e1", referenceId: "d1", referenceType: "delivery" });
    assert.deepEqual(await attach({ escrowId: "e1", referenceId: "d1", referenceType: "delivery" }),
      { success: true, alreadyAttached: true });
    assert.equal((await h.read("escrows/e1")).referenceId, "d1");
  });

  test("ATT-21 an attached escrow cannot move to another order", async () => {
    await attach({ escrowId: "e1", referenceId: "d1", referenceType: "delivery" });
    await rejects(attach({ escrowId: "e1", referenceId: "d2", referenceType: "delivery" }),
      "failed-precondition", /already attached/);
  });

  test("ATT-22 a second escrow cannot be attached to the same order (H1)", async () => {
    await attach({ escrowId: "e1", referenceId: "d1", referenceType: "delivery" });
    // The attach now also records escrowId on the delivery, so the
    // order-level check refuses first; the link-record check (H1) is
    // exercised by ATT-23 and ATT-24.
    assert.equal((await h.read("deliveries/d1")).escrowId, "e1");
    await rejects(attach({ escrowId: "e2", referenceId: "d1", referenceType: "delivery" }),
      "failed-precondition", /paid by another escrow|already has an escrow/);
    assert.equal((await h.read("escrows/e2")).referenceId, null);
  });

  test("ATT-23 an escrow attached before this check (no link record) still blocks a second", async () => {
    await h.db().doc("escrows/e1").update({ referenceId: "d1" }); // legacy attach
    await rejects(attach({ escrowId: "e2", referenceId: "d1", referenceType: "delivery" }),
      "failed-precondition", /already has an escrow/);
  });

  test("ATT-24 two escrows racing for one order: exactly one wins", async () => {
    const results = await Promise.allSettled([
      attach({ escrowId: "e1", referenceId: "d1", referenceType: "delivery" }),
      attach({ escrowId: "e2", referenceId: "d1", referenceType: "delivery" }),
    ]);
    assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
    const attached = [await h.read("escrows/e1"), await h.read("escrows/e2")]
      .filter((e) => e.referenceId === "d1");
    assert.equal(attached.length, 1);
  });
});

describe("attachment feeds delivery settlement", () => {
  test("ATT-30 a properly attached delivery escrow settles; a swapped escrowId is refused", async () => {
    await h.seed("wallets/" + P, { balance: 0, heldBalance: 101 });
    await h.seed("drivers/drv", { walletBalance: 0 });
    await seedEscrow("e1");
    await seedEscrow("e2", { amount: 1, driverNet: 0.85, platformFee: 0.15 });
    await h.seed("deliveries/d1", deliveryOrder());
    await attach({ escrowId: "e1", referenceId: "d1", referenceType: "delivery" });

    // The swap the review found: a tiny escrow can no longer be linked.
    await rejects(attach({ escrowId: "e2", referenceId: "d1", referenceType: "delivery" }),
      "failed-precondition");

    // Even if the client points the order at e2, settlement refuses it.
    const swapped = { status: "completed", passengerId: P, driverId: "drv",
      paymentMethod: "wallet", deliveryOtp: "1", otpSubmitted: "1",
      estimatedFare: 100, escrowId: "e2" };
    await h.seed("deliveries/d1", swapped);
    await trips.onDeliveryCompleted.run({ params: { deliveryId: "d1" },
      data: { before: { data: () => ({ ...swapped, status: "arrivedAtDropoff" }) },
        after: { data: () => swapped } } });
    assert.equal((await h.read("deliveries/d1")).settlementFailureReason, "escrow_unattached");
    assert.equal((await h.read("drivers/drv")).walletBalance, 0);
  });
});
