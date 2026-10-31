// Clients cannot forge withdrawal requests, held balances, the one-open-
// withdrawal lock or payout records; withdrawals are created and moved only
// by Cloud Functions (Admin SDK) or an active admin.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, getDoc, setDoc, updateDoc, deleteDoc, deleteField, serverTimestamp } = require("firebase/firestore");
const h = require("./helpers");

describe("withdrawal and payout state", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      const fs = ctx.firestore();
      await setDoc(doc(fs, "withdrawals/wOwn"), { userId: h.DRIVER, amount: 50, status: "pending" });
      await setDoc(doc(fs, `drivers/${h.DRIVER}`), { uid: h.DRIVER, role: "driver_hailing",
        isApproved: true, signupStep: "approved", walletBalance: 50, totalEarnings: 100,
        pendingWithdrawal: 50, activeWithdrawalId: "wOwn" }, { merge: true });
      await setDoc(doc(fs, "payments/P1"), { userId: h.DRIVER, type: "payout", status: "pending" });
    });
  });

  const drv = (uid = h.DRIVER) => doc(h.db(uid), `drivers/${h.DRIVER}`);

  it("WST-S01 a driver cannot set, change or clear the lock or held balances", async () => {
    for (const f of [{ activeWithdrawalId: deleteField() }, { activeWithdrawalId: "other" },
      { pendingWithdrawal: 0 }, { pendingWithdrawal: 500 }, { walletBalance: 5000 }, { totalEarnings: 5000 }]) {
      await assertFails(updateDoc(drv(), f), JSON.stringify(f));
    }
  });

  it("WST-S02 no client creates or moves a withdrawal", async () => {
    await assertFails(setDoc(doc(h.db(h.DRIVER), "withdrawals/forged"),
      { userId: h.DRIVER, amount: 50, status: "pending", createdAt: serverTimestamp() }));
    await assertFails(setDoc(doc(h.db(h.PAX), "withdrawals/forged2"),
      { userId: h.PAX, amount: 30, status: "pending" }));
    for (const status of ["processing", "completed", "rejected", "failed"]) {
      await assertFails(updateDoc(doc(h.db(h.DRIVER), "withdrawals/wOwn"), { status }), status);
    }
  });

  it("WST-S03 payout records, callbacks and the audit log are server-only", async () => {
    await assertFails(getDoc(doc(h.db(h.DRIVER), "payments/P1")));
    await assertFails(updateDoc(doc(h.db(h.DRIVER), "payments/P1"), { status: "success" }));
    await assertFails(setDoc(doc(h.db(h.DRIVER), "bridge_callbacks/x"), { verified: true }));
    await assertFails(setDoc(doc(h.db(h.DRIVER), "audit_log/x"), { action: "withdrawal_payout_confirmed" }));
  });

  it("WST-P01 the driver still reads their own withdrawal; others cannot", async () => {
    await assertSucceeds(getDoc(doc(h.db(h.DRIVER), "withdrawals/wOwn")));
    await assertFails(getDoc(doc(h.db(h.STRANGER), "withdrawals/wOwn")));
  });

  it("WST-P02 an admin cannot write a withdrawal directly; only Cloud Functions can", async () => {
    await h.env().withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), "admins/superW"), { active: true, role: "super_admin", email: "s@test" });
    });
    for (const uid of [h.ADMIN, "superW"]) {
      const w = (id) => doc(h.db(uid), `withdrawals/${id}`);
      await assertFails(updateDoc(w("wOwn"), { adminNote: "checked" }), uid);
      await assertFails(updateDoc(w("wOwn"), { status: "completed" }), uid);
      await assertFails(setDoc(w("wNew"), { userId: h.DRIVER, amount: 50, status: "pending" }), uid);
      await assertFails(deleteDoc(w("wOwn")), uid);
    }
  });
});
