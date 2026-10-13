// Driver availability and driver-location visibility for passengers (PA-01).
//
// Business rule: passengers must not get unrestricted access to nearby
// drivers' precise live locations; they may see the assigned driver's
// location only for their own active booking.

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  collection,
  doc,
  getDoc,
  getDocs,
  query,
  where,
} = require("firebase/firestore");
const h = require("./helpers");

describe("driver availability (passenger)", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(h.seed);

  it("AVL-S01 passenger cannot list online drivers (driversNearbyProvider query)", () =>
    assertFails(
      getDocs(
        query(
          collection(h.db(h.PAX), "drivers"),
          where("isOnline", "==", true),
          where("isApproved", "==", true),
          where("isAvailable", "==", true),
        ),
      ),
    ));

  it("AVL-S02 passenger cannot read an unrelated driver's profile", () =>
    assertFails(getDoc(doc(h.db(h.PAX), `drivers/${h.OTHER_DRIVER}`))));

  it("AVL-P01 passenger can read their own booking, which carries the assigned driver's location", () =>
    assertSucceeds(getDoc(doc(h.db(h.PAX), "trips/assigned"))));
});
