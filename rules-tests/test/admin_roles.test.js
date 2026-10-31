// Admin records (admins/{uid}): only a super admin may write them, never its
// own, so an ordinary admin cannot grant itself or anyone else super_admin
// (security blocker B5). A user reads only their own record.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, getDoc, setDoc, updateDoc, deleteDoc } = require("firebase/firestore");
const h = require("./helpers");

const SUPER = "superA";
const PLAIN = "plainAdmin";
const OTHER_PLAIN = "plainAdmin2";
const NOBODY = "pax1"; // signed in, no admins doc

const dbs = new Map();
const D = (uid) => {
  const key = uid ?? "<unauthenticated>";
  if (!dbs.has(key)) dbs.set(key, h.db(uid));
  return dbs.get(key);
};
const adm = (uid, target) => doc(D(uid), `admins/${target}`);

describe("admin roles", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      const fs = ctx.firestore();
      await setDoc(doc(fs, `admins/${SUPER}`), { active: true, role: "super_admin", email: "s@test" });
      await setDoc(doc(fs, `admins/${PLAIN}`), { active: true, role: "admin", email: "p@test" });
      await setDoc(doc(fs, `admins/${OTHER_PLAIN}`), { active: true, role: "admin", email: "p2@test" });
    });
  });

  it("ADM-R01 an ordinary admin cannot escalate itself or write any other admins doc", async () => {
    await assertFails(updateDoc(adm(PLAIN, PLAIN), { role: "super_admin" }));
    await assertFails(setDoc(adm(PLAIN, PLAIN), { active: true, role: "super_admin", email: "p@test" }));
    await assertFails(updateDoc(adm(PLAIN, PLAIN), { active: false }));
    await assertFails(setDoc(adm(PLAIN, "newUid"), { active: true, role: "super_admin", email: "n@test" }));
    await assertFails(setDoc(adm(PLAIN, "newUid"), { active: true, role: "admin", email: "n@test" }));
    await assertFails(updateDoc(adm(PLAIN, OTHER_PLAIN), { active: false }));
    await assertFails(updateDoc(adm(PLAIN, SUPER), { active: false }));
    await assertFails(deleteDoc(adm(PLAIN, OTHER_PLAIN)));
    await assertFails(deleteDoc(adm(PLAIN, SUPER)));
  });

  it("ADM-R02 a super admin cannot modify or delete its own doc", async () => {
    await assertFails(updateDoc(adm(SUPER, SUPER), { role: "admin" }));
    await assertFails(updateDoc(adm(SUPER, SUPER), { active: false }));
    await assertFails(setDoc(adm(SUPER, SUPER), { active: true, role: "super_admin", email: "s@test" }));
    await assertFails(deleteDoc(adm(SUPER, SUPER)));
  });

  it("ADM-R03 a super admin creates an admin doc for another uid and deactivates another admin", async () => {
    await assertSucceeds(setDoc(adm(SUPER, "newUid"), { active: true, role: "admin", email: "n@test" }));
    await assertSucceeds(updateDoc(adm(SUPER, PLAIN), { active: false }));
    let active;
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      active = (await getDoc(doc(ctx.firestore(), `admins/${PLAIN}`))).data().active;
    });
    if (active !== false) throw new Error("not deactivated");
    await assertSucceeds(deleteDoc(adm(SUPER, OTHER_PLAIN)));
  });

  it("ADM-R04 a non-admin or unauthenticated user cannot write; a user reads only their own doc", async () => {
    for (const uid of [NOBODY, null]) {
      await assertFails(setDoc(adm(uid, NOBODY), { active: true, role: "super_admin", email: "x@test" }));
      await assertFails(setDoc(adm(uid, "newUid"), { active: true, role: "admin", email: "x@test" }));
      await assertFails(updateDoc(adm(uid, PLAIN), { active: false }));
      await assertFails(deleteDoc(adm(uid, PLAIN)));
    }
    await assertSucceeds(getDoc(adm(PLAIN, PLAIN)));
    await assertFails(getDoc(adm(PLAIN, OTHER_PLAIN)));
    await assertFails(getDoc(adm(SUPER, PLAIN)));
    await assertFails(getDoc(adm(NOBODY, PLAIN)));
    await assertFails(getDoc(adm(null, PLAIN)));
  });
});
