// Gas supplier wallet rules (gas_supplier_wallet.js): wallets, withdrawals,
// recipient verification and their audit trail are written by Cloud
// Functions only; admins read them; suppliers and every other client can
// neither read nor write them directly. Supplier withdrawal limits in
// settings/gas_supplier_payouts are super-admin only and must be
// consistent whole pesewas.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, getDoc, getDocs, setDoc, updateDoc, deleteDoc, collection, query, where } = require("firebase/firestore");
const h = require("./helpers");

const SUPER = "walletSuper", OWNER = "walletOwner", STAFF = "walletStaff", OTHER_OWNER = "walletOwnerB";
const S = "supW", S2 = "supW2";
const PAYOUTS = "settings/gas_supplier_payouts";
const LIMITS = { minWithdrawalPesewas: 1000, maxWithdrawalPesewas: 50000, dailyWithdrawalLimitPesewas: 100000 }; // test values only
const WALLET = `gas_supplier_wallets/${S}`;
const WD = `${WALLET}/withdrawals/w_1`;

describe("gas supplier wallet rules", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      const fs = ctx.firestore();
      await setDoc(doc(fs, `admins/${SUPER}`), { active: true, role: "super_admin" });
      for (const [uid, sid, role] of [[OWNER, S, "owner"], [STAFF, S, "staff"], [OTHER_OWNER, S2, "owner"]]) {
        await setDoc(doc(fs, `gas_supplier_members/${uid}`), { uid, supplierId: sid, role, status: "active", version: 1 });
      }
      await setDoc(doc(fs, PAYOUTS), { enabled: false });
      await setDoc(doc(fs, "settings/platform"), { gasEnabled: true });
      await setDoc(doc(fs, WALLET), { supplierId: S, availablePesewas: 5000, reservedPesewas: 0, withdrawnPesewas: 0, creditedPesewas: 5000,
        activeWithdrawalId: null, recipient: { key: "k", maskedNumber: "024****567", verifiedBy: SUPER } });
      await setDoc(doc(fs, WD), { supplierId: S, status: "processing", outcome: "unknown", amountPesewas: 2000 });
      await setDoc(doc(fs, "audit_log/a1"), { action: "gas_supplier_withdrawal_requested", supplierId: S });
      await setDoc(doc(fs, "audit_log/a2"), { action: "admin_role_changed", uid: "someone" });
    });
  });

  it("WR-01 suppliers (owner or staff) and other clients cannot read or write wallets, withdrawals or the ledger of either supplier", async () => {
    for (const uid of [OWNER, STAFF, OTHER_OWNER, h.PAX, h.DRIVER, null]) {
      await assertFails(getDoc(doc(h.db(uid), WALLET)));
      await assertFails(getDoc(doc(h.db(uid), WD)));
      await assertFails(updateDoc(doc(h.db(uid), WALLET), { availablePesewas: 999999 }));
      await assertFails(setDoc(doc(h.db(uid), `gas_supplier_wallets/${S2}`), { availablePesewas: 1 }));
      await assertFails(updateDoc(doc(h.db(uid), WD), { status: "successful" }));
      await assertFails(setDoc(doc(h.db(uid), `${WALLET}/withdrawals/w_new`), { amountPesewas: 100, status: "processing" }));
      await assertFails(setDoc(doc(h.db(uid), "ledger/gas_supplier_wallet_credit_x"), { type: "EARNING", supplierId: S }));
    }
  });

  it("WR-02 admins read wallets and withdrawals but write nothing: no balance, status, verification or outcome change", async () => {
    for (const uid of [h.ADMIN, SUPER]) {
      await assertSucceeds(getDoc(doc(h.db(uid), WALLET)));
      await assertSucceeds(getDoc(doc(h.db(uid), WD)));
      await assertSucceeds(getDocs(collection(h.db(uid), `${WALLET}/withdrawals`)));
      await assertFails(updateDoc(doc(h.db(uid), WALLET), { availablePesewas: 1 }));
      await assertFails(updateDoc(doc(h.db(uid), WALLET), { recipient: { key: "other", verifiedBy: uid } }));
      await assertFails(updateDoc(doc(h.db(uid), WD), { status: "successful", outcome: "confirmed_paid" }));
      await assertFails(deleteDoc(doc(h.db(uid), WD)));
    }
  });

  it("WR-03 admins read the wallet's audit trail only; other audit entries stay closed; nobody writes it", async () => {
    await assertSucceeds(getDoc(doc(h.db(h.ADMIN), "audit_log/a1")));
    await assertFails(getDoc(doc(h.db(h.ADMIN), "audit_log/a2")));
    await assertSucceeds(getDocs(query(collection(h.db(SUPER), "audit_log"), where("action", "in", ["gas_supplier_withdrawal_requested", "gas_supplier_withdrawal_paid"]))));
    // An action that is not a wallet action is never readable.
    await assertFails(getDocs(query(collection(h.db(SUPER), "audit_log"), where("action", "in", ["gas_supplier_withdrawal_requested", "admin_role_changed"]))));
    await assertFails(getDocs(collection(h.db(SUPER), "audit_log")));
    await assertFails(getDoc(doc(h.db(OWNER), "audit_log/a1")));
    for (const uid of [h.ADMIN, SUPER, OWNER]) await assertFails(setDoc(doc(h.db(uid), "audit_log/x"), { action: "gas_supplier_withdrawal_paid", supplierId: S }));
  });

  it("WR-04 only a super admin enables payouts or changes limits; ordinary admins and suppliers cannot", async () => {
    for (const uid of [h.ADMIN, OWNER, STAFF]) {
      await assertFails(updateDoc(doc(h.db(uid), PAYOUTS), { enabled: true, ...LIMITS }));
      await assertFails(updateDoc(doc(h.db(uid), PAYOUTS), LIMITS));
    }
    await assertSucceeds(updateDoc(doc(h.db(SUPER), PAYOUTS), LIMITS));
    await assertSucceeds(updateDoc(doc(h.db(SUPER), PAYOUTS), { enabled: true }));
    await assertSucceeds(updateDoc(doc(h.db(SUPER), PAYOUTS), { enabled: false }));
  });

  it("WR-05 limits are whole pesewas with 1 <= minimum <= maximum <= daily, all three while enabled", async () => {
    const su = doc(h.db(SUPER), PAYOUTS);
    await assertFails(setDoc(su, { enabled: true }), "enabled without limits");
    await assertFails(setDoc(su, { enabled: true, minWithdrawalPesewas: 1000, maxWithdrawalPesewas: 50000 }), "no daily limit");
    for (const bad of [
      { ...LIMITS, minWithdrawalPesewas: 0 }, { ...LIMITS, minWithdrawalPesewas: -5 }, { ...LIMITS, minWithdrawalPesewas: 10.5 },
      { ...LIMITS, minWithdrawalPesewas: 60000 }, { ...LIMITS, dailyWithdrawalLimitPesewas: 49999 },
      { ...LIMITS, maxWithdrawalPesewas: "50000" }, { ...LIMITS, dailyWithdrawalLimitPesewas: null },
      { minWithdrawalPesewas: 1000 }, // partial, even while off
    ]) {
      await assertFails(setDoc(su, { enabled: false, ...bad }), JSON.stringify(bad));
      await assertFails(setDoc(su, { enabled: true, ...bad }), JSON.stringify(bad));
    }
    await assertSucceeds(setDoc(su, { enabled: false }));
    await assertSucceeds(setDoc(su, { enabled: true, ...LIMITS }));
    await assertSucceeds(setDoc(su, { enabled: true, minWithdrawalPesewas: 5000, maxWithdrawalPesewas: 5000, dailyWithdrawalLimitPesewas: 5000 }));
  });

  it("WR-07 other settings documents keep their existing permissions (ordinary admins may write them)", async () => {
    await assertSucceeds(updateDoc(doc(h.db(h.ADMIN), "settings/platform"), { gasEnabled: false }));
    await assertFails(updateDoc(doc(h.db(h.PAX), "settings/platform"), { gasEnabled: false }));
  });
});
