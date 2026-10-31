// C4 — Driver App writes after the C4 changes, against the UNCHANGED rules.
//
// C4-D: the mark-busy write no longer sends currentTripType, so it fits the
//       existing drivers owner allow-list; currentTripType stays protected.
// C4-C: driver cancellation of a delivery or gas order is one transaction
//       that updates the order and releases the driver's own document.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  doc,
  setDoc,
  updateDoc,
  runTransaction,
  deleteField,
  serverTimestamp,
} = require("firebase/firestore");
const h = require("./helpers");

async function seedJobs() {
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, "deliveries/d1"), {
      passengerId: h.PAX, driverId: h.DRIVER, status: "packagePicked",
    });
    await setDoc(doc(db, "gas_orders/g1"), {
      passengerId: h.PAX, driverId: h.DRIVER, status: "driverEnRoute",
    });
    await setDoc(doc(db, `drivers/${h.DRIVER}`), {
      isApproved: true, isAvailable: false, currentTripId: "d1", walletBalance: 50,
    }, { merge: true });
  });
}

// Mirrors the Driver App's cancel transaction (active_*_screen.dart).
function cancelTx(uid, path, orderFields) {
  const db = h.db(uid);
  const orderRef = doc(db, path);
  const driverRef = doc(db, `drivers/${uid}`);
  return runTransaction(db, async (tx) => {
    await tx.get(orderRef);
    await tx.get(driverRef);
    tx.update(orderRef, orderFields);
    tx.update(driverRef, { isAvailable: true, currentTripId: deleteField() });
  });
}

describe("C4 driver writes (rules unchanged)", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await seedJobs();
  });

  // ── C4-D ────────────────────────────────────────────────────────────────
  it("C4D-01 driver marks itself busy after accepting (new payload)", async () => {
    // Free first: the seeded driver is busy with d1.
    await h.env().withSecurityRulesDisabled((ctx) => updateDoc(
      doc(ctx.firestore(), `drivers/${h.DRIVER}`), { currentTripId: deleteField() }));
    await assertSucceeds(
      updateDoc(doc(h.db(h.DRIVER), `drivers/${h.DRIVER}`), {
        isAvailable: false,
        currentTripId: "g1",
      }),
    );
  });

  it("C4D-02 currentTripType remains outside the owner allow-list", () =>
    assertFails(
      updateDoc(doc(h.db(h.DRIVER), `drivers/${h.DRIVER}`), {
        isAvailable: false,
        currentTripId: "searching",
        currentTripType: "trips",
      }),
    ));

  it("C4D-03 a driver cannot set another driver's assignment", () =>
    assertFails(
      updateDoc(doc(h.db(h.OTHER_DRIVER), `drivers/${h.DRIVER}`), {
        isAvailable: false,
        currentTripId: "searching",
      }),
    ));

  it("C4D-04 money fields stay protected alongside the busy/release write", () =>
    assertFails(
      updateDoc(doc(h.db(h.DRIVER), `drivers/${h.DRIVER}`), {
        isAvailable: true,
        currentTripId: deleteField(),
        walletBalance: 9999,
      }),
    ));

  // ── C4-C ────────────────────────────────────────────────────────────────
  it("C4C-01 assigned driver cancels a delivery and is released in one transaction", () =>
    assertSucceeds(
      cancelTx(h.DRIVER, "deliveries/d1", {
        status: "cancelled",
        statusReason: "cancelledByDriver",
        cancelledAt: serverTimestamp(),
        cancelReason: "Cancelled by driver",
      }),
    ));

  it("C4C-02 assigned driver cancels a gas order and is released in one transaction", async () => {
    await h.env().withSecurityRulesDisabled((ctx) => updateDoc(
      doc(ctx.firestore(), `drivers/${h.DRIVER}`), { currentTripId: "g1" }));
    await assertSucceeds(
      cancelTx(h.DRIVER, "gas_orders/g1", {
        status: "cancelled",
        cancelledAt: serverTimestamp(),
        cancelReason: "Cancelled by driver",
      }),
    );
  });

  // The app releases only when currentTripId is the cancelled order
  // (decideDriverCancellation); a release while another job is open is
  // refused (currentTripId is server-owned).
  it("C4C-05 cancelling one order cannot clear a different job still open", () =>
    assertFails(
      cancelTx(h.DRIVER, "gas_orders/g1", {
        status: "cancelled",
        cancelledAt: serverTimestamp(),
        cancelReason: "Cancelled by driver",
      }),
    ));

  it("C4C-03 a driver who is not assigned cannot cancel the delivery", () =>
    assertFails(
      cancelTx(h.OTHER_DRIVER, "deliveries/d1", {
        status: "cancelled",
        cancelReason: "Cancelled by driver",
      }),
    ));

  it("C4C-04 a driver who is not assigned cannot cancel the gas order", () =>
    assertFails(
      cancelTx(h.OTHER_DRIVER, "gas_orders/g1", {
        status: "cancelled",
        cancelReason: "Cancelled by driver",
      }),
    ));
});
