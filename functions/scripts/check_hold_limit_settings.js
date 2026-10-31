// Read-only check of settings/platform against the holdBalance limits
// (escrow.js: HOLD_MIN_AMOUNT, maxEscrowHold / HOLD_MAX_DEFAULT).
//
// It reads ONE document, settings/platform, with a single get(). It never
// writes. It prints only the pricing figures that decide whether a
// legitimate wallet order could fall outside the limits: every minimum fare
// and minimum delivery fee must be at least the hold minimum, and the
// largest commercial gas order the maximum allows is reported so the
// business can decide on maxEscrowHold. It does not choose that value.
//
// Usage (local emulator, the default and only unflagged mode):
//   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 node scripts/check_hold_limit_settings.js
//
// A remote project needs explicit flags; production needs a separate one,
// to be used only with written authorisation and a read-only identity:
//   node scripts/check_hold_limit_settings.js --project <id> --allow-remote-read
//   ... --project ctstransportapp --allow-remote-read --production-read-authorized

"use strict";

const { resolveTarget } = require("./assess_auto_expired_escrows");

// Same values as escrow.js; kept here so the script never loads Functions code.
const HOLD_MIN_AMOUNT = 5.0;
const HOLD_MAX_DEFAULT = 5000.0;

// Where the Passenger app and Functions read each minimum (pricing_service.dart,
// trips.js calculate*Fare). A missing value means the code default applies.
const MINIMUMS = [
  { key: "ride.okada.minimumFare", path: ["okada", "minimumFare"], codeDefault: 5 },
  { key: "ride.pragyia.minimumFare", path: ["pragyia", "minimumFare"], codeDefault: 8 },
  { key: "ride.taxi.minimumFare", path: ["taxi", "minimumFare"], codeDefault: 10 },
  { key: "delivery.okada.minimumFare", path: ["delivery", "okada", "minimumFare"], codeDefault: 10 },
  { key: "delivery.aboboya.minimumFare", path: ["delivery", "aboboya", "minimumFare"], codeDefault: 20 },
  { key: "delivery.miniTruck.minimumFare", path: ["delivery", "miniTruck", "minimumFare"], codeDefault: 50 },
  { key: "delivery.minimumFare (legacy flat)", path: ["delivery", "minimumFare"], codeDefault: null },
  { key: "gas.minDeliveryFee", path: ["gas", "minDeliveryFee"], codeDefault: 12 },
];

const GAS_SIZES = ["3kg", "6kg", "12kg", "14kg", "19kg", "45kg"];

const at = (obj, path) => path.reduce((o, k) => (o && typeof o === "object" ? o[k] : undefined), obj);
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** Pure: evaluates a settings/platform document (or null). */
function evaluateHoldLimitSettings(settings, { min = HOLD_MIN_AMOUNT, maxDefault = HOLD_MAX_DEFAULT } = {}) {
  const s = settings || {};
  const problems = [];

  const minimums = MINIMUMS.map(({ key, path, codeDefault }) => {
    const raw = at(s, path);
    const configured = num(raw);
    const effective = configured ?? codeDefault;
    const ok = effective == null || effective >= min;
    if (raw !== undefined && configured == null) problems.push(`${key} is set but not a number`);
    if (!ok) problems.push(`${key} = ${effective} is below the GHS ${min.toFixed(2)} hold minimum`);
    return { key, configured, effective, ok };
  });

  // Same acceptance rule as escrow.js getMaxEscrowHold().
  const rawMax = s.maxEscrowHold;
  const maxValid = num(rawMax) != null && rawMax >= min;
  const maxEscrowHold = { configured: rawMax === undefined ? null : rawMax, valid: maxValid,
    effective: maxValid ? rawMax : maxDefault, usingDefault: !maxValid };
  if (rawMax !== undefined && !maxValid) problems.push("maxEscrowHold is set but unusable; the default applies");

  // Commercial bulk: refill price × quantity × commercialRate (+ delivery,
  // brand multiplier). No quantity cap exists in the app.
  const rate = num(at(s, ["gas", "commercialRate"]));
  const commercialRate = rate && rate > 0 ? rate : 1;
  const deliveryFloor = num(at(s, ["gas", "minDeliveryFee"])) ?? 12;
  const commercial = GAS_SIZES.map((size) => {
    const refill = num(at(s, ["gas", `refill${size}`]));
    const unit = refill == null ? null : Math.round(refill * commercialRate * 100) / 100;
    const maxQuantity = unit ? Math.max(0, Math.floor((maxEscrowHold.effective - deliveryFloor) / unit)) : null;
    return { size, refillPrice: refill, commercialUnit: unit, maxQuantityUnderMax: maxQuantity };
  });

  return { holdMinimum: min, maxEscrowHold, minimums, commercialGas: { commercialRate, deliveryFloor,
    sizes: commercial, note: "Approximate: brand multipliers and distance-based delivery fees lower these counts." },
  ok: problems.length === 0, problems };
}

async function main() {
  const { projectId } = resolveTarget(process.argv.slice(2), process.env);
  const admin = require("firebase-admin");
  if (!admin.apps.length) admin.initializeApp({ projectId });
  const snap = await admin.firestore().collection("settings").doc("platform").get();
  const report = evaluateHoldLimitSettings(snap.exists ? snap.data() : null);
  process.stdout.write(JSON.stringify({ projectId, documentExists: snap.exists, ...report }, null, 2) + "\n");
}

module.exports = { evaluateHoldLimitSettings, MINIMUMS, HOLD_MIN_AMOUNT, HOLD_MAX_DEFAULT };

if (require.main === module) {
  main().catch((e) => {
    console.error(e.message);
    process.exit(1);
  });
}
