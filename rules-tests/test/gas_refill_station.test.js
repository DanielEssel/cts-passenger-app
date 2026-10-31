// Phase 2B rules: a Gas order may name its refill station only as a
// { supplierId, stationId } reference at creation; the trusted snapshot
// (verifiedRefillStation) is server-only; the legacy free-text station fields
// are no longer accepted (released apps write null); the order — and so the
// snapshot — is read only by its passenger, its assigned driver and admins.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, setDoc, updateDoc, getDoc, GeoPoint } = require("firebase/firestore");
const h = require("./helpers");

const DEL = "drvDelRS";
const OTHER_DEL = "drvDelRS2";
const ACCRA = new GeoPoint(5.6037, -0.187);
const REF = { supplierId: "sup1", stationId: "st1" };
const SNAPSHOT = { supplierId: "sup1", stationId: "st1", productId: "exchangeEmpty_kg6_goGas",
  name: "Osu Station", address: "Oxford St, Osu", location: ACCRA };

// What Passenger 1.0.1 creates (no client completion code, a delivery fee).
const gas101 = (o = {}) => ({
  passengerId: h.PAX, driverId: null, status: "pendingApproval", refillType: "exchangeEmpty",
  cylinderSize: "kg6", quantity: 1, deliveryLocation: ACCRA, totalPrice: 90, deliveryFee: 12,
  paymentMethod: "cash", deliveredAt: null, ...o,
});

async function seed() {
  await h.seed();
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const put = (p, d) => setDoc(doc(ctx.firestore(), p), d);
    for (const id of [DEL, OTHER_DEL]) {
      await put(`drivers/${id}`, { uid: id, role: "driver_delivery", isApproved: true, isOnline: true,
        isAvailable: true, signupStep: "approved", location: ACCRA });
    }
    await put("gas_orders/g_ref", gas101({ refillStationRef: REF, verifiedRefillStation: SNAPSHOT }));
    await put("gas_orders/g_assigned", gas101({ status: "refilling", driverId: DEL,
      refillStationRef: REF, verifiedRefillStation: SNAPSHOT }));
  });
}

const create = (uid, path, data) => setDoc(doc(h.db(uid), path), data);
const upd = (uid, path, data) => updateDoc(doc(h.db(uid), path), data);
const read = (uid, path) => getDoc(doc(h.db(uid), path));

describe("gas refill station reference (Phase 2B)", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(seed);

  it("a customer may create an order with or without a { supplierId, stationId } reference", async () => {
    await assertSucceeds(create(h.PAX, "gas_orders/n1", gas101()));
    await assertSucceeds(create(h.PAX, "gas_orders/n2", gas101({ refillStationRef: REF })));
  });

  it("released app payloads (legacy station fields written as null) still create", async () => {
    await assertSucceeds(create(h.PAX, "gas_orders/n3", gas101({ preferredStation: null,
      preferredStationAddress: null, refillStation: null, refillStationAddress: null })));
  });

  it("a malformed reference is refused at creation", async () => {
    for (const [i, bad] of [
      "sup1/st1", { supplierId: "sup1" }, { supplierId: "sup1", stationId: "" },
      { supplierId: 1, stationId: "st1" }, { supplierId: "sup1", stationId: "st1", price: 1 },
      { supplierId: "s".repeat(129), stationId: "st1" },
    ].entries()) {
      await assertFails(create(h.PAX, `gas_orders/bad${i}`, gas101({ refillStationRef: bad })), JSON.stringify(bad));
    }
  });

  it("legacy free-text station fields are no longer accepted with a value", async () => {
    for (const k of ["preferredStation", "preferredStationAddress", "refillStation", "refillStationAddress"]) {
      await assertFails(create(h.PAX, `gas_orders/t_${k}`, gas101({ [k]: "Somewhere" })), k);
    }
  });

  it("no client may write the trusted station snapshot", async () => {
    await assertFails(create(h.PAX, "gas_orders/n4", gas101({ refillStationRef: REF, verifiedRefillStation: SNAPSHOT })));
    await assertFails(upd(h.PAX, "gas_orders/g_ref", { "verifiedRefillStation.address": "Elsewhere" }));
    await assertFails(upd(DEL, "gas_orders/g_assigned", { "verifiedRefillStation.location": new GeoPoint(5.7, -0.2) }));
    await assertFails(upd(h.PAX, "gas_orders/g_ref", { verifiedRefillStation: null }));
  });

  it("the reference and the legacy station fields cannot change after creation", async () => {
    await assertFails(upd(h.PAX, "gas_orders/g_ref", { refillStationRef: { supplierId: "sup2", stationId: "st9" } }));
    await assertFails(upd(DEL, "gas_orders/g_assigned", { refillStationRef: null }));
    await assertFails(upd(h.PAX, "gas_orders/g_ref", { preferredStation: "Somewhere" }));
  });

  it("an assigned order's snapshot is read by its passenger and assigned driver only", async () => {
    await assertSucceeds(read(h.PAX, "gas_orders/g_assigned"));
    await assertSucceeds(read(DEL, "gas_orders/g_assigned"));
    await assertFails(read(OTHER_DEL, "gas_orders/g_assigned"));
    await assertFails(read(h.STRANGER, "gas_orders/g_ref"));
  });

  // Release v5 stage 3b only (stage 3a keeps released Driver 1.0.2's open
  // order reads): before assignment drivers see the offer, never the order.
  it("GRS-3B an unassigned driver cannot read an open order or its snapshot (stage 3b)", async () => {
    await assertFails(read(OTHER_DEL, "gas_orders/g_ref"));
  });
});
