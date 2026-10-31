// Unit tests for the driver_map marker projection (no emulator needed).
// Run: cd functions && node --test test/driver_map.test.js

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { _driverMap } = require("../driver_map");

const { mapEntryFor } = _driverMap;
const geo = (latitude, longitude) => ({ latitude, longitude });
const online = {
  isOnline: true,
  isApproved: true,
  isAvailable: true,
  serviceType: "okada",
  location: geo(5.603456, -0.187654),
  phone: "secret",
  email: "secret",
  displayName: "secret",
};

test("an online, approved, available driver gets a rounded marker", () => {
  assert.deepEqual(mapEntryFor(online), { lat: 5.603, lng: -0.188, serviceType: "okada" });
});

test("the marker carries no personal data", () => {
  assert.deepEqual(Object.keys(mapEntryFor(online)).sort(), ["lat", "lng", "serviceType"]);
});

test("offline, unapproved, busy or missing drivers are not shown", () => {
  for (const d of [
    { ...online, isOnline: false },
    { ...online, isApproved: false },
    { ...online, isAvailable: false },
    { ...online, isOnline: undefined },
    undefined,
  ]) {
    assert.equal(mapEntryFor(d), null);
  }
});

test("falls back to currentLocation, rejects unusable positions", () => {
  assert.deepEqual(
    mapEntryFor({ ...online, location: undefined, currentLocation: geo(5.6, -0.2) }),
    { lat: 5.6, lng: -0.2, serviceType: "okada" },
  );
  for (const loc of [undefined, geo(0, 0), geo(NaN, 1), geo(95, 1), geo(1, 200)]) {
    assert.equal(mapEntryFor({ ...online, location: loc, currentLocation: undefined }), null);
  }
});
