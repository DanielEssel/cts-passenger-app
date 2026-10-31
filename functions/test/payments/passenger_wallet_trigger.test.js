// createPassengerWallet: fires only for users/{userId} creations, creates an
// empty wallet for a passenger, never overwrites an existing wallet, and
// ignores everything else. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
process.env.GCLOUD_PROJECT = "demo-ctsgo-payments";
process.env.PAYMENTS_MODE = "stub";
process.env.BRIDGE_CLIENT_KEY = "fake-client-key";
process.env.BRIDGE_SECRET_KEY = "fake-secret-key";
process.env.BRIDGE_SERVICE_ID = "1";
const index = require("../../index");
const h = require("./helpers");

const fn = index.createPassengerWallet;

async function userCreated(userId, data) {
  await h.seed(`users/${userId}`, data);
  await fn.run({ params: { userId }, data: { data: () => data } });
}

after(() => h.fft.cleanup());
beforeEach(() => h.clearFirestore());

describe("createPassengerWallet", () => {
  test("PWT-01 the trigger is scoped to users/{userId} creations", () => {
    const t = fn.__endpoint.eventTrigger;
    assert.equal(t.eventFilterPathPatterns.document, "users/{userId}");
    assert.ok(t.eventType.endsWith(".document.v1.created"));
    assert.equal(t.retry, false);
    assert.deepEqual(fn.__endpoint.region, ["europe-west2"]);
  });

  test("PWT-02 a new passenger gets an empty GHS wallet", async () => {
    await userCreated("p1", { role: "passenger", phoneNumber: "+233240000001" });
    const w = await h.read("wallets/p1");
    assert.equal(w.userId, "p1");
    assert.equal(w.balance, 0);
    assert.equal(w.currency, "GHS");
    assert.equal(w.isActive, true);
    assert.ok(w.createdAt);
  });

  test("PWT-03 an existing wallet is never overwritten (createWallet callable got there first)", async () => {
    await h.seed("wallets/p2", { userId: "p2", balance: 40, heldBalance: 10, email: "x@test", currency: "GHS" });
    await userCreated("p2", { role: "passenger" });
    assert.deepEqual(await h.read("wallets/p2"),
      { userId: "p2", balance: 40, heldBalance: 10, email: "x@test", currency: "GHS" });
  });

  test("PWT-04 non-passenger users get no wallet", async () => {
    await userCreated("d1", { role: "driver" });
    await userCreated("n1", { displayName: "no role" });
    assert.equal(await h.read("wallets/d1"), null);
    assert.equal(await h.read("wallets/n1"), null);
  });

  test("PWT-05 a repeated event is a no-op", async () => {
    await userCreated("p3", { role: "passenger" });
    const first = await h.read("wallets/p3");
    await fn.run({ params: { userId: "p3" }, data: { data: () => ({ role: "passenger" }) } });
    assert.deepEqual(await h.read("wallets/p3"), first);
  });

  test("PWT-06 a document created elsewhere cannot reach the wallet logic", () => {
    // The manifest filter is what keeps unrelated creations away; the
    // tripwire in ride_dispatch.test.js (RDP-03) requires every Firestore
    // trigger to declare one.
    assert.notEqual(fn.__endpoint.eventTrigger.eventFilterPathPatterns.document, undefined);
  });
});
