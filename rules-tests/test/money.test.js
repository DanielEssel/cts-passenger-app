// Wallets, escrows, ledger, transaction history and withdrawals.
// Balances must only move through Cloud Functions (Admin SDK bypasses rules).

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  doc,
  getDoc,
  setDoc,
  updateDoc,
  deleteDoc,
  addDoc,
  collection,
  increment,
  serverTimestamp,
} = require("firebase/firestore");
const h = require("./helpers");

const ref = (uid, path) => doc(h.db(uid), path);

describe("money", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(h.seed);

  describe("security: wallet balances", () => {
    it("MON-S01 passenger cannot raise own wallet balance", () =>
      assertFails(updateDoc(ref(h.PAX, `wallets/${h.PAX}`), { balance: 10000 })));

    it("MON-S02 passenger cannot release own held balance", () =>
      assertFails(
        updateDoc(ref(h.PAX, `wallets/${h.PAX}`), {
          heldBalance: 0,
          balance: increment(20.5),
        }),
      ));

    it("MON-S03 user cannot create a wallet with a balance", () =>
      assertFails(
        setDoc(ref("freshUser", "wallets/freshUser"), {
          userId: "freshUser",
          balance: 500,
          currency: "GHS",
        }),
      ));

    it("MON-S04 user cannot delete own wallet", () =>
      assertFails(deleteDoc(ref(h.PAX, `wallets/${h.PAX}`))));

    it("MON-S05 user cannot read someone else's wallet", () =>
      assertFails(getDoc(ref(h.STRANGER, `wallets/${h.PAX}`))));

    it("MON-S06 user cannot touch escrows", async () => {
      await assertFails(updateDoc(ref(h.PAX, "escrows/esc1"), { status: "REFUNDED" }));
      await assertFails(
        setDoc(ref(h.PAX, "escrows/mine"), { userId: h.PAX, amount: 1, status: "HELD" }),
      );
    });

    it("MON-S07 user cannot write the ledger", () =>
      assertFails(
        setDoc(ref(h.PAX, "ledger/fake"), {
          type: "TOPUP",
          toUserId: h.PAX,
          amount: 1000,
          status: "COMPLETED",
        }),
      ));

    it("MON-S08 driver cannot write driver_wallets", () =>
      assertFails(updateDoc(ref(h.DRIVER, `driver_wallets/${h.DRIVER}`), { balance: 9999 })));

    it("MON-S09 user cannot forge a completed credit in transaction history", () =>
      assertFails(
        addDoc(collection(h.db(h.PAX), "transactions"), {
          userId: h.PAX,
          type: "credit",
          category: "top_up",
          amount: 1000,
          status: "completed",
          createdAt: serverTimestamp(),
        }),
      ));
  });

  describe("security: withdrawals", () => {
    it("MON-S10 driver cannot create a withdrawal request directly", () =>
      assertFails(
        addDoc(collection(h.db(h.DRIVER), "withdrawals"), {
          userId: h.DRIVER,
          amount: 4000,
          status: "pending",
          phone: "233200000000",
          network: "MTN",
          createdAt: serverTimestamp(),
        }),
      ));

    it("MON-S11 passenger cannot create a withdrawal request directly", () =>
      assertFails(
        addDoc(collection(h.db(h.PAX), "withdrawals"), {
          userId: h.PAX,
          amount: 30,
          status: "pending",
          createdAt: serverTimestamp(),
        }),
      ));

    it("MON-S12 cannot create a withdrawal for someone else", () =>
      assertFails(
        addDoc(collection(h.db(h.STRANGER), "withdrawals"), {
          userId: h.DRIVER,
          amount: 20,
          status: "pending",
        }),
      ));

    it("MON-S13 driver cannot mark own withdrawal approved or completed", () =>
      assertFails(updateDoc(ref(h.DRIVER, "withdrawals/w1"), { status: "completed" })));

    it("MON-S14 legacy driver WithdrawalScreen payload is rejected", () =>
      assertFails(
        addDoc(collection(h.db(h.DRIVER), "withdrawals"), {
          driverId: h.DRIVER,
          amount: 20,
          method: "mobile_money",
          network: "MTN",
          accountNumber: "0200000000",
          accountName: "Driver",
          status: "pending",
          createdAt: serverTimestamp(),
        }),
      ));

    it("MON-S15 user cannot read someone else's withdrawal", () =>
      assertFails(getDoc(ref(h.STRANGER, "withdrawals/w1"))));
  });

  describe("app behaviour (must keep working)", () => {
    it("MON-P01 passenger reads own wallet", () =>
      assertSucceeds(getDoc(ref(h.PAX, `wallets/${h.PAX}`))));

    it("MON-P02 passenger reads own escrow", () =>
      assertSucceeds(getDoc(ref(h.PAX, "escrows/esc1"))));

    it("MON-P03 passenger reads own ledger entry", () =>
      assertSucceeds(getDoc(ref(h.PAX, "ledger/l1"))));

    it("MON-P04 driver reads own withdrawal", () =>
      assertSucceeds(getDoc(ref(h.DRIVER, "withdrawals/w1"))));

    it("MON-P05 driver reads own earnings summary", () =>
      assertSucceeds(getDoc(ref(h.DRIVER, `drivers/${h.DRIVER}/earnings/summary`))));

    it("MON-P06 admin can read any wallet", () =>
      assertSucceeds(getDoc(ref(h.ADMIN, `wallets/${h.STRANGER}`))));
  });
});
