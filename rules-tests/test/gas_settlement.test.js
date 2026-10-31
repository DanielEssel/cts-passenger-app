// Gas supplier settlement records (functions/gas_settlement_ledger.js):
// written only by Cloud Functions; admins may read; no client, including a
// super admin, may create, change or delete an entry, claim, statement,
// commission terms version, the current terms, or an order's allocation.
// The order's passenger reads the order but never its allocation
// (commission and supplier net are not shown to customers).

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, getDoc, setDoc, updateDoc, deleteDoc } = require("firebase/firestore");
const h = require("./helpers");

const SUPER = "settleSuper";
const PATHS = {
  ledger: "gas_settlement_ledger/o1__supplier__entitlement",
  claim: "gas_settlement_claims/o1__supplier__entitlement",
  statement: "gas_settlement_statements/2026-10-20__supplier__sup1",
  terms: "gas_commission_terms/current",
  termsVersion: "gas_commission_terms/v1",
  allocation: "gas_supplier_orders/o1/finance/allocation",
};

describe("gas settlement records", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      const fs = ctx.firestore();
      await setDoc(doc(fs, `admins/${SUPER}`), { active: true, role: "super_admin", email: "s@test" });
      await setDoc(doc(fs, PATHS.ledger), { orderId: "o1", party: "supplier", partyId: "sup1", amountPesewas: 27000 });
      await setDoc(doc(fs, PATHS.claim), { entryId: "o1__supplier__entitlement", statementId: "s1" });
      await setDoc(doc(fs, PATHS.statement), { party: "supplier", partyId: "sup1", netPesewas: 27000, payoutStatus: "not_started" });
      await setDoc(doc(fs, PATHS.terms), { active: false, rateBps: null, version: 1 });
      await setDoc(doc(fs, PATHS.termsVersion), { termsId: "v1", version: 1, status: "proposed", rateBps: 0 });
      await setDoc(doc(fs, "gas_supplier_orders/o1"), { passengerId: h.PAX, supplierId: "sup1", status: "awaiting_payment" });
      await setDoc(doc(fs, PATHS.allocation), { orderId: "o1", supplierId: "sup1", commissionPesewas: 3000, supplierNetPesewas: 27000 });
    });
  });

  it("GST-P01 admins can read settlement records", async () => {
    for (const p of Object.values(PATHS)) {
      await assertSucceeds(getDoc(doc(h.db(h.ADMIN), p)));
      await assertSucceeds(getDoc(doc(h.db(SUPER), p)));
    }
  });

  it("GST-S01 passengers, drivers and signed-out users cannot read them", async () => {
    for (const uid of [h.PAX, h.DRIVER, null]) {
      for (const p of Object.values(PATHS)) await assertFails(getDoc(doc(h.db(uid), p)), `${uid} ${p}`);
    }
  });

  it("GST-S03 the order's own passenger reads the order, not its allocation", async () => {
    await assertSucceeds(getDoc(doc(h.db(h.PAX), "gas_supplier_orders/o1")));
    await assertFails(getDoc(doc(h.db(h.PAX), PATHS.allocation)));
    await assertFails(getDoc(doc(h.db(h.PAX), "gas_supplier_orders/o1/finance/other")));
  });

  it("GST-S02 nobody writes them from a client, including a super admin", async () => {
    for (const uid of [h.PAX, h.DRIVER, h.ADMIN, SUPER]) {
      for (const p of Object.values(PATHS)) {
        await assertFails(setDoc(doc(h.db(uid), `${p}-new`), { amountPesewas: 1 }), `${uid} create ${p}`);
        await assertFails(updateDoc(doc(h.db(uid), p), { amountPesewas: 1, netPesewas: 1, payoutStatus: "paid", active: true, rateBps: 1, status: "approved", approvedBy: uid, commissionPesewas: 0 }), `${uid} update ${p}`);
        await assertFails(deleteDoc(doc(h.db(uid), p)), `${uid} delete ${p}`);
      }
    }
  });
});
