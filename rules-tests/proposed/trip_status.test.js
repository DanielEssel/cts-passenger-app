// PROPOSED (TRIP-STATUS): trip status may only move along the ride lifecycle.
// Runs against rules-tests/proposed/firestore.trip-status.rules, never the
// deployed firestore.rules:
//
//   cd rules-tests && RULES_FILE=proposed/firestore.trip-status.rules \
//     firebase emulators:exec --only firestore --project demo-ctsgo-rules \
//     --config ../firebase.json "mocha test proposed"

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, setDoc, updateDoc, serverTimestamp, deleteField } = require("firebase/firestore");
const h = require("../test/helpers");

const TRIP = "statusTrip";

async function seedTrip(status, extra = {}) {
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    await setDoc(
      doc(ctx.firestore(), `trips/${TRIP}`),
      h.newTripPayload({ status, driverId: h.DRIVER, ...extra }),
    );
  });
}

const as = (uid, data) => updateDoc(doc(h.db(uid), `trips/${TRIP}`), data);

describe("PROPOSED trip status transitions", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(h.seed);

  describe("driver lifecycle", () => {
    for (const [from, to] of [
      ["tripAccepted", "driverArrived"],
      ["driverArrived", "tripStarted"],
      ["tripStarted", "completed"],
    ]) {
      it(`allows ${from} → ${to}`, async () => {
        await seedTrip(from);
        await assertSucceeds(as(h.DRIVER, { status: to }));
      });
    }

    for (const [from, to] of [
      ["tripAccepted", "completed"], // the old "Complete Trip" shortcut
      ["driverArrived", "completed"], // complete without starting
      ["tripAccepted", "tripStarted"], // start without arriving
      ["completed", "tripStarted"], // reopen a finished trip
      ["cancelledByPassenger", "tripStarted"], // continue a cancelled trip
    ]) {
      it(`refuses ${from} → ${to}`, async () => {
        await seedTrip(from);
        await assertFails(as(h.DRIVER, { status: to }));
      });
    }

    it("may cancel before completion, not after", async () => {
      await seedTrip("tripStarted");
      await assertSucceeds(as(h.DRIVER, { status: "cancelledByDriver" }));
      await seedTrip("completed");
      await assertFails(as(h.DRIVER, { status: "cancelledByDriver" }));
    });

    it("can still write location without changing status", async () => {
      await seedTrip("tripStarted");
      await assertSucceeds(
        as(h.DRIVER, { lastLocationUpdate: serverTimestamp() }),
      );
    });
  });

  describe("status field integrity", () => {
    it("a party cannot remove the status field", async () => {
      await seedTrip("tripStarted");
      await assertFails(as(h.DRIVER, { status: deleteField() }));
      await assertFails(as(h.PAX, { status: deleteField() }));
    });
  });

  describe("passenger", () => {
    it("cannot mark the trip completed or started", async () => {
      await seedTrip("tripStarted");
      await assertFails(as(h.PAX, { status: "completed" }));
      await seedTrip("driverArrived");
      await assertFails(as(h.PAX, { status: "tripStarted" }));
    });

    it("can cancel at any stage before completion", async () => {
      for (const from of ["searching", "tripAccepted", "driverArrived", "tripStarted"]) {
        await seedTrip(from, from === "searching" ? { driverId: null } : {});
        await assertSucceeds(as(h.PAX, { status: "cancelledByPassenger" }));
      }
    });

    it("can record the search timeout", async () => {
      await seedTrip("searching", { driverId: null });
      await assertSucceeds(as(h.PAX, { status: "noDriversAvailable" }));
    });

    it("can still confirm a completed trip (status unchanged)", async () => {
      await seedTrip("completed");
      await assertSucceeds(as(h.PAX, { passengerConfirmed: true }));
    });
  });
});
