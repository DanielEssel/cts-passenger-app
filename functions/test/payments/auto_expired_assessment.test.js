// The historical impact assessment reads only, refuses production without
// explicit authorisation, and picks out the orders the old auto-refund
// left unsettled. Emulator fixtures only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const {
  assessAutoExpiredEscrows, classify, resolveTarget,
} = require("../../scripts/assess_auto_expired_escrows");

const { Timestamp } = h.admin.firestore;
const at = (iso) => Timestamp.fromDate(new Date(iso));

async function seedRefunded(id, { referenceType = "gas_order", referenceId,
  heldAt = "2026-09-01T08:00:00Z", refundedAt = "2026-09-01T10:30:00Z",
  reason = "auto_expired" } = {}) {
  await h.seed(`escrows/${id}`, {
    id, userId: "p1", amount: 120, driverNet: 102, platformFee: 18,
    referenceType, referenceId: referenceId ?? null, status: "REFUNDED",
    releaseReason: reason, heldAt: at(heldAt), releasedAt: at(refundedAt),
  });
  await h.seed(`ledger/refund-${id}`, {
    type: "REFUND", amount: 120, idempotencyKey: `refund_${id}`,
    processedAt: at(refundedAt),
  });
}

after(() => h.fft.cleanup());
beforeEach(() => h.clearFirestore());

describe("classify (pure)", () => {
  const t = (s) => new Date(s);
  test("AEA-01 refunded before a completed order: likely affected", () => {
    assert.equal(classify({ settled: true, captureCount: 0,
      refundedAt: t("2026-09-01T10:30Z"), completedAt: t("2026-09-01T11:00Z") }),
    "likely_affected");
  });
  test("AEA-02 a capture also exists, or times are missing: manual check", () => {
    assert.equal(classify({ settled: true, captureCount: 1,
      refundedAt: t("2026-09-01T10:30Z"), completedAt: t("2026-09-01T11:00Z") }),
    "needs_manual_check");
    assert.equal(classify({ settled: true, captureCount: 0,
      refundedAt: null, completedAt: t("2026-09-01T11:00Z") }), "needs_manual_check");
  });
  test("AEA-03 orders that never completed are not affected", () => {
    assert.equal(classify({ settled: false, captureCount: 0,
      refundedAt: t("2026-09-01T10:30Z"), completedAt: null }), "not_affected");
  });
});

describe("resolveTarget (access guard)", () => {
  test("AEA-10 the emulator is allowed without flags", () => {
    assert.equal(resolveTarget([], { FIRESTORE_EMULATOR_HOST: "127.0.0.1:8080" }).remote, false);
  });
  test("AEA-11 remote reads need --allow-remote-read", () => {
    assert.throws(() => resolveTarget(["--project", "ctsgo-staging"], {}), /allow-remote-read/);
    assert.equal(resolveTarget(["--project", "ctsgo-staging", "--allow-remote-read"], {}).remote, true);
  });
  test("AEA-12 production needs a separate authorisation flag", () => {
    assert.throws(() => resolveTarget(["--project", "ctstransportapp", "--allow-remote-read"], {}),
      /authorisation/);
  });
});

describe("assessAutoExpiredEscrows (emulator fixtures)", () => {
  async function seedScenario() {
    // Gas Pickup & Return refunded at 10:30, delivered at 11:15: old Gas
    // handler marked it processed without paying the driver.
    await seedRefunded("e-gas", { referenceId: "g-1" });
    await h.seed("gas_orders/g-1", {
      status: "delivered", driverId: "d1", passengerId: "p1", escrowId: "e-gas",
      paymentMethod: "wallet", deliveredAt: at("2026-09-01T11:15:00Z"),
      walletProcessed: true, driverEarnings: 102,
    });
    // Delivery refunded, then completed: old handler failed settlement.
    await seedRefunded("e-del", { referenceType: "delivery", referenceId: "dl-1" });
    await h.seed("deliveries/dl-1", {
      status: "completed", driverId: "d2", passengerId: "p1", escrowId: "e-del",
      completedAt: at("2026-09-01T12:00:00Z"), settlementStatus: "failed",
      walletProcessError: "Escrow e-del was refunded and cannot settle delivery",
    });
    // Unattached hold whose order exists (found through escrowId), completed.
    await seedRefunded("e-unlinked", { referenceId: null });
    await h.seed("gas_orders/g-2", {
      status: "delivered", driverId: "d1", escrowId: "e-unlinked",
      deliveredAt: at("2026-09-01T11:00:00Z"), walletProcessed: true,
    });
    // Correct refunds of orders that never completed.
    await seedRefunded("e-cancel", { referenceId: "g-3" });
    await h.seed("gas_orders/g-3", { status: "cancelled", escrowId: "e-cancel" });
    await seedRefunded("e-orphan"); // abandoned hold, no order
    // Not auto-expired at all.
    await seedRefunded("e-normal", { referenceId: "g-4", reason: "gas_order_cancelled" });
    await h.seed("gas_orders/g-4", { status: "delivered", escrowId: "e-normal" });
    // A ride: out of scope for this assessment.
    await seedRefunded("e-trip", { referenceType: "trip", referenceId: "t-1" });
  }

  test("AEA-20 finds completed Gas and Delivery orders refunded beforehand", async () => {
    await seedScenario();

    const report = await assessAutoExpiredEscrows(h.db());

    assert.equal(report.readOnly, true);
    assert.deepEqual(report.counts, {
      total: 6, outOfScope: 1, orderMissing: 1, not_affected: 1,
      likely_affected: 3, needs_manual_check: 0,
    });
    const byEscrow = Object.fromEntries(report.findings.map((f) => [f.escrowId, f]));
    assert.deepEqual(Object.keys(byEscrow).sort(), ["e-del", "e-gas", "e-unlinked"]);
    assert.equal(byEscrow["e-gas"].signals.walletProcessed, true);
    assert.equal(byEscrow["e-gas"].captureLedger.length, 0);
    assert.equal(byEscrow["e-gas"].refundLedger.length, 1);
    assert.equal(byEscrow["e-del"].signals.settlementStatus, "failed");
    assert.equal(byEscrow["e-unlinked"].orderId, "g-2");
    assert.ok(report.evidenceChecklist.length >= 5);
  });

  test("AEA-21 a completed order that also has a capture needs a manual check", async () => {
    await seedRefunded("e-both", { referenceId: "g-9" });
    await h.seed("gas_orders/g-9", { status: "delivered", escrowId: "e-both",
      deliveredAt: at("2026-09-01T11:00:00Z") });
    await h.seed("ledger/cap-e-both", { type: "CAPTURE", amount: 120,
      idempotencyKey: "capture_e-both" });

    const report = await assessAutoExpiredEscrows(h.db());

    assert.equal(report.counts.needs_manual_check, 1);
    assert.equal(report.findings[0].classification, "needs_manual_check");
  });

  test("AEA-22 the assessment writes nothing", async () => {
    await seedScenario();
    const snapshot = async () => {
      const out = {};
      for (const c of ["escrows", "ledger", "gas_orders", "deliveries", "wallets",
        "drivers", "admin_alerts"]) {
        const s = await h.db().collection(c).get();
        out[c] = s.docs.map((d) => [d.id, JSON.stringify(d.data())]).sort();
      }
      return out;
    };
    const before = await snapshot();

    await assessAutoExpiredEscrows(h.db());

    assert.deepEqual(await snapshot(), before);
  });
});
