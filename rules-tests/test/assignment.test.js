// Trip assignment integrity (TRIP-S06/S14/S15/S18/S19/S20) and driver
// approval/suspension integrity (DRV-S04), plus the released apps' writes
// that must keep working. Payloads mirror the committed app code.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  doc,
  setDoc,
  updateDoc,
  runTransaction,
  deleteField,
  serverTimestamp,
  GeoPoint,
} = require("firebase/firestore");
const h = require("./helpers");

const trip = (uid, id) => doc(h.db(uid), `trips/${id}`);
const drv = (uid, id = uid) => doc(h.db(uid), `drivers/${id}`);

// requests_section.dart accept: transaction on the trip, then mark busy.
const acceptPayload = (uid) => ({
  driverId: uid,
  driverName: `Driver ${uid}`,
  driverPhone: "+233200000000",
  driverRating: 4.8,
  driverPlate: "GR-1234-24",
  status: "tripAccepted",
  acceptedAt: serverTimestamp(),
});

function acceptTx(uid, id = "searching") {
  const db = h.db(uid);
  const ref = doc(db, `trips/${id}`);
  return runTransaction(db, async (tx) => {
    const snap = await tx.get(ref);
    if (snap.data().status !== "searching" || snap.data().driverId != null) {
      throw new Error("taken");
    }
    tx.update(ref, acceptPayload(uid));
  });
}

async function seedExtra() {
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    const fs = ctx.firestore();
    await setDoc(doc(fs, "trips/timedOut"), {
      ...h.newTripPayload({ status: "noDriversAvailable" }),
      createdAt: null,
    });
    // As the Admin app suspends (drivers/page.tsx): approval removed too.
    await setDoc(doc(fs, "drivers/drvSusAdmin"), {
      uid: "drvSusAdmin", role: "driver_hailing", isApproved: false,
      isOnline: false, isAvailable: false, signupStep: "suspended",
      serviceType: "taxi",
    });
    await setDoc(doc(fs, "drivers/drvRej"), {
      uid: "drvRej", role: "driver_hailing", isApproved: false,
      signupStep: "rejected", serviceType: "taxi",
    });
  });
}

describe("trip assignment integrity", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await seedExtra();
  });

  // ── Must keep working (released apps) ─────────────────────────────────
  it("ASG-P01 approved driver accepts via the app's transaction", () =>
    assertSucceeds(acceptTx(h.OTHER_DRIVER)));

  it("ASG-P02 passenger cancels while searching", () =>
    assertSucceeds(
      updateDoc(trip(h.PAX, "searching"), {
        status: "cancelledByPassenger",
        cancelledAt: serverTimestamp(),
      }),
    ));

  it("ASG-P03 assigned driver streams location to the trip", () =>
    assertSucceeds(
      updateDoc(trip(h.DRIVER, "assigned"), {
        driverCurrentLocation: new GeoPoint(5.6, -0.18),
        driverHeading: 90,
        lastLocationUpdate: serverTimestamp(),
      }),
    ));

  it("ASG-P04 assigned driver cancels and is released in one transaction", () => {
    const db = h.db(h.DRIVER);
    return assertSucceeds(
      runTransaction(db, async (tx) => {
        tx.update(doc(db, "trips/assigned"), {
          status: "cancelledByDriver",
          cancelledAt: serverTimestamp(),
        });
        tx.update(doc(db, `drivers/${h.DRIVER}`), {
          isAvailable: true,
          currentTripId: deleteField(),
        });
      }),
    );
  });

  it("ASG-P05 assigned driver completes the trip", () =>
    assertSucceeds(
      updateDoc(trip(h.DRIVER, "started"), {
        status: "completed",
        completedAt: serverTimestamp(),
      }),
    ));

  // ── Must be denied ────────────────────────────────────────────────────
  it("ASG-S01 a passenger account cannot claim a trip", () =>
    assertFails(acceptTx(h.STRANGER)));

  it("ASG-S02 the trip's own passenger cannot claim it", () =>
    assertFails(updateDoc(trip(h.PAX, "searching"), acceptPayload(h.PAX))));

  it("ASG-S03 an unapproved driver cannot claim", () =>
    assertFails(acceptTx(h.NEW_DRIVER)));

  it("ASG-S04 a suspended driver cannot claim", () =>
    assertFails(acceptTx(h.SUSPENDED_DRIVER)));

  it("ASG-S05 a driver cannot claim a trip for someone else", () =>
    assertFails(
      updateDoc(trip(h.OTHER_DRIVER, "searching"), {
        ...acceptPayload(h.OTHER_DRIVER),
        driverId: h.DRIVER,
      }),
    ));

  it("ASG-S06 a driver cannot claim a trip that is no longer searching", () =>
    assertFails(
      updateDoc(trip(h.OTHER_DRIVER, "timedOut"), acceptPayload(h.OTHER_DRIVER)),
    ));

  it("ASG-S07 a claim must set status to tripAccepted", () =>
    assertFails(
      updateDoc(trip(h.OTHER_DRIVER, "searching"), {
        ...acceptPayload(h.OTHER_DRIVER),
        status: "completed",
      }),
    ));

  it("ASG-S08 a claim cannot touch fare or settlement fields", async () => {
    await assertFails(
      updateDoc(trip(h.OTHER_DRIVER, "searching"), {
        ...acceptPayload(h.OTHER_DRIVER),
        estimatedFare: 500,
      }),
    );
    await assertFails(
      updateDoc(trip(h.OTHER_DRIVER, "searching"), {
        ...acceptPayload(h.OTHER_DRIVER),
        walletProcessed: true,
      }),
    );
  });

  it("ASG-S09 an assigned trip cannot be re-claimed by another driver", () =>
    assertFails(
      updateDoc(trip(h.OTHER_DRIVER, "assigned"), acceptPayload(h.OTHER_DRIVER)),
    ));

  it("ASG-S10 passenger cannot assign or unassign a driver", async () => {
    await assertFails(updateDoc(trip(h.PAX, "searching"), { driverId: h.DRIVER }));
    await assertFails(updateDoc(trip(h.PAX, "assigned"), { driverId: null }));
  });

  it("ASG-S11 assigned driver cannot hand off, drop, or change the passenger", async () => {
    await assertFails(updateDoc(trip(h.DRIVER, "assigned"), { driverId: h.OTHER_DRIVER }));
    await assertFails(updateDoc(trip(h.DRIVER, "assigned"), { driverId: null }));
    await assertFails(updateDoc(trip(h.DRIVER, "assigned"), { passengerId: h.DRIVER }));
  });

  it("ASG-S12 signed-out users cannot claim", () =>
    assertFails(updateDoc(trip(null, "searching"), acceptPayload("x"))));
});

describe("driver approval and suspension integrity (DRV-S04)", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await seedExtra();
  });

  // ── Must keep working ─────────────────────────────────────────────────
  it("APR-P01 onboarding steps still advance (vehicle setup)", () =>
    assertSucceeds(
      updateDoc(drv(h.NEW_DRIVER), {
        vehicleType: "taxi",
        serviceType: "taxi",
        vehicleSetupComplete: true,
        signupStep: "vehicleSetup",
        updatedAt: serverTimestamp(),
      }),
    ));

  // Mirrors driver_documents_screens.dart: merge-upload one document, then
  // the submit step.
  it("APR-P02 approved driver can re-upload documents", async () => {
    await assertSucceeds(
      setDoc(drv(h.DRIVER), {
        documents: {
          drivers_license: {
            status: "uploaded", url: "https://x/u.jpg", fileType: "image",
            uploadedAt: serverTimestamp(),
          },
        },
      }, { merge: true }),
    );
    await assertSucceeds(
      updateDoc(drv(h.DRIVER), {
        documentsUploaded: true,
        signupStep: "documentsUploaded",
        submittedForReviewAt: serverTimestamp(),
      }),
    );
  });

  it("APR-P03 suspended driver can still go offline", () =>
    assertSucceeds(
      updateDoc(drv(h.SUSPENDED_DRIVER), {
        isOnline: false,
        isAvailable: false,
        lastStatusChange: serverTimestamp(),
      }),
    ));

  // ── Must be denied ────────────────────────────────────────────────────
  it("APR-S01 suspended driver cannot change signupStep at all", async () => {
    await assertFails(updateDoc(drv(h.SUSPENDED_DRIVER), { signupStep: "approved" }));
    await assertFails(updateDoc(drv(h.SUSPENDED_DRIVER), { signupStep: "vehicleSetup" }));
  });

  it("APR-S02 rejected driver cannot reset their signupStep", () =>
    assertFails(updateDoc(drv("drvRej"), { signupStep: "documentsUploaded" })));

  it("APR-S03 no driver can set an admin signupStep", async () => {
    for (const step of ["approved", "suspended", "rejected"]) {
      await assertFails(updateDoc(drv(h.NEW_DRIVER), { signupStep: step }));
    }
  });

  it("APR-S04 no driver can set approval fields", async () => {
    await assertFails(updateDoc(drv(h.NEW_DRIVER), { isApproved: true }));
    await assertFails(updateDoc(drv("drvSusAdmin"), { isApproved: true }));
    await assertFails(
      updateDoc(drv("drvSusAdmin"), { isApproved: true, signupStep: "approved" }),
    );
    await assertFails(updateDoc(drv(h.NEW_DRIVER), { isRejected: false }));
    await assertFails(updateDoc(drv(h.NEW_DRIVER), { approvedAt: serverTimestamp() }));
  });

  it("APR-S05 suspended driver cannot read open requests or claim", async () => {
    await assertFails(acceptTx(h.SUSPENDED_DRIVER));
  });
});
