// AUTH-03: role resolution must not treat a token-only drivers/{uid} as a
// driver. Run: cd functions && node --test test/roles.test.js

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { _roles } = require("../wallet");

const { classifyRole } = _roles;
const passenger = { role: "passenger", firstName: "A" };
const tokenStub = { fcmToken: "t", platform: "android" };

test("a real driver record is a driver, even with a users doc", () => {
  assert.equal(classifyRole({ role: "driver_hailing" }, passenger).role, "driver");
  assert.equal(classifyRole({ role: "driver_delivery" }, null).role, "driver");
});

test("a passenger with a token-only drivers doc stays a passenger", () => {
  const r = classifyRole(tokenStub, passenger);
  assert.equal(r.role, "passenger");
  assert.equal(r.data, passenger);
});

test("a driver mid-signup (no role yet) with no users doc is a driver", () => {
  assert.equal(classifyRole({ phone: "p" }, null).role, "driver");
});

test("a non-driver role string on drivers doc is not a driver record", () => {
  assert.equal(classifyRole({ role: "passenger" }, passenger).role, "passenger");
});

test("neither doc: unknown", () => {
  assert.equal(classifyRole(null, null).role, "unknown");
});
