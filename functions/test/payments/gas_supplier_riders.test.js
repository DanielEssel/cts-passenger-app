// Gas supplier linked riders (gas_supplier_riders.js): super admins only,
// one supplier per driver, versioned links, an audit row per change, and a
// revoke that clears the rider's pending offer. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const r = require("../../gas_supplier_riders");

const SUPER = "gsr-super", ADMIN = "gsr-admin", INACTIVE = "gsr-inactive", PAX = "gsr-pax", DRIVER = "gsr-driver", MEMBER = "gsr-member";
const RIDER = "gsr-rider";
const call = (fn, data, uid) => h.callCallable(fn, uid, data);
const LINK = r.adminLinkGasSupplierRider, REVOKE = r.adminRevokeGasSupplierRider, LIST = r.adminListGasSupplierRiders;

async function rejects(promise, code, reason) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, `${e.code}: ${e.message} ${JSON.stringify(e.details)}`);
    if (reason) assert.equal(e.details?.reason, reason, JSON.stringify(e.details));
    return true;
  });
}
const refused = (p, reason) => rejects(p, "failed-precondition", reason);

const driver = (o = {}) => ({ role: "driver_delivery", isApproved: true, signupStep: "complete", displayName: "Kofi", vehicleType: "Okada", ...o });
const auditRows = async () => (await h.db().collection(r.RIDER_AUDIT).get()).docs.map((d) => d.data());

describe("gas supplier riders", () => {
  beforeEach(async () => {
    await h.clearFirestore();
    await h.seed(`admins/${SUPER}`, { active: true, role: "super_admin", email: "s@x.test" });
    await h.seed(`admins/${ADMIN}`, { active: true, role: "admin", email: "a@x.test" });
    await h.seed(`admins/${INACTIVE}`, { active: false, role: "super_admin", email: "i@x.test" });
    await h.seed(`users/${PAX}`, { role: "passenger" });
    await h.seed(`drivers/${DRIVER}`, driver());
    await h.seed(`drivers/${RIDER}`, driver());
    await h.seed(`gas_supplier_members/${MEMBER}`, { supplierId: "supA", status: "approved" });
    await h.seed("gas_suppliers/supA", { status: "approved", name: "A" });
    await h.seed("gas_suppliers/supB", { status: "approved", name: "B" });
  });
  after(async () => { await h.clearFirestore(); });

  test("GSR-01 every callable is refused to anyone but an active super admin, with no writes", async () => {
    const calls = [[LINK, { supplierId: "supA", driverId: DRIVER }], [REVOKE, { driverId: DRIVER, reason: "x" }], [LIST, { supplierId: "supA" }]];
    for (const [fn, data] of calls) {
      await rejects(call(fn, data, undefined), "unauthenticated");
      for (const uid of [PAX, DRIVER, MEMBER, INACTIVE, ADMIN, "nobody"]) await rejects(call(fn, data, uid), "permission-denied");
    }
    assert.equal((await h.db().collection(r.RIDERS).get()).size, 0);
    assert.equal((await auditRows()).length, 0);
  });

  test("GSR-02 a link is refused for an ineligible driver or supplier", async () => {
    const link = (supplierId = "supA", driverId = DRIVER) => call(LINK, { supplierId, driverId }, SUPER);
    await refused(link("supA", "ghost"), "driver_not_found");
    await h.seed(`drivers/${DRIVER}`, driver({ role: "driver_hailing" }));
    await refused(link(), "driver_wrong_role");
    await h.seed(`drivers/${DRIVER}`, driver({ isApproved: false }));
    await refused(link(), "driver_not_approved");
    await h.seed(`drivers/${DRIVER}`, driver({ signupStep: "suspended" }));
    await refused(link(), "driver_not_approved");
    await h.seed(`drivers/${DRIVER}`, driver());
    await h.seed(`admins/${DRIVER}`, { active: true, role: "admin" });
    await refused(link(), "admin_cannot_be_rider");
    await h.seed(`drivers/${MEMBER}`, driver());
    await refused(link("supA", MEMBER), "supplier_member_cannot_be_rider");
    await refused(link("ghost"), "supplier_not_found");
    await h.seed("gas_suppliers/supPending", { status: "pending" });
    await refused(link("supPending", RIDER), "supplier_not_found");
    assert.equal((await h.db().collection(r.RIDERS).get()).size, 0);
    assert.equal((await auditRows()).length, 0);
  });

  test("GSR-03 one supplier per driver; versions go 1, 2, 3; a repeat link adds no audit row", async () => {
    const a = await call(LINK, { supplierId: "supA", driverId: RIDER }, SUPER);
    assert.deepEqual(a, { driverId: RIDER, supplierId: "supA", status: "active", version: 1 });
    await refused(call(LINK, { supplierId: "supB", driverId: RIDER }, SUPER), "rider_linked_to_other_supplier");
    assert.deepEqual(await call(LINK, { supplierId: "supA", driverId: RIDER }, SUPER), a);
    assert.equal((await auditRows()).length, 1);
    const rv = await call(REVOKE, { driverId: RIDER, reason: "left" }, SUPER);
    assert.equal(rv.version, 2);
    const b = await call(LINK, { supplierId: "supB", driverId: RIDER }, SUPER);
    assert.equal(b.version, 3);
    const doc = await h.read(`${r.RIDERS}/${RIDER}`);
    assert.equal(doc.supplierId, "supB");
    assert.equal(doc.status, "active");
    assert.equal(doc.linkedBy, SUPER);
  });

  test("GSR-04 revoke needs a reason, works once, and the audit has one row per change", async () => {
    await call(LINK, { supplierId: "supA", driverId: RIDER }, SUPER);
    for (const reason of [undefined, "", "   ", 5]) {
      await rejects(call(REVOKE, { driverId: RIDER, reason }, SUPER), "invalid-argument", "reason_required");
    }
    await refused(call(REVOKE, { driverId: DRIVER, reason: "x" }, SUPER), "rider_not_found");
    const rv = await call(REVOKE, { driverId: RIDER, reason: "left the company" }, SUPER);
    assert.deepEqual(rv, { driverId: RIDER, status: "revoked", version: 2, voidedOrderId: null });
    await refused(call(REVOKE, { driverId: RIDER, reason: "again" }, SUPER), "already_revoked");
    const rows = (await auditRows()).sort((x, y) => x.version - y.version);
    assert.equal(rows.length, 2);
    assert.deepEqual(rows.map((x) => [x.action, x.by, x.version, x.driverId, x.supplierId]),
      [["link", SUPER, 1, RIDER, "supA"], ["revoke", SUPER, 2, RIDER, "supA"]]);
    const doc = await h.read(`${r.RIDERS}/${RIDER}`);
    assert.equal(doc.status, "revoked");
    assert.equal(doc.revokedBy, SUPER);
    assert.equal(doc.revokeReason, "left the company");
  });

  test("GSR-05 revoking clears a pending offer and restarts the order's deadline", async () => {
    await h.seed("settings/gas_supplier_fulfilment", { riderAcceptMinutes: 7 });
    await call(LINK, { supplierId: "supA", driverId: RIDER }, SUPER);
    const offer = { driverId: RIDER, seq: 2, offeredAt: new Date(), expiresAt: new Date(Date.now() + 60000), deliveryFeePesewas: 500 };
    await h.seed("gas_supplier_orders/o1", { status: "confirmed", supplierId: "supA", riderOffer: offer, riderOfferSeq: 2 });
    await h.seed("gas_supplier_orders/o-other", { status: "confirmed", supplierId: "supA", riderOffer: { ...offer, driverId: DRIVER } });
    await h.seed("gas_supplier_orders/o-done", { status: "driverAssigned", supplierId: "supA", driverId: RIDER });
    const before = Date.now();
    const rv = await call(REVOKE, { driverId: RIDER, reason: "left" }, SUPER);
    assert.equal(rv.voidedOrderId, "o1");
    const o = await h.read("gas_supplier_orders/o1");
    assert.equal(o.riderOffer, undefined);
    assert.equal(o.lastRiderOffer.outcome, "revoked");
    assert.equal(o.lastRiderOffer.driverId, RIDER);
    assert.equal(o.lastRiderOffer.seq, 2);
    const wait = o.riderDeadlineAt.toMillis() - before;
    assert.ok(wait >= 7 * 60000 - 1000 && wait <= 7 * 60000 + 10000, `deadline ${wait}`);
    assert.equal((await h.read("gas_supplier_orders/o-other")).riderOffer.driverId, DRIVER);
    assert.equal((await h.read("gas_supplier_orders/o-done")).driverId, RIDER);
    assert.equal((await auditRows()).find((x) => x.action === "revoke").voidedOrderId, "o1");
  });

  test("GSR-06 the list shows a supplier's riders and its audit, nothing of another supplier's", async () => {
    await call(LINK, { supplierId: "supA", driverId: RIDER }, SUPER);
    await call(LINK, { supplierId: "supB", driverId: DRIVER }, SUPER);
    await call(REVOKE, { driverId: RIDER, reason: "left" }, SUPER);
    const res = await call(LIST, { supplierId: "supA" }, SUPER);
    assert.equal(res.riders.length, 1);
    const [x] = res.riders;
    assert.equal(x.driverId, RIDER);
    assert.equal(x.name, "Kofi");
    assert.equal(x.vehicle, "Okada");
    assert.equal(x.status, "revoked");
    assert.equal(x.version, 2);
    assert.equal(x.linkedBy, SUPER);
    assert.equal(x.revokeReason, "left");
    assert.equal(typeof x.linkedAt, "number");
    assert.equal(res.audit.length, 2);
    assert.ok(res.audit.every((a) => a.supplierId === "supA"));
    assert.equal(res.audit[0].action, "revoke");
  });

  test("GSR-07 activeRiderLink finds only an active link to that supplier", async () => {
    const find = (d, s) => h.db().runTransaction((tx) => r.activeRiderLink(tx, d, s));
    assert.equal(await find(RIDER, "supA"), null);
    await call(LINK, { supplierId: "supA", driverId: RIDER }, SUPER);
    assert.equal((await find(RIDER, "supA")).version, 1);
    assert.equal(await find(RIDER, "supB"), null);
    await call(REVOKE, { driverId: RIDER, reason: "left" }, SUPER);
    assert.equal(await find(RIDER, "supA"), null);
  });

  test("GSR-08 riderAcceptMinutes takes a whole number from 1 to 60, else 5", () => {
    const warn = console.warn;
    console.warn = () => {};
    try {
      for (const v of [1, 5, 60]) assert.equal(r.riderAcceptMinutes({ riderAcceptMinutes: v }), v);
      for (const v of [0, 61, 2.5, "7", null, NaN]) assert.equal(r.riderAcceptMinutes({ riderAcceptMinutes: v }), 5);
      assert.equal(r.riderAcceptMinutes(null), 5);
      assert.equal(r.riderAcceptMinutes({}), 5);
      assert.equal(r.DEFAULT_RIDER_ACCEPT_MINUTES, 5);
    } finally { console.warn = warn; }
  });
});
