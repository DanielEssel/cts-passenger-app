const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { getFirestore, FieldValue, GeoPoint } = require("firebase-admin/firestore");

// Public map markers for the passenger app.
//
// Passengers may not read drivers/{id} (phone, email, documents). This keeps
// driver_map/{id} in step with each driver document, holding only what a map
// marker needs: a position rounded to ~110 m and the vehicle type. A driver
// appears only while online, approved and available.

// 3 decimal places of latitude/longitude ≈ 110 m.
const round = (n) => Math.round(n * 1000) / 1000;

function validGeo(loc) {
  if (!loc) return null;
  const lat = loc.latitude;
  const lng = loc.longitude;
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  if (lat === 0 && lng === 0) return null;
  return { lat, lng };
}

// Returns the marker for a driver document, or null if it must not be shown.
function mapEntryFor(driver) {
  if (!driver) return null;
  if (driver.isOnline !== true || driver.isApproved !== true || driver.isAvailable !== true) {
    return null;
  }
  const pos = validGeo(driver.location) || validGeo(driver.currentLocation);
  if (!pos) return null;
  return {
    lat: round(pos.lat),
    lng: round(pos.lng),
    serviceType: typeof driver.serviceType === "string" ? driver.serviceType : "",
  };
}

const sameEntry = (a, b) =>
  a === b ||
  (a !== null && b !== null &&
    a.lat === b.lat && a.lng === b.lng && a.serviceType === b.serviceType);

exports.syncDriverMap = onDocumentWritten(
  { region: "europe-west2", document: "drivers/{driverId}" },
  async (event) => {
    const before = mapEntryFor(event.data?.before?.data());
    const after = mapEntryFor(event.data?.after?.data());

    // Most driver writes are location pings that stay inside the same
    // ~110 m cell: skip them.
    if (sameEntry(before, after)) return;

    const ref = getFirestore().collection("driver_map").doc(event.params.driverId);
    if (after === null) {
      await ref.delete();
      return;
    }
    await ref.set({
      location: new GeoPoint(after.lat, after.lng),
      serviceType: after.serviceType,
      updatedAt: FieldValue.serverTimestamp(),
    });
  }
);

exports._driverMap = { mapEntryFor };
