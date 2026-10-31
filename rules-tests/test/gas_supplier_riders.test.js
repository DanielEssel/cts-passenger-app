// Linked-rider records (functions/gas_supplier_riders.js): written and read
// only by Cloud Functions. gas_supplier_riders and gas_supplier_rider_audit
// refuse every client read and write, admins included (admins reach them
// through callables). gas_settlement_debts is admin-readable like the ledger;
// no client, including a super admin, writes it. A driver cannot touch a
// supplier order's rider offer, driver or accepted fee.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, getDoc, setDoc, updateDoc, deleteDoc } = require("firebase/firestore");
const h = require("./helpers");

const SUPER = "riderSuper", MEMBER = "riderSupMember";
const CLOSED = ["gas_supplier_riders/drvA", "gas_supplier_rider_audit/a1"];
const DEBT = "gas_settlement_debts/d1";

describe("gas supplier linked riders", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      const fs = ctx.firestore();
      await setDoc(doc(fs, `admins/${SUPER}`), { active: true, role: "super_admin", email: "s@test" });
      await setDoc(doc(fs, `gas_supplier_members/${MEMBER}`), { supplierId: "sup1", role: "owner", active: true });
      await setDoc(doc(fs, CLOSED[0]), { supplierId: "sup1", driverId: h.DRIVER, status: "active" });
      await setDoc(doc(fs, CLOSED[1]), { riderId: h.DRIVER, supplierId: "sup1", action: "link" });
      await setDoc(doc(fs, DEBT), { statementId: "s1", partyId: "drvA", status: "open", amountPesewas: 500 });
      await setDoc(doc(fs, "gas_supplier_orders/o1"), {
        passengerId: h.PAX, supplierId: "sup1", status: "accepted",
        driverId: h.DRIVER, acceptedFeePesewas: 800, riderOffer: { driverId: h.DRIVER, seq: 1 },
      });
    });
  });

  it("RULES-LR01 riders and rider audit refuse every read and write, for everyone", async () => {
    for (const uid of [null, h.PAX, h.DRIVER, MEMBER, h.ADMIN, SUPER]) {
      for (const p of CLOSED) {
        await assertFails(getDoc(doc(h.db(uid), p)), `${uid} read ${p}`);
        await assertFails(setDoc(doc(h.db(uid), `${p}-new`), { status: "active" }), `${uid} create ${p}`);
        await assertFails(updateDoc(doc(h.db(uid), p), { status: "suspended" }), `${uid} update ${p}`);
        await assertFails(deleteDoc(doc(h.db(uid), p)), `${uid} delete ${p}`);
      }
    }
  });

  it("RULES-LR02 debts: admins read; nobody writes, super admin included", async () => {
    await assertSucceeds(getDoc(doc(h.db(h.ADMIN), DEBT)));
    await assertSucceeds(getDoc(doc(h.db(SUPER), DEBT)));
    for (const uid of [null, h.PAX, h.DRIVER, MEMBER]) await assertFails(getDoc(doc(h.db(uid), DEBT)), String(uid));
    for (const uid of [null, h.PAX, h.DRIVER, MEMBER, h.ADMIN, SUPER]) {
      await assertFails(setDoc(doc(h.db(uid), "gas_settlement_debts/d-new"), { status: "open" }), `${uid} create`);
      await assertFails(updateDoc(doc(h.db(uid), DEBT), { status: "resolved" }), `${uid} update`);
      await assertFails(deleteDoc(doc(h.db(uid), DEBT)), `${uid} delete`);
    }
  });

  it("RULES-LR02b admins can run the admin app's debt queries", async () => {
    const { collection, query, where, orderBy, limit, getDocs } = require("firebase/firestore");
    const col = (uid) => collection(h.db(uid), "gas_settlement_debts");
    for (const uid of [h.ADMIN, SUPER]) {
      await assertSucceeds(getDocs(query(col(uid), where("status", "in", ["open", "held"]))));
      await assertSucceeds(getDocs(query(col(uid), orderBy("createdAt", "desc"), limit(100))));
      await assertSucceeds(getDocs(query(col(uid), where("partyId", "==", "drvA"))));
    }
    await assertFails(getDocs(query(col(h.DRIVER), where("partyId", "==", "drvA"))));
  });

  it("RULES-LR04 a driver cannot change an order's rider offer, driver or accepted fee", async () => {
    for (const patch of [
      { riderOffer: { driverId: h.DRIVER, seq: 2 } },
      { driverId: h.OTHER_DRIVER },
      { acceptedFeePesewas: 99999 },
      { status: "delivered" },
    ]) {
      for (const uid of [h.DRIVER, h.OTHER_DRIVER]) {
        await assertFails(updateDoc(doc(h.db(uid), "gas_supplier_orders/o1"), patch), `${uid} ${JSON.stringify(patch)}`);
      }
    }
  });
});
