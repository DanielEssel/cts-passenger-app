// Driver payouts: review-only requests (initiateBridgePayout), one open
// withdrawal per driver, atomic admin approval and rejection, unknown payout
// outcomes, admin reconciliation (resolveUnconfirmedPayout), and Bridge
// callbacks that are recorded but never move money while they cannot be
// authenticated. Every path is checked for money conservation.
// Firestore emulator + local stub gateway only.

"use strict";

const { test, describe, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
// A short Bridge timeout so the timeout tests run quickly (server env, read
// when withdrawal_approval.js loads).
process.env.BRIDGE_HTTP_TIMEOUT_MS = "1500"; // above the delay tests (≤700 ms)
const h = require("./helpers");

let stub;
let bridge;
let approval;
let wallet;

const REF = "CTS-PAYOUT-WDA-1";

// A withdrawal as initiateBridgePayout leaves it: funds held, lock set.
async function seed({ held = 50, lock = "W1", status = "pending", withdrawal = {}, admin = { active: true, role: "super_admin" } } = {}) {
  await h.seed("admins/adm1", { email: "admin@test", ...admin });
  await h.seed("admins/inactive", { active: false, email: "x@test" });
  await h.seed("drivers/drv1", {
    displayName: "Driver One", isApproved: true,
    walletBalance: 0, totalEarnings: 0, pendingWithdrawal: held,
    ...(lock ? { activeWithdrawalId: lock } : {}),
  });
  await h.seed("withdrawals/W1", {
    userId: "drv1", userName: "Driver One", role: "driver", amount: 50,
    phone: "233200000001", network: "MTN", status, bridgeTransId: REF, ...withdrawal,
  });
}

const approve = (uid = "adm1", id = "W1") => h.callCallable(approval.approveWithdrawal, uid, { withdrawalId: id });
const reject = (uid = "adm1", id = "W1") => h.callCallable(approval.rejectWithdrawal, uid, { withdrawalId: id, reason: "test" });
const resolve = (outcome, { uid = "adm1", id = "W1", evidence = "Bridge ref B-123" } = {}) =>
  h.callCallable(approval.resolveUnconfirmedPayout, uid, { withdrawalId: id, outcome, evidence });
const payoutCallback = (trans_status, ref = REF) => h.callHttp(bridge.bridgePayoutCallback,
  { body: { trans_ref: ref, trans_status, trans_id: "B1", amount: 50 } });
const driver = () => h.read("drivers/drv1");
const withdrawal = () => h.read("withdrawals/W1");
const payment = () => h.read(`payments/${REF}`);
const code = (e) => e.code ?? e.httpErrorCode?.canonicalName;

// Money conservation for one GHS 50 withdrawal: held + returned + paid = 50.
async function assertConserved({ paid }) {
  const d = await driver();
  assert.equal(d.pendingWithdrawal + d.walletBalance + paid, 50,
    `held ${d.pendingWithdrawal} + returned ${d.walletBalance} + paid ${paid} must equal 50`);
}

before(async () => {
  stub = await h.startStubGateway();
  bridge = require("../../bridge");
  approval = require("../../withdrawal_approval");
  wallet = require("../../wallet");
});
after(async () => { await stub.close(); h.fft.cleanup(); });
beforeEach(async () => { stub.reset(); await h.clearFirestore(); });

describe("super admin role (B4)", () => {
  const plain = { active: true, role: "admin" };

  test("WDR-A01 approveWithdrawal: an active admin gets permission-denied and nothing changes; a super admin proceeds", async () => {
    await seed({ admin: plain });
    await assert.rejects(approve(), (e) => code(e) === "permission-denied" && /Super admins only\./.test(e.message));
    assert.equal(stub.requests.length, 0);
    assert.equal((await withdrawal()).status, "pending");
    await assertConserved({ paid: 0 });
    await h.seed("admins/adm1", { email: "admin@test", active: true, role: "super_admin" });
    await approve();
    assert.equal(stub.requests.length, 1);
  });

  test("WDR-A02 rejectWithdrawal: an active admin gets permission-denied and nothing changes; a super admin proceeds", async () => {
    await seed({ admin: plain });
    await assert.rejects(reject(), (e) => code(e) === "permission-denied" && /Super admins only\./.test(e.message));
    assert.equal((await withdrawal()).status, "pending");
    await assertConserved({ paid: 0 });
    assert.equal((await driver()).pendingWithdrawal, 50);
    await h.seed("admins/adm1", { email: "admin@test", active: true, role: "super_admin" });
    await reject();
    assert.equal((await withdrawal()).status, "rejected");
    assert.equal((await driver()).walletBalance, 50);
  });

  test("WDR-A03 resolveUnconfirmedPayout: an active admin gets permission-denied and nothing changes; a super admin proceeds", async () => {
    await seed({ status: "processing", withdrawal: { payoutOutcome: "unknown" } });
    await h.seed("admins/adm1", { email: "admin@test", ...plain });
    await assert.rejects(resolve("paid"), (e) => code(e) === "permission-denied" && /Super admins only\./.test(e.message));
    assert.equal((await withdrawal()).status, "processing");
    assert.equal((await driver()).pendingWithdrawal, 50);
    assert.equal(await h.count("ledger", "idempotencyKey", "payout_W1"), 0);
    await h.seed("admins/adm1", { email: "admin@test", active: true, role: "super_admin" });
    await resolve("paid");
    assert.equal((await withdrawal()).status, "completed");
  });
});

describe("inactive super admin (B4)", () => {
  test("WDR-A04 an inactive super_admin is refused by approve, reject and resolve", async () => {
    await seed({ withdrawal: { payoutOutcome: "unknown" } });
    await h.seed("admins/inactiveSuper", { active: false, role: "super_admin", email: "i@test" });
    await assert.rejects(approve("inactiveSuper"), (e) => code(e) === "permission-denied");
    await assert.rejects(reject("inactiveSuper"), (e) => code(e) === "permission-denied");
    await assert.rejects(resolve("paid", { uid: "inactiveSuper" }), (e) => code(e) === "permission-denied");
    assert.equal(stub.requests.length, 0);
    assert.equal((await withdrawal()).status, "pending");
    await assertConserved({ paid: 0 });
  });
});

describe("initiateBridgePayout (driver request)", () => {
  const request = (uid = "drv2", amount = 50) =>
    h.callCallable(bridge.initiateBridgePayout, uid, { amount, phone: "0200000002", network: "MTN" });
  const seedDriver = (o = {}) => h.seed("drivers/drv2", { displayName: "Driver Two", phone: "0200000002",
    isApproved: true, walletBalance: 100, totalEarnings: 100, commissionOwed: 0, ...o });

  test("WDA-01 a request holds the funds and waits for admin review; nothing is paid", async () => {
    await seedDriver();
    const r = await request();
    assert.equal(r.status, "pending_review");
    assert.equal(stub.requests.length, 0, "no automatic payout");
    const d = await h.read("drivers/drv2");
    assert.equal(d.walletBalance, 50);
    assert.equal(d.pendingWithdrawal, 50);
    assert.equal(d.activeWithdrawalId, r.withdrawalId);
    const w = await h.read(`withdrawals/${r.withdrawalId}`);
    assert.equal(w.status, "pending");
    assert.equal(w.needsReview, true);
    assert.equal(await h.count("audit_log", "action", "withdrawal_requested"), 1);
  });

  test("WDA-02 repeat drivers and small amounts are not auto-paid either", async () => {
    await seedDriver();
    await h.seed("withdrawals/old", { userId: "drv2", status: "completed", amount: 20 });
    const r = await request("drv2", 20);
    assert.equal(r.status, "pending_review");
    assert.equal(stub.requests.length, 0);
  });

  test("WDA-03 one open withdrawal per driver, sequential and concurrent", async () => {
    await seedDriver({ walletBalance: 500, totalEarnings: 500 });
    await request("drv2", 50);
    await assert.rejects(request("drv2", 50), (e) => code(e) === "failed-precondition");
    await h.clearFirestore();
    await seedDriver({ walletBalance: 500, totalEarnings: 500 });
    const results = await Promise.allSettled(Array.from({ length: 4 }, () => request("drv2", 50)));
    assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
    const d = await h.read("drivers/drv2");
    assert.equal(d.pendingWithdrawal, 50, "funds reserved once");
    assert.equal(d.walletBalance, 450);
    assert.equal((await h.db().collection("withdrawals").get()).size, 1);
  });

  test("WDA-04 the lock is released when the withdrawal ends, so the driver can request again", async () => {
    await seedDriver();
    await h.seed("admins/adm1", { active: true, role: "super_admin" });
    const r = await request();
    await h.callCallable(approval.rejectWithdrawal, "adm1", { withdrawalId: r.withdrawalId });
    const d = await h.read("drivers/drv2");
    assert.equal(d.activeWithdrawalId, undefined);
    assert.equal(d.walletBalance, 100);
    assert.equal(d.totalEarnings, 100, "rejection restores what the request debited");
    assert.equal(d.pendingWithdrawal, 0);
    assert.equal((await request()).status, "pending_review");
  });

  test("WDA-05 an insufficient balance holds nothing", async () => {
    await seedDriver({ walletBalance: 30, totalEarnings: 30 });
    await assert.rejects(request("drv2", 50), (e) => code(e) === "failed-precondition");
    const d = await h.read("drivers/drv2");
    assert.equal(d.walletBalance, 30);
    assert.equal(d.pendingWithdrawal ?? 0, 0);
    assert.equal(d.activeWithdrawalId, undefined);
  });

  test("WDA-06 the retired withdrawal callables refuse without touching money", async () => {
    await seedDriver();
    await h.seed("wallets/pax1", { userId: "pax1", balance: 100 });
    await assert.rejects(h.callCallable(wallet.requestWithdrawal, "drv2",
      { amount: 50, method: "momo", phoneNumber: "0200000002" }), (e) => code(e) === "failed-precondition");
    await assert.rejects(h.callCallable(wallet.requestWithdrawal, "pax1",
      { amount: 50, method: "momo", phoneNumber: "0240000001" }), (e) => code(e) === "failed-precondition");
    await assert.rejects(h.callCallable(wallet.requestDriverWithdrawal, "drv2",
      { amount: 50, phoneNumber: "0200000002", network: "MTN" }), (e) => code(e) === "failed-precondition");
    assert.deepEqual(await h.read("drivers/drv2"), { displayName: "Driver Two", phone: "0200000002",
      isApproved: true, walletBalance: 100, totalEarnings: 100, commissionOwed: 0 });
    await assert.rejects(h.callCallable(wallet.requestDriverWithdrawal, "pax1",
      { amount: 50, phoneNumber: "0240000001", network: "MTN" }), (e) => code(e) === "failed-precondition");
    await assert.rejects(h.callCallable(wallet.requestWithdrawal, null,
      { amount: 50, method: "momo", phoneNumber: "0240000001" }), (e) => code(e) === "unauthenticated");
    await assert.rejects(h.callCallable(wallet.requestDriverWithdrawal, null,
      { amount: 50, phoneNumber: "0200000002", network: "MTN" }), (e) => code(e) === "unauthenticated");
    assert.equal((await h.read("wallets/pax1")).balance, 100);
    for (const c of ["withdrawals", "ledger", "transactions", "payments"]) {
      assert.equal((await h.db().collection(c).get()).size, 0, c);
    }
    assert.equal(stub.requests.length, 0);
  });
});

describe("approveWithdrawal", () => {
  test("WDA-10 a held, pending withdrawal is sent once and stays processing", async () => {
    await seed();
    const r = await approve();
    assert.equal(r.status, "processing");
    assert.equal(stub.requests.length, 1);
    const w = await withdrawal();
    assert.equal(w.status, "processing");
    assert.equal(w.payoutOutcome, "sent");
    assert.equal((await driver()).pendingWithdrawal, 50, "held until the outcome is confirmed");
    await assertConserved({ paid: 0 });
  });

  test("WDA-11 five concurrent approvals send exactly one payout", async () => {
    await seed();
    const results = await Promise.allSettled(Array.from({ length: 5 }, () => approve()));
    assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
    for (const r of results.filter((x) => x.status === "rejected")) {
      assert.equal(code(r.reason), "failed-precondition");
    }
    assert.equal(stub.requests.length, 1);
  });

  test("WDA-12 a retried approval is refused and sends nothing", async () => {
    await seed();
    await approve();
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
    await resolve("paid");
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
    assert.equal(stub.requests.length, 1);
  });

  test("WDA-13 only an active admin may approve, reject or resolve", async () => {
    await seed();
    await assert.rejects(h.callCallable(approval.approveWithdrawal, null, { withdrawalId: "W1" }),
      (e) => code(e) === "unauthenticated");
    for (const uid of ["drv1", "inactive"]) {
      await assert.rejects(approve(uid), (e) => code(e) === "permission-denied", uid);
      await assert.rejects(reject(uid), (e) => code(e) === "permission-denied", uid);
      await assert.rejects(resolve("paid", { uid }), (e) => code(e) === "permission-denied", uid);
    }
    assert.equal(stub.requests.length, 0);
    assert.equal((await withdrawal()).status, "pending");
    await assertConserved({ paid: 0 });
  });

  test("WDA-14 money not held by this withdrawal is never paid or refunded", async () => {
    // Not held at all (e.g. a client-created request).
    await seed({ held: 0, lock: null });
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
    await assert.rejects(reject(), (e) => code(e) === "failed-precondition");
    // Held, but by another withdrawal: a forged second request sharing a real hold.
    await seed({ held: 50, lock: "W-real" });
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
    await assert.rejects(reject(), (e) => code(e) === "failed-precondition");
    // Locked to this withdrawal but less held than requested.
    await seed({ held: 20 });
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
    assert.equal(stub.requests.length, 0);
    assert.equal((await driver()).walletBalance, 0, "nothing credited");
  });

  test("WDA-15 rejected, failed, completed or processing withdrawals cannot be paid", async () => {
    for (const status of ["rejected", "failed", "completed", "processing"]) {
      await h.clearFirestore();
      stub.reset();
      await seed({ status });
      await assert.rejects(approve(), (e) => code(e) === "failed-precondition", status);
      assert.equal(stub.requests.length, 0, status);
    }
  });

  test("WDA-16 an incomplete withdrawal record is refused", async () => {
    await seed({ withdrawal: { userId: null } });
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
    await seed({ withdrawal: { amount: "50" } });
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
    assert.equal(stub.requests.length, 0);
  });
});

describe("payout provider outcomes", () => {
  test("WDA-20 an explicit rejection refunds once, releases the lock and is final", async () => {
    await seed();
    stub.state.mode = "reject";
    stub.state.code = "001";
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
    const d = await driver();
    assert.equal(d.walletBalance, 50);
    assert.equal(d.pendingWithdrawal, 0);
    assert.equal(d.activeWithdrawalId, undefined);
    assert.equal((await withdrawal()).status, "failed");
    stub.reset();
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
    await assert.rejects(resolve("failed"), (e) => code(e) === "failed-precondition");
    assert.equal(stub.requests.length, 0);
    await assertConserved({ paid: 0 });
  });

  for (const mode of ["drop", "http500"]) {
    test(`WDA-21 ${mode}: an unknown outcome holds the money, keeps the lock, blocks re-approval and alerts`, async () => {
      await seed();
      stub.state.mode = mode;
      await assert.rejects(approve(), (e) => code(e) === "unavailable");
      const d = await driver();
      assert.equal(d.walletBalance, 0, "not refunded: Bridge may have paid");
      assert.equal(d.pendingWithdrawal, 50);
      assert.equal(d.activeWithdrawalId, "W1", "no new request until reconciled");
      const w = await withdrawal();
      assert.equal(w.status, "processing");
      assert.equal(w.payoutOutcome, "unknown");
      assert.equal((await payment()).status, "unconfirmed");
      assert.equal(await h.count("admin_alerts", "type", "payout_outcome_unknown"), 1);
      stub.reset();
      await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
      assert.equal(stub.requests.length, 0, "never resent");
    });
  }
});

describe("attempt faults and races (Phase 2D)", () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const assertUnknownHeld = async () => {
    const w = await withdrawal();
    assert.equal(w.status, "processing");
    assert.equal(w.payoutOutcome, "unknown");
    const d = await driver();
    assert.equal(d.walletBalance, 0, "not refunded");
    assert.equal(d.pendingWithdrawal, 50, "still held");
    assert.equal(d.activeWithdrawalId, "W1");
    assert.equal((await payment()).status, "unconfirmed");
  };

  for (const [mode, label] of [["empty200", "no response code"], ["garbage200", "a non-JSON body"]]) {
    test(`WDA-60 ${label} is an unknown outcome, not a refusal`, async () => {
      await seed();
      stub.state.mode = mode;
      await assert.rejects(approve(), (e) => code(e) === "unavailable");
      await assertUnknownHeld();
      assert.equal(await h.count("ledger", "idempotencyKey", "payout_refund_W1"), 0);
    });
  }

  for (const c of ["999", "002", "500", "00", "0001"]) {
    test(`WDA-61 code "${c}" is an unknown outcome`, async () => {
      await seed();
      stub.state.mode = "reject";
      stub.state.code = c;
      await assert.rejects(approve(), (e) => code(e) === "unavailable");
      await assertUnknownHeld();
    });
  }

  test("WDA-62 a timeout leaves the money held and the attempt recoverable", async () => {
    await seed();
    stub.state.mode = "hang";
    const t0 = Date.now();
    await assert.rejects(approve(), (e) => code(e) === "unavailable");
    assert.ok(Date.now() - t0 < 5000, "bounded by the request timeout");
    await assertUnknownHeld();
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition", "never re-sent");
    assert.equal(stub.requests.length, 1);
    await resolve("failed");
    assert.equal((await driver()).walletBalance, 50, "recovered by an admin");
  });

  test("WDA-63 a 202 is accepted (sent), still held", async () => {
    await seed();
    stub.state.mode = "reject";
    stub.state.code = "202";
    await approve();
    assert.equal((await withdrawal()).payoutOutcome, "sent");
    assert.equal((await driver()).pendingWithdrawal, 50);
  });

  test("WDA-64 a failure before sending returns the withdrawal to pending; one payout overall", async () => {
    await seed();
    const saved = process.env.BRIDGE_API_BASE;
    process.env.BRIDGE_API_BASE = "https://api.bridgeagw.com"; // refused locally: fails before sending
    try {
      await assert.rejects(approve(), (e) => code(e) === "unavailable" && /not sent/.test(e.message));
    } finally {
      process.env.BRIDGE_API_BASE = saved;
    }
    assert.equal(stub.requests.length, 0, "nothing left the platform");
    const w = await withdrawal();
    assert.equal(w.status, "pending");
    assert.equal(w.attemptId, undefined);
    assert.equal((await driver()).pendingWithdrawal, 50, "still held for the next approval");
    assert.equal(await h.count("audit_log", "action", "withdrawal_payout_not_sent"), 1);
    await approve();
    assert.equal(stub.requests.length, 1);
  });

  test("WDA-65 an admin cannot resolve while an attempt is in flight", async () => {
    await seed();
    stub.state.mode = "delay";
    stub.state.code = "001";
    stub.state.delayMs = 600;
    const pending = approve();
    await sleep(150);
    await assert.rejects(resolve("failed"), (e) => code(e) === "failed-precondition" &&
      /in progress/.test(e.message));
    await assert.rejects(resolve("paid"), (e) => code(e) === "failed-precondition");
    await assert.rejects(pending, (e) => code(e) === "failed-precondition"); // Bridge refused
    const d = await driver();
    assert.equal(d.walletBalance, 50, "refunded exactly once");
    assert.equal(d.pendingWithdrawal, 0);
    assert.equal(await h.count("ledger", "idempotencyKey", "payout_refund_W1"), 1);
    await assertConserved({ paid: 0 });
  });

  for (const outcome of ["failed", "paid"]) {
    test(`WDA-66 a late refusal after an admin resolved a stale attempt (${outcome}) is not applied`, async () => {
      await seed();
      stub.state.mode = "delay";
      stub.state.code = "001";
      stub.state.delayMs = 700;
      const pending = approve();
      await sleep(150);
      // The attempt looks dead (older than the stale bound); an admin resolves it.
      await h.db().doc("withdrawals/W1").update({
        sendingStartedAt: h.admin.firestore.Timestamp.fromMillis(Date.now() - 11 * 60 * 1000),
      });
      await resolve(outcome);
      await assert.rejects(pending, (e) => code(e) === "aborted");
      const w = await withdrawal();
      assert.equal(w.status, outcome === "paid" ? "completed" : "failed");
      assert.equal(await h.count("admin_alerts", "type", "payout_attempt_superseded"), 1);
      const ledger = (await h.db().collection("ledger").get()).size;
      assert.equal(ledger, 1, "one financial outcome");
      await assertConserved({ paid: outcome === "paid" ? 50 : 0 });
    });
  }

  test("WDA-67 an explicit refusal is applied atomically with one ledger entry", async () => {
    await seed();
    stub.state.mode = "reject";
    stub.state.code = "003";
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
    const w = await withdrawal();
    assert.equal(w.status, "failed");
    assert.equal(w.payoutOutcome, "refused");
    assert.equal((await payment()).status, "failed");
    assert.equal(await h.count("ledger", "idempotencyKey", "payout_refund_W1"), 1);
    assert.equal(await h.count("audit_log", "action", "withdrawal_payout_refused"), 1);
    const d = await driver();
    assert.equal(d.activeWithdrawalId, undefined);
    await assertConserved({ paid: 0 });
  });
});

describe("Bridge callbacks (unauthenticated)", () => {
  test("WDA-30 success and failure callbacks are recorded but settle nothing", async () => {
    await seed();
    await approve();
    for (const s of ["000", "001", "003", "000"]) await payoutCallback(s);
    const w = await withdrawal();
    assert.equal(w.status, "processing");
    const d = await driver();
    assert.equal(d.pendingWithdrawal, 50);
    assert.equal(d.walletBalance, 0);
    assert.equal((await payment()).status, "pending");
    assert.equal((await payment()).callbackCount, 4);
    assert.equal((await h.db().collection("bridge_callbacks").get()).size, 4);
    assert.equal(await h.count("admin_alerts", "type", "bridge_callback_unverified"), 1, "one alert per payment");
    assert.equal(await h.count("ledger", "referenceId", REF), 0);
  });

  test("WDA-31 concurrent duplicate callbacks still move no money", async () => {
    await seed();
    await approve();
    await Promise.allSettled(Array.from({ length: 6 }, () => payoutCallback("001")));
    await assertConserved({ paid: 0 });
    assert.equal((await driver()).walletBalance, 0);
    assert.equal(await h.count("admin_alerts", "type", "bridge_callback_unverified"), 1);
  });

  test("WDA-32 a top-up callback never credits a wallet", async () => {
    await h.seed("wallets/pax1", { userId: "pax1", balance: 0, heldBalance: 0 });
    await h.seed("payments/CTS-TOPUP-WDA", { transactionId: "CTS-TOPUP-WDA", userId: "pax1",
      amount: 20, type: "topup", status: "pending" });
    await h.callHttp(bridge.bridgeTopUpCallback,
      { body: { trans_ref: "CTS-TOPUP-WDA", trans_status: "000", trans_id: "B9", amount: 20 } });
    assert.equal((await h.read("wallets/pax1")).balance, 0);
    assert.equal((await h.read("payments/CTS-TOPUP-WDA")).status, "pending");
    assert.equal((await h.db().collection("ledger").get()).size, 0);
  });
});

describe("resolveUnconfirmedPayout (admin reconciliation)", () => {
  test("WDA-40 confirmed paid: completed, hold released once, one ledger entry, lock released", async () => {
    await seed();
    stub.state.mode = "drop";
    await assert.rejects(approve());
    await resolve("paid");
    const w = await withdrawal();
    assert.equal(w.status, "completed");
    assert.equal(w.resolutionEvidence, "Bridge ref B-123");
    const d = await driver();
    assert.equal(d.pendingWithdrawal, 0);
    assert.equal(d.activeWithdrawalId, undefined);
    assert.equal(await h.count("ledger", "idempotencyKey", "payout_W1"), 1);
    assert.equal(await h.count("audit_log", "action", "withdrawal_payout_confirmed"), 1);
    await assertConserved({ paid: 50 });
  });

  test("WDA-41 confirmed failed: the hold is returned once", async () => {
    await seed();
    stub.state.mode = "drop";
    await assert.rejects(approve());
    await resolve("failed");
    const d = await driver();
    assert.equal(d.walletBalance, 50);
    assert.equal(d.pendingWithdrawal, 0);
    assert.equal((await withdrawal()).status, "failed");
    assert.equal(await h.count("ledger", "idempotencyKey", "payout_refund_W1"), 1);
    await assertConserved({ paid: 0 });
  });

  test("WDA-42 concurrent or repeated resolutions: exactly one wins; never both paid and refunded", async () => {
    await seed();
    await approve();
    const results = await Promise.allSettled([resolve("paid"), resolve("failed"), resolve("paid"), resolve("failed")]);
    assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
    const w = await withdrawal();
    const paid = w.status === "completed" ? 50 : 0;
    await assertConserved({ paid });
    await assert.rejects(resolve("failed"), (e) => code(e) === "failed-precondition");
    await assertConserved({ paid });
    const ledger = (await h.db().collection("ledger").get()).size;
    assert.equal(ledger, 1);
  });

  test("WDA-43 resolution requires processing state and evidence", async () => {
    await seed(); // still pending: must be approved first
    await assert.rejects(resolve("paid"), (e) => code(e) === "failed-precondition");
    await approve();
    await assert.rejects(resolve("paid", { evidence: "" }), (e) => code(e) === "invalid-argument");
    await assert.rejects(resolve("maybe"), (e) => code(e) === "invalid-argument");
    assert.equal((await withdrawal()).status, "processing");
  });

  test("WDA-44 a forged processing withdrawal cannot be resolved", async () => {
    await seed({ status: "processing", lock: "W-real" });
    await assert.rejects(resolve("failed"), (e) => code(e) === "failed-precondition");
    assert.equal((await driver()).walletBalance, 0);
  });
});

describe("rejectWithdrawal", () => {
  test("WDA-50 rejecting a held withdrawal returns the money once and releases the lock", async () => {
    await seed();
    await reject();
    await assert.rejects(reject(), (e) => code(e) === "failed-precondition");
    const d = await driver();
    assert.equal(d.walletBalance, 50);
    assert.equal(d.pendingWithdrawal, 0);
    assert.equal(d.activeWithdrawalId, undefined);
    assert.equal((await withdrawal()).status, "rejected");
    await assert.rejects(approve(), (e) => code(e) === "failed-precondition");
    assert.equal(stub.requests.length, 0);
    await assertConserved({ paid: 0 });
  });

  test("WDA-51 a concurrent approval and rejection: exactly one wins, never both", async () => {
    await seed();
    const [a, r] = await Promise.allSettled([approve(), reject()]);
    assert.equal([a, r].filter((x) => x.status === "fulfilled").length, 1);
    const w = await withdrawal();
    const d = await driver();
    if (a.status === "fulfilled") {
      assert.equal(w.status, "processing");
      assert.equal(stub.requests.length, 1);
      assert.equal(d.walletBalance, 0);
    } else {
      assert.equal(w.status, "rejected");
      assert.equal(stub.requests.length, 0);
      assert.equal(d.walletBalance, 50);
    }
  });
});
