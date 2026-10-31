// Policy A (approved/suspended drivers cannot change role, ride type or
// vehicle type) and delivery/gas confirmation-code integrity.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const { doc, setDoc, updateDoc, serverTimestamp, GeoPoint } = require("firebase/firestore");
const h = require("./helpers");

const ACCRA = new GeoPoint(5.6037, -0.187);
const SUS_ADMIN = "drvSusAdmin"; // suspended exactly as the Admin app does it
const DEL = "drvDel";
const PROTECTED = {
  role: "driver_delivery",
  serviceType: "okada",
  vehicleType: "miniTruck",
};

const drv = (uid, id = uid) => doc(h.db(uid), `drivers/${id}`);

async function seedExtra() {
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    const put = (p, d) => setDoc(doc(fs, p), d);
    await put(`drivers/${SUS_ADMIN}`, {
      uid: SUS_ADMIN, role: "driver_hailing", serviceType: "taxi",
      vehicleType: "taxi", isApproved: false, signupStep: "suspended",
      isOnline: false, isAvailable: false,
    });
    await put(`drivers/${DEL}`, {
      uid: DEL, role: "driver_delivery", serviceType: "delivery",
      vehicleType: "motorcycle", isApproved: true, signupStep: "approved",
      isOnline: true, isAvailable: true, location: ACCRA,
    });
    // The shared seed's approved driver has no vehicleType; give it one.
    await setDoc(doc(fs, `drivers/${h.DRIVER}`), { vehicleType: "taxi" }, { merge: true });
    const order = (o) => ({
      passengerId: h.PAX, driverId: DEL, status: "driverAssigned",
      deliveryOtp: "1234", estimatedFare: 20, totalPrice: 50, ...o,
    });
    await put("deliveries/d1", order({}));
    await put("gas_orders/g1", order({ status: "returning" }));
  });
}

describe("Policy A: eligibility fields", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => { await h.seed(); await seedExtra(); });

  for (const [field, value] of Object.entries(PROTECTED)) {
    it(`ELG-S-${field} approved driver cannot change ${field}`, () =>
      assertFails(updateDoc(drv(h.DRIVER), { [field]: value })));

    it(`ELG-S-${field}-sus suspended driver cannot change ${field}`, async () => {
      await assertFails(updateDoc(drv(SUS_ADMIN), { [field]: value }));
      await assertFails(updateDoc(drv(h.SUSPENDED_DRIVER), { [field]: value }));
    });

    it(`ELG-P-${field} unapproved (onboarding) driver can set ${field}`, () =>
      assertSucceeds(updateDoc(drv(h.NEW_DRIVER), { [field]: value })));

    it(`ELG-P-${field}-admin admin can change ${field} for an approved driver`, () =>
      assertSucceeds(updateDoc(doc(h.db(h.ADMIN), `drivers/${h.DRIVER}`), { [field]: value })));
  }

  it("ELG-S-combo approved driver cannot sneak a change in with other fields", () =>
    assertFails(updateDoc(drv(h.DRIVER), {
      displayName: "New name", serviceType: "okada", updatedAt: serverTimestamp(),
    })));

  // driver_vehicle_setup_screen.dart writes all three; re-saving the same
  // values (as an approved driver revisiting the screen would) is allowed.
  it("ELG-P-same released vehicle-setup write with unchanged values still works", () =>
    assertSucceeds(updateDoc(drv(h.DRIVER), {
      role: "driver_hailing",
      vehicleType: "taxi",
      serviceType: "taxi",
      vehicleSetupComplete: true,
      updatedAt: serverTimestamp(),
    })));

  it("ELG-P-profile approved driver still updates unrelated profile fields", () =>
    assertSucceeds(updateDoc(drv(h.DRIVER), {
      displayName: "New name", vehicleModel: "Toyota Vitz", vehiclePlate: "GR-1-24",
      photoUrl: "https://x/p.jpg", updatedAt: serverTimestamp(),
    })));

  it("ELG-P-docs approved driver still uploads documents", () =>
    assertSucceeds(setDoc(drv(h.DRIVER), {
      documents: {
        insurance: { status: "uploaded", url: "https://x/i.jpg", fileType: "image",
          uploadedAt: serverTimestamp() },
      },
    }, { merge: true })));

  it("ELG-P-online approved driver still goes online and offline", () =>
    assertSucceeds(updateDoc(drv(h.DRIVER), {
      isOnline: false, isAvailable: false, lastStatusChange: serverTimestamp(),
    })));
});

describe("confirmation codes (deliveryOtp)", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => { await h.seed(); await seedExtra(); });

  it("OTP-P01 driver completes a delivery with the recipient's code (released write)", () =>
    assertSucceeds(updateDoc(doc(h.db(DEL), "deliveries/d1"), {
      status: "completed", otpSubmitted: "1234", otpVerifiedAt: serverTimestamp(),
      completedAt: serverTimestamp(), actualFare: 20,
    })));

  it("OTP-P02 driver marks a gas order delivered with the code (released write)", () =>
    assertSucceeds(updateDoc(doc(h.db(DEL), "gas_orders/g1"), {
      status: "delivered", otpSubmitted: "1234", otpVerifiedAt: serverTimestamp(),
      deliveredAt: serverTimestamp(), actualFare: 50,
    })));

  it("OTP-S01 assigned driver cannot rewrite the delivery code", async () => {
    await assertFails(updateDoc(doc(h.db(DEL), "deliveries/d1"), { deliveryOtp: "0000" }));
    await assertFails(updateDoc(doc(h.db(DEL), "deliveries/d1"), {
      deliveryOtp: "0000", otpSubmitted: "0000", status: "completed",
    }));
  });

  it("OTP-S02 assigned driver cannot rewrite the gas code", async () => {
    await assertFails(updateDoc(doc(h.db(DEL), "gas_orders/g1"), { deliveryOtp: "0000" }));
    await assertFails(updateDoc(doc(h.db(DEL), "gas_orders/g1"), {
      deliveryOtp: "0000", otpSubmitted: "0000", status: "delivered",
    }));
  });

  it("OTP-S03 passenger cannot rewrite or remove the code either", async () => {
    await assertFails(updateDoc(doc(h.db(h.PAX), "deliveries/d1"), { deliveryOtp: "9999" }));
    await assertFails(updateDoc(doc(h.db(h.PAX), "gas_orders/g1"), { deliveryOtp: null }));
  });

  it("OTP-P03 admin can still correct a code", () =>
    assertSucceeds(updateDoc(doc(h.db(h.ADMIN), "deliveries/d1"), { deliveryOtp: "5555" })));
});
