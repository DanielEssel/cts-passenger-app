// functions/config.js
// Per-environment payment configuration and the outbound-payment guard.
//
// Values come from Firebase parameterized config:
//   functions/.env.<projectId>  deployed with that project (non-secret values)
//   functions/.env.local        emulator only, git-ignored, never deployed
// Credentials stay in Secret Manager (defineSecret in bridge.js), which is
// scoped per Firebase project, so staging and production never share them.
//
// The guard fails closed: a payment request is sent only when the mode, the
// project and the destination agree. It decides where requests may go; it
// does not change what a payment request contains.

"use strict";

const { defineString } = require("firebase-functions/params");

const PRODUCTION_PROJECT_ID = "ctstransportapp";
const FUNCTIONS_REGION = "europe-west2";
// The live Bridge gateway. Refused in sandbox mode until Bridge confirms how
// its sandbox is reached (a separate host, or this host with test keys).
const PRODUCTION_BRIDGE_HOST = "api.bridgeagw.com";
const LOCAL_HOSTS = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);

// The only host a deployed project may receive Bridge callbacks on.
function expectedCallbackHost(projectId) {
  return `${FUNCTIONS_REGION}-${projectId}.cloudfunctions.net`;
}

// live    — production only; real Bridge requests.
// sandbox — non-production only; provider test credentials (not yet confirmed
//           to exist; see functions/PAYMENTS-STAGING.md).
// stub    — local emulator/tests only; requests go to a local stub gateway.
const PAYMENTS_MODE = defineString("PAYMENTS_MODE", {
  description: "Payment mode: live (production), sandbox (staging) or stub (local).",
});
const BRIDGE_API_BASE = defineString("BRIDGE_API_BASE", {
  description: "Bridge gateway base URL for this environment.",
});
const BRIDGE_CALLBACK_BASE_URL = defineString("BRIDGE_CALLBACK_BASE_URL", {
  description: "Base URL Bridge calls back, e.g. https://europe-west2-<project>.cloudfunctions.net",
});

class PaymentConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = "PaymentConfigError";
  }
}

function currentProjectId() {
  if (process.env.GCLOUD_PROJECT) return process.env.GCLOUD_PROJECT;
  try {
    return JSON.parse(process.env.FIREBASE_CONFIG || "{}").projectId || "";
  } catch (_) {
    return "";
  }
}

// Any sign of a local run counts as local, so tests can never reach a real
// gateway even if a mode or URL is misconfigured.
function isLocalRun() {
  return (
    process.env.FUNCTIONS_EMULATOR === "true" ||
    Boolean(process.env.FIRESTORE_EMULATOR_HOST) ||
    currentProjectId().startsWith("demo-")
  );
}

function parseUrl(raw, what) {
  try {
    return new URL(String(raw || ""));
  } catch (_) {
    throw new PaymentConfigError(`${what} is missing or not a valid URL.`);
  }
}

function paymentsMode() {
  return String(PAYMENTS_MODE.value() || "").trim();
}

/**
 * Throws PaymentConfigError unless a request to `url` is allowed for the
 * current project and mode. Call before every outbound Bridge request.
 */
function assertBridgeRequestAllowed(url) {
  const target = parseUrl(url, "Bridge request URL");
  const mode = paymentsMode();
  const project = currentProjectId();

  if (isLocalRun()) {
    if (mode !== "stub") {
      throw new PaymentConfigError(`Local runs require PAYMENTS_MODE=stub (got "${mode}").`);
    }
    if (!LOCAL_HOSTS.has(target.hostname)) {
      throw new PaymentConfigError(`Local runs may only call a local stub, not ${target.hostname}.`);
    }
    return;
  }

  if (target.protocol !== "https:") {
    throw new PaymentConfigError("Bridge requests must use https outside local runs.");
  }

  if (mode === "live") {
    if (project !== PRODUCTION_PROJECT_ID) {
      throw new PaymentConfigError(`PAYMENTS_MODE=live is only allowed in ${PRODUCTION_PROJECT_ID}.`);
    }
    return;
  }

  if (mode === "sandbox") {
    if (project === PRODUCTION_PROJECT_ID) {
      throw new PaymentConfigError("PAYMENTS_MODE=sandbox is not allowed in production.");
    }
    if (target.hostname === PRODUCTION_BRIDGE_HOST) {
      throw new PaymentConfigError(
        `PAYMENTS_MODE=sandbox may not use the live gateway ${PRODUCTION_BRIDGE_HOST}.`,
      );
    }
    return;
  }

  throw new PaymentConfigError(`Payments are disabled: PAYMENTS_MODE "${mode}" is not valid here.`);
}

/** Bridge API base for this environment, guarded. */
function bridgeApiBase() {
  const base = String(BRIDGE_API_BASE.value() || "").trim().replace(/\/+$/, "");
  assertBridgeRequestAllowed(base);
  return base;
}

/**
 * Full callback URL for one of our HTTP functions.
 *
 * Deployed projects: https only, and the host must be exactly
 * <region>-<this project>.cloudfunctions.net with the path /<functionName>.
 * That rejects custom domains, run.app URLs, other regions, and any other
 * project's host, so no non-production project can name a production host.
 * Local runs: loopback hosts only (the emulator's own URL format).
 */
function bridgeCallbackUrl(functionName) {
  const base = String(BRIDGE_CALLBACK_BASE_URL.value() || "").trim().replace(/\/+$/, "");
  const url = parseUrl(`${base}/${functionName}`, "Bridge callback URL");

  if (isLocalRun()) {
    if (!LOCAL_HOSTS.has(url.hostname)) {
      throw new PaymentConfigError(`Local runs may only use loopback callbacks, not ${url.hostname}.`);
    }
    return url.href;
  }

  const project = currentProjectId();
  if (!project) {
    throw new PaymentConfigError("Cannot determine the project for Bridge callbacks.");
  }
  if (url.protocol !== "https:") {
    throw new PaymentConfigError("Bridge callbacks must use https.");
  }
  if (project !== PRODUCTION_PROJECT_ID && url.hostname === expectedCallbackHost(PRODUCTION_PROJECT_ID)) {
    throw new PaymentConfigError("Non-production callbacks must not point at the production project.");
  }
  const expectedHost = expectedCallbackHost(project);
  if (url.hostname !== expectedHost) {
    throw new PaymentConfigError(`Bridge callback host must be ${expectedHost}, not ${url.hostname}.`);
  }
  if (
    url.pathname !== `/${functionName}` ||
    url.port || url.search || url.hash || url.username || url.password
  ) {
    throw new PaymentConfigError(`Bridge callback URL must be https://${expectedHost}/${functionName}.`);
  }
  return url.href;
}

/**
 * Paystack is retired. Its remaining production endpoints keep working
 * unchanged until a separate removal change, but no other environment may
 * call Paystack.
 */
function assertPaystackRequestAllowed() {
  if (isLocalRun() || currentProjectId() !== PRODUCTION_PROJECT_ID) {
    throw new PaymentConfigError("Paystack is retired and disabled outside production.");
  }
}

module.exports = {
  PRODUCTION_PROJECT_ID,
  PRODUCTION_BRIDGE_HOST,
  expectedCallbackHost,
  PaymentConfigError,
  assertBridgeRequestAllowed,
  assertPaystackRequestAllowed,
  bridgeApiBase,
  bridgeCallbackUrl,
  currentProjectId,
  isLocalRun,
};
