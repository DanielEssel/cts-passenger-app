// Role escalation through profile documents (USR-*).
//
// users/{uid} used to allow any owner write, so a passenger could set its
// own role (or any other field). Owners may now only write the fields the
// Passenger app writes, and role only ever as 'passenger'. drivers/{uid}
// already locked approval and suspension; role is now limited to the
// driver roles, even before approval. Admins and Cloud Functions (Admin
// SDK, which bypasses rules) keep full control.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  doc, setDoc, updateDoc, deleteField, serverTimestamp,
} = require("firebase/firestore");
const h = require("./helpers");

const PAX_PHONE = "+233240000001";
const NEW_PAX = "paxNew";
const NEW_PAX_PHONE = "+233240000077";

// A signed-in user as the Passenger app sees them: phone-auth token.
function as(uid, phone) {
  return h.env().authenticatedContext(uid, phone ? { phone_number: phone } : {}).firestore();
}
const user = (fs, uid) => doc(fs, `users/${uid}`);
const driver = (fs, uid) => doc(fs, `drivers/${uid}`);

// FirestorePassengerAccountStore.createPassenger (passenger app).
function newPassengerProfile(uid, phone, o = {}) {
  return {
    uid,
    firstName: "Ama",
    lastName: "Mensah",
    displayName: "Ama Mensah",
    phoneNumber: phone,
    email: null,
    role: "passenger",
    hasSeenWelcome: false,
    termsAcceptedAt: serverTimestamp(),
    createdAt: serverTimestamp(),
    termsVersion: "1.0",
    lastLoginAt: serverTimestamp(),
    ...o,
  };
}

describe("users/{uid} and drivers/{uid}: role escalation (USR)", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(h.seed);

  describe("security: a passenger cannot change its role", () => {
    const pax = () => user(as(h.PAX, PAX_PHONE), h.PAX);

    it("USR-S01 passenger → driver is refused", async () => {
      await assertFails(updateDoc(pax(), { role: "driver_hailing" }));
      await assertFails(updateDoc(pax(), { role: "driver_delivery" }));
      await assertFails(updateDoc(pax(), { role: "driver" }));
    });

    it("USR-S02 passenger → admin is refused", async () => {
      await assertFails(updateDoc(pax(), { role: "admin" }));
      await assertFails(updateDoc(pax(), { role: "super_admin" }));
    });

    it("USR-S03 the role cannot be removed or nulled", async () => {
      await assertFails(updateDoc(pax(), { role: deleteField() }));
      await assertFails(updateDoc(pax(), { role: null }));
    });

    it("USR-S04 a role change hidden in a legitimate edit is refused", () =>
      assertFails(updateDoc(pax(), { firstName: "Ama", role: "admin" })));

    it("USR-S05 privileged or unknown fields cannot be added", async () => {
      for (const field of [
        { isAdmin: true }, { isApproved: true }, { isSuspended: false },
        { permissions: ["all"] }, { walletBalance: 5000 }, { rating: 5 },
        { signupStep: "approved" }, { claims: { admin: true } },
      ]) {
        await assertFails(updateDoc(pax(), field));
      }
    });

    it("USR-S06 a deactivated account cannot reactivate itself", async () => {
      await h.env().withSecurityRulesDisabled((ctx) =>
        updateDoc(doc(ctx.firestore(), `users/${h.PAX}`), { isDeactivated: true }));
      await assertFails(updateDoc(pax(), { isDeactivated: false }));
      await assertFails(updateDoc(pax(), { isDeactivated: deleteField() }));
    });

    it("USR-S07 the phone number can't be swapped for another one", () =>
      assertFails(updateDoc(pax(), { phoneNumber: "+233209999999" })));

    it("USR-S08 nobody else's profile can be written", async () => {
      await assertFails(updateDoc(user(as(h.STRANGER, "+233240000002"), h.PAX),
        { firstName: "X" }));
      await assertFails(updateDoc(user(as(h.DRIVER), h.PAX), { role: "driver_hailing" }));
    });

    it("USR-S09 a passenger cannot make itself an admin record", async () => {
      await assertFails(setDoc(doc(as(h.PAX, PAX_PHONE), `admins/${h.PAX}`),
        { active: true, role: "super_admin" }));
    });
  });

  describe("security: creating a profile with another role", () => {
    it("USR-S10 a new profile can't be created as a driver or admin", async () => {
      const fs = as(NEW_PAX, NEW_PAX_PHONE);
      for (const role of ["driver_hailing", "driver_delivery", "admin", "super_admin", null]) {
        await assertFails(setDoc(user(fs, NEW_PAX),
          newPassengerProfile(NEW_PAX, NEW_PAX_PHONE, { role })));
      }
    });

    it("USR-S11 a new profile can't carry privileged fields", async () => {
      const fs = as(NEW_PAX, NEW_PAX_PHONE);
      await assertFails(setDoc(user(fs, NEW_PAX),
        newPassengerProfile(NEW_PAX, NEW_PAX_PHONE, { isAdmin: true })));
      await assertFails(setDoc(user(fs, NEW_PAX),
        newPassengerProfile(NEW_PAX, NEW_PAX_PHONE, { walletBalance: 100 })));
    });

    it("USR-S12 a new profile must use the verified phone number and uid", async () => {
      const fs = as(NEW_PAX, NEW_PAX_PHONE);
      await assertFails(setDoc(user(fs, NEW_PAX),
        newPassengerProfile(NEW_PAX, "+233209999999")));
      await assertFails(setDoc(user(fs, NEW_PAX),
        newPassengerProfile("someone-else", NEW_PAX_PHONE)));
    });

    it("USR-S13 a role-less stub can only become a passenger", async () => {
      await h.env().withSecurityRulesDisabled((ctx) =>
        setDoc(doc(ctx.firestore(), `users/${NEW_PAX}`), { fcmToken: "t" }));
      await assertFails(updateDoc(user(as(NEW_PAX, NEW_PAX_PHONE), NEW_PAX),
        { role: "admin" }));
      await assertFails(updateDoc(user(as(NEW_PAX, NEW_PAX_PHONE), NEW_PAX),
        { role: "driver_hailing" }));
    });
  });

  describe("security: a driver cannot change its role or approval", () => {
    const approved = () => driver(as(h.DRIVER), h.DRIVER);
    const onboarding = () => driver(as(h.NEW_DRIVER), h.NEW_DRIVER);

    it("USR-S14 approved driver → admin is refused", async () => {
      await assertFails(updateDoc(approved(), { role: "admin" }));
      await assertFails(updateDoc(approved(), { role: "super_admin" }));
    });

    it("USR-S15 an onboarding (unapproved) driver cannot pick a non-driver role", async () => {
      for (const role of ["admin", "super_admin", "passenger", "driver", "owner"]) {
        await assertFails(updateDoc(onboarding(), { role }));
      }
    });

    it("USR-S16 a new driver profile cannot be created with a non-driver role", async () => {
      const fs = as("drvFresh");
      await assertFails(setDoc(driver(fs, "drvFresh"), {
        uid: "drvFresh", role: "admin", isApproved: false,
      }));
    });

    it("USR-S17 approval and suspension fields stay admin-only", async () => {
      await assertFails(updateDoc(onboarding(), { isApproved: true }));
      await assertFails(updateDoc(onboarding(), { signupStep: "approved" }));
      await assertFails(updateDoc(driver(as(h.SUSPENDED_DRIVER), h.SUSPENDED_DRIVER),
        { signupStep: "documents" }));
      await assertFails(updateDoc(driver(as(h.SUSPENDED_DRIVER), h.SUSPENDED_DRIVER),
        { isApproved: true, signupStep: "approved" }));
      await assertFails(updateDoc(approved(), { signupStep: "rejected" }));
    });

    it("USR-S18 a driver cannot write a passenger profile with a driver or admin role", async () => {
      const fs = as(h.DRIVER, "+233200000000");
      await assertFails(setDoc(user(fs, h.DRIVER),
        newPassengerProfile(h.DRIVER, "+233200000000", { role: "driver_hailing" })));
      await assertFails(setDoc(user(fs, h.DRIVER),
        newPassengerProfile(h.DRIVER, "+233200000000", { role: "admin" })));
    });
  });

  describe("app behaviour (must keep working)", () => {
    it("USR-P01 sign-up creates the passenger profile", () =>
      assertSucceeds(setDoc(user(as(NEW_PAX, NEW_PAX_PHONE), NEW_PAX),
        newPassengerProfile(NEW_PAX, NEW_PAX_PHONE), { merge: true })));

    it("USR-P02 an older build's token-only stub, then its completion", async () => {
      const fs = as(NEW_PAX, NEW_PAX_PHONE);
      await assertSucceeds(setDoc(user(fs, NEW_PAX), {
        fcmToken: "t", fcmTokenUpdatedAt: serverTimestamp(), platform: "android",
      }, { merge: true }));
      await assertSucceeds(setDoc(user(fs, NEW_PAX),
        newPassengerProfile(NEW_PAX, NEW_PAX_PHONE), { merge: true }));
    });

    it("USR-P03 login stamps lastLoginAt; welcome flag; preferences", async () => {
      const fs = as(h.PAX, PAX_PHONE);
      await assertSucceeds(updateDoc(user(fs, h.PAX), { lastLoginAt: serverTimestamp() }));
      await assertSucceeds(updateDoc(user(fs, h.PAX), { hasSeenWelcome: true }));
      await assertSucceeds(updateDoc(user(fs, h.PAX), { biometricsEnabled: true }));
      await assertSucceeds(updateDoc(user(fs, h.PAX), { marketingEmails: false }));
    });

    it("USR-P04 edit profile: names, email, photo", async () => {
      const fs = as(h.PAX, PAX_PHONE);
      await assertSucceeds(updateDoc(user(fs, h.PAX), {
        firstName: "Ama", lastName: "Owusu", displayName: "Ama Owusu",
        email: "ama@example.com", photoURL: "https://example.com/p.jpg",
        updatedAt: serverTimestamp(),
      }));
      await assertSucceeds(updateDoc(user(fs, h.PAX), { photoURL: deleteField() }));
    });

    it("USR-P05 push token saved and cleared", async () => {
      const fs = as(h.PAX, PAX_PHONE);
      await assertSucceeds(updateDoc(user(fs, h.PAX), {
        fcmToken: "t", fcmTokenUpdatedAt: serverTimestamp(), platform: "android",
      }));
      await assertSucceeds(updateDoc(user(fs, h.PAX), {
        fcmToken: deleteField(), fcmTokenUpdatedAt: serverTimestamp(),
      }));
    });

    it("USR-P06 deactivation and deletion requests", async () => {
      const fs = as(h.PAX, PAX_PHONE);
      await assertSucceeds(updateDoc(user(fs, h.PAX), {
        isDeactivated: true, deletionRequestedAt: serverTimestamp(),
      }));
      await assertSucceeds(updateDoc(user(fs, h.PAX), {
        isDeactivated: true, deactivatedAt: serverTimestamp(),
      }));
    });

    it("USR-P07 re-writing the same role (sign-up merge) is not a change", () =>
      assertSucceeds(setDoc(user(as(h.PAX, PAX_PHONE), h.PAX),
        { role: "passenger", lastLoginAt: serverTimestamp() }, { merge: true })));

    it("USR-P08 a new driver picks a driver role", async () => {
      await assertSucceeds(updateDoc(driver(as(h.NEW_DRIVER), h.NEW_DRIVER),
        { role: "driver_delivery" }));
      await assertSucceeds(updateDoc(driver(as(h.NEW_DRIVER), h.NEW_DRIVER),
        { role: "driver_hailing" }));
    });

    it("USR-P09 an approved driver's other updates are unaffected", () =>
      assertSucceeds(updateDoc(driver(as(h.DRIVER), h.DRIVER),
        { isOnline: false, isAvailable: false, lastStatusChange: serverTimestamp() })));
  });

  describe("admin and server (must keep working)", () => {
    const adminFs = () => as(h.ADMIN);

    it("USR-A01 an admin can change a user's role and protected fields", async () => {
      await assertSucceeds(updateDoc(user(adminFs(), h.PAX), { role: "driver_hailing" }));
      await assertSucceeds(updateDoc(user(adminFs(), h.STRANGER),
        { isDeactivated: false, isSuspended: true }));
    });

    it("USR-A02 an admin approves, suspends and changes a driver's role", async () => {
      await assertSucceeds(updateDoc(driver(adminFs(), h.NEW_DRIVER),
        { isApproved: true, signupStep: "approved" }));
      await assertSucceeds(updateDoc(driver(adminFs(), h.DRIVER),
        { signupStep: "suspended", isApproved: false, isAvailable: false, isOnline: false }));
      await assertSucceeds(updateDoc(driver(adminFs(), h.OTHER_DRIVER),
        { role: "driver_delivery" }));
    });

    it("USR-A03 Cloud Functions (Admin SDK) are not subject to these rules", () =>
      h.env().withSecurityRulesDisabled((ctx) =>
        assertSucceeds(updateDoc(doc(ctx.firestore(), `users/${h.PAX}`),
          { role: "passenger", rating: 4.9 }))));
  });
});
