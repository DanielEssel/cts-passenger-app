// wallets/{userId} creation: server-only (Admin SDK) or an active admin.
// No Passenger, Driver or admin-panel build creates a wallet; the previous
// owner rule checked only balance == 0, so a user could create a wallet
// with a heldBalance or other financial state of their choosing.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, getDoc, setDoc, serverTimestamp } = require("firebase/firestore");
const h = require("./helpers");

const wallet = (uid, o = {}) => ({ userId: uid, balance: 0, currency: "GHS", isActive: true,
  createdAt: serverTimestamp(), updatedAt: serverTimestamp(), ...o });
const ref = (uid, id) => doc(h.db(uid), `wallets/${id}`);

describe("wallet creation", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(h.seed);

  it("WLT-S01 a user cannot create their own wallet, even an empty one", () =>
    assertFails(setDoc(ref("freshUser", "freshUser"), wallet("freshUser"))));

  it("WLT-S02 forged financial state is refused", async () => {
    for (const forged of [{ heldBalance: 500 }, { balance: 0, heldBalance: -10 },
      { pendingWithdrawal: 100 }, { balance: 1000 }, { isActive: true, currency: "USD" }]) {
      await assertFails(setDoc(ref("freshUser", "freshUser"), wallet("freshUser", forged)), JSON.stringify(forged));
    }
  });

  it("WLT-S03 a user cannot create a wallet for someone else", () =>
    assertFails(setDoc(ref("freshUser", "someoneElse"), wallet("someoneElse"))));

  it("WLT-P01 an active admin can still create one; owners still read their wallet", async () => {
    await assertSucceeds(setDoc(ref(h.ADMIN, "createdByAdmin"), wallet("createdByAdmin")));
    await assertSucceeds(getDoc(ref(h.PAX, h.PAX)));
    await assertFails(getDoc(ref(h.STRANGER, h.PAX)));
  });
});
