// Release v5: Delivery and legacy Gas order privacy. An order document is
// readable only by its passenger, the driver it is assigned to now, and
// admins; unassigned drivers browse delivery_offers / gas_order_offers
// (server-written: area label and ~1 km point, no contacts, codes or exact
// addresses; functions/order_offers.js). Firestore emulator only.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  collection, doc, getDoc, getDocs, setDoc, updateDoc, deleteDoc, query, where, limit, Timestamp, onSnapshot, GeoPoint,
} = require("firebase/firestore");

/** Resolves "data" on the listener's first snapshot, "denied" on its first error. */
function firstEvent(ref) {
  return new Promise((resolve) => {
    const stop = onSnapshot(ref, () => { stop(); resolve("data"); }, () => resolve("denied"));
  });
}
const assert = require("node:assert/strict");
const h = require("./helpers");

const BIKE = "prvBike";       // active Delivery driver (would have seen open orders before v5)
const BIKE2 = "prvBike2";     // another active Delivery driver
const NEWBIE = "prvNew";      // Delivery driver awaiting approval
const SUSP = "prvSusp";       // suspended Delivery driver
const TAXI = "prvTaxi";       // active Ride driver
const active = { isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true, location: h.ACCRA };
const DRIVERS = {
  [BIKE]: { uid: BIKE, role: "driver_delivery", serviceType: "delivery", vehicleType: "motorcycle", ...active },
  [BIKE2]: { uid: BIKE2, role: "driver_delivery", serviceType: "delivery", vehicleType: "motorcycle", ...active },
  [NEWBIE]: { uid: NEWBIE, role: "driver_delivery", vehicleType: "motorcycle", ...active,
    isApproved: false, signupStep: "documentsUploaded" },
  [SUSP]: { uid: SUSP, role: "driver_delivery", vehicleType: "motorcycle", ...active,
    isApproved: false, signupStep: "suspended" },
  [TAXI]: { uid: TAXI, role: "driver_hailing", serviceType: "taxi", vehicleType: "taxi", ...active },
};

const EXACT = { pickupAddress: "12 Oxford St, Osu, Accra", dropoffAddress: "7 Ring Rd, Adabraka, Accra" };
const delivery = (o = {}) => ({ passengerId: h.PAX, driverId: null, status: "pending", vehicleType: "Okada",
  weightTier: "Small", paymentMethod: "cash", estimatedFare: 30, pickupLocation: h.ACCRA,
  dropoffLocation: h.ACCRA, ...EXACT, receiverName: "R", receiverPhone: "+233240000009",
  createdAt: Timestamp.now(), ...o });
const gasOrder = (o = {}) => ({ passengerId: h.PAX, driverId: null, status: "pendingApproval",
  paymentMethod: "cash", refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1, totalPrice: 62,
  deliveryFee: 12, gasPrice: 50, deliveryLocation: h.ACCRA, pickupLocation: h.ACCRA,
  deliveryAddress: EXACT.pickupAddress, pickupAddress: EXACT.pickupAddress,
  scheduledPickupAt: Timestamp.now(), deliveryInstructions: "gate code 4411", createdAt: Timestamp.now(), ...o });
const offer = (o = {}) => ({ schema: 1, service: "delivery", pickupArea: "Osu, Accra", fare: 30, ...o });

async function seed() {
  await h.seed();
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    const put = (p, d) => setDoc(doc(fs, p), d);
    for (const [id, d] of Object.entries(DRIVERS)) await put(`drivers/${id}`, d);
    await put("deliveries/open", delivery());
    await put("deliveries/mine", delivery({ status: "driverAssigned", driverId: BIKE }));
    await put("deliveries/theirs", delivery({ status: "pickupEnroute", driverId: BIKE2 }));
    await put("deliveries/open/private/details", { receiverName: "R", receiverPhone: "+233240000009" });
    await put("deliveries/mine/private/details", { receiverName: "R", receiverPhone: "+233240000009" });
    await put("gas_orders/open", gasOrder());
    await put("gas_orders/mine", gasOrder({ status: "driverAssigned", driverId: BIKE }));
    await put("gas_orders/open/private/details", { deliveryInstructions: "gate code 4411" });
    await put("order_completion_codes/deliveries_open", { code: "123456", passengerId: h.PAX });
    await put("order_completion_codes/deliveries_mine", { code: "654321", passengerId: h.PAX });
    await put("delivery_offers/open", offer());
    await put("gas_order_offers/open", offer({ service: "gas", fare: 62 }));
  });
}

describe("order privacy (release v5)", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(seed);

  describe("unassigned drivers", () => {
    it("PRV-01 no driver reads an open delivery or gas order by id (exact addresses, contacts, times)", async () => {
      for (const uid of [BIKE, BIKE2, NEWBIE, SUSP, TAXI]) {
        await assertFails(getDoc(doc(h.db(uid), "deliveries/open")), uid);
        await assertFails(getDoc(doc(h.db(uid), "gas_orders/open")), uid);
      }
    });

    it("PRV-02 no driver lists open orders, with or without filters", async () => {
      for (const uid of [BIKE, BIKE2]) {
        await assertFails(getDocs(query(collection(h.db(uid), "deliveries"),
          where("status", "==", "pending"), where("driverId", "==", null))));
        await assertFails(getDocs(query(collection(h.db(uid), "gas_orders"),
          where("status", "==", "pendingApproval"), where("driverId", "==", null))));
        await assertFails(getDocs(query(collection(h.db(uid), "deliveries"), limit(5))));
      }
    });

    it("PRV-03 no client reads private details, whoever asks (only the server copies them)", async () => {
      for (const uid of [BIKE, BIKE2, h.PAX, h.STRANGER, null]) {
        await assertFails(getDoc(doc(h.db(uid), "deliveries/open/private/details")), String(uid));
        await assertFails(getDoc(doc(h.db(uid), "deliveries/mine/private/details")), String(uid));
        await assertFails(getDoc(doc(h.db(uid), "gas_orders/open/private/details")), String(uid));
      }
    });

    it("PRV-04 completion codes stay the passenger's: no driver reads them, assigned or not", async () => {
      await assertFails(getDoc(doc(h.db(BIKE), "order_completion_codes/deliveries_open")));
      await assertFails(getDoc(doc(h.db(BIKE), "order_completion_codes/deliveries_mine")));
      await assertSucceeds(getDoc(doc(h.db(h.PAX), "order_completion_codes/deliveries_mine")));
    });
  });

  describe("offers", () => {
    it("PRV-10 active Delivery drivers read and list offers", async () => {
      for (const uid of [BIKE, BIKE2]) {
        await assertSucceeds(getDoc(doc(h.db(uid), "delivery_offers/open")));
        await assertSucceeds(getDocs(query(collection(h.db(uid), "delivery_offers"), limit(20))));
        await assertSucceeds(getDocs(query(collection(h.db(uid), "gas_order_offers"), limit(20))));
      }
    });

    it("PRV-11 Ride, unapproved and suspended drivers, passengers and signed-out users do not", async () => {
      for (const uid of [TAXI, NEWBIE, SUSP, h.PAX, h.STRANGER, null]) {
        await assertFails(getDoc(doc(h.db(uid), "delivery_offers/open")), String(uid));
        await assertFails(getDoc(doc(h.db(uid), "gas_order_offers/open")), String(uid));
      }
    });

    it("PRV-12 no client writes, creates or deletes an offer (admins included)", async () => {
      for (const uid of [BIKE, h.PAX, h.ADMIN]) {
        await assertFails(setDoc(doc(h.db(uid), "delivery_offers/forged"), offer()), uid);
        await assertFails(updateDoc(doc(h.db(uid), "delivery_offers/open"), { fare: 1 }), uid);
        await assertFails(deleteDoc(doc(h.db(uid), "gas_order_offers/open")), uid);
      }
    });
  });

  describe("assigned driver", () => {
    it("PRV-20 reads only the order assigned to them now", async () => {
      await assertSucceeds(getDoc(doc(h.db(BIKE), "deliveries/mine")));
      await assertSucceeds(getDoc(doc(h.db(BIKE), "gas_orders/mine")));
      await assertFails(getDoc(doc(h.db(BIKE), "deliveries/theirs")));
    });

    it("PRV-21 subscribes only to their own jobs (a query naming another driver is refused)", async () => {
      await assertSucceeds(getDocs(query(collection(h.db(BIKE), "deliveries"), where("driverId", "==", BIKE))));
      await assertFails(getDocs(query(collection(h.db(BIKE), "deliveries"), where("driverId", "==", BIKE2))));
    });

    it("PRV-22 reassignment revokes the previous driver at once", async () => {
      await h.env().withSecurityRulesDisabled((ctx) =>
        updateDoc(doc(ctx.firestore(), "deliveries/mine"), { driverId: BIKE2 }));
      await assertFails(getDoc(doc(h.db(BIKE), "deliveries/mine")));
      await assertSucceeds(getDoc(doc(h.db(BIKE2), "deliveries/mine")));
    });

    it("PRV-23 an admin reassignment is itself allowed; a party cannot reassign", async () => {
      await assertSucceeds(updateDoc(doc(h.db(h.ADMIN), "gas_orders/mine"), { driverId: BIKE2 }));
      await assertFails(getDoc(doc(h.db(BIKE), "gas_orders/mine")));
      await assertFails(updateDoc(doc(h.db(BIKE2), "gas_orders/mine"), { driverId: BIKE }));
      await assertFails(updateDoc(doc(h.db(h.PAX), "gas_orders/mine"), { driverId: BIKE }));
    });
  });

  describe("passenger", () => {
    it("PRV-30 reads own open and assigned orders and history (exact details)", async () => {
      await assertSucceeds(getDoc(doc(h.db(h.PAX), "deliveries/open")));
      await assertSucceeds(getDoc(doc(h.db(h.PAX), "gas_orders/mine")));
      await assertSucceeds(getDocs(query(collection(h.db(h.PAX), "deliveries"), where("passengerId", "==", h.PAX))));
      await assertSucceeds(getDocs(query(collection(h.db(h.PAX), "gas_orders"), where("passengerId", "==", h.PAX))));
    });

    it("PRV-31 another passenger reads nothing of it", async () => {
      await assertFails(getDoc(doc(h.db(h.STRANGER), "deliveries/open")));
      await assertFails(getDocs(query(collection(h.db(h.STRANGER), "deliveries"), where("passengerId", "==", h.PAX))));
    });
  });

  describe("Gas amounts after creation", () => {
    it("PRV-40 neither party changes the delivery fee, unit price, brand or service fee", async () => {
      for (const uid of [h.PAX, BIKE]) {
        for (const [k, v] of Object.entries({ deliveryFee: 30, gasPrice: 1, preferredBrand: "shell", serviceFee: 5 })) {
          await assertFails(updateDoc(doc(h.db(uid), "gas_orders/mine"), { [k]: v }), `${uid} ${k}`);
        }
      }
    });

    it("PRV-41 neither party writes verifiedPrice", async () => {
      for (const uid of [h.PAX, BIKE]) {
        await assertFails(updateDoc(doc(h.db(uid), "gas_orders/mine"),
          { verifiedPrice: { version: "gas-v2", total: 1, commission: 0, driverNet: 1 } }), uid);
      }
    });
  });

  describe("review round: subscriptions, notifications, ended and legacy orders", () => {
    it("PRV-50 a live listener of the previous driver is cut off when the job is reassigned", async () => {
      const ref = doc(h.db(BIKE), "deliveries/mine");
      const events = [];
      const errored = new Promise((resolve) => {
        const stop = onSnapshot(ref, () => events.push("data"), () => { stop(); resolve("denied"); });
      });
      await new Promise((r) => setTimeout(r, 500));
      assert.deepEqual(events, ["data"]);
      await h.env().withSecurityRulesDisabled((ctx) =>
        updateDoc(doc(ctx.firestore(), "deliveries/mine"), { driverId: BIKE2 }));
      assert.equal(await errored, "denied");
      assert.equal(await firstEvent(doc(h.db(BIKE), "deliveries/mine")), "denied", "no new listener either");
    });

    it("PRV-51 an unassigned driver cannot subscribe to an open order or the open-order query", async () => {
      assert.equal(await firstEvent(doc(h.db(BIKE2), "deliveries/open")), "denied");
      assert.equal(await firstEvent(doc(h.db(BIKE2), "gas_orders/open")), "denied");
      assert.equal(await firstEvent(query(collection(h.db(BIKE2), "deliveries"),
        where("status", "==", "pending"), where("driverId", "==", null))), "denied");
      assert.equal(await firstEvent(doc(h.db(BIKE2), "delivery_offers/open")), "data");
    });

    it("PRV-52 driver inboxes and passenger notifications are their owners' only", async () => {
      await h.env().withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `drivers/${BIKE}/notifications/n1`), { body: "Documents — Osu, Accra" });
        await setDoc(doc(ctx.firestore(), `notifications/${h.PAX}/items/n1`), { body: "x" });
      });
      await assertSucceeds(getDoc(doc(h.db(BIKE), `drivers/${BIKE}/notifications/n1`)));
      await assertFails(getDoc(doc(h.db(BIKE2), `drivers/${BIKE}/notifications/n1`)));
      await assertFails(getDoc(doc(h.db(BIKE), `notifications/${h.PAX}/items/n1`)));
    });

    it("PRV-53 cancellation before assignment leaves the order unreadable to every driver", async () => {
      await h.env().withSecurityRulesDisabled((ctx) =>
        updateDoc(doc(ctx.firestore(), "deliveries/open"), { status: "cancelled" }));
      for (const uid of [BIKE, BIKE2]) await assertFails(getDoc(doc(h.db(uid), "deliveries/open")));
    });

    it("PRV-54 a legacy open order (Passenger 1.0.0 shape, with deliveryOtp) is unreadable to unassigned drivers", async () => {
      await h.env().withSecurityRulesDisabled((ctx) =>
        setDoc(doc(ctx.firestore(), "deliveries/legacy"), delivery({ deliveryOtp: "1234" })));
      await assertFails(getDoc(doc(h.db(BIKE), "deliveries/legacy")));
    });

    it("PRV-K01 KNOWN: the driver still named on an ended order (completed, or cancelled after acceptance) keeps reading it", async () => {
      // History and earnings read the driver's own ended jobs (driver_jobs_repository.dart,
      // earning_screen.dart). Nothing new is revealed after the job; recorded for the review.
      await h.env().withSecurityRulesDisabled((ctx) =>
        updateDoc(doc(ctx.firestore(), "deliveries/mine"), { status: "cancelled" }));
      await assertSucceeds(getDoc(doc(h.db(BIKE), "deliveries/mine")));
    });

    it("PRV-K02 KNOWN: a legacy order carrying deliveryOtp exposes it to its assigned driver", async () => {
      await h.env().withSecurityRulesDisabled((ctx) =>
        setDoc(doc(ctx.firestore(), "deliveries/legacyMine"), delivery({ status: "driverAssigned", driverId: BIKE, deliveryOtp: "1234" })));
      const snap = await getDoc(doc(h.db(BIKE), "deliveries/legacyMine"));
      assert.equal(snap.data().deliveryOtp, "1234");
    });
  });

  describe("Delivery/Gas wallet switch document", () => {
    it("APC-01 app_config/payments: admins read it; no client writes it (owner console only)", async () => {
      await h.env().withSecurityRulesDisabled((ctx) =>
        setDoc(doc(ctx.firestore(), "app_config/payments"), { deliveryGasWalletEnabled: false }));
      await assertSucceeds(getDoc(doc(h.db(h.ADMIN), "app_config/payments")));
      for (const uid of [h.ADMIN, h.PAX, BIKE, null]) {
        await assertFails(setDoc(doc(h.db(uid), "app_config/payments"), { deliveryGasWalletEnabled: true }), String(uid));
        await assertFails(updateDoc(doc(h.db(uid), "app_config/payments"), { deliveryGasWalletEnabled: true }), String(uid));
      }
      for (const uid of [h.PAX, BIKE, null]) await assertFails(getDoc(doc(h.db(uid), "app_config/payments")), String(uid));
    });
  });

  describe("Delivery quotes (release v5 round 3)", () => {
    const quoteDoc = (o = {}) => ({ passengerId: h.PAX, pricingVersion: "delivery-v2", totalPesewas: 3000,
      distanceMeters: 10000, pickup: h.ACCRA, dropoff: h.ACCRA, usedBy: null, ...o });
    const create101 = (o = {}) => ({ ...delivery({ createdAt: Timestamp.now() }), deliveryQuoteId: "q1", ...o });

    it("QTE-01 a customer reads only their own quotes; nobody writes one", async () => {
      await h.env().withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), "delivery_quotes/q1"), quoteDoc());
        await setDoc(doc(ctx.firestore(), "delivery_quotes/q2"), quoteDoc({ passengerId: h.STRANGER }));
      });
      await assertSucceeds(getDoc(doc(h.db(h.PAX), "delivery_quotes/q1")));
      await assertFails(getDoc(doc(h.db(h.PAX), "delivery_quotes/q2")));
      for (const uid of [BIKE, TAXI, null]) await assertFails(getDoc(doc(h.db(uid), "delivery_quotes/q1")), String(uid));
      for (const uid of [h.PAX, BIKE, h.ADMIN]) {
        await assertFails(setDoc(doc(h.db(uid), "delivery_quotes/forged"), quoteDoc()), uid);
        await assertFails(updateDoc(doc(h.db(uid), "delivery_quotes/q1"), { totalPesewas: 1 }), uid);
        await assertFails(updateDoc(doc(h.db(uid), "delivery_quotes/q1"), { usedBy: "x" }), uid);
      }
    });

    it("QTE-02 a new delivery must name its quote (3b); a number or missing id is refused", async () => {
      const r = doc(h.db(h.PAX), "deliveries/n1");
      await assertSucceeds(setDoc(r, create101()));
      const noQuote = create101(); delete noQuote.deliveryQuoteId;
      await assertFails(setDoc(doc(h.db(h.PAX), "deliveries/n2"), noQuote));
      await assertFails(setDoc(doc(h.db(h.PAX), "deliveries/n3"), create101({ deliveryQuoteId: 7 })));
      await assertFails(setDoc(doc(h.db(h.PAX), "deliveries/n4"), create101({ verifiedPrice: { version: "delivery-v2" } })));
    });

    it("QTE-03 after creation no party moves the endpoints or swaps the quote", async () => {
      for (const uid of [h.PAX, BIKE]) {
        const elsewhere = new GeoPoint(5.7, -0.2);
        for (const [k, v] of Object.entries({ pickupLocation: elsewhere, dropoffLocation: elsewhere,
          deliveryQuoteId: "q-other" })) {
          await assertFails(updateDoc(doc(h.db(uid), "deliveries/mine"), { [k]: v }), `${uid} ${k}`);
        }
      }
      await assertSucceeds(updateDoc(doc(h.db(h.PAX), "deliveries/mine"), { passengerRating: 5 }), "other writes still work");
    });

    it("QTE-04 app_config/pricing (rollout switch) is admin-read and never client-written", async () => {
      await assertFails(setDoc(doc(h.db(h.ADMIN), "app_config/pricing"), { legacyUnquotedDeliveries: true }));
      await assertFails(getDoc(doc(h.db(h.PAX), "app_config/pricing")));
      await assertSucceeds(getDoc(doc(h.db(h.ADMIN), "app_config/pricing")));
    });
  });
});
