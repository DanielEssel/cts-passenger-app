// Gas supplier onboarding (gas_suppliers): staff-only records, an audited
// status workflow with separate approval, and a station catalog whose
// prices are versioned. Writes mirror ctsride-admin src/lib/gas-supplier-data.ts.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  doc, getDoc, getDocs, collection, setDoc, updateDoc, deleteDoc, writeBatch,
  serverTimestamp, GeoPoint,
} = require("firebase/firestore");
const h = require("./helpers");

const SUPER_A = "superA"; // creates suppliers in these tests
const SUPER_B = "superB"; // a second super admin
const PLAIN = "plainAdmin"; // active admin without super_admin
const INACTIVE = "inactiveAdmin";
const MEMBER = "supplierStaff"; // future portal user, listed in members/

const S = "sup1";
const ST = "st1";
const PID = "exchangeEmpty_kg12_5_goGas";
const TEMA = new GeoPoint(5.6698, -0.0166);

// One Firestore instance per user: a batch may only hold references from
// the instance it was created on.
const dbs = new Map();
const D = (uid) => {
  const key = uid ?? "<unauthenticated>";
  if (!dbs.has(key)) dbs.set(key, h.db(uid));
  return dbs.get(key);
};

const sup = (uid, id = S) => doc(D(uid), `gas_suppliers/${id}`);
const hist = (uid, seq, id = S) => doc(D(uid), `gas_suppliers/${id}/status_history/${seq}`);
const station = (uid, id = ST) => doc(D(uid), `gas_suppliers/${S}/stations/${id}`);
const product = (uid, id = PID) => doc(D(uid), `gas_suppliers/${S}/stations/${ST}/products/${id}`);
const priceHist = (uid, v, id = PID) =>
  doc(D(uid), `gas_suppliers/${S}/stations/${ST}/products/${id}/price_history/${v}`);

function draftSupplier(uid, overrides = {}) {
  return {
    legalName: "Test Gas Ltd",
    tradingName: "Test Gas",
    operatingModel: "lpg_station",
    contact: { name: "A. Mensah", phone: "+233200000001", email: "ops@test.example" },
    address: "Spintex Road, Accra",
    registration: { businessRegNo: "CS000000", licenceNo: "", licenceExpiry: "", notes: "" },
    fulfillment: { exchangeEmpty: true, pickupAndReturn: false, newCylinder: false, commercialBulk: false },
    riderArrangement: "ctsgo_dispatch",
    verificationNotes: "",
    internalNotes: "",
    status: "draft",
    statusReason: null,
    statusChangedAt: serverTimestamp(),
    statusChangedBy: uid,
    ordersEnabled: false,
    auditSeq: 1,
    createdAt: serverTimestamp(),
    createdBy: uid,
    updatedAt: serverTimestamp(),
    updatedBy: uid,
    ...overrides,
  };
}

function historyEntry(uid, seq, type, fromStatus, toStatus, ordersEnabled, reason = null) {
  return { seq, type, fromStatus, toStatus, ordersEnabled, reason, by: uid, byEmail: `${uid}@test`, at: serverTimestamp() };
}

/** createSupplier: the supplier and status_history/1 in one batch. */
function createSupplier(uid, overrides = {}, id = S) {
  const b = writeBatch(D(uid));
  const data = draftSupplier(uid, overrides);
  b.set(sup(uid, id), data);
  b.set(hist(uid, 1, id), historyEntry(uid, 1, "created", null, data.status, data.ordersEnabled));
  return b.commit();
}

/** changeSupplierStatus: status fields + next history entry in one batch. */
function changeStatus(uid, { from, to, seq, reason = null, ordersEnabled = false, histOverrides = {}, supOverrides = {} }) {
  const b = writeBatch(D(uid));
  b.update(sup(uid), {
    status: to, statusReason: reason, statusChangedAt: serverTimestamp(), statusChangedBy: uid,
    ordersEnabled, auditSeq: seq, updatedAt: serverTimestamp(), updatedBy: uid, ...supOverrides,
  });
  b.set(hist(uid, seq), { ...historyEntry(uid, seq, "status_changed", from, to, ordersEnabled, reason), ...histOverrides });
  return b.commit();
}

function setOrders(uid, { status, enabled, seq }) {
  const b = writeBatch(D(uid));
  b.update(sup(uid), {
    ordersEnabled: enabled, auditSeq: seq, statusChangedAt: serverTimestamp(), statusChangedBy: uid,
    updatedAt: serverTimestamp(), updatedBy: uid,
  });
  b.set(hist(uid, seq), historyEntry(uid, seq, enabled ? "orders_enabled" : "orders_disabled", status, status, enabled));
  return b.commit();
}

/** Seeds S at `status` with the history it would have, rules disabled. */
async function seedSupplier(status, { createdBy = SUPER_A, ordersEnabled = false, auditSeq = 3 } = {}) {
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    await setDoc(doc(fs, `gas_suppliers/${S}`), {
      ...draftSupplier(createdBy), status, ordersEnabled, auditSeq,
      statusReason: null, createdAt: new Date(0), updatedAt: new Date(0), statusChangedAt: new Date(0),
    });
    for (let i = 1; i <= auditSeq; i++) {
      await setDoc(doc(fs, `gas_suppliers/${S}/status_history/${i}`), { seq: i, type: "seed", by: createdBy });
    }
  });
}

function stationData(uid, overrides = {}) {
  return {
    name: "Tema Community 1 Station",
    supplierId: S,
    address: "Community 1, Tema",
    location: TEMA,
    contact: { name: "Station lead", phone: "+233200000002", email: "" },
    operatingHours: "Mon–Sat 07:00–19:00",
    serviceArea: "Tema, Community 1–12",
    serviceRadiusKm: 8,
    supportedSizes: ["kg6", "kg12_5"],
    fulfillment: { exchangeEmpty: true },
    stockApproach: "admin_managed",
    status: "draft",
    verificationNotes: "",
    createdAt: serverTimestamp(),
    createdBy: uid,
    updatedAt: serverTimestamp(),
    updatedBy: uid,
    ...overrides,
  };
}

async function seedStation(status = "draft", overrides = {}) {
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    const data = { ...stationData(SUPER_A), status, createdAt: new Date(0), updatedAt: new Date(0), ...overrides };
    if (status === "verified") Object.assign(data, { verifiedBy: SUPER_B, verifiedAt: new Date(0) });
    await setDoc(doc(fs, `gas_suppliers/${S}/stations/${ST}`), data);
  });
}

function productData(uid, overrides = {}) {
  return {
    orderType: "exchangeEmpty",
    cylinderSize: "kg12_5",
    brand: "goGas",
    price: 150,
    handlingFee: 0,
    currency: "GHS",
    priceVersion: 1,
    availability: "unavailable",
    verified: false,
    notes: "",
    createdAt: serverTimestamp(),
    createdBy: uid,
    updatedAt: serverTimestamp(),
    updatedBy: uid,
    ...overrides,
  };
}

function createProduct(uid, overrides = {}, id = PID, histOverrides = {}) {
  const b = writeBatch(D(uid));
  const data = productData(uid, overrides);
  b.set(product(uid, id), data);
  b.set(priceHist(uid, 1, id), {
    version: 1, price: data.price, handlingFee: data.handlingFee, previousPrice: null,
    previousHandlingFee: null, reason: "Initial price", changedBy: uid, changedAt: serverTimestamp(),
    ...histOverrides,
  });
  return b.commit();
}

async function seedProduct({ verified = false, availability = "unavailable", price = 150, priceVersion = 1 } = {}) {
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    const data = { ...productData(SUPER_A), verified, availability, price, priceVersion, createdAt: new Date(0), updatedAt: new Date(0) };
    if (verified) Object.assign(data, { verifiedBy: SUPER_B, verifiedAt: new Date(0) });
    await setDoc(doc(fs, `gas_suppliers/${S}/stations/${ST}/products/${PID}`), data);
    for (let v = 1; v <= priceVersion; v++) {
      await setDoc(doc(fs, `gas_suppliers/${S}/stations/${ST}/products/${PID}/price_history/${v}`), { version: v, price });
    }
  });
}

function changePrice(uid, { from, to, version, verified = false, availability = "unavailable", extra = {}, histOverrides = {} }) {
  const b = writeBatch(D(uid));
  b.update(product(uid), {
    price: to, priceVersion: version, verified, availability,
    updatedAt: serverTimestamp(), updatedBy: uid, ...extra,
  });
  b.set(priceHist(uid, version), {
    version, price: to, handlingFee: 0, previousPrice: from, previousHandlingFee: 0,
    reason: "Supplier price list", changedBy: uid, changedAt: serverTimestamp(), ...histOverrides,
  });
  return b.commit();
}

describe("gas suppliers", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      const fs = ctx.firestore();
      await setDoc(doc(fs, `admins/${SUPER_A}`), { active: true, role: "super_admin", email: "a@test" });
      await setDoc(doc(fs, `admins/${SUPER_B}`), { active: true, role: "super_admin", email: "b@test" });
      await setDoc(doc(fs, `admins/${PLAIN}`), { active: true, role: "admin", email: "p@test" });
      await setDoc(doc(fs, `admins/${INACTIVE}`), { active: false, role: "super_admin", email: "i@test" });
      await setDoc(doc(fs, `admins/${h.ADMIN}`), { active: "true", role: "super_admin", email: "s@test" }); // string, not bool
    });
  });

  describe("admin workflow (must work)", () => {
    it("GSP-P01 an admin creates a draft supplier with its first history entry", async () => {
      await assertSucceeds(createSupplier(PLAIN));
      const snap = await getDoc(sup(PLAIN));
      if (snap.data().status !== "draft" || snap.data().ordersEnabled !== false) throw new Error("not a draft");
      await assertSucceeds(getDoc(hist(PLAIN, 1)));
    });

    it("GSP-P02 an admin edits a draft's details", async () => {
      await createSupplier(PLAIN);
      await assertSucceeds(updateDoc(sup(PLAIN), {
        legalName: "Test Gas Limited", fulfillment: { exchangeEmpty: true, pickupAndReturn: true },
        updatedAt: serverTimestamp(), updatedBy: PLAIN,
      }));
      await assertSucceeds(updateDoc(sup(SUPER_B), { internalNotes: "Called them", updatedAt: serverTimestamp(), updatedBy: SUPER_B }));
    });

    it("GSP-P03 full onboarding: submit → approve (other super admin) → enable → suspend → reinstate", async () => {
      await createSupplier(SUPER_A);
      await assertSucceeds(changeStatus(PLAIN, { from: "draft", to: "pending_verification", seq: 2 }));
      await assertSucceeds(changeStatus(SUPER_B, { from: "pending_verification", to: "approved", seq: 3 }));
      await assertSucceeds(setOrders(SUPER_B, { status: "approved", enabled: true, seq: 4 }));
      await assertSucceeds(changeStatus(SUPER_A, { from: "approved", to: "suspended", seq: 5, reason: "Licence expired" }));
      const s = (await getDoc(sup(SUPER_A))).data();
      if (s.ordersEnabled !== false || s.auditSeq !== 5) throw new Error("suspension must stop orders");
      await assertSucceeds(changeStatus(SUPER_B, { from: "suspended", to: "approved", seq: 6 }));
      const history = await getDocs(collection(D(PLAIN), `gas_suppliers/${S}/status_history`));
      if (history.size !== 6) throw new Error(`expected 6 history entries, got ${history.size}`);
    });

    it("GSP-P04 reject with a reason, then reopen as a draft", async () => {
      await seedSupplier("pending_verification");
      await assertSucceeds(changeStatus(SUPER_B, { from: "pending_verification", to: "rejected", seq: 4, reason: "No LPG licence" }));
      await assertSucceeds(changeStatus(SUPER_A, { from: "rejected", to: "draft", seq: 5, reason: "Licence received" }));
    });

    it("GSP-P05 any admin can stop orders; an approved supplier can be sent back for re-verification", async () => {
      await seedSupplier("approved", { ordersEnabled: true });
      await assertSucceeds(setOrders(PLAIN, { status: "approved", enabled: false, seq: 4 }));
      await assertSucceeds(changeStatus(PLAIN, { from: "approved", to: "pending_verification", seq: 5, reason: "Address changed" }));
    });

    it("GSP-P06 station: an admin adds a draft, a super admin verifies it", async () => {
      await seedSupplier("pending_verification");
      await assertSucceeds(setDoc(station(PLAIN), stationData(PLAIN)));
      await assertSucceeds(updateDoc(station(SUPER_A), {
        status: "verified", verifiedBy: SUPER_A, verifiedAt: serverTimestamp(),
        updatedAt: serverTimestamp(), updatedBy: SUPER_A,
      }));
      await assertSucceeds(updateDoc(station(PLAIN), { operatingHours: "Daily 06:00–20:00", updatedAt: serverTimestamp(), updatedBy: PLAIN }));
      await assertSucceeds(updateDoc(station(PLAIN), { status: "inactive", updatedAt: serverTimestamp(), updatedBy: PLAIN }));
    });

    it("GSP-P07 product: created unverified, verified and put on sale by a super admin", async () => {
      await seedSupplier("approved");
      await seedStation("verified");
      await assertSucceeds(createProduct(PLAIN));
      await assertSucceeds(updateDoc(product(SUPER_B), {
        verified: true, verifiedBy: SUPER_B, verifiedAt: serverTimestamp(), availability: "available",
        updatedAt: serverTimestamp(), updatedBy: SUPER_B,
      }));
      // Stock changes on a verified product are routine.
      await assertSucceeds(updateDoc(product(PLAIN), { availability: "out_of_stock", updatedAt: serverTimestamp(), updatedBy: PLAIN }));
    });

    it("GSP-P08 a price change is versioned and recorded; earlier prices stay readable", async () => {
      await seedSupplier("approved");
      await seedStation("verified");
      await seedProduct({ verified: true, availability: "available" });
      await assertSucceeds(changePrice(PLAIN, { from: 150, to: 165, version: 2 })); // admin: un-verifies
      await assertSucceeds(changePrice(SUPER_B, {
        from: 165, to: 170, version: 3, verified: true, availability: "available",
        extra: { verifiedBy: SUPER_B, verifiedAt: serverTimestamp() },
      }));
      const v1 = (await getDoc(priceHist(PLAIN, 1))).data();
      if (v1.price !== 150) throw new Error("version 1 must keep its price");
    });
  });

  describe("access and authorisation (must be refused)", () => {
    it("GSP-S01 passengers, drivers, inactive or malformed admins and strangers have no access", async () => {
      await seedSupplier("approved");
      for (const uid of [h.PAX, h.DRIVER, INACTIVE, h.ADMIN, MEMBER, null]) {
        await assertFails(getDoc(sup(uid)), String(uid));
        await assertFails(getDocs(collection(D(uid), "gas_suppliers")), String(uid));
        await assertFails(createSupplier(uid, {}, `new-${uid}`), String(uid));
      }
    });

    it("GSP-S02 a new supplier must be a draft, orders off, stamped by the caller, with history/1", async () => {
      await assertFails(createSupplier(PLAIN, { status: "approved" }));
      await assertFails(createSupplier(SUPER_A, { status: "pending_verification" }));
      await assertFails(createSupplier(PLAIN, { ordersEnabled: true }));
      await assertFails(createSupplier(PLAIN, { createdBy: SUPER_B }));
      await assertFails(createSupplier(PLAIN, { auditSeq: 2 }));
      await assertFails(createSupplier(PLAIN, { legalName: "" }));
      await assertFails(createSupplier(PLAIN, { unknownField: true }));
      await assertFails(setDoc(sup(PLAIN), draftSupplier(PLAIN))); // no history entry
    });

    it("GSP-S03 an admin without super_admin cannot approve, reject, suspend or reinstate", async () => {
      await seedSupplier("pending_verification");
      await assertFails(changeStatus(PLAIN, { from: "pending_verification", to: "approved", seq: 4 }));
      await assertFails(changeStatus(PLAIN, { from: "pending_verification", to: "rejected", seq: 4, reason: "No licence" }));
      await seedSupplier("approved");
      await assertFails(changeStatus(PLAIN, { from: "approved", to: "suspended", seq: 4, reason: "Complaint" }));
      await seedSupplier("suspended");
      await assertFails(changeStatus(PLAIN, { from: "suspended", to: "approved", seq: 4 }));
    });

    it("GSP-S04 the super admin who created a supplier cannot approve or reinstate it", async () => {
      await seedSupplier("pending_verification", { createdBy: SUPER_A });
      await assertFails(changeStatus(SUPER_A, { from: "pending_verification", to: "approved", seq: 4 }));
      await seedSupplier("suspended", { createdBy: SUPER_A });
      await assertFails(changeStatus(SUPER_A, { from: "suspended", to: "approved", seq: 4 }));
    });

    it("GSP-S05 status changes must follow the workflow", async () => {
      await seedSupplier("draft");
      await assertFails(changeStatus(SUPER_B, { from: "draft", to: "approved", seq: 4 })); // skips verification
      await assertFails(changeStatus(SUPER_B, { from: "draft", to: "suspended", seq: 4, reason: "x x x" }));
      await seedSupplier("rejected");
      await assertFails(changeStatus(SUPER_B, { from: "rejected", to: "approved", seq: 4 }));
    });

    it("GSP-S06 rejecting, suspending or re-verifying needs a reason", async () => {
      await seedSupplier("pending_verification");
      await assertFails(changeStatus(SUPER_B, { from: "pending_verification", to: "rejected", seq: 4 }));
      await assertFails(changeStatus(SUPER_B, { from: "pending_verification", to: "rejected", seq: 4, reason: "" }));
      await seedSupplier("approved");
      await assertFails(changeStatus(SUPER_B, { from: "approved", to: "suspended", seq: 4 }));
      await assertFails(changeStatus(PLAIN, { from: "approved", to: "pending_verification", seq: 4 }));
    });

    it("GSP-S07 a status change without a matching history entry is refused", async () => {
      await seedSupplier("pending_verification");
      // No history entry at all.
      await assertFails(updateDoc(sup(SUPER_B), {
        status: "approved", statusReason: null, statusChangedAt: serverTimestamp(), statusChangedBy: SUPER_B,
        ordersEnabled: false, auditSeq: 4, updatedAt: serverTimestamp(), updatedBy: SUPER_B,
      }));
      // Entry naming someone else, the wrong previous status, or a reused number.
      await assertFails(changeStatus(SUPER_B, { from: "pending_verification", to: "approved", seq: 4, histOverrides: { by: SUPER_A } }));
      await assertFails(changeStatus(SUPER_B, { from: "draft", to: "approved", seq: 4 }));
      await assertFails(changeStatus(SUPER_B, { from: "pending_verification", to: "approved", seq: 3 }));
      await assertFails(changeStatus(SUPER_B, { from: "pending_verification", to: "approved", seq: 5 }));
      // Status changed but auditSeq not bumped.
      await assertFails(updateDoc(sup(SUPER_B), {
        status: "approved", statusChangedAt: serverTimestamp(), statusChangedBy: SUPER_B,
        updatedAt: serverTimestamp(), updatedBy: SUPER_B,
      }));
    });

    it("GSP-S08 history is append-only and cannot be written on its own", async () => {
      await seedSupplier("approved");
      await assertFails(updateDoc(hist(SUPER_B, 3), { by: SUPER_B }));
      await assertFails(deleteDoc(hist(SUPER_B, 3)));
      await assertFails(setDoc(hist(SUPER_B, 4),
        historyEntry(SUPER_B, 4, "status_changed", "approved", "suspended", false, "Complaint")));
    });

    it("GSP-S09 draft, pending, rejected and suspended suppliers cannot take orders", async () => {
      for (const status of ["draft", "pending_verification", "rejected", "suspended"]) {
        await seedSupplier(status);
        await assertFails(setOrders(SUPER_B, { status, enabled: true, seq: 4 }), status);
      }
      // Approval itself never turns orders on.
      await seedSupplier("pending_verification");
      await assertFails(changeStatus(SUPER_B, { from: "pending_verification", to: "approved", seq: 4, ordersEnabled: true }));
      // A suspension cannot leave orders on.
      await seedSupplier("approved", { ordersEnabled: true });
      await assertFails(changeStatus(SUPER_B, { from: "approved", to: "suspended", seq: 4, reason: "Complaint", ordersEnabled: true }));
    });

    it("GSP-S10 only a super admin can turn orders on", async () => {
      await seedSupplier("approved");
      await assertFails(setOrders(PLAIN, { status: "approved", enabled: true, seq: 4 }));
      await assertFails(updateDoc(sup(SUPER_B), { ordersEnabled: true, updatedAt: serverTimestamp(), updatedBy: SUPER_B }));
    });

    it("GSP-S11 once approved, business identity cannot be edited without re-verification", async () => {
      await seedSupplier("approved");
      for (const f of [{ legalName: "Other Ltd" }, { registration: { businessRegNo: "X" } },
        { fulfillment: { commercialBulk: true } }, { address: "Elsewhere" }, { riderArrangement: "supplier_riders" }]) {
        await assertFails(updateDoc(sup(SUPER_B), { ...f, updatedAt: serverTimestamp(), updatedBy: SUPER_B }), JSON.stringify(f));
      }
      await assertFails(updateDoc(sup(SUPER_B), { createdBy: SUPER_B, updatedAt: serverTimestamp(), updatedBy: SUPER_B }));
      await assertFails(updateDoc(sup(SUPER_B), { internalNotes: "x", updatedAt: serverTimestamp(), updatedBy: SUPER_A }));
    });

    it("GSP-P09 payout preference: MTN MoMo, Telecel Cash or AT Money with a 10-digit number and name", async () => {
      await createSupplier(SUPER_A);
      for (const method of ["mtn_momo", "telecel_cash", "at_money"]) {
        await assertSucceeds(updateDoc(sup(PLAIN), { payoutPreference: { method, accountNumber: "0241234567",
          accountName: "Test Gas Ltd" }, updatedAt: serverTimestamp(), updatedBy: PLAIN }), method);
      }
      await assertSucceeds(createSupplier(SUPER_A, { payoutPreference: { method: "at_money",
        accountNumber: "0261234567", accountName: "Other Gas" } }, "sup-new"));
    });

    it("GSP-S19 malformed payout preferences are refused", async () => {
      await createSupplier(SUPER_A);
      for (const p of [{ method: "bank", accountNumber: "0241234567", accountName: "X Y" },
        { method: "mtn_momo", accountNumber: "241234567", accountName: "X Y" },
        { method: "mtn_momo", accountNumber: "+233241234567", accountName: "X Y" },
        { method: "mtn_momo", accountNumber: "02412345678", accountName: "X Y" },
        { method: "mtn_momo", accountNumber: "0241234567", accountName: "X" },
        { method: "mtn_momo", accountNumber: "0241234567" },
        { method: "mtn_momo", accountNumber: "0241234567", accountName: "X Y", payoutEnabled: true },
        "mtn_momo"]) {
        await assertFails(updateDoc(sup(PLAIN), { payoutPreference: p, updatedAt: serverTimestamp(), updatedBy: PLAIN }),
          JSON.stringify(p));
      }
    });

    it("GSP-S20 after approval only a super admin changes the payout destination, and only on its own", async () => {
      await seedSupplier("approved");
      const pref = { method: "telecel_cash", accountNumber: "0201234567", accountName: "Test Gas Ltd" };
      await assertFails(updateDoc(sup(PLAIN), { payoutPreference: pref, updatedAt: serverTimestamp(), updatedBy: PLAIN }));
      await assertFails(updateDoc(sup(SUPER_B), { payoutPreference: pref, internalNotes: "x",
        updatedAt: serverTimestamp(), updatedBy: SUPER_B }));
      await assertSucceeds(updateDoc(sup(SUPER_B), { payoutPreference: pref, updatedAt: serverTimestamp(), updatedBy: SUPER_B }));
      await assertFails(updateDoc(sup(SUPER_B), { payoutPreference: { ...pref, accountNumber: "0201234568" },
        updatedAt: serverTimestamp(), updatedBy: SUPER_A }), "stamped by the caller");
    });

    it("GSP-S12 supplier staff (future portal) cannot read any supplier, including their own", async () => {
      await seedSupplier("approved");
      await h.env().withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `gas_suppliers/${S}/members/${MEMBER}`), { role: "owner" });
        await setDoc(doc(ctx.firestore(), "gas_suppliers/sup2"), { legalName: "Other" });
      });
      await assertFails(getDoc(sup(MEMBER)));
      await assertFails(getDoc(sup(MEMBER, "sup2")));
      await assertFails(getDoc(doc(D(MEMBER), `gas_suppliers/${S}/members/${MEMBER}`)));
      await assertFails(setDoc(doc(D(MEMBER), `gas_suppliers/sup2/members/${MEMBER}`), { role: "owner" }));
      await assertFails(setDoc(doc(D(PLAIN), `gas_suppliers/sup2/members/${MEMBER}`), { role: "owner" }));
      await assertFails(getDoc(station(MEMBER)));
    });

    it("GSP-S13 stations: verification is super-admin only and needs an address and coordinates", async () => {
      await seedSupplier("pending_verification");
      await assertFails(setDoc(station(PLAIN), stationData(PLAIN, { status: "verified" })));
      await assertFails(setDoc(station(PLAIN), stationData(PLAIN, { supplierId: "sup2" })));
      await assertFails(setDoc(doc(D(PLAIN), `gas_suppliers/missing/stations/x`), stationData(PLAIN, { supplierId: "missing" })));
      await seedStation("draft", { location: null });
      const verify = (uid) => ({ status: "verified", verifiedBy: uid, verifiedAt: serverTimestamp(), updatedAt: serverTimestamp(), updatedBy: uid });
      await assertFails(updateDoc(station(SUPER_B), verify(SUPER_B))); // no coordinates
      await seedStation("draft");
      await assertFails(updateDoc(station(PLAIN), verify(PLAIN)));
      await assertFails(updateDoc(station(SUPER_B), { ...verify(SUPER_B), verifiedBy: SUPER_A }));
    });

    it("GSP-S14 a verified station's location and address cannot change while it stays verified", async () => {
      await seedSupplier("approved");
      await seedStation("verified");
      for (const f of [{ location: new GeoPoint(5.7, -0.1) }, { address: "Elsewhere" }, { name: "Renamed" },
        { supportedSizes: ["kg45"] }, { verifiedBy: SUPER_A }]) {
        await assertFails(updateDoc(station(SUPER_B), { ...f, updatedAt: serverTimestamp(), updatedBy: SUPER_B }), JSON.stringify(f));
      }
    });

    it("GSP-S15 products start unverified and off sale; only a super admin verifies", async () => {
      await seedSupplier("approved");
      await seedStation("verified");
      await assertFails(createProduct(PLAIN, { availability: "available" }));
      await assertFails(createProduct(SUPER_B, { verified: true, verifiedBy: SUPER_B, verifiedAt: serverTimestamp() }));
      await assertFails(createProduct(PLAIN, {}, "pickupAndReturn_kg12_5_goGas")); // id must match the product
      await assertFails(createProduct(PLAIN, { brand: "any" }, "exchangeEmpty_kg12_5_any"));
      await assertFails(createProduct(PLAIN, { price: 0 }, PID, { price: 0 }));
      await assertFails(createProduct(PLAIN, { price: -5 }, PID, { price: -5 }));
      await assertFails(createProduct(PLAIN, { currency: "USD" }));
      await assertFails(createProduct(PLAIN, {}, PID, { price: 1 })); // history disagrees
      await assertFails(setDoc(product(PLAIN), productData(PLAIN))); // no price history
      await seedProduct();
      await assertFails(updateDoc(product(PLAIN), {
        verified: true, verifiedBy: PLAIN, verifiedAt: serverTimestamp(), updatedAt: serverTimestamp(), updatedBy: PLAIN,
      }));
      await assertFails(updateDoc(product(SUPER_B), { availability: "available", updatedAt: serverTimestamp(), updatedBy: SUPER_B }));
    });

    it("GSP-S16 prices change only through a recorded, versioned change", async () => {
      await seedSupplier("approved");
      await seedStation("verified");
      await seedProduct({ verified: true, availability: "available" });
      // No version bump / no history.
      await assertFails(updateDoc(product(SUPER_B), { price: 99, updatedAt: serverTimestamp(), updatedBy: SUPER_B }));
      await assertFails(updateDoc(product(SUPER_B), { price: 99, priceVersion: 2, updatedAt: serverTimestamp(), updatedBy: SUPER_B }));
      // History that misstates the old or new price, or the actor.
      await assertFails(changePrice(PLAIN, { from: 140, to: 165, version: 2 }));
      await assertFails(changePrice(PLAIN, { from: 150, to: 165, version: 2, histOverrides: { price: 160 } }));
      await assertFails(changePrice(PLAIN, { from: 150, to: 165, version: 2, histOverrides: { changedBy: SUPER_B } }));
      // An ordinary admin cannot keep a re-priced product verified or on sale.
      await assertFails(changePrice(PLAIN, { from: 150, to: 165, version: 2, verified: true, availability: "available" }));
      // Identity of a product is fixed.
      await assertFails(updateDoc(product(SUPER_B), { cylinderSize: "kg6", updatedAt: serverTimestamp(), updatedBy: SUPER_B }));
    });

    it("GSP-S17 price history is append-only", async () => {
      await seedSupplier("approved");
      await seedStation("verified");
      await seedProduct();
      await assertFails(updateDoc(priceHist(SUPER_B, 1), { price: 1 }));
      await assertFails(deleteDoc(priceHist(SUPER_B, 1)));
      await assertFails(setDoc(priceHist(SUPER_B, 2), {
        version: 2, price: 150, handlingFee: 0, previousPrice: 150, previousHandlingFee: 0,
        changedBy: SUPER_B, changedAt: serverTimestamp(),
      }));
    });

    it("GSP-S18 nothing in gas_suppliers can be deleted", async () => {
      await seedSupplier("draft");
      await seedStation("draft");
      await seedProduct();
      for (const ref of [sup(SUPER_B), station(SUPER_B), product(SUPER_B)]) {
        await assertFails(deleteDoc(ref), ref.path);
      }
    });
  });
});
