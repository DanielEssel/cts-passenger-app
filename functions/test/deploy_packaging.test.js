// What `firebase deploy` would upload from functions/, computed with the
// installed firebase-tools' own directory walker and ignore matching
// (minimatch against absolute paths with matchBase, so ignore patterns
// must be slash-free names such as "test", not "test/**").
//
// Needs no emulator or network. Skips when firebase-tools is not
// installed globally.

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const { execSync } = require("node:child_process");

const repoRoot = path.resolve(__dirname, "../..");
const functionsDir = path.join(repoRoot, "functions");

function firebaseTools() {
  try {
    const root = execSync("npm root -g", { encoding: "utf8" }).trim();
    return require(path.join(root, "firebase-tools/lib/fsAsync.js"));
  } catch (_) {
    return null;
  }
}

async function uploadedFiles() {
  const fsAsync = firebaseTools();
  if (!fsAsync) return null;
  const cfg = JSON.parse(fs.readFileSync(path.join(repoRoot, "firebase.json"), "utf8"))
    .functions[0];
  // Same list prepareFunctionsUpload builds.
  const ignore = [...(cfg.ignore || ["node_modules", ".git"]),
    "firebase-debug.log", "firebase-debug.*.log", ".runtimeconfig.json"];
  const files = await fsAsync.readdirRecursive({ path: functionsDir, ignoreStrings: ignore });
  return files.map((f) => path.relative(functionsDir, f.name)).sort();
}

test("PKG-01 tests, fixtures, scripts, logs, backups, docs and templates are not uploaded", async (t) => {
  const files = await uploadedFiles();
  if (!files) return t.skip("firebase-tools not installed globally");
  const offenders = files.filter((f) =>
    f.startsWith("test/") || f.startsWith("scripts/") || /\.(log|bak|md|example)$/.test(f));
  assert.deepEqual(offenders, []);
});

test("PKG-02 every runtime module, the manifest and the project env file are uploaded", async (t) => {
  const files = await uploadedFiles();
  if (!files) return t.skip("firebase-tools not installed globally");
  const required = new Set(["index.js", "package.json", "package-lock.json"]);
  for (const f of fs.readdirSync(functionsDir).filter((n) => n.endsWith(".js"))) {
    const src = fs.readFileSync(path.join(functionsDir, f), "utf8");
    for (const m of src.matchAll(/require\("\.\/([a-z_]+)"\)/g)) required.add(`${m[1]}.js`);
  }
  // Read by the CLI from disk at deploy for params; kept in the upload too.
  if (fs.existsSync(path.join(functionsDir, ".env.ctstransportapp"))) {
    required.add(".env.ctstransportapp");
  }
  for (const r of required) assert.ok(files.includes(r), `${r} must be uploaded`);
});

test("PKG-03 ignore patterns are slash-free (the CLI matches them by name)", () => {
  const cfg = JSON.parse(fs.readFileSync(path.join(repoRoot, "firebase.json"), "utf8"))
    .functions[0];
  for (const p of cfg.ignore) assert.ok(!p.includes("/"), `pattern "${p}" would never match`);
});
