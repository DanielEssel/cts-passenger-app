// Gas supplier live tracking (gas_supplier_tracking/{orderId}, written by
// functions/gas_supplier_tracking.js). The order's passenger, the currently
// assigned driver and admins read it; only that driver updates, and only
// their position while the order is active; nobody creates or deletes it
// from a client. Drivers still cannot read the parent order or its code.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, getDoc, setDoc, updateDoc, deleteDoc, serverTimestamp, GeoPoint } = require("firebase/firestore");
const h = require("./helpers");

const T = "gas_supplier_tracking/so1";
const HERE = new GeoPoint(5.61, -0.19);
const tracking = (o = {}) => ({
  orderId: "so1", driverId: h.DRIVER, status: "driverAssigned", updatedAt: new Date(0),
  driverCurrentLocation: null, driverHeading: null, lastLocationUpdate: null, driverLocationUpdatedAt: null, ...o,
});
/** What DriverLocationPublisher writes for one fix (jobLocationFields, legacy timestamp on). */
const fix = (o = {}) => ({
  driverCurrentLocation: HERE, driverHeading: 90, lastLocationUpdate: serverTimestamp(), driverLocationUpdatedAt: serverTimestamp(), ...o,
});

async function seedTracking(o = {}) {
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), T), tracking(o));
  });
}

describe("gas supplier live tracking", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      const fs = ctx.firestore();
      await setDoc(doc(fs, "gas_supplier_orders/so1"), {
        passengerId: h.PAX, driverId: h.DRIVER, status: "driverAssigned", completionCode: "4821",
        deliveryAddress: "12 Palm St", priceSnapshot: { total: 170 }, createdAt: new Date(0),
      });
    });
    await seedTracking();
  });

  it("GSTK-01 the order's passenger can read its tracking", () => assertSucceeds(getDoc(doc(h.db(h.PAX), T))));

  it("GSTK-02 an unrelated passenger cannot", () => assertFails(getDoc(doc(h.db(h.STRANGER), T))));

  it("GSTK-03 the assigned driver can read it", () => assertSucceeds(getDoc(doc(h.db(h.DRIVER), T))));

  it("GSTK-04 another driver, and the former driver after release, cannot", async () => {
    await assertFails(getDoc(doc(h.db(h.OTHER_DRIVER), T)));
    await seedTracking({ driverId: null, status: "confirmed" });
    await assertFails(getDoc(doc(h.db(h.DRIVER), T)));
  });

  it("GSTK-05 an admin can read it; signed-out users cannot", async () => {
    await assertSucceeds(getDoc(doc(h.db(h.ADMIN), T)));
    await assertFails(getDoc(doc(h.db(null), T)));
  });

  it("GSTK-06 the assigned driver updates their position in every active status", async () => {
    for (const status of ["driverAssigned", "atStation", "outForDelivery"]) {
      await seedTracking({ status });
      await assertSucceeds(updateDoc(doc(h.db(h.DRIVER), T), fix()));
    }
    // Without a heading (the publisher omits it when unknown), and with the legacy timestamp only when written.
    await assertSucceeds(updateDoc(doc(h.db(h.DRIVER), T), { driverCurrentLocation: HERE, lastLocationUpdate: serverTimestamp() }));
  });

  it("GSTK-07 the driver cannot change the status, the assignment or the order, nor send a bad position", async () => {
    const db = h.db(h.DRIVER);
    for (const forged of [{ status: "delivered" }, { driverId: h.OTHER_DRIVER }, { orderId: "so2" }, { updatedAt: serverTimestamp() }, { completionCode: "4821" }]) {
      await assertFails(updateDoc(doc(db, T), fix(forged)), JSON.stringify(forged));
    }
    await assertFails(updateDoc(doc(db, T), fix({ driverCurrentLocation: "5.6,-0.1" })));
    await assertFails(updateDoc(doc(db, T), fix({ driverHeading: "north" })));
    await assertFails(updateDoc(doc(db, T), fix({ lastLocationUpdate: new Date(0) })), "a client-chosen time");
  });

  it("GSTK-08 no position updates once the order is not active, or by anyone but the assigned driver", async () => {
    for (const status of ["confirmed", "delivered", "cancelled"]) {
      await seedTracking({ status });
      await assertFails(updateDoc(doc(h.db(h.DRIVER), T), fix()), status);
    }
    await seedTracking();
    for (const uid of [h.OTHER_DRIVER, h.PAX, h.ADMIN, null]) await assertFails(updateDoc(doc(h.db(uid), T), fix()), String(uid));
  });

  it("GSTK-09 the former driver cannot update the position after release", async () => {
    await seedTracking({ driverId: null, status: "confirmed" });
    await assertFails(updateDoc(doc(h.db(h.DRIVER), T), fix()));
    // Released then reassigned to someone else.
    await seedTracking({ driverId: h.OTHER_DRIVER, status: "driverAssigned" });
    await assertFails(updateDoc(doc(h.db(h.DRIVER), T), fix()));
    await assertSucceeds(updateDoc(doc(h.db(h.OTHER_DRIVER), T), fix()));
  });

  it("GSTK-10 no client creates or deletes a tracking document", async () => {
    for (const uid of [h.DRIVER, h.PAX, h.ADMIN]) {
      await assertFails(setDoc(doc(h.db(uid), "gas_supplier_tracking/new"), tracking({ orderId: "new" })), `create ${uid}`);
      await assertFails(deleteDoc(doc(h.db(uid), T)), `delete ${uid}`);
    }
  });

  it("GSTK-11 the driver still cannot read the parent order or its completion code", async () => {
    await assertFails(getDoc(doc(h.db(h.DRIVER), "gas_supplier_orders/so1")));
    await assertSucceeds(getDoc(doc(h.db(h.PAX), "gas_supplier_orders/so1")));
  });
});
