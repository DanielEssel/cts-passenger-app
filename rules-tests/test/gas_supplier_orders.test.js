// Gas supplier pricing fields and collections. Supplier, station, product,
// price-snapshot and quote fields are written only by
// functions/gas_supplier_orders.js (Admin SDK); no client may set or change
// them on any order, and gas_quotes / gas_supplier_orders are server-written.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, getDoc, getDocs, collection, query, where, setDoc, updateDoc, deleteDoc, serverTimestamp, GeoPoint } =
  require("firebase/firestore");
const h = require("./helpers");

const DEL = "drvDel";
const ACCRA = new GeoPoint(5.6037, -0.187);
const PROTECTED = ["supplierId", "stationId", "productId", "priceSnapshot", "quoteId"];
const forged = {
  supplierId: "sup1", stationId: "st1", productId: "exchangeEmpty_kg12_5_goGas", quoteId: "q1",
  priceSnapshot: { total: 1, productAmount: 1, deliveryFee: 0, priceVersion: 1 },
};

// Same shape as orders_documents.test.js (GasRefillRequest.toFirestore()).
// The Passenger 1.0.1 creation payload (no deliveryOtp; typed fee and
// quantity, as release v5 requires).
const newGas = (o = {}) => ({
  passengerId: h.PAX, driverId: null, driverName: null, status: "pendingApproval",
  refillType: "refillOnly", cylinderSize: "small", pickupLocation: ACCRA,
  deliveryLocation: ACCRA, pickupAddress: "A", deliveryAddress: "B",
  totalPrice: 50, deliveryFee: 12, quantity: 1, paymentMethod: "cash", createdAt: serverTimestamp(),
  ...o,
});

const supplierOrder = (o = {}) => ({
  passengerId: h.PAX, supplierId: "sup1", stationId: "st1", productId: "exchangeEmpty_kg12_5_goGas",
  orderType: "exchangeEmpty", cylinderSize: "kg12_5", quantity: 1, deliveryLocation: ACCRA,
  deliveryAddress: "B", status: "awaiting_payment",
  priceSnapshot: { total: 170, productAmount: 150, handlingFee: 0, deliveryFee: 20, priceVersion: 1, quoteId: "q1" },
  createdAt: new Date(0), ...o,
});

describe("gas supplier pricing fields", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      const fs = ctx.firestore();
      await setDoc(doc(fs, `drivers/${DEL}`), {
        uid: DEL, role: "driver_delivery", serviceType: "delivery", vehicleType: "motorcycle",
        isApproved: true, isOnline: true, isAvailable: true, signupStep: "approved", location: ACCRA,
      });
      await setDoc(doc(fs, "gas_orders/pendingGas"), { ...newGas(), createdAt: null });
      await setDoc(doc(fs, "gas_orders/assignedGas"), { ...newGas({ status: "driverAssigned", driverId: DEL }), createdAt: null });
      await setDoc(doc(fs, "gas_supplier_orders/so1"), supplierOrder());
      await setDoc(doc(fs, "gas_supplier_orders/so2"), supplierOrder({ passengerId: h.STRANGER }));
      await setDoc(doc(fs, "gas_quotes/q1"), { userId: h.PAX, pricing: { total: 170 }, status: "open" });
    });
  });

  it("GSO-P01 control: the app's own gas order payload is still accepted", () =>
    assertSucceeds(setDoc(doc(h.db(h.PAX), "gas_orders/new"), newGas())));

  it("GSO-S01 a passenger cannot create a gas order carrying supplier or price-snapshot fields", async () => {
    for (const k of PROTECTED) {
      await assertFails(setDoc(doc(h.db(h.PAX), `gas_orders/new-${k}`), newGas({ [k]: forged[k] })), k);
    }
  });

  it("GSO-S02 neither party can add or change those fields on an existing gas order", async () => {
    // Each forged write is an otherwise-allowed status change (the controls
    // below), so only the protected field can be the reason it is refused.
    const paxCancel = { status: "cancelled" };
    const drvEnRoute = { status: "driverEnRoute" };
    for (const k of PROTECTED) {
      await assertFails(updateDoc(doc(h.db(h.PAX), "gas_orders/pendingGas"), { ...paxCancel, [k]: forged[k] }), `passenger ${k}`);
      await assertFails(updateDoc(doc(h.db(DEL), "gas_orders/assignedGas"), { ...drvEnRoute, [k]: forged[k] }), `driver ${k}`);
    }
    await assertSucceeds(updateDoc(doc(h.db(h.PAX), "gas_orders/pendingGas"), paxCancel));
    await assertSucceeds(updateDoc(doc(h.db(DEL), "gas_orders/assignedGas"), drvEnRoute));
  });

  it("GSO-S03 the fields are equally protected on trips and deliveries", async () => {
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), "deliveries/d1"), { passengerId: h.PAX, driverId: null, status: "pending", estimatedFare: 20 });
    });
    // Control: the same trip payload without the field is accepted here.
    await assertSucceeds(setDoc(doc(h.db(h.PAX), "trips/t-clean"), h.newTripPayload()));
    await assertFails(setDoc(doc(h.db(h.PAX), "trips/t-forged"), h.newTripPayload({ priceSnapshot: forged.priceSnapshot })));
    // Control: a passenger update the rules allow on this delivery, then the same with a supplier field.
    await assertSucceeds(updateDoc(doc(h.db(h.PAX), "deliveries/d1"), { status: "cancelled", cancelledAt: serverTimestamp() }));
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), "deliveries/d1"), { passengerId: h.PAX, driverId: null, status: "pending", estimatedFare: 20 });
    });
    await assertFails(updateDoc(doc(h.db(h.PAX), "deliveries/d1"), { status: "cancelled", cancelledAt: serverTimestamp(), supplierId: "sup1" }));
  });

  it("GSO-P02 a passenger reads their own supplier order and its snapshot", async () => {
    await assertSucceeds(getDoc(doc(h.db(h.PAX), "gas_supplier_orders/so1")));
    await assertSucceeds(getDocs(query(collection(h.db(h.PAX), "gas_supplier_orders"), where("passengerId", "==", h.PAX))));
    await assertSucceeds(getDoc(doc(h.db(h.ADMIN), "gas_supplier_orders/so2")));
  });

  it("GSO-S04 other users and drivers cannot read someone else's supplier order", async () => {
    await assertFails(getDoc(doc(h.db(h.STRANGER), "gas_supplier_orders/so1")));
    await assertFails(getDoc(doc(h.db(DEL), "gas_supplier_orders/so1")));
    await assertFails(getDoc(doc(h.db(null), "gas_supplier_orders/so1")));
    await assertFails(getDocs(collection(h.db(h.PAX), "gas_supplier_orders"))); // unfiltered list
  });

  it("GSO-S05 no client creates, changes or deletes a supplier order, even its own", async () => {
    await assertFails(setDoc(doc(h.db(h.PAX), "gas_supplier_orders/mine"), supplierOrder()));
    await assertFails(updateDoc(doc(h.db(h.PAX), "gas_supplier_orders/so1"), { "priceSnapshot.total": 1 }));
    await assertFails(updateDoc(doc(h.db(h.PAX), "gas_supplier_orders/so1"), { status: "pendingApproval" }));
    await assertFails(updateDoc(doc(h.db(h.ADMIN), "gas_supplier_orders/so1"), { status: "cancelled" }));
    await assertFails(deleteDoc(doc(h.db(h.PAX), "gas_supplier_orders/so1")));
  });

  it("GSO-S06 quotes are server-only: not readable or writable by the passenger they belong to", async () => {
    await assertFails(getDoc(doc(h.db(h.PAX), "gas_quotes/q1")));
    await assertFails(setDoc(doc(h.db(h.PAX), "gas_quotes/q2"), { userId: h.PAX, pricing: { total: 1 } }));
    await assertFails(updateDoc(doc(h.db(h.PAX), "gas_quotes/q1"), { "pricing.total": 1 }));
  });
});
