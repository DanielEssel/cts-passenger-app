// Completion codes held server-side (functions/completion_codes.js): only
// the order's own passenger reads the code; the assigned driver, other
// drivers and other users cannot; no client writes one. Waivers are
// admin-only (RUL-A01/A02 in functions/test/payments/settlement_rules).

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, getDoc, setDoc, updateDoc, deleteDoc, onSnapshot } = require("firebase/firestore");
const h = require("./helpers");

const PAX = "ccPax";
const OTHER_PAX = "ccOtherPax";
const DRIVER = "ccDriver";

async function seed() {
  await h.seed();
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    await setDoc(doc(fs, `drivers/${DRIVER}`), { uid: DRIVER, role: "driver_delivery", isApproved: true,
      signupStep: "approved", isOnline: true, isAvailable: false, currentTripId: "d1" });
    await setDoc(doc(fs, "deliveries/d1"), { passengerId: PAX, driverId: DRIVER, status: "arrivedAtDropoff" });
    await setDoc(doc(fs, "order_completion_codes/deliveries_d1"),
      { collection: "deliveries", orderId: "d1", passengerId: PAX, code: "4821", attempts: 0 });
    await setDoc(doc(fs, "gas_orders/g1"), { passengerId: PAX, driverId: DRIVER, status: "driverArrived" });
    await setDoc(doc(fs, "order_completion_codes/gas_orders_g1"),
      { collection: "gas_orders", orderId: "g1", passengerId: PAX, code: "5930", attempts: 0 });
    // g2: just created by the app; onGasOrderCreated has not stored its code yet.
    await setDoc(doc(fs, "gas_orders/g2"), { passengerId: PAX, status: "pending" });
  });
}

describe("completion codes", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(seed);

  it("CCR-P01 the order's passenger reads their code", () =>
    assertSucceeds(getDoc(doc(h.db(PAX), "order_completion_codes/deliveries_d1"))));

  it("CCR-S01 the assigned driver, another driver or passenger, and signed-out users cannot", async () => {
    for (const uid of [DRIVER, h.DRIVER, OTHER_PAX, null]) {
      await assertFails(getDoc(doc(h.db(uid), "order_completion_codes/deliveries_d1")), String(uid));
    }
  });

  it("CCR-S02 no client creates, changes or deletes a code (the passenger included)", async () => {
    for (const uid of [PAX, DRIVER, h.ADMIN]) {
      await assertFails(setDoc(doc(h.db(uid), "order_completion_codes/deliveries_d2"),
        { collection: "deliveries", orderId: "d2", passengerId: PAX, code: "1111" }), `create ${uid}`);
      await assertFails(updateDoc(doc(h.db(uid), "order_completion_codes/deliveries_d1"), { attempts: 0 }), `update ${uid}`);
      await assertFails(deleteDoc(doc(h.db(uid), "order_completion_codes/deliveries_d1")), `delete ${uid}`);
    }
  });

  it("CCR-P02 the Gas order's passenger reads their code", () =>
    assertSucceeds(getDoc(doc(h.db(PAX), "order_completion_codes/gas_orders_g1"))));

  it("CCR-S03 nobody else reads a Gas order's code (assigned/other driver, other passenger)", async () => {
    for (const uid of [DRIVER, h.DRIVER, h.OTHER_DRIVER, OTHER_PAX, null]) {
      await assertFails(getDoc(doc(h.db(uid), "order_completion_codes/gas_orders_g1")), String(uid));
    }
  });

  // The device's repeated PERMISSION_DENIED: the passenger's listener starts
  // before the create trigger stores the code. The rules cannot grant a read
  // of a record that does not exist yet, so the app listens again
  // (completion_code_provider.dart) rather than the rules being loosened.
  it("CCR-S04 even the passenger is denied a code not stored yet", () =>
    assertFails(getDoc(doc(h.db(PAX), "order_completion_codes/gas_orders_g2"))));

  it("CCR-P03 a listen started after the code is stored receives it", async () => {
    await h.env().withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(),
      "order_completion_codes/gas_orders_g2"),
      { collection: "gas_orders", orderId: "g2", passengerId: PAX, code: "1234", attempts: 0 }));
    const code = await new Promise((resolve, reject) => {
      const stop = onSnapshot(doc(h.db(PAX), "order_completion_codes/gas_orders_g2"),
        (s) => { stop(); resolve(s.data()?.code); }, reject);
    });
    if (code !== "1234") throw new Error(`expected the stored code, got ${code}`);
  });
});
