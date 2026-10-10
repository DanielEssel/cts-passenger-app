// Shared harness for the payment tests.
//
// Runs only under `firebase emulators:exec --only firestore` with a demo-
// project, so Firestore writes go to the local emulator and no Google
// resource is reachable. Outbound Bridge calls go to a local stub gateway;
// config.js refuses anything else during local runs.

"use strict";

const http = require("node:http");

const PROJECT_ID = "demo-ctsgo-payments";

// Environment must be set before the functions modules read their params.
process.env.GCLOUD_PROJECT = PROJECT_ID;
process.env.PAYMENTS_MODE = "stub";
process.env.BRIDGE_CLIENT_KEY = "fake-client-key";
process.env.BRIDGE_SECRET_KEY = "fake-secret-key";
process.env.BRIDGE_SERVICE_ID = "1";
delete process.env.GOOGLE_APPLICATION_CREDENTIALS;

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error("Run these tests with `firebase emulators:exec --only firestore`.");
}

const admin = require("firebase-admin");
if (!admin.apps.length) admin.initializeApp({ projectId: PROJECT_ID });
const fft = require("firebase-functions-test")({ projectId: PROJECT_ID });

const db = () => admin.firestore();

/** Deletes every document in the emulator database. */
async function clearFirestore() {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const res = await fetch(
    `http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: "DELETE" },
  );
  if (!res.ok) throw new Error(`Could not clear emulator: ${res.status}`);
}

/**
 * Local stand-in for the Bridge gateway. It reproduces only the response
 * shape the current code already reads (`response_code`, `response_message`);
 * it makes no claim about the real provider's behaviour.
 *
 * mode: "accept" (code "000"), "reject" (code given), "drop" (close the
 * socket without a response, i.e. an ambiguous network failure).
 */
async function startStubGateway() {
  const requests = [];
  const state = { mode: "accept", code: "000" };

  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      let parsed = null;
      try {
        parsed = JSON.parse(body);
      } catch (_) {
        parsed = body;
      }
      requests.push({ method: req.method, path: req.url, body: parsed });
      if (state.mode === "drop") {
        req.socket.destroy();
        return;
      }
      const code = state.mode === "reject" ? state.code : "000";
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ response_code: code, response_message: "stub" }));
    });
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;

  process.env.BRIDGE_API_BASE = base;
  process.env.BRIDGE_CALLBACK_BASE_URL = `http://127.0.0.1:5001/${PROJECT_ID}/europe-west2`;

  return {
    base,
    requests,
    state,
    reset() {
      requests.length = 0;
      state.mode = "accept";
      state.code = "000";
    },
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

/** Calls a v2 HTTP function with a mock request and response. */
async function callHttp(fn, { method = "POST", body = {}, headers = {} } = {}) {
  const req = {
    method,
    body,
    headers,
    rawBody: Buffer.from(JSON.stringify(body)),
    get: (h) => headers[String(h).toLowerCase()],
    header: (h) => headers[String(h).toLowerCase()],
  };
  const resolveDone = () => {};
  const res = {
    statusCode: 200,
    body: undefined,
    headersSent: false,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(payload) {
      this.body = payload;
      this.headersSent = true;
      resolveDone();
      return this;
    },
    send(payload) {
      this.body = payload;
      this.headersSent = true;
      resolveDone();
      return this;
    },
    set() {
      return this;
    },
    setHeader() {},
    getHeader() {},
    on() {},
    end() {
      this.headersSent = true;
      resolveDone();
    },
  };
  // Await the handler itself: it may keep working after responding.
  await fn(req, res);
  return res;
}

/** Calls a v2 callable function as a signed-in user. */
function callCallable(fn, uid, data) {
  return fft.wrap(fn)({ data, auth: uid ? { uid, token: {} } : undefined });
}

async function seed(path, data) {
  await db().doc(path).set(data);
}

async function read(path) {
  const snap = await db().doc(path).get();
  return snap.exists ? snap.data() : null;
}

async function count(collection, field, value) {
  const snap = await db().collection(collection).where(field, "==", value).get();
  return snap.size;
}

module.exports = {
  PROJECT_ID,
  admin,
  db,
  fft,
  clearFirestore,
  startStubGateway,
  callHttp,
  callCallable,
  seed,
  read,
  count,
};
