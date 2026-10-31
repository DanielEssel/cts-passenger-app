// The eligibility cases shared with the Driver App
// (test/fixtures/eligibility_cases.json), run against dispatch_policy.js,
// which notification dispatch (selectRecipients) and the acceptance
// callables (driverRejection) both use. Pure: no emulator needed.
// The Driver App runs a byte-identical copy against its request-list
// filter (test/features/driver/eligibility_parity_test.dart).

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const policy = require("../../dispatch_policy");

const FIXTURE = path.join(__dirname, "../fixtures/eligibility_cases.json");
const F = JSON.parse(fs.readFileSync(FIXTURE, "utf8"));
const pt = ([latitude, longitude]) => ({ latitude, longitude });

function driverDoc(spec) {
  const loc = "location" in spec
    ? (spec.location === null ? null : pt(typeof spec.location === "string" ? F[spec.location] : spec.location))
    : pt(F.near);
  const { location, ...rest } = spec;
  return { isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true,
    serviceType: null, ...rest, location: loc };
}

function jobDoc({ service, point, ...fields }) {
  const at = pt(point ?? F.jobPoint);
  return service === "gas"
    ? { ...fields, deliveryLocation: at, pickupLocation: at }
    : { ...fields, pickupLocation: at };
}

test("ELG-00 every fixture driver and case is well-formed", () => {
  for (const c of F.cases) {
    assert.ok(c.expect || c.jobRejection, JSON.stringify(c.job));
    for (const id of Object.keys(c.expect ?? {})) assert.ok(F.drivers[id], id);
  }
});

for (const c of F.cases) {
  const label = Object.values(c.job).join(" ");
  const job = jobDoc(c.job);
  test(`ELG ${label}`, () => {
    if (c.jobRejection) {
      assert.equal(policy.jobRejection(c.job.service, job), c.jobRejection);
      // Offered to nobody, so accepted by nobody.
      const all = Object.entries(F.drivers).map(([id, d]) => ({ id, data: driverDoc(d) }));
      assert.deepEqual(policy.selectRecipients(c.job.service, job, all).recipients, []);
      return;
    }
    assert.equal(policy.jobRejection(c.job.service, job), null);
    for (const [id, want] of Object.entries(c.expect)) {
      const d = driverDoc(F.drivers[id]);
      // Acceptance and dispatch use the same function and must agree.
      assert.equal(policy.driverRejection(c.job.service, job, d), want, `${id} (accept)`);
      const { recipients } = policy.selectRecipients(c.job.service, job, [{ id, data: d }]);
      assert.equal(recipients.length === 1, want === null, `${id} (dispatch)`);
    }
  });
}

test("ELG-99 the Driver App's copy of the cases is identical (when checked out alongside)", (t) => {
  const driverCopy = path.resolve(__dirname,
    "../../../../../driver/cts-transport-driver-app-clean/test/fixtures/eligibility_cases.json");
  if (!fs.existsSync(driverCopy)) return t.skip("Driver App repository not alongside");
  const hash = (p) => crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex");
  assert.equal(hash(driverCopy), hash(FIXTURE));
});
