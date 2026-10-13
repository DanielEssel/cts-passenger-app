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
    await put("gas_orders/pendingGas", { ...newGas(), createdAt: null });
    await put("gas_orders/assignedGas", { ...newGas({ status: "driverAssigned", driverId: DEL }), createdAt: null });
  });
}

describe("deliveries", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => { await h.seed(); await seedOrders(); });

  // ── Must keep working ─────────────────────────────────────────────────
  it("DLV-P01 passenger creates a delivery with the app's payload", () =>
    assertSucceeds(setDoc(doc(h.db(h.PAX), "deliveries/new"), newDelivery())));

  it("DLV-P02 passenger reads own delivery and history", async () => {
    await assertSucceeds(getDoc(doc(h.db(h.PAX), "deliveries/pendingDel")));
    await assertSucceeds(getDocs(query(collection(h.db(h.PAX), "deliveries"),
      where("passengerId", "==", h.PAX), orderBy("createdAt", "desc"))));
  });

  it("DLV-P03 approved delivery driver runs the released request query", () =>
    assertSucceeds(getDocs(openDeliveries(DEL))));

  it("DLV-P04 approved delivery driver accepts via the app's transaction", () =>
    assertSucceeds(acceptDeliveryTx(DEL2)));

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
    await assertSucceeds(updateDoc(r, { escrowId: "esc1" }));
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
});

describe("gas orders", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => { await h.seed(); await seedOrders(); });

  it("GAS-P01 passenger creates and reads own order", async () => {
    await assertSucceeds(setDoc(doc(h.db(h.PAX), "gas_orders/new"), newGas()));
    await assertSucceeds(getDoc(doc(h.db(h.PAX), "gas_orders/pendingGas")));
    await assertSucceeds(getDocs(query(collection(h.db(h.PAX), "gas_orders"),
      where("passengerId", "==", h.PAX))));
  });

  it("GAS-P02 approved delivery driver runs the released open-orders query", () =>
    assertSucceeds(getDocs(openGas(DEL))));

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
