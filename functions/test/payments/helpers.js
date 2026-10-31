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
  const hanging = [];
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
      if (state.mode === "hang") {
        // Never answers; the caller's timeout decides. Closed with the server.
        hanging.push(res);
        return;
      }
      if (state.mode === "empty200") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end("{}");
        return;
      }
      if (state.mode === "garbage200") {
        res.writeHead(200, { "Content-Type": "text/html" });
        res.end("<html>gateway</html>");
        return;
      }
      if (state.mode === "delay") {
        // Answers with state.code after state.delayMs (an in-flight attempt).
        const codeNow = state.code;
        setTimeout(() => {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ response_code: codeNow, response_message: "stub" }));
        }, state.delayMs ?? 500);
        return;
      }
      if (state.mode === "http500") {
        // A server error: the request reached Bridge, the outcome is unknown.
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ message: "stub server error" }));
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
      state.delayMs = undefined;
      for (const r of hanging.splice(0)) r.destroy?.();
    },
    close: () => {
      for (const r of hanging.splice(0)) r.destroy?.();
      return new Promise((resolve) => server.close(resolve));
    },
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

/**
 * Runs [fn] while every query on [collection] that filters on [field]
 * rejects the way Firestore rejects a query whose composite index is
 * missing (FAILED_PRECONDITION). The emulator never enforces indexes, so
 * this is how the production failure is reproduced. Resolves to the number
 * of queries it intercepted, so a test can prove the failure reached the
 * code under test; an internal change in the Admin SDK makes that 0.
 */
async function withMissingIndex({ collection, field }, fn) {
  const { Query } = admin.firestore;
  const realGet = Query.prototype.get;
  let intercepted = 0;
  Query.prototype.get = function (...args) {
    const q = this._queryOptions;
    if (q?.collectionId === collection && JSON.stringify(q.filters ?? []).includes(field)) {
      intercepted++;
      const err = new Error("9 FAILED_PRECONDITION: The query requires an index.");
      err.code = 9;
      return Promise.reject(err);
    }
    return realGet.apply(this, args);
  };
  try {
    await fn();
  } finally {
    Query.prototype.get = realGet;
  }
  return intercepted;
}

/**
 * [order] with the amounts the Passenger App writes for it (release v5): the
 * server's price for its type, size, quantity and brand under [settings]
 * (functions/gas_pricing.js), as totalPrice and deliveryFee. An order the
 * server cannot price gets [unpriceableTotal] when given (tests of what
 * happens to such orders), else this throws.
 */
function gasPriced(order, settings = null, unpriceableTotal = undefined) {
  const quote = require("../../gas_pricing").gasPriceQuote(order, settings);
  if (!quote.ok && unpriceableTotal !== undefined) return { ...order, totalPrice: unpriceableTotal };
  if (!quote.ok) throw new Error(`fixture cannot be priced: ${quote.reason}`);
  return { ...order, totalPrice: quote.total, deliveryFee: quote.deliveryFee };
}

/**
 * The state in which wallet payment may fund Delivery and Gas orders: the
 * code-secure minimum versions AND the dedicated switch
 * (app_config/payments.deliveryGasWalletEnabled, escrow.js). [mobile]
 * overrides the minimum-version fields.
 */
async function enableDeliveryGasWallet(mobile = {}) {
  await seed("app_config/mobile", { passengerMinimumVersion: "1.0.1", driverMinimumVersion: "1.0.3", ...mobile });
  await seed("app_config/payments", { deliveryGasWalletEnabled: true });
}

// ── Delivery pricing fixtures (release v5 round 3: server quotes) ───────────
// A complete rate card for tests: the Passenger App's built-in defaults
// (pricing_service.dart). Production's values are the owner's.
const DELIVERY_RATES = Object.freeze({
  okada: { baseFare: 5, perKmRate: 2.5, minimumFare: 10 },
  aboboya: { baseFare: 15, perKmRate: 4, minimumFare: 20 },
  miniTruck: { baseFare: 40, perKmRate: 7, minimumFare: 50 },
  weightSurchargeSmall: 0, weightSurchargeMedium: 5, weightSurchargeLarge: 15,
  fragileItemSurcharge: 5, helperSurcharge: 10,
});

const deliveryInputs = (o) => ({
  vehicleKey: require("../../delivery_pricing").vehicleKey(o.vehicleType),
  weightTier: o.weightTier, isFragile: o.isFragile ?? false, requiresHelpers: o.requiresHelpers ?? false,
});

/** A route length (m) at which [order] costs exactly its estimatedFare under [settings]. */
function metersForFare(order, settings) {
  const pricing = require("../../delivery_pricing");
  const rc = pricing.readRateCard(settings);
  if (!rc.ok) throw new Error(`fixture settings have no usable rate card: ${rc.reason}`);
  const want = pricing.pesewas(order.estimatedFare);
  const r = rc.card.vehicles[deliveryInputs(order).vehicleKey];
  if (!r) throw new Error(`fixture vehicle cannot be quoted: ${order.vehicleType}`);
  const atZero = pricing.priceDelivery({ ...deliveryInputs(order), distanceMeters: 0 }, rc.card);
  if (atZero.ok && atZero.total === want) return 0;
  const guess = Math.max(0, Math.floor(((want - (atZero.ok ? atZero.subtotal : r.base)) * 1000) / r.perKm));
  for (let m = Math.max(0, guess - 20); m <= guess + 20; m++) {
    const p = pricing.priceDelivery({ ...deliveryInputs(order), distanceMeters: m }, rc.card);
    if (p.ok && p.total === want) return m;
  }
  throw new Error(`no route length prices ${order.vehicleType}/${order.weightTier} at ${order.estimatedFare}`);
}

/**
 * Seeds the server quote [order] was placed with (as quoteDelivery stores it;
 * [settings] = settings/platform, which must hold the rate card) and returns
 * the order naming it. Its fare is unchanged, unless [distanceMeters] is
 * given: then the quote is for that route and the order takes its total.
 */
async function quotedDelivery(order, { quoteId = `q-${Math.random().toString(36).slice(2, 10)}`, settings,
  expiresInMs = 10 * 60 * 1000, usedBy = null, distanceMeters: fixedMeters } = {}) {
  const pricing = require("../../delivery_pricing");
  const rc = pricing.readRateCard(settings);
  if (!rc.ok) throw new Error(`fixture settings have no usable rate card: ${rc.reason}`);
  if (fixedMeters !== undefined) {
    const at = pricing.priceDelivery({ ...deliveryInputs(order), distanceMeters: fixedMeters }, rc.card);
    if (!at.ok) throw new Error(`fixture cannot be quoted: ${at.reason}`);
    order = { ...order, estimatedFare: at.total / 100 };
  }
  const distanceMeters = fixedMeters ?? metersForFare(order, settings);
  const p = pricing.priceDelivery({ ...deliveryInputs(order), distanceMeters }, rc.card);
  const now = Date.now();
  const { Timestamp } = require("firebase-admin/firestore");
  await seed(`delivery_quotes/${quoteId}`, {
    passengerId: order.passengerId, pricingVersion: pricing.PRICING_VERSION, rateCardVersion: rc.version,
    routeProvider: "test", pickup: order.pickupLocation, dropoff: order.dropoffLocation,
    ...deliveryInputs(order), vehicleType: order.vehicleType, distanceMeters, durationSeconds: null,
    items: p.items, subtotalPesewas: p.subtotal, minimumPesewas: p.minimum, minimumApplied: p.minimumApplied,
    totalPesewas: p.total, commissionPesewas: p.commission, driverNetPesewas: p.driverNet,
    feeBasisPoints: rc.card.feeBasisPoints, createdAt: Timestamp.fromMillis(now),
    expiresAt: Timestamp.fromMillis(now + expiresInMs), usedBy,
  });
  return { ...order, deliveryQuoteId: quoteId };
}

/**
 * [order] as onDeliveryCreated leaves it once its quote is verified: with a
 * "delivery-v2" verifiedPrice for its estimatedFare ([feePercent] commission).
 * For tests that seed orders past creation. Pure.
 */
function deliveryStamped(order, { feePercent = 15, quoteId = "q-fixture" } = {}) {
  const pricing = require("../../delivery_pricing");
  const total = pricing.pesewas(order.estimatedFare);
  const commission = pricing.mulDivHalfUp(total, Math.round(feePercent * 100), 10000);
  return { ...order, deliveryQuoteId: order.deliveryQuoteId ?? quoteId, verifiedPrice: { version: pricing.PRICING_VERSION,
    quoteId: order.deliveryQuoteId ?? quoteId, rateCardVersion: "fixture", distanceMeters: 0, totalPesewas: total,
    total: total / 100, commissionPesewas: commission, commission: commission / 100,
    driverNetPesewas: total - commission, driverNet: (total - commission) / 100 } };
}

/**
 * Approved Gas commission terms as adminDecideGasCommissionTerms leaves
 * them: the version document (approved) and `current`. A TEST FIXTURE, not
 * a commercial rate. Keys given as undefined are left out ("missing").
 */
async function seedGasCommissionTerms(o = {}) {
  const version = o.version ?? 1;
  const terms = { termsId: `v${version}`, version, rateBps: 1000, termsReference: "TEST-FIXTURE (not commercial)",
    settlementHoldHours: 24, currency: "GHS", commissionBase: "product_subtotal", handlingFeeCommissionable: false,
    deliveryFeeCommissionable: false, proposedBy: "test-proposer", approvedBy: "test-approver", active: true, ...o };
  for (const k of Object.keys(terms)) if (terms[k] === undefined) delete terms[k];
  const { active, ...versionDoc } = terms;
  void active;
  await seed(`gas_commission_terms/v${version}`, { ...versionDoc, status: "approved" });
  await seed("gas_commission_terms/current", terms);
  return terms;
}

module.exports = {
  PROJECT_ID,
  seedGasCommissionTerms,
  gasPriced,
  enableDeliveryGasWallet,
  DELIVERY_RATES,
  metersForFare,
  quotedDelivery,
  deliveryStamped,
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
  withMissingIndex,
};
