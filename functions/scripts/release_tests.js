// Release-scope test run for the escrow-containment release
// (deploy/phase1e/RELEASE-MANIFEST.md).
//
// The release keeps HEAD's bridge.js, config.js, wallet.js and
// withdrawal_approval.js, and deploys none of their functions. Tests whose
// subject is that code are run by the full suite, not here, whether they pass
// or fail against it. Everything else must pass. Excluded tests are not run
// here (node's --test-skip-pattern filters them out of the counts); this
// script lists every one of them, with its reason, before and after the run.
//
// Run inside the emulator, from functions/:
//   npm run test:release            (scope check, then the in-scope suite)
//   node scripts/release_tests.js --list

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.join(__dirname, "..");

// Whole files whose every test exercises excluded code.
const EXCLUDED_FILES = {
  "test/payments/bridge_topup.test.js": "Bridge top-up callbacks and Paystack removal (bridge.js, config.js, wallet.js)",
  "test/payments/security.test.js": "Bridge top-up and payout callbacks, payout approval (bridge.js, withdrawal_approval.js)",
  "test/payments/smoke.test.js": "Bridge payment configuration guard, env wiring, Paystack removal, runbook (config.js, bridge.js, wallet.js)",
  "test/payments/withdrawal_approval.test.js": "driver withdrawals and payout outcomes (withdrawal_approval.js, bridge.js)",
};

// Tests excluded from files that otherwise stay in scope.
const EXCLUDED_TESTS = {
  "test/payments/wallet_integrity.test.js": {
    ids: ["WI-P01", "WI-P02", "WI-P03", "WI-P04"],
    reason: "driver withdrawable balance (wallet.js getDriverWallet / withdrawals)",
  },
};

function testFiles() {
  const list = (dir) => fs.readdirSync(path.join(ROOT, dir))
    .filter((f) => f.endsWith(".test.js")).map((f) => `${dir}/${f}`);
  return [...list("test"), ...list("test/payments")].sort();
}

/** Fails if an exclusion no longer matches the tests it names. */
function checkScope() {
  const problems = [];
  for (const f of Object.keys(EXCLUDED_FILES)) {
    if (!fs.existsSync(path.join(ROOT, f))) problems.push(`excluded file missing: ${f}`);
  }
  for (const [f, { ids }] of Object.entries(EXCLUDED_TESTS)) {
    const src = fs.readFileSync(path.join(ROOT, f), "utf8");
    for (const id of ids) {
      if (!new RegExp(`test\\(\\s*["'\`]${id} `).test(src)) problems.push(`${f}: no test ${id}`);
    }
  }
  return problems;
}

const inScope = testFiles().filter((f) => !(f in EXCLUDED_FILES));
const skipIds = Object.values(EXCLUDED_TESTS).flatMap((e) => e.ids);

function printExclusions() {
  console.log("Not run in the release scope (run by the full suite):");
  for (const [f, why] of Object.entries(EXCLUDED_FILES)) console.log(`  ${f} (whole file): ${why}`);
  for (const [f, e] of Object.entries(EXCLUDED_TESTS)) console.log(`  ${f} ${e.ids.join(", ")}: ${e.reason}`);
}

if (process.argv.includes("--list")) {
  console.log("In scope:\n  " + inScope.join("\n  "));
  printExclusions();
  process.exit(0);
}

const problems = checkScope();
if (problems.length) {
  console.error("Release test scope is out of date:\n  " + problems.join("\n  "));
  process.exit(2);
}

const args = ["--test", "--test-concurrency=1", "--test-timeout=120000",
  `--test-skip-pattern=^(${skipIds.join("|")}) `, ...inScope];
console.log(`Release scope: ${inScope.length} files. Not run: ${Object.keys(EXCLUDED_FILES).length} files ` +
  `and ${skipIds.length} tests, listed below.`);
printExclusions();
const r = spawnSync(process.execPath, args, { cwd: ROOT, stdio: "inherit" });
printExclusions();
process.exit(r.status ?? 1);
