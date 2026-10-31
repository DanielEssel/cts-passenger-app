// Linked-rider offer notifications (notifications.js, handleRiderOfferChange):
// one inbox entry and one push per offer or ended offer, none on redelivery,
// none for a stale or expired offer. Firestore emulator only; FCM is faked.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const { handleRiderOfferChange } = require("../../notifications");

const { Timestamp } = h.admin.firestore;
const O = "gsro-order1", R = "gsro-rider", R2 = "gsro-rider2";
const NOW = Date.now();
const offer = (driverId, seq, expiresInMs = 300000) => ({
  driverId, seq, offeredAt: Timestamp.fromMillis(NOW), expiresAt: Timestamp.fromMillis(NOW + expiresInMs), deliveryFeePesewas: 1000,
});
const ended = (driverId, seq, outcome) => ({ driverId, seq, outcome, at: Timestamp.fromMillis(NOW) });
const fakeFcm = (err) => {
  const sends = [];
  return { sends, send: async (m) => { sends.push(m); if (err) throw err; return "id"; } };
};
const inbox = (uid) => h.db().collection("drivers").doc(uid).collection("notifications").get();
const putOrder = (data) => h.db().collection("gas_supplier_orders").doc(O).set({ status: "confirmed", ...data });

describe("rider offer notifications", () => {
  after(async () => { await h.clearFirestore(); return h.fft.cleanup(); });
  beforeEach(async () => {
    await h.clearFirestore();
    await h.db().collection("drivers").doc(R).set({ fcmToken: "tok-r" });
    await h.db().collection("drivers").doc(R2).set({ fcmToken: "tok-r2" });
  });

  test("GSF-N01 a new offer makes one inbox doc and one push, and a redelivery makes none", async () => {
    const before = { riderOfferSeq: 0 };
    const after = { riderOffer: offer(R, 1), riderOfferSeq: 1 };
    await putOrder(after);
    const fcm = fakeFcm();
    const r1 = await handleRiderOfferChange(before, after, O, { now: NOW, fcm });
    assert.deepEqual(r1.sent, [`gas_rider_offer_${O}_1_offer`]);
    const docs = await inbox(R);
    assert.equal(docs.size, 1);
    assert.equal(docs.docs[0].id, `gas_rider_offer_${O}_1_offer`);
    assert.equal(fcm.sends.length, 1);
    assert.equal(fcm.sends[0].token, "tok-r");
    assert.equal(fcm.sends[0].android.notification.tag, `gsro_${O}`);
    assert.equal(fcm.sends[0].apns.headers["apns-collapse-id"], `gsro_${O}`);

    const r2 = await handleRiderOfferChange(before, after, O, { now: NOW, fcm });
    assert.deepEqual(r2.sent, []);
    assert.deepEqual(r2.skipped, [`gas_rider_offer_${O}_1_offer`]);
    assert.equal((await inbox(R)).size, 1);
    assert.equal(fcm.sends.length, 1);
  });

  test("GSF-N02 stale or expired offers send no offer push", async () => {
    const fcm = fakeFcm();
    // The order has moved on to seq 2 by the time the seq 1 event is handled.
    await putOrder({ riderOffer: offer(R2, 2), riderOfferSeq: 2 });
    const stale = await handleRiderOfferChange({}, { riderOffer: offer(R, 1), riderOfferSeq: 1 }, O, { now: NOW, fcm });
    assert.deepEqual(stale.sent, []);
    // Expired by now.
    await putOrder({ riderOffer: offer(R, 3, 1000), riderOfferSeq: 3 });
    const late = await handleRiderOfferChange({}, { riderOffer: offer(R, 3, 1000) }, O, { now: NOW + 5000, fcm });
    assert.deepEqual(late.sent, []);
    // The offer is gone from the order.
    await putOrder({ riderOfferSeq: 4 });
    const gone = await handleRiderOfferChange({}, { riderOffer: offer(R, 4) }, O, { now: NOW, fcm });
    assert.deepEqual(gone.sent, []);
    assert.equal(fcm.sends.length, 0);
    assert.equal((await inbox(R)).size + (await inbox(R2)).size, 0);
  });

  test("GSF-N02 an ended offer sends one ENDED push to the previous rider only", async () => {
    for (const outcome of ["withdrawn", "timed_out", "cancelled", "revoked"]) {
      await h.clearFirestore();
      await h.db().collection("drivers").doc(R).set({ fcmToken: "tok-r" });
      await h.db().collection("drivers").doc(R2).set({ fcmToken: "tok-r2" });
      const fcm = fakeFcm();
      const before = { riderOffer: offer(R, 1), riderOfferSeq: 1 };
      const after = { riderOfferSeq: 1, lastRiderOffer: ended(R, 1, outcome) };
      await putOrder(after);
      const res = await handleRiderOfferChange(before, after, O, { now: NOW, fcm });
      assert.deepEqual(res.sent, [`gas_rider_offer_${O}_1_ended`], outcome);
      assert.equal(fcm.sends.length, 1, outcome);
      assert.deepEqual(Object.keys(fcm.sends[0].data).sort(), ["orderId", "type"]);
      assert.deepEqual(fcm.sends[0].data, { type: "GAS_SUPPLIER_RIDER_OFFER_ENDED", orderId: O });
      assert.equal(fcm.sends[0].token, "tok-r");
      assert.equal((await inbox(R2)).size, 0);
      // Redelivery sends nothing more.
      await handleRiderOfferChange(before, after, O, { now: NOW, fcm });
      assert.equal(fcm.sends.length, 1, outcome);
    }
  });

  test("GSF-N02 a replaced offer ends the old rider's and offers the new rider's", async () => {
    const fcm = fakeFcm();
    const before = { riderOffer: offer(R, 1), riderOfferSeq: 1 };
    const after = { riderOffer: offer(R2, 2), riderOfferSeq: 2, lastRiderOffer: ended(R, 1, "withdrawn") };
    await putOrder(after);
    const res = await handleRiderOfferChange(before, after, O, { now: NOW, fcm });
    assert.equal(res.sent.length, 2);
    assert.deepEqual(fcm.sends.map((m) => [m.token, m.data.type]).sort(),
      [["tok-r", "GAS_SUPPLIER_RIDER_OFFER_ENDED"], ["tok-r2", "GAS_SUPPLIER_RIDER_OFFER"]]);
    assert.deepEqual(Object.keys(fcm.sends[0].data).sort(), ["orderId", "type"]);
  });

  test("GSF-N02 accepted and declined offers send nothing", async () => {
    const fcm = fakeFcm();
    for (const outcome of ["accepted", "declined"]) {
      const before = { riderOffer: offer(R, 1), riderOfferSeq: 1 };
      const after = { riderOfferSeq: 1, lastRiderOffer: ended(R, 1, outcome) };
      await putOrder(after);
      const res = await handleRiderOfferChange(before, after, O, { now: NOW, fcm });
      assert.deepEqual(res.sent, [], outcome);
    }
    assert.equal(fcm.sends.length, 0);
    assert.equal((await inbox(R)).size, 0);
  });

  test("GSF-N03 a dead token is removed; the order is untouched", async () => {
    const after = { riderOffer: offer(R, 1), riderOfferSeq: 1 };
    await putOrder(after);
    const err = Object.assign(new Error("gone"), { code: "messaging/registration-token-not-registered" });
    await handleRiderOfferChange({}, after, O, { now: NOW, fcm: fakeFcm(err) });
    assert.equal((await h.db().collection("drivers").doc(R).get()).data().fcmToken, undefined);
    assert.equal((await h.db().collection("drivers").doc(R2).get()).data().fcmToken, "tok-r2");
    const order = (await h.db().collection("gas_supplier_orders").doc(O).get()).data();
    assert.equal(order.status, "confirmed");
    assert.equal(order.riderOffer.seq, 1);
    assert.equal(order.riderOffer.driverId, R);
  });

  test("GSF-N03 a token the rider saved while the send was failing is kept; only the token the send used is dropped", async () => {
    const after = { riderOffer: offer(R, 1), riderOfferSeq: 1 };
    await putOrder(after);
    const err = Object.assign(new Error("gone"), { code: "messaging/registration-token-not-registered" });
    // The app rotates the token between the send and the failure handling.
    const sends = [];
    const fcm = { sends, send: async (m) => {
      sends.push(m);
      await h.db().collection("drivers").doc(R).update({ fcmToken: "tok-r-new" });
      throw err;
    } };
    await handleRiderOfferChange({}, after, O, { now: NOW, fcm });
    assert.equal(sends.length, 1);
    assert.equal(sends[0].token, "tok-r");
    assert.equal((await h.db().collection("drivers").doc(R).get()).data().fcmToken, "tok-r-new");
  });

  test("GSF-N03 any other FCM error leaves the token and the order untouched", async () => {
    const after = { riderOffer: offer(R, 1), riderOfferSeq: 1 };
    await putOrder(after);
    const err = Object.assign(new Error("boom"), { code: "messaging/internal-error" });
    const res = await handleRiderOfferChange({}, after, O, { now: NOW, fcm: fakeFcm(err) });
    assert.equal(res.sent.length, 1);
    assert.equal((await h.db().collection("drivers").doc(R).get()).data().fcmToken, "tok-r");
    const order = (await h.db().collection("gas_supplier_orders").doc(O).get()).data();
    assert.equal(order.status, "confirmed");
    assert.equal(order.riderOffer.seq, 1);
  });
});
