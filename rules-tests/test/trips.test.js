// Trip document rules.
//
// "security" tests assert what a client must NOT be able to do.
// "app behaviour" tests replay the exact writes the passenger and driver apps
// make today, so tightening the rules later cannot silently break them.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  doc,
  setDoc,
  updateDoc,
  writeBatch,
  deleteField,
  serverTimestamp,
  GeoPoint,
} = require("firebase/firestore");
const h = require("./helpers");

const trip = (uid, id) => doc(h.db(uid), `trips/${id}`);

describe("trips", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(h.seed);

  describe("security: passenger", () => {
    it("TRIP-S01 cannot change the fare after creating the trip", () =>
      assertFails(updateDoc(trip(h.PAX, "searching"), { estimatedFare: 1 })));

    it("TRIP-S02 cannot swap the escrow attached to the trip", () =>
      assertFails(updateDoc(trip(h.PAX, "assigned"), { escrowId: "someOtherEscrow" })));

    it("TRIP-S03 cannot mark settlement as done", () =>
      assertFails(
        updateDoc(trip(h.PAX, "completed"), {
          walletProcessed: true,
          settlementStatus: "completed",
        }),
      ));

    it("TRIP-S04 cannot mark an assigned trip completed", () =>
      assertFails(updateDoc(trip(h.PAX, "assigned"), { status: "completed" })));

    it("TRIP-S05 cannot cancel a trip that is already completed", () =>
      assertFails(
        updateDoc(trip(h.PAX, "completed"), {
          status: "cancelledByPassenger",
          cancelledAt: serverTimestamp(),
        }),
      ));

    it("TRIP-S06 cannot assign a driver to their own trip", () =>
      assertFails(updateDoc(trip(h.PAX, "searching"), { driverId: h.DRIVER })));

    it("TRIP-S07 cannot create a trip that is already completed with a driver", () =>
      assertFails(
        setDoc(
          trip(h.PAX, "forged"),
          h.newTripPayload({
            status: "completed",
            driverId: h.DRIVER,
            paymentMethod: "cash",
          }),
        ),
      ));

    it("TRIP-S08 cannot create a trip with settlement fields preset", () =>
      assertFails(
        setDoc(
          trip(h.PAX, "forged2"),
          h.newTripPayload({ walletProcessed: true, actualFare: 0.01 }),
        ),
      ));

    it("TRIP-S09 cannot create a trip on behalf of another passenger", () =>
      assertFails(
        setDoc(trip(h.STRANGER, "forged3"), h.newTripPayload({ passengerId: h.PAX })),
      ));

    it("TRIP-S10 cannot update someone else's trip", () =>
      assertFails(
        updateDoc(trip(h.STRANGER, "searching"), { status: "cancelledByPassenger" }),
      ));
  });

  describe("security: driver", () => {
    it("TRIP-S11 assigned driver cannot change the fare", () =>
      assertFails(
        updateDoc(trip(h.DRIVER, "started"), { actualFare: 999, estimatedFare: 999 }),
      ));

    it("TRIP-S12 assigned driver cannot inflate the trip distance", () =>
      assertFails(updateDoc(trip(h.DRIVER, "started"), { actualDistanceKm: 500 })));

    it("TRIP-S13 assigned driver cannot confirm on the passenger's behalf", () =>
      assertFails(
        updateDoc(trip(h.DRIVER, "completed"), {
          passengerConfirmed: true,
          passengerConfirmedAt: serverTimestamp(),
        }),
      ));

    it("TRIP-S14 assigned driver cannot hand the trip to another driver", () =>
      assertFails(updateDoc(trip(h.DRIVER, "assigned"), { driverId: h.OTHER_DRIVER })));

    it("TRIP-S15 assigned driver cannot change who the passenger is", () =>
      assertFails(updateDoc(trip(h.DRIVER, "assigned"), { passengerId: h.DRIVER })));

    it("TRIP-S16 assigned driver cannot mark settlement as done", () =>
      assertFails(updateDoc(trip(h.DRIVER, "completed"), { walletProcessed: true })));

    it("TRIP-S17 a driver who is not assigned cannot update the trip", () =>
      assertFails(
        updateDoc(trip(h.OTHER_DRIVER, "assigned"), { status: "cancelledByDriver" }),
      ));

    it("TRIP-S18 a passenger account (no driver profile) cannot claim a trip", () =>
      assertFails(
        updateDoc(trip(h.STRANGER, "searching"), {
          driverId: h.STRANGER,
          status: "tripAccepted",
        }),
      ));

    it("TRIP-S19 an unapproved driver cannot claim a trip", () =>
      assertFails(
        updateDoc(trip(h.NEW_DRIVER, "searching"), {
          driverId: h.NEW_DRIVER,
          status: "tripAccepted",
        }),
      ));

    it("TRIP-S20 a claiming driver cannot change the fare while claiming", () =>
      assertFails(
        updateDoc(trip(h.OTHER_DRIVER, "searching"), {
          driverId: h.OTHER_DRIVER,
          status: "tripAccepted",
          estimatedFare: 500,
        }),
      ));
  });

  describe("app behaviour: passenger (must keep working)", () => {
    it("TRIP-P01 creates a trip with the app's payload", () =>
      assertSucceeds(setDoc(trip(h.PAX, "new"), h.newTripPayload())));

    it("TRIP-P02 cancels while searching (driver_matching_screen)", () =>
      assertSucceeds(
        updateDoc(trip(h.PAX, "searching"), {
          status: "cancelledByPassenger",
          cancelledAt: serverTimestamp(),
          cancellationReason: "User cancelled while searching",
        }),
      ));

    it("TRIP-P03 marks search timed out (driver_matching_screen)", () =>
      assertSucceeds(
        updateDoc(trip(h.PAX, "searching"), {
          status: "noDriversAvailable",
          expiredAt: serverTimestamp(),
          expiredBy: "passenger_timeout",
        }),
      ));

    it("TRIP-P04 cancels after a driver is assigned, before pickup", () =>
      assertSucceeds(
        updateDoc(trip(h.PAX, "assigned"), {
          status: "cancelledByPassenger",
          cancelledAt: serverTimestamp(),
        }),
      ));

    it("TRIP-P05 confirms arrival on a completed trip", () =>
      assertSucceeds(
        updateDoc(trip(h.PAX, "completed"), {
          passengerConfirmed: true,
          passengerConfirmedAt: serverTimestamp(),
        }),
      ));

    it("TRIP-P06 disputes a completed trip", () =>
      assertSucceeds(
        updateDoc(trip(h.PAX, "completed"), {
          disputed: true,
          disputedAt: serverTimestamp(),
          disputeReason: "Passenger did not confirm arrival",
        }),
      ));

    it("TRIP-P07 rates a completed trip (trip_complete_screen)", () =>
      assertSucceeds(
        updateDoc(trip(h.PAX, "completed"), {
          passengerRating: 5,
          passengerTags: ["Friendly"],
          passengerFeedback: "Great ride",
          ratedAt: serverTimestamp(),
        }),
      ));
  });

  describe("app behaviour: driver (must keep working)", () => {
    it("TRIP-P08 approved driver claims a searching trip (requests_section)", () =>
      assertSucceeds(
        updateDoc(trip(h.OTHER_DRIVER, "searching"), {
          driverId: h.OTHER_DRIVER,
          driverName: "Driver drvB",
          driverPhone: "+233200000000",
          driverRating: 4.8,
          driverPlate: "GR-1234-24",
          status: "tripAccepted",
          acceptedAt: serverTimestamp(),
        }),
      ));

    it("TRIP-P09 writes live location to the trip", () =>
      assertSucceeds(
        updateDoc(trip(h.DRIVER, "assigned"), {
          driverCurrentLocation: new GeoPoint(5.6, -0.18),
          driverHeading: 90,
          lastLocationUpdate: serverTimestamp(),
        }),
      ));

    it("TRIP-P10 marks arrived", () =>
      assertSucceeds(
        updateDoc(trip(h.DRIVER, "assigned"), {
          status: "driverArrived",
          arrivedAt: serverTimestamp(),
        }),
      ));

    it("TRIP-P11 starts the trip", async () => {
      await h.env().withSecurityRulesDisabled((ctx) =>
        updateDoc(doc(ctx.firestore(), "trips/assigned"), { status: "driverArrived" }),
      );
      await assertSucceeds(
        updateDoc(trip(h.DRIVER, "assigned"), {
          status: "tripStarted",
          startedAt: serverTimestamp(),
        }),
      );
    });

    it("TRIP-P12 completes the trip", () =>
      assertSucceeds(
        updateDoc(trip(h.DRIVER, "started"), {
          status: "completed",
          completedAt: serverTimestamp(),
        }),
      ));

    it("TRIP-P13 cancels an assigned trip and frees itself (one batch)", () => {
      const fs_ = h.db(h.DRIVER);
      const b = writeBatch(fs_);
      b.update(doc(fs_, "trips/assigned"), {
        status: "cancelledByDriver",
        cancelledAt: serverTimestamp(),
      });
      b.update(doc(fs_, `drivers/${h.DRIVER}`), {
        isAvailable: true,
        currentTripId: deleteField(),
      });
      return assertSucceeds(b.commit());
    });
  });
});
