// B1 acceptance tests for Bridge top-ups and payouts (PT-01 to PT-12).
//
// Each test states the invariant B1 must establish. Against the pre-B1 code
// most are EXPECTED TO FAIL; that failure list is the recorded baseline.
// They use only the local stub gateway and the Firestore emulator.
//
// None of them assume how Bridge authenticates callbacks: an "unverified"
// callback here is simply one carrying no provider proof of any kind.

"use strict";

const { test, describe, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");

let stub;
let bridge;
let approval;

const TOPUP_REF = "CTS-TOPUP-TEST-1";
const PAYOUT_REF = "CTS-PAYOUT-TEST-1";

async function seedPendingTopUp() {
  await h.seed("users/pax1", { role: "passenger" });
  await h.seed("wallets/pax1", { userId: "pax1", balance: 0, heldBalance: 0, currency: "GHS" });
  await h.seed(`payments/${TOPUP_REF}`, {
    transactionId: TOPUP_REF,
    userId: "pax1",
    phone: "233240000001",
    network: "MTN",
    amount: 20,
    currency: "GHS",
    type: "topup",
    status: "pending",
    bridgeTransId: null,
  });
}

async function seedPendingPayout({ withPaymentDoc = true } = {}) {
  await h.seed("admins/adm1", { active: true, role: "super_admin", email: "admin@test" });
  await h.seed("drivers/drv1", {
    displayName: "Driver One",
    isApproved: true,
    walletBalance: 0,
    totalEarnings: 0,
    pendingWithdrawal: 50, // the 50 was held when the withdrawal was requested
    // ...by this withdrawal: initiateBridgePayout sets the lock in the same
    // transaction as the hold (Phase 2B), and approval requires it.
    activeWithdrawalId: "W1",
  });
  await h.seed("withdrawals/W1", {
    userId: "drv1",
    userName: "Driver One",
    role: "driver",
    amount: 50,
    phone: "233200000001",
    network: "MTN",
    status: "pending",
    bridgeTransId: PAYOUT_REF,
  });
  if (withPaymentDoc) {
    await h.seed(`payments/${PAYOUT_REF}`, {
      transactionId: PAYOUT_REF,
      userId: "drv1",
      role: "driver",
      amount: 50,
      type: "payout",
      status: "pending",
      withdrawalId: "W1",
      txId: null,
    });
  }
}

const topUpCallback = (body) => h.callHttp(bridge.bridgeTopUpCallback, { body });
const payoutCallback = (body) => h.callHttp(bridge.bridgePayoutCallback, { body });

before(async () => {
  stub = await h.startStubGateway();
  bridge = require("../../bridge");
  approval = require("../../withdrawal_approval");
});
after(async () => {
  await stub.close();
  h.fft.cleanup();
});
beforeEach(async () => {
  stub.reset();
  await h.clearFirestore();
});

describe("top-up callback", () => {
  test("PT-01 an unverified success callback does not credit the wallet", async () => {
    await seedPendingTopUp();
    await topUpCallback({ trans_ref: TOPUP_REF, trans_status: "000", trans_id: "B1", amount: 20 });
    assert.equal((await h.read("wallets/pax1")).balance, 0);
  });

  test("PT-02 the credited amount never exceeds the amount recorded at initiation", async () => {
    await seedPendingTopUp();
    await topUpCallback({ trans_ref: TOPUP_REF, trans_status: "000", trans_id: "B1", amount: 5000 });
    assert.ok((await h.read("wallets/pax1")).balance <= 20);
  });

  test("PT-03 an unknown reference changes nothing", async () => {
    await seedPendingTopUp();
    const res = await topUpCallback({ trans_ref: "NOPE", trans_status: "000", trans_id: "B1", amount: 20 });
    assert.equal(res.statusCode, 200);
    assert.equal((await h.read("wallets/pax1")).balance, 0);
    assert.equal((await h.db().collection("ledger").get()).size, 0);
  });

  test("PT-04 a replayed callback credits at most once", async () => {
    await seedPendingTopUp();
    for (let i = 0; i < 3; i++) {
      await topUpCallback({ trans_ref: TOPUP_REF, trans_status: "000", trans_id: "B1", amount: 20 });
    }
    assert.ok((await h.read("wallets/pax1")).balance <= 20);
    assert.ok((await h.count("ledger", "referenceId", TOPUP_REF)) <= 1);
  });

  test("PT-05 ten concurrent identical callbacks credit at most once", async () => {
    await seedPendingTopUp();
    await Promise.allSettled(
      Array.from({ length: 10 }, () =>
        topUpCallback({ trans_ref: TOPUP_REF, trans_status: "000", trans_id: "B1", amount: 20 }),
      ),
    );
    assert.ok((await h.read("wallets/pax1")).balance <= 20);
    assert.ok((await h.count("ledger", "referenceId", TOPUP_REF)) <= 1);
  });

  test("PT-06 a terminal success is never overwritten by a later failure or pending event", async () => {
    await seedPendingTopUp();
    await h.db().doc(`payments/${TOPUP_REF}`).update({ status: "success", bridgeTransId: "B1" });
    await topUpCallback({ trans_ref: TOPUP_REF, trans_status: "001", trans_id: "B2", amount: 20 });
    await topUpCallback({ trans_ref: TOPUP_REF, trans_status: "002", trans_id: "B3", amount: 20 });
    assert.equal((await h.read(`payments/${TOPUP_REF}`)).status, "success");
  });
});

describe("payout callback", () => {
  test("PT-07 an unverified failure callback does not refund a pending payout", async () => {
    await seedPendingPayout();
    await payoutCallback({ trans_ref: PAYOUT_REF, trans_status: "001", trans_id: "B1", amount: 50 });
    const d = await h.read("drivers/drv1");
    assert.equal(d.walletBalance, 0);
    assert.equal(d.totalEarnings, 0);
  });

  test("PT-08 concurrent duplicate failure callbacks refund at most once", async () => {
    await seedPendingPayout();
    await Promise.allSettled(
      Array.from({ length: 5 }, () =>
        payoutCallback({ trans_ref: PAYOUT_REF, trans_status: "001", trans_id: "B1", amount: 50 }),
      ),
    );
    assert.ok((await h.read("drivers/drv1")).walletBalance <= 50);
  });
});

describe("payout approval and initiation", () => {
  test("PT-09 a dropped connection during payout leaves no refund and no re-approvable withdrawal", async () => {
    await seedPendingPayout({ withPaymentDoc: false });
    stub.state.mode = "drop";
    await assert.rejects(h.callCallable(approval.approveWithdrawal, "adm1", { withdrawalId: "W1" }));
    const d = await h.read("drivers/drv1");
    const w = await h.read("withdrawals/W1");
    assert.equal(d.walletBalance, 0, "outcome is unknown, so nothing may be refunded yet");
    assert.notEqual(w.status, "pending", "an unresolved payout must not be approvable again");
  });

  test("PT-10 two concurrent approvals send the payout once", async () => {
    await seedPendingPayout({ withPaymentDoc: false });
    await Promise.allSettled([
      h.callCallable(approval.approveWithdrawal, "adm1", { withdrawalId: "W1" }),
      h.callCallable(approval.approveWithdrawal, "adm1", { withdrawalId: "W1" }),
    ]);
    assert.equal(stub.requests.length, 1);
  });

  test("PT-11 pendingWithdrawal returns to zero after approval plus confirmed success", async () => {
    // Updated in Phase 2B: Bridge callbacks cannot be authenticated, so a
    // success callback alone must not settle a payout (the same rule PT-07
    // applies to failures). Success is confirmed by an admin
    // (resolveUnconfirmedPayout). The invariant is unchanged: approval plus
    // one confirmed success clears the hold exactly once (no double count).
    await seedPendingPayout({ withPaymentDoc: false });
    await h.callCallable(approval.approveWithdrawal, "adm1", { withdrawalId: "W1" });
    await payoutCallback({ trans_ref: PAYOUT_REF, trans_status: "000", trans_id: "B1", amount: 50 });
    assert.equal((await h.read("drivers/drv1")).pendingWithdrawal, 50, "an unverified callback settles nothing");
    await h.callCallable(approval.resolveUnconfirmedPayout, "adm1",
      { withdrawalId: "W1", outcome: "paid", evidence: "Bridge ref B1" });
    assert.equal((await h.read("drivers/drv1")).pendingWithdrawal, 0);
  });

  test("PT-12 initiateBridgePayout completes or reverses cleanly", async () => {
    await h.seed("drivers/drv2", {
      displayName: "Driver Two",
      phone: "0200000002",
      isApproved: true,
      walletBalance: 100,
      totalEarnings: 100,
      commissionOwed: 0,
    });
    let result;
    let error;
    try {
      result = await h.callCallable(bridge.initiateBridgePayout, "drv2", {
        amount: 50,
        phone: "0200000002",
        network: "MTN",
      });
    } catch (e) {
      error = e;
    }
    const d = await h.read("drivers/drv2");
    if (error) {
      // A failed request must leave the balance exactly as it was.
      assert.equal(d.walletBalance, 100, `failed with "${error.message}" but kept funds held`);
    } else {
      assert.equal(result.success, true);
    }
  });
});
