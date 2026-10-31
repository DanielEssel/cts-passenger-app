// The Gas supplier switches (settings/gas_supplier_fulfilment and
// settings/gas_supplier_payouts): any signed-in user may read them (the apps
// check the flag before acting); only an active super admin may create,
// change or delete them, and only to values the functions read. Ordinary
// admins keep write access to every other settings document.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, getDoc, setDoc, updateDoc, deleteDoc } = require("firebase/firestore");
const h = require("./helpers");

const SUPER = "switchSuper", INACTIVE_SUPER = "switchSuperOff";
const SWITCHES = ["settings/gas_supplier_fulfilment", "settings/gas_supplier_payouts"];

describe("gas supplier switches", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      const fs = ctx.firestore();
      await setDoc(doc(fs, `admins/${SUPER}`), { active: true, role: "super_admin" });
      await setDoc(doc(fs, `admins/${INACTIVE_SUPER}`), { active: false, role: "super_admin" });
      for (const p of SWITCHES) await setDoc(doc(fs, p), { enabled: false });
      await setDoc(doc(fs, "settings/platform"), { gasEnabled: true });
    });
  });

  it("GSW-01 signed-in users may read the switches; nobody signed out may", async () => {
    for (const p of SWITCHES) {
      await assertSucceeds(getDoc(doc(h.db(h.PAX), p)));
      await assertFails(getDoc(doc(h.db(null), p)));
    }
  });

  it("GSW-02 an ordinary admin cannot turn either switch on, change or delete it", async () => {
    for (const p of SWITCHES) {
      await assertFails(updateDoc(doc(h.db(h.ADMIN), p), { enabled: true }));
      await assertFails(setDoc(doc(h.db(h.ADMIN), p), { enabled: true }));
      await assertFails(deleteDoc(doc(h.db(h.ADMIN), p)));
    }
    await assertFails(updateDoc(doc(h.db(h.ADMIN), SWITCHES[0]), { supplierResponseMinutes: 60 }));
  });

  it("GSW-03 passengers, drivers and inactive super admins cannot change them", async () => {
    for (const uid of [h.PAX, h.DRIVER, INACTIVE_SUPER, null]) {
      for (const p of SWITCHES) await assertFails(updateDoc(doc(h.db(uid), p), { enabled: true }));
    }
  });

  it("GSW-04 an active super admin may switch them on and off and set the response deadline", async () => {
    for (const p of SWITCHES) {
      await assertSucceeds(updateDoc(doc(h.db(SUPER), p), { enabled: true }));
      await assertSucceeds(updateDoc(doc(h.db(SUPER), p), { enabled: false }));
    }
    await assertSucceeds(updateDoc(doc(h.db(SUPER), SWITCHES[0]), { supplierResponseMinutes: 10 }));
    await assertSucceeds(deleteDoc(doc(h.db(SUPER), SWITCHES[1])));
    await assertSucceeds(setDoc(doc(h.db(SUPER), SWITCHES[1]), { enabled: false }));
  });

  it("GSW-05 only values the functions read: a boolean switch, a whole-minute deadline from 1 to 1440", async () => {
    for (const bad of [{ enabled: "true" }, { enabled: 1 }]) {
      for (const p of SWITCHES) await assertFails(setDoc(doc(h.db(SUPER), p), bad), JSON.stringify(bad));
    }
    for (const minutes of [0, 1441, 10.5, "10", null]) {
      await assertFails(updateDoc(doc(h.db(SUPER), SWITCHES[0]), { supplierResponseMinutes: minutes }), String(minutes));
    }
    await assertSucceeds(updateDoc(doc(h.db(SUPER), SWITCHES[0]), { supplierResponseMinutes: 1440 }));
  });

  it("RULES-LR03 riderAcceptMinutes: a super admin sets a whole number of minutes from 1 to 60", async () => {
    for (const minutes of [1, 60]) {
      await assertSucceeds(updateDoc(doc(h.db(SUPER), SWITCHES[0]), { riderAcceptMinutes: minutes }), String(minutes));
    }
    for (const bad of [0, 61, 2.5, "5"]) {
      await assertFails(updateDoc(doc(h.db(SUPER), SWITCHES[0]), { riderAcceptMinutes: bad }), JSON.stringify(bad));
    }
    await assertFails(updateDoc(doc(h.db(h.ADMIN), SWITCHES[0]), { riderAcceptMinutes: 5 }));
  });

  it("GSW-06 other settings documents stay admin-writable", async () => {
    await assertSucceeds(updateDoc(doc(h.db(h.ADMIN), "settings/platform"), { gasEnabled: true }));
    await assertFails(updateDoc(doc(h.db(h.PAX), "settings/platform"), { gasEnabled: false }));
  });
});
