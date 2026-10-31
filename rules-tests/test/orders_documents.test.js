// Delivery and gas-order privacy/claims, and driver document review
// integrity. Payloads mirror the committed Passenger and Driver app code.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  collection,
  doc,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
  runTransaction,
  deleteField,
  query,
  where,
  orderBy,
  limit,
  serverTimestamp,
  GeoPoint,
} = require("firebase/firestore");
const h = require("./helpers");

const DEL = "drvDel"; // approved delivery driver
const DEL2 = "drvDel2"; // another approved delivery driver
const DEL_NEW = "drvDelNew"; // delivery driver awaiting approval
const DEL_SUS = "drvDelSus"; // suspended by admin (as the Admin app does)
const ACCRA = new GeoPoint(5.6037, -0.187);

const deliveryDriver = (uid, o = {}) => ({
  uid, role: "driver_delivery", displayName: `Driver ${uid}`,
  serviceType: "delivery", vehicleType: "motorcycle", isApproved: true,
  isOnline: true, isAvailable: true, signupStep: "approved", location: ACCRA, ...o,
});

// DeliveryRequest.toFirestore() at creation.
const newDelivery = (o = {}) => ({
  passengerId: h.PAX, driverId: null, driverName: null, driverPhone: null,
  driverRating: null, status: "pending", pickupLocation: ACCRA,
  dropoffLocation: ACCRA, pickupAddress: "A", dropoffAddress: "B",
  parcelType: "small", weightTier: "Small", weightRange: "0-5kg",
  isFragile: false, requiresHelpers: false, photoUrl: null, notes: null,
  vehicleType: "motorbike", receiverPhone: "+233240000009",
  receiverName: "R", deliveryOtp: "1234", estimatedFare: 20,
  actualFare: null, createdAt: serverTimestamp(), assignedAt: null,
  pickedUpAt: null, completedAt: null, cancelledAt: null,
  paymentMethod: "cash", passengerRating: null, ...o,
});

// GasRefillRequest.toFirestore() at creation (subset that matters).
const newGas = (o = {}) => ({
  passengerId: h.PAX, driverId: null, driverName: null, status: "pendingApproval",
  refillType: "refillOnly", cylinderSize: "small", pickupLocation: ACCRA,
  deliveryLocation: ACCRA, pickupAddress: "A", deliveryAddress: "B",
  totalPrice: 50, paymentMethod: "cash", createdAt: serverTimestamp(),
  deliveryOtp: "4321", ...o,
});

// Passenger 1.0.1 creates orders without deliveryOtp (the server stores the
// code in order_completion_codes); Gas orders carry their delivery fee and
// quantity (gas_order_screen.dart). The HEAD (1.0.0) payloads above are
// what older builds write; they are refused at creation (release v5).
const without = (o, k) => { const c = { ...o }; delete c[k]; return c; };
// ... and names its server quote (delivery_quotes.js; release v5 round 3).
const newDelivery101 = (o = {}) => without(newDelivery({ deliveryQuoteId: "q-1", ...o }), "deliveryOtp");
const newGas101 = (o = {}) => without(newGas({
  refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1, preferredBrand: null,
  gasPrice: 50, deliveryFee: 12, totalPrice: 62, ...o,
}), "deliveryOtp");
// requests_section.dart delivery accept.
const acceptDelivery = (uid) => ({
  driverId: uid, driverName: `Driver ${uid}`, driverPhone: "",
  driverRating: 5, status: "driverAssigned", acceptedAt: serverTimestamp(),
});
function acceptDeliveryTx(uid, id = "pendingDel") {
  const db = h.db(uid);
  const ref = doc(db, `deliveries/${id}`);
  return runTransaction(db, async (tx) => {
    const snap = await tx.get(ref);
    if (snap.data().driverId != null || snap.data().status !== "pending") {
      throw new Error("taken");
    }
    tx.update(ref, acceptDelivery(uid));
  });
}

// requests_section.dart open-request queries.
const openDeliveries = (uid) =>
  query(collection(h.db(uid), "deliveries"),
    where("status", "==", "pending"), where("driverId", "==", null),
    orderBy("createdAt", "desc"), limit(20),
    where("weightTier", "in", ["Small", "Medium"]));
const openGas = (uid) =>
  query(collection(h.db(uid), "gas_orders"),
    where("status", "==", "pendingApproval"), where("driverId", "==", null),
    orderBy("createdAt", "desc"), limit(20));

async function seedOrders() {
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    const put = (p, d) => setDoc(doc(fs, p), d);
    await put(`drivers/${DEL}`, deliveryDriver(DEL));
    await put(`drivers/${DEL2}`, deliveryDriver(DEL2));
    await put(`drivers/${DEL_NEW}`, deliveryDriver(DEL_NEW, { isApproved: false, signupStep: "documentsUploaded" }));
    await put(`drivers/${DEL_SUS}`, deliveryDriver(DEL_SUS, { isApproved: false, signupStep: "suspended", isOnline: false, isAvailable: false }));
    await put("deliveries/pendingDel", { ...newDelivery(), createdAt: null });
    await put("deliveries/assignedDel", { ...newDelivery({ status: "driverAssigned", driverId: DEL }), createdAt: null });
    await put("deliveries/cancelledDel", { ...newDelivery({ status: "cancelled" }), createdAt: null });
    await put("deliveries/completedDel", { ...newDelivery({ status: "completed", driverId: DEL }), createdAt: null });
    await put("gas_orders/pendingGas", { ...newGas(), createdAt: null });
    await put("gas_orders/assignedGas", { ...newGas({ status: "driverAssigned", driverId: DEL }), createdAt: null });
  });
}

describe("deliveries", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => { await h.seed(); await seedOrders(); });

  // ── Must keep working ─────────────────────────────────────────────────
  it("DLV-P01 passenger creates a delivery with the app's payload (Passenger 1.0.1)", () =>
    assertSucceeds(setDoc(doc(h.db(h.PAX), "deliveries/new"), newDelivery101())));

  it("DLV-S09 an order carrying its own completion code (Passenger 1.0.0 payload) is refused", () =>
    assertFails(setDoc(doc(h.db(h.PAX), "deliveries/new"), newDelivery())));

  it("DLV-P02 passenger reads own delivery and history", async () => {
    await assertSucceeds(getDoc(doc(h.db(h.PAX), "deliveries/pendingDel")));
    await assertSucceeds(getDocs(query(collection(h.db(h.PAX), "deliveries"),
      where("passengerId", "==", h.PAX), orderBy("createdAt", "desc"))));
  });

  it("DLV-S10 an approved delivery driver no longer reads open deliveries (list or get)", async () => {
    await assertFails(getDocs(openDeliveries(DEL)));
    await assertFails(getDoc(doc(h.db(DEL), "deliveries/pendingDel")));
  });

  it("DLV-P03 approved delivery driver reads the open-request offers instead", async () => {
    await h.env().withSecurityRulesDisabled((ctx) =>
      setDoc(doc(ctx.firestore(), "delivery_offers/pendingDel"), { service: "delivery", fare: 20 }));
    await assertSucceeds(getDoc(doc(h.db(DEL), "delivery_offers/pendingDel")));
    await assertSucceeds(getDocs(query(collection(h.db(DEL), "delivery_offers"), limit(20))));
  });

  it("DLV-P04 the claim rule still governs a claim write sent without a read", () =>
    assertSucceeds(updateDoc(doc(h.db(DEL2), "deliveries/pendingDel"), acceptDelivery(DEL2))));

  it("DLV-S11 the released read-first accept transaction is refused at its read", () =>
    assertFails(acceptDeliveryTx(DEL2)));

  it("DLV-P05 assigned driver progresses, streams location and completes with OTP", async () => {
    const r = doc(h.db(DEL), "deliveries/assignedDel");
    await assertSucceeds(updateDoc(r, { status: "pickupEnroute" }));
    await assertSucceeds(updateDoc(r, {
      driverCurrentLocation: ACCRA, driverHeading: 10,
      driverLocationUpdatedAt: serverTimestamp(),
    }));
    await assertSucceeds(updateDoc(r, {
      status: "completed", otpSubmitted: "1234", otpVerifiedAt: serverTimestamp(),
      completedAt: serverTimestamp(), actualFare: 20,
    }));
  });

  it("DLV-P06 assigned driver cancels and is released (C4 transaction)", () => {
    const db = h.db(DEL);
    return assertSucceeds(runTransaction(db, async (tx) => {
      await tx.get(doc(db, "deliveries/assignedDel"));
      await tx.get(doc(db, `drivers/${DEL}`));
      tx.update(doc(db, "deliveries/assignedDel"), {
        status: "cancelled", statusReason: "cancelledByDriver",
        cancelledAt: serverTimestamp(), cancelReason: "Cancelled by driver",
      });
      tx.update(doc(db, `drivers/${DEL}`), { isAvailable: true, currentTripId: deleteField() });
    }));
  });

  it("DLV-P07 passenger cancels, rates and attaches escrow", async () => {
    const r = doc(h.db(h.PAX), "deliveries/pendingDel");
    // As in delivery_vehicle_screen.dart: attachEscrowToOrder (server) links
    // the escrow to this delivery first, then the app saves its id. An
    // escrow not linked to this delivery cannot be saved (ORD-ESC tests).
    await h.env().withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), "escrows/escDel"),
      { userId: h.PAX, amount: 20, status: "HELD", referenceId: "pendingDel", referenceType: "delivery" }));
    await assertSucceeds(updateDoc(r, { escrowId: "escDel" }));
    await assertSucceeds(updateDoc(r, { status: "cancelled", cancelledAt: serverTimestamp(), cancelReason: "x" }));
    await assertSucceeds(updateDoc(doc(h.db(h.PAX), "deliveries/assignedDel"), { passengerRating: 5 }));
  });

  // ── Must be denied ────────────────────────────────────────────────────
  it("DLV-S01 unrelated passenger cannot read or list pending deliveries", async () => {
    await assertFails(getDoc(doc(h.db(h.STRANGER), "deliveries/pendingDel")));
    await assertFails(getDocs(openDeliveries(h.STRANGER)));
  });

  it("DLV-S02 a ride (hailing) driver cannot read or claim deliveries", async () => {
    await assertFails(getDocs(openDeliveries(h.DRIVER)));
    await assertFails(acceptDeliveryTx(h.DRIVER));
  });

  it("DLV-S03 unapproved and suspended delivery drivers cannot read or claim", async () => {
    for (const uid of [DEL_NEW, DEL_SUS]) {
      await assertFails(getDocs(openDeliveries(uid)));
      await assertFails(acceptDeliveryTx(uid));
    }
  });

  it("DLV-S04 passenger cannot claim, and signed-out users cannot read", async () => {
    await assertFails(updateDoc(doc(h.db(h.STRANGER), "deliveries/pendingDel"), acceptDelivery(h.STRANGER)));
    await assertFails(getDoc(doc(h.db(null), "deliveries/pendingDel")));
  });

  it("DLV-S05 claim must be for self, from pending, with only accept fields", async () => {
    const r = (uid, id = "pendingDel") => doc(h.db(uid), `deliveries/${id}`);
    await assertFails(updateDoc(r(DEL2), { ...acceptDelivery(DEL2), driverId: DEL }));
    await assertFails(updateDoc(r(DEL2), { ...acceptDelivery(DEL2), estimatedFare: 500 }));
    await assertFails(updateDoc(r(DEL2), { ...acceptDelivery(DEL2), status: "completed" }));
    await assertFails(updateDoc(r(DEL2, "cancelledDel"), acceptDelivery(DEL2)));
    await assertFails(updateDoc(r(DEL2, "assignedDel"), acceptDelivery(DEL2)));
  });

  it("DLV-S06 parties cannot change who is on the delivery", async () => {
    await assertFails(updateDoc(doc(h.db(h.PAX), "deliveries/pendingDel"), { driverId: DEL }));
    await assertFails(updateDoc(doc(h.db(DEL), "deliveries/assignedDel"), { driverId: DEL2 }));
    await assertFails(updateDoc(doc(h.db(DEL), "deliveries/assignedDel"), { driverId: null }));
    await assertFails(updateDoc(doc(h.db(DEL), "deliveries/assignedDel"), { passengerId: DEL }));
  });

  it("DLV-S07 passenger cannot create a delivery pre-assigned to a driver", () =>
    assertFails(setDoc(doc(h.db(h.PAX), "deliveries/new"),
      newDelivery({ driverId: DEL, status: "driverAssigned" }))));

  // A completed delivery's status is final for the parties: cancelling it
  // would fire onDeliveryCancelled on a delivery that was already paid.
  it("DLV-S08 neither party can cancel or reopen a completed delivery", async () => {
    for (const uid of [h.PAX, DEL]) {
      const r = doc(h.db(uid), "deliveries/completedDel");
      await assertFails(updateDoc(r, { status: "cancelled", cancelledAt: serverTimestamp(), cancelReason: "x" }));
      await assertFails(updateDoc(r, { status: "pending" }));
      await assertFails(updateDoc(r, { status: deleteField() }));
    }
  });

  it("DLV-P08 a completed delivery can still be rated and written without status changes", async () => {
    await assertSucceeds(updateDoc(doc(h.db(h.PAX), "deliveries/completedDel"), { passengerRating: 4 }));
    await assertSucceeds(updateDoc(doc(h.db(DEL), "deliveries/completedDel"), { driverRating: 5 }));
    await assertSucceeds(updateDoc(doc(h.db(h.PAX), "deliveries/completedDel"), { status: "completed" }));
  });

  it("DLV-P09 normal cancellation before completion still works for both parties", async () => {
    await assertSucceeds(updateDoc(doc(h.db(h.PAX), "deliveries/assignedDel"),
      { status: "cancelled", cancelledAt: serverTimestamp(), cancelReason: "changed my mind" }));
    await assertSucceeds(updateDoc(doc(h.db(h.PAX), "deliveries/pendingDel"),
      { status: "cancelled", cancelledAt: serverTimestamp(), cancelReason: "x" }));
  });
});

describe("gas orders", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => { await h.seed(); await seedOrders(); });

  it("GAS-P01 passenger creates and reads own order (Passenger 1.0.1 payload)", async () => {
    await assertSucceeds(setDoc(doc(h.db(h.PAX), "gas_orders/new"), newGas101()));
    await assertSucceeds(getDoc(doc(h.db(h.PAX), "gas_orders/pendingGas")));
    await assertSucceeds(getDocs(query(collection(h.db(h.PAX), "gas_orders"),
      where("passengerId", "==", h.PAX))));
  });

  it("GAS-S05 an approved delivery driver no longer reads open gas orders (list or get)", async () => {
    await assertFails(getDocs(openGas(DEL)));
    await assertFails(getDoc(doc(h.db(DEL), "gas_orders/pendingGas")));
  });

  it("GAS-P02 approved delivery driver reads the open-order offers instead", async () => {
    await h.env().withSecurityRulesDisabled((ctx) =>
      setDoc(doc(ctx.firestore(), "gas_order_offers/pendingGas"), { service: "gas", fare: 62 }));
    await assertSucceeds(getDoc(doc(h.db(DEL), "gas_order_offers/pendingGas")));
  });

  it("GAS-S06 Gas creation refuses the 1.0.0 payload and untyped amounts", async () => {
    const r = doc(h.db(h.PAX), "gas_orders/new");
    await assertFails(setDoc(r, newGas()));
    await assertFails(setDoc(r, { ...newGas101(), deliveryOtp: "4321" }));
    await assertFails(setDoc(r, newGas101({ totalPrice: "62" })));
    await assertFails(setDoc(r, without(newGas101(), "deliveryFee")));
    await assertFails(setDoc(r, newGas101({ quantity: 1.5 })));
    await assertFails(setDoc(r, newGas101({ verifiedPrice: { total: 62 } })));
  });

  it("GAS-P03 assigned driver reads and updates the order", async () => {
    await assertSucceeds(getDoc(doc(h.db(DEL), "gas_orders/assignedGas")));
    await assertSucceeds(updateDoc(doc(h.db(DEL), "gas_orders/assignedGas"), { status: "driverEnRoute" }));
  });

  it("GAS-S01 unrelated passenger cannot read pending orders", async () => {
    await assertFails(getDoc(doc(h.db(h.STRANGER), "gas_orders/pendingGas")));
    await assertFails(getDocs(openGas(h.STRANGER)));
  });

  it("GAS-S02 ride, unapproved and suspended drivers cannot read pending orders", async () => {
    for (const uid of [h.DRIVER, DEL_NEW, DEL_SUS]) {
      await assertFails(getDocs(openGas(uid)));
    }
  });

  it("GAS-S03 even an eligible driver cannot claim client-side (server-only)", () =>
    assertFails(updateDoc(doc(h.db(DEL), "gas_orders/pendingGas"), {
      driverId: DEL, status: "driverAssigned",
    })));

  it("GAS-S04 passenger cannot create an order pre-assigned to a driver", () =>
    assertFails(setDoc(doc(h.db(h.PAX), "gas_orders/new"),
      newGas({ driverId: DEL, status: "driverAssigned" }))));
});

describe("driver document review", () => {
  const NEWBIE = "drvDocNew";
  const upload = (url = "https://x/u.jpg") => ({
    status: "uploaded", url, fileType: "image", uploadedAt: serverTimestamp(),
  });

  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await h.env().withSecurityRulesDisabled((ctx) =>
      setDoc(doc(ctx.firestore(), `drivers/${DEL_NEW}`), deliveryDriver(DEL_NEW, {
        isApproved: false, signupStep: "documentsUploaded",
        documents: {
          drivers_license: { status: "rejected", url: "https://x/old.jpg", rejectionReason: "blurry" },
          insurance: { status: "approved", url: "https://x/ins.jpg" },
        },
      })));
  });

  const me = (uid = DEL_NEW) => doc(h.db(uid), `drivers/${uid}`);

  // ── Must keep working ─────────────────────────────────────────────────
  it("DOC-P01 driver uploads a new document (the app's merge write)", () =>
    assertSucceeds(setDoc(me(), { documents: { national_id: upload() } }, { merge: true })));

  it("DOC-P02 driver resubmits a rejected document", () =>
    assertSucceeds(setDoc(me(), {
      documents: { drivers_license: { ...upload("https://x/new.jpg"), expiryDate: new Date(2030, 0, 1) } },
    }, { merge: true })));

  it("DOC-P03 approved driver re-uploads an expiring document", () =>
    assertSucceeds(setDoc(doc(h.db(h.DRIVER), `drivers/${h.DRIVER}`),
      { documents: { insurance: upload() } }, { merge: true })));

  it("DOC-P04 signup create with uploaded documents", () =>
    assertSucceeds(setDoc(doc(h.db(NEWBIE), `drivers/${NEWBIE}`),
      { documents: { national_id: upload() } }, { merge: true })));

  it("DOC-P05 submit for review", () =>
    assertSucceeds(updateDoc(me(), {
      documentsUploaded: true, signupStep: "documentsUploaded",
      submittedForReviewAt: serverTimestamp(),
    })));

  it("DOC-P06 admin approves and rejects documents", async () => {
    await assertSucceeds(updateDoc(doc(h.db(h.ADMIN), `drivers/${DEL_NEW}`), {
      "documents.drivers_license.status": "approved",
    }));
    await assertSucceeds(updateDoc(doc(h.db(h.ADMIN), `drivers/${DEL_NEW}`), {
      "documents.insurance.status": "rejected", "documents.insurance.rejectionReason": "expired",
    }));
  });

  // ── Must be denied ────────────────────────────────────────────────────
  it("DOC-S01 driver cannot mark their own document approved", async () => {
    await assertFails(updateDoc(me(), { "documents.drivers_license.status": "approved" }));
    await assertFails(setDoc(me(), { documents: { national_id: { ...upload(), status: "approved" } } }, { merge: true }));
  });

  it("DOC-S02 driver cannot write review fields or unknown entry fields", async () => {
    await assertFails(updateDoc(me(), { "documents.drivers_license.rejectionReason": "" }));
    await assertFails(setDoc(me(), { documents: { national_id: { ...upload(), reviewedBy: "admin1" } } }, { merge: true }));
  });

  it("DOC-S06 a resubmission cannot rewrite or add a rejection reason", async () => {
    await assertFails(setDoc(me(), {
      documents: { drivers_license: { ...upload("https://x/new.jpg"), rejectionReason: "" } },
    }, { merge: true }));
    await assertFails(setDoc(me(), {
      documents: { national_id: { ...upload(), rejectionReason: "fine" } },
    }, { merge: true }));
  });

  it("DOC-S03 driver cannot remove or invent document entries", async () => {
    await assertFails(updateDoc(me(), { "documents.insurance": deleteField() }));
    await assertFails(setDoc(me(), { documents: { selfie_bonus: upload() } }, { merge: true }));
  });

  it("DOC-S04 cannot create a profile with pre-approved documents", () =>
    assertFails(setDoc(doc(h.db(NEWBIE), `drivers/${NEWBIE}`),
      { documents: { national_id: { ...upload(), status: "approved" } } }, { merge: true })));

  it("DOC-S05 an upload without a URL is rejected", () =>
    assertFails(setDoc(me(), { documents: { national_id: { status: "uploaded" } } }, { merge: true })));
});
