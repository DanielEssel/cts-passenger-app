// Passenger map markers (driver_map).
//
// Passengers see nearby drivers through driver_map, which holds only a
// rounded position and vehicle type and is written only by the backend.
// drivers/{id} stays private (see availability.test.js).

const { assertFails, assertSucceeds } = require("@firebase/rules-unit-testing");
const {
  collection,
  doc,
  getDoc,
  getDocs,
  query,
  where,
  setDoc,
  updateDoc,
  deleteDoc,
  GeoPoint,
} = require("firebase/firestore");
const h = require("./helpers");

async function seedMap() {
  await h.env().withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), `driver_map/${h.DRIVER}`), {
      location: new GeoPoint(5.603, -0.187),
      serviceType: "okada",
    });
  });
}

describe("driver_map (passenger map markers)", () => {
  before(h.setupEnv);
  after(() => h.env().cleanup());
  beforeEach(async () => {
    await h.seed();
    await seedMap();
  });

  it("MAP-P01 signed-in passenger can list driver markers", () =>
    assertSucceeds(getDocs(collection(h.db(h.PAX), "driver_map"))));

  it("MAP-P02 signed-in passenger can read one marker", () =>
    assertSucceeds(getDoc(doc(h.db(h.PAX), `driver_map/${h.DRIVER}`))));

  // The Gas order screen's ETA estimate (gas_order_screen.dart).
  it("MAP-P03 passenger can query delivery/gas markers for the Gas ETA", () =>
    assertSucceeds(getDocs(query(collection(h.db(h.PAX), "driver_map"),
      where("serviceType", "in", ["delivery", "gas"])))));

  it("MAP-S06 passenger cannot query drivers/ (the former Gas ETA query)", () =>
    assertFails(getDocs(query(collection(h.db(h.PAX), "drivers"),
      where("isOnline", "==", true), where("isApproved", "==", true),
      where("isAvailable", "==", true)))));

  it("MAP-S01 signed-out user cannot list driver markers", () =>
    assertFails(getDocs(collection(h.db(null), "driver_map"))));

  it("MAP-S02 passenger cannot create a fake marker", () =>
    assertFails(
      setDoc(doc(h.db(h.PAX), "driver_map/fake"), {
        location: new GeoPoint(5.6, -0.18),
        serviceType: "taxi",
      }),
    ));

  it("MAP-S03 driver cannot move their own marker directly", () =>
    assertFails(
      updateDoc(doc(h.db(h.DRIVER), `driver_map/${h.DRIVER}`), {
        location: new GeoPoint(5.7, -0.2),
      }),
    ));

  it("MAP-S04 nobody but the backend can delete a marker", () =>
    assertFails(deleteDoc(doc(h.db(h.DRIVER), `driver_map/${h.DRIVER}`))));

  it("MAP-S05 drivers collection stays private to passengers", () =>
    assertFails(getDocs(collection(h.db(h.PAX), "drivers"))));
});
