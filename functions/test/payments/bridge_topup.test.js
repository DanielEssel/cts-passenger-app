// Bridge (The Bridge Solutions) wallet top-ups, with no global freeze:
//   • a top-up starts: one request to the gateway, one pending payment;
//   • nothing credits a wallet until a top-up's result is confirmed through
//     a documented, authenticated mechanism. No such mechanism exists yet
//     (bridge.js verifyBridgeCallback), so every callback, however it looks,
//     is recorded and alerted and the top-up stays pending;
//   • the status check tells the app when a result was reported but cannot
//     be verified (awaitingVerification), so it never suggests paying again;
//   • the Paystack callables and webhook are gone.
// Firestore emulator + local stub gateway only.

"use strict";

const { test, describe, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");

let stub;
let bridge;
let wallet;
let escrow;
let config;

const code = (e) => e.code ?? e.httpErrorCode?.canonicalName;
const topUp = (data, uid = "pax1") => h.callCallable(bridge.initiateBridgeTopUp, uid, data);
const status = (transactionId, uid = "pax1") =>
  h.callCallable(bridge.checkBridgeTopUpStatus, uid, { transactionId });
const callback = (body) => h.callHttp(bridge.bridgeTopUpCallback, { body });
const valid = { amount: 20, phone: "0240000001", network: "MTN" };

async function assertNothingCredited(uid = "pax1") {
  assert.equal((await h.read(`wallets/${uid}`)).balance, 0, "wallet not credited");
  assert.equal(await h.count("ledger", "type", "TOPUP"), 0, "no top-up ledger entry");
}

before(async () => {
  stub = await h.startStubGateway();
  bridge = require("../../bridge");
  wallet = require("../../wallet");
  escrow = require("../../escrow");
  config = require("../../config");
});
after(async () => { await stub.close(); h.fft.cleanup(); });
beforeEach(async () => {
  stub.reset();
  await h.clearFirestore();
  await h.seed("wallets/pax1", { userId: "pax1", balance: 0, heldBalance: 0 });
});

describe("no global freeze", () => {
  test("BTU-01 a top-up starts: one gateway request, one pending payment, no credit", async () => {
    const r = await topUp(valid);
    assert.equal(r.success, true);
    assert.equal(stub.requests.length, 1);
    assert.equal(stub.requests[0].body.trans_type, "CTM");
    assert.equal(stub.requests[0].body.amount, 20);
    const p = await h.read(`payments/${r.transactionId}`);
    assert.equal(p.status, "pending");
    assert.equal(p.userId, "pax1");
    assert.equal(p.amount, 20);
    await assertNothingCredited();
  });

  test("BTU-02 the configuration exposes no freeze or Paystack switch", () => {
    for (const name of ["topUpsFrozen", "bridgeTopUpsFrozen", "assertPaystackRequestAllowed"]) {
      assert.equal(config[name], undefined, name);
    }
  });

  test("BTU-03 the Paystack callables and webhook no longer exist", () => {
    assert.equal(wallet.initializePaystackPayment, undefined);
    assert.equal(wallet.verifyPaystackPayment, undefined);
    assert.equal(escrow.paystackWebhook, undefined);
  });

  test("BTU-04 invalid requests and signed-out callers are refused before any request", async () => {
    await assert.rejects(h.callCallable(bridge.initiateBridgeTopUp, null, valid),
      (e) => code(e) === "unauthenticated");
    for (const bad of [{ ...valid, amount: 0 }, { ...valid, amount: "20" }, { ...valid, phone: "" },
      { ...valid, network: "XYZ" }, { ...valid, phone: "12345" }]) {
      await assert.rejects(topUp(bad), (e) => code(e) === "invalid-argument", JSON.stringify(bad));
    }
    assert.equal(stub.requests.length, 0);
    assert.equal((await h.db().collection("payments").get()).size, 0);
  });

  test("BTU-05 a refusal from the gateway marks the payment failed and credits nothing", async () => {
    stub.state.mode = "reject";
    stub.state.code = "019";
    await assert.rejects(topUp(valid), (e) => code(e) === "failed-precondition");
    const payments = (await h.db().collection("payments").get()).docs.map((d) => d.data());
    assert.equal(payments.length, 1);
    assert.equal(payments[0].status, "failed");
    await assertNothingCredited();
  });
});

describe("pending until verified", () => {
  test("BTU-10 an unverified success callback is recorded, alerted, and credits nothing", async () => {
    const { transactionId } = await topUp(valid);
    const res = await callback({ trans_ref: transactionId, trans_status: "000", trans_id: "B1", amount: 20 });
    assert.equal(res.statusCode, 200);
    assert.equal(res.body.note, "recorded_unverified");
    assert.equal((await h.read(`payments/${transactionId}`)).status, "pending");
    assert.equal(await h.count("bridge_callbacks", "transactionId", transactionId), 1);
    assert.equal(await h.count("admin_alerts", "type", "bridge_callback_unverified"), 1);
    await assertNothingCredited();
  });

  test("BTU-11 repeated and concurrent callbacks still credit nothing; one alert per payment", async () => {
    const { transactionId } = await topUp(valid);
    const body = { trans_ref: transactionId, trans_status: "000", trans_id: "B1", amount: 20 };
    await callback(body);
    await Promise.all([callback(body), callback(body), callback({ ...body, amount: 5000 })]);
    assert.equal((await h.read(`payments/${transactionId}`)).status, "pending");
    assert.equal(await h.count("bridge_callbacks", "transactionId", transactionId), 4);
    assert.equal(await h.count("admin_alerts", "type", "bridge_callback_unverified"), 1);
    await assertNothingCredited();
  });

  test("BTU-12 an unverified failure callback does not mark the top-up failed either", async () => {
    const { transactionId } = await topUp(valid);
    await callback({ trans_ref: transactionId, trans_status: "001", trans_id: "B1" });
    assert.equal((await h.read(`payments/${transactionId}`)).status, "pending");
  });

  test("BTU-13 the status check reports awaitingVerification only after a reported result", async () => {
    const { transactionId } = await topUp(valid);
    const before = await status(transactionId);
    assert.equal(before.localStatus, "pending");
    assert.equal(before.awaitingVerification, false);
    await callback({ trans_ref: transactionId, trans_status: "000", trans_id: "B1", amount: 20 });
    const after = await status(transactionId);
    assert.equal(after.localStatus, "pending", "never reported as success");
    assert.equal(after.awaitingVerification, true);
  });

  test("BTU-14 a failed initiation is not awaiting verification", async () => {
    stub.state.mode = "reject";
    stub.state.code = "019";
    await assert.rejects(topUp(valid));
    const [doc] = (await h.db().collection("payments").get()).docs;
    const s = await status(doc.id);
    assert.equal(s.localStatus, "failed");
    assert.equal(s.awaitingVerification, false);
  });

  test("BTU-15 only the payment's owner can check it", async () => {
    const { transactionId } = await topUp(valid);
    await assert.rejects(status(transactionId, "someone-else"), (e) => code(e) === "permission-denied");
  });

  test("BTU-16 existing pending and failed records are left as they are, never deleted", async () => {
    for (const [ref, st] of [["CTS-TOPUP-PENDING", "pending"], ["CTS-TOPUP-FAILED", "failed"]]) {
      await h.seed(`payments/${ref}`, { transactionId: ref, userId: "pax1", amount: 20, type: "topup", status: st });
    }
    await callback({ trans_ref: "CTS-TOPUP-PENDING", trans_status: "000", trans_id: "B1", amount: 20 });
    await callback({ trans_ref: "CTS-TOPUP-FAILED", trans_status: "000", trans_id: "B2", amount: 5000 });
    assert.equal((await h.read("payments/CTS-TOPUP-PENDING")).status, "pending");
    assert.equal((await h.read("payments/CTS-TOPUP-FAILED")).status, "failed");
    assert.equal((await h.db().collection("payments").get()).size, 2);
    await assertNothingCredited();
  });
});
