"use strict";

// Gas vehicle rules (business rule, 2026-10-28), enforced by the backend for
// offer targeting and acceptance (dispatch_policy.js driverRejection →
// gas_dispatch_policy.js canHandleGasOrder):
//   motorbike            standard only (exchangeEmpty, newCylinder, pickupAndReturn)
//   aboboyaa, mini truck standard and bulk (commercialBulk)
//   pragyia, taxi, quadricycle: no Gas orders
// Every combination, the historical vehicle aliases, and unknown values
// (which fail closed). Pure; no emulator needed.

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { canHandleGasOrder } = require("../gas_dispatch_policy");
const { driverRejection } = require("../dispatch_policy");

const STANDARD = ["exchangeEmpty", "newCylinder", "pickupAndReturn"];
const BULK = ["commercialBulk"];
const ALL = [...STANDARD, ...BULK];
const ALLOWED = {
  motorcycle: STANDARD,
  tricycle: ALL,
  miniTruck: ALL,
  pragyia: [],
  taxi: [],
  quadricycle: [],
};
const ALIASES = { okada: "motorcycle", motorbike: "motorcycle", aboboyaa: "tricycle", aboboya: "tricycle",
  mini_truck: "miniTruck", "mini truck": "miniTruck", minitruck: "miniTruck", " Taxi ": "taxi" };

test("GVM-01 every vehicle and Gas order type combination", () => {
  for (const [vehicle, allowed] of Object.entries(ALLOWED)) {
    for (const type of ALL) {
      assert.equal(canHandleGasOrder(vehicle, type), allowed.includes(type), `${vehicle} × ${type}`);
    }
  }
});

test("GVM-02 historical vehicle aliases follow their vehicle", () => {
  for (const [alias, vehicle] of Object.entries(ALIASES)) {
    for (const type of ALL) {
      assert.equal(canHandleGasOrder(alias, type), ALLOWED[vehicle].includes(type), `${alias} × ${type}`);
    }
  }
});

test("GVM-03 unknown or missing vehicles and order types fail closed", () => {
  for (const v of [null, undefined, "", "bicycle", "truck", 7, {}]) {
    for (const type of ALL) assert.equal(canHandleGasOrder(v, type), false, `${String(v)} × ${type}`);
  }
  for (const type of [null, "", "refill", "bulk", "PickupAndReturn"]) {
    for (const v of Object.keys(ALLOWED)) assert.equal(canHandleGasOrder(v, type), false, `${v} × ${String(type)}`);
  }
});

test("GVM-04 acceptance applies the same rule to an otherwise eligible delivery driver", () => {
  const driver = (vehicleType) => ({ isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true,
    currentTripId: null, role: "driver_delivery", vehicleType });
  for (const [vehicle, allowed] of Object.entries(ALLOWED)) {
    for (const type of ALL) {
      const why = driverRejection("gas", { refillType: type }, driver(vehicle), { checkLocation: false });
      assert.equal(why, allowed.includes(type) ? null : "vehicle_not_eligible", `${vehicle} × ${type}`);
    }
  }
});
