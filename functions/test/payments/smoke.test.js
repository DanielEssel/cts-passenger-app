// B0 smoke tests: the harness works, the config guard fails closed, and no
// local run can reach a real gateway. These must pass before B1 starts.

"use strict";

const { test, describe, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const config = require("../../config");

function withEnv(overrides, fn) {
  const saved = {};
  for (const [k, v] of Object.entries(overrides)) {
    saved[k] = process.env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

// Simulates a deployed (non-local) runtime for one project.
const deployedAs = (project, extra = {}) => ({
  GCLOUD_PROJECT: project,
  FIRESTORE_EMULATOR_HOST: undefined,
  FUNCTIONS_EMULATOR: undefined,
  ...extra,
});

describe("config guard", () => {
  test("SMK-01 local run allows only the local stub in stub mode", () => {
    config.assertBridgeRequestAllowed("http://127.0.0.1:8099/make_payment");
    assert.throws(
      () => config.assertBridgeRequestAllowed("https://api.bridgeagw.com/make_payment"),
      config.PaymentConfigError,
    );
  });

  test("SMK-02 local run refuses live and sandbox modes", () => {
    for (const mode of ["live", "sandbox", ""]) {
      withEnv({ PAYMENTS_MODE: mode }, () =>
        assert.throws(
          () => config.assertBridgeRequestAllowed("http://127.0.0.1:8099/x"),
          config.PaymentConfigError,
        ),
      );
    }
  });

  test("SMK-03 a demo- project counts as local even without emulator variables", () => {
    withEnv(deployedAs("demo-anything", { PAYMENTS_MODE: "live" }), () =>
      assert.throws(
        () => config.assertBridgeRequestAllowed("https://api.bridgeagw.com/make_payment"),
        config.PaymentConfigError,
      ),
    );
  });

  test("SMK-04 production with live mode allows the production gateway (today's behaviour)", () => {
    withEnv(deployedAs("ctstransportapp", { PAYMENTS_MODE: "live" }), () => {
      config.assertBridgeRequestAllowed("https://api.bridgeagw.com/make_payment");
    });
  });

  test("SMK-05 live mode is refused outside production", () => {
    withEnv(deployedAs("ctsgo-staging", { PAYMENTS_MODE: "live" }), () =>
      assert.throws(
        () => config.assertBridgeRequestAllowed("https://api.bridgeagw.com/make_payment"),
        config.PaymentConfigError,
      ),
    );
  });

  test("SMK-06 sandbox mode is refused in production; allowed in staging", () => {
    withEnv(deployedAs("ctstransportapp", { PAYMENTS_MODE: "sandbox" }), () =>
      assert.throws(
        () => config.assertBridgeRequestAllowed("https://sandbox.example/make_payment"),
        config.PaymentConfigError,
      ),
    );
    withEnv(deployedAs("ctsgo-staging", { PAYMENTS_MODE: "sandbox" }), () => {
      config.assertBridgeRequestAllowed("https://sandbox.example/make_payment");
    });
  });

  test("SMK-07 missing or unknown mode, missing host, or plain http fail closed when deployed", () => {
    withEnv(deployedAs("ctstransportapp", { PAYMENTS_MODE: "" }), () =>
      assert.throws(() => config.assertBridgeRequestAllowed("https://api.bridgeagw.com/x")),
    );
    withEnv(deployedAs("ctstransportapp", { PAYMENTS_MODE: "stub" }), () =>
      assert.throws(() => config.assertBridgeRequestAllowed("https://api.bridgeagw.com/x")),
    );
    withEnv(deployedAs("ctsgo-staging", { PAYMENTS_MODE: "sandbox", BRIDGE_API_BASE: "" }), () =>
      assert.throws(() => config.bridgeApiBase(), config.PaymentConfigError),
    );
    withEnv(deployedAs("ctstransportapp", { PAYMENTS_MODE: "live" }), () =>
      assert.throws(() => config.assertBridgeRequestAllowed("http://api.bridgeagw.com/x")),
    );
  });

  test("SMK-08 staging can never use production callback URLs", () => {
    withEnv(
      deployedAs("ctsgo-staging", {
        BRIDGE_CALLBACK_BASE_URL: "https://europe-west2-ctstransportapp.cloudfunctions.net",
      }),
      () => assert.throws(() => config.bridgeCallbackUrl("bridgeTopUpCallback"), config.PaymentConfigError),
    );
    withEnv(
      deployedAs("ctsgo-staging", {
        BRIDGE_CALLBACK_BASE_URL: "https://europe-west2-ctsgo-staging.cloudfunctions.net/",
      }),
      () =>
        assert.equal(
          config.bridgeCallbackUrl("bridgeTopUpCallback"),
          "https://europe-west2-ctsgo-staging.cloudfunctions.net/bridgeTopUpCallback",
        ),
    );
  });

  test("SMK-09 production callback URLs equal the values hardcoded before B0", () => {
    withEnv(
      deployedAs("ctstransportapp", {
        BRIDGE_CALLBACK_BASE_URL: "https://europe-west2-ctstransportapp.cloudfunctions.net",
      }),
      () => {
        assert.equal(
          config.bridgeCallbackUrl("bridgeTopUpCallback"),
          "https://europe-west2-ctstransportapp.cloudfunctions.net/bridgeTopUpCallback",
        );
        assert.equal(
          config.bridgeCallbackUrl("bridgePayoutCallback"),
          "https://europe-west2-ctstransportapp.cloudfunctions.net/bridgePayoutCallback",
        );
      },
    );
  });

  test("SMK-10 Paystack is removed: no Paystack guard remains in the payment configuration", () => {
    assert.equal(config.assertPaystackRequestAllowed, undefined);
  });
});

describe("harness and wiring", () => {
  let stub;
  let bridge;
  let wallet;

  before(async () => {
    stub = await h.startStubGateway();
    bridge = require("../../bridge");
    wallet = require("../../wallet");
  });
  after(async () => {
    await stub.close();
    h.fft.cleanup();
  });
  beforeEach(async () => {
    stub.reset();
    await h.clearFirestore();
    await h.seed("users/pax1", { role: "passenger", displayName: "Test Passenger" });
  });

  test("SMK-11 the production env file matches the pre-B0 hardcoded values", () => {
    const fs = require("node:fs");
    const path = require("node:path");
    const text = fs.readFileSync(path.join(__dirname, "../../.env.ctstransportapp"), "utf8");
    const env = Object.fromEntries(
      text
        .split("\n")
        .filter((l) => l && !l.startsWith("#"))
        .map((l) => l.split("=").map((s) => s.trim())),
    );
    assert.deepEqual(env, {
      PAYMENTS_MODE: "live",
      BRIDGE_API_BASE: "https://api.bridgeagw.com",
      BRIDGE_CALLBACK_BASE_URL: "https://europe-west2-ctstransportapp.cloudfunctions.net",
    });
  });

  test("SMK-12 a top-up reaches only the local stub, with a local callback URL", async () => {
    const result = await h.callCallable(bridge.initiateBridgeTopUp, "pax1", {
      amount: 20,
      phone: "0240000001",
      network: "MTN",
    });
    assert.equal(result.success, true);
    assert.equal(stub.requests.length, 1);
    assert.equal(stub.requests[0].path, "/make_payment");
    const body = stub.requests[0].body;
    assert.equal(body.trans_type, "CTM");
    assert.equal(body.amount, 20);
    assert.match(body.callback_url, /^http:\/\/127\.0\.0\.1:5001\/demo-ctsgo-payments\//);
    assert.doesNotMatch(body.callback_url, /ctstransportapp/);
    const payment = await h.read(`payments/${result.transactionId}`);
    assert.equal(payment.status, "pending");
  });

  test("SMK-13 a misconfigured local run refuses before writing anything", async () => {
    const saved = process.env.BRIDGE_API_BASE;
    process.env.BRIDGE_API_BASE = "https://api.bridgeagw.com";
    try {
      await assert.rejects(
        h.callCallable(bridge.initiateBridgeTopUp, "pax1", {
          amount: 20,
          phone: "0240000001",
          network: "MTN",
        }),
        /Payments are temporarily unavailable/,
      );
    } finally {
      process.env.BRIDGE_API_BASE = saved;
    }
    assert.equal(stub.requests.length, 0);
    const payments = await h.db().collection("payments").get();
    assert.equal(payments.size, 0);
  });

  test("SMK-14 the Paystack callables are removed from the wallet module and the entry point", () => {
    assert.equal(wallet.initializePaystackPayment, undefined);
    assert.equal(wallet.verifyPaystackPayment, undefined);
    // index.js initialises firebase-admin itself, so its exports are checked
    // from the source rather than by loading it a second time here.
    const src = require("node:fs").readFileSync(require("node:path").join(__dirname, "../../index.js"), "utf8");
    for (const name of ["initializePaystackPayment", "verifyPaystackPayment", "paystackWebhook"]) {
      assert.doesNotMatch(src, new RegExp(`^exports\\.${name}\\s*=`, "m"), name);
    }
  });
});

describe("B0 corrections (R-1 to R-4)", () => {
  const PROD = "https://europe-west2-ctstransportapp.cloudfunctions.net";
  const cb = (project, base) =>
    withEnv(deployedAs(project, { BRIDGE_CALLBACK_BASE_URL: base }), () =>
      config.bridgeCallbackUrl("bridgeTopUpCallback"),
    );
  const rejects = (project, base) =>
    assert.throws(() => cb(project, base), config.PaymentConfigError, `${project} accepted ${base}`);

  // ── R-3: exact callback hosts ──────────────────────────────────────────────
  test("R3-01 production accepts only its exact cloudfunctions host and path", () => {
    assert.equal(cb("ctstransportapp", PROD), `${PROD}/bridgeTopUpCallback`);
    assert.equal(cb("ctstransportapp", `${PROD}/`), `${PROD}/bridgeTopUpCallback`);
    rejects("ctstransportapp", `${PROD}/extra`);
    rejects("ctstransportapp", "http://europe-west2-ctstransportapp.cloudfunctions.net");
    rejects("ctstransportapp", "https://europe-west2-ctstransportapp.cloudfunctions.net:8443");
  });

  test("R3-02 production rejects lookalikes that merely contain the project ID", () => {
    rejects("ctstransportapp", "https://ctstransportapp.example.com");
    rejects("ctstransportapp", "https://evil.example/ctstransportapp");
    rejects("ctstransportapp", "https://europe-west2-ctstransportapp.cloudfunctions.net.evil.example");
    rejects("ctstransportapp", "https://us-central1-ctstransportapp.cloudfunctions.net");
    rejects("ctstransportapp", "https://bridgetopupcallback-abc123-nw.a.run.app");
  });

  test("R3-03 a non-production project rejects every production callback form", () => {
    rejects("ctsgo-staging", PROD);
    rejects("ctsgo-staging", "https://bridgetopupcallback-abc123-nw.a.run.app");
    rejects("ctsgo-staging", "https://pay.ctsgo.example");
    rejects("ctsgo-staging", "https://europe-west2-ctsgo-staging.cloudfunctions.net.evil.example");
    rejects("ctsgo-staging", "http://europe-west2-ctsgo-staging.cloudfunctions.net");
    assert.equal(
      cb("ctsgo-staging", "https://europe-west2-ctsgo-staging.cloudfunctions.net"),
      "https://europe-west2-ctsgo-staging.cloudfunctions.net/bridgeTopUpCallback",
    );
  });

  test("R3-04 project IDs containing ctstransportapp use their own host, never production's", () => {
    const own = "https://europe-west2-ctstransportapp-staging.cloudfunctions.net";
    assert.equal(cb("ctstransportapp-staging", own), `${own}/bridgeTopUpCallback`);
    rejects("ctstransportapp-staging", PROD);
    rejects("ctstransportapp", own);
    rejects("staging-ctstransportapp", PROD);
  });

  test("R3-05 callbacks fail closed without a project or a base URL", () => {
    rejects("", PROD);
    rejects("ctstransportapp", "");
  });

  test("R3-06 local runs accept only loopback callbacks", () => {
    assert.match(config.bridgeCallbackUrl("bridgeTopUpCallback"), /^http:\/\/127\.0\.0\.1:5001\//);
    withEnv({ BRIDGE_CALLBACK_BASE_URL: PROD }, () =>
      assert.throws(() => config.bridgeCallbackUrl("bridgeTopUpCallback"), config.PaymentConfigError),
    );
  });

  test("R3-07 FIREBASE_CONFIG alone identifies the project when GCLOUD_PROJECT is absent", () => {
    withEnv(
      deployedAs(undefined, {
        GCLOUD_PROJECT: undefined,
        FIREBASE_CONFIG: JSON.stringify({ projectId: "ctstransportapp" }),
        BRIDGE_CALLBACK_BASE_URL: PROD,
      }),
      () => assert.equal(config.bridgeCallbackUrl("bridgeTopUpCallback"), `${PROD}/bridgeTopUpCallback`),
    );
  });

  // ── R-4: no live gateway in sandbox ────────────────────────────────────────
  test("R4-01 sandbox mode rejects the live gateway host, in any letter case", () => {
    withEnv(deployedAs("ctsgo-staging", { PAYMENTS_MODE: "sandbox" }), () => {
      for (const url of [
        "https://api.bridgeagw.com/make_payment",
        "https://API.BRIDGEAGW.COM/make_payment",
        "https://api.bridgeagw.com:443/make_payment",
      ]) {
        assert.throws(() => config.assertBridgeRequestAllowed(url), config.PaymentConfigError, url);
      }
      config.assertBridgeRequestAllowed("https://sandbox.gateway.example/make_payment");
    });
  });

  test("R4-02 sandbox rejection also applies to project IDs containing ctstransportapp", () => {
    withEnv(deployedAs("ctstransportapp-staging", { PAYMENTS_MODE: "sandbox" }), () =>
      assert.throws(
        () => config.assertBridgeRequestAllowed("https://api.bridgeagw.com/make_payment"),
        config.PaymentConfigError,
      ),
    );
  });

  test("R4-03 production live mode still reaches the live gateway (unchanged)", () => {
    withEnv(deployedAs("ctstransportapp", { PAYMENTS_MODE: "live" }), () =>
      config.assertBridgeRequestAllowed("https://api.bridgeagw.com/make_payment"),
    );
  });

  // ── R-2: payout guard before any write or hold ─────────────────────────────
  describe("R-2 initiateBridgePayout", () => {
    let stub;
    let bridge;
    before(async () => {
      stub = await h.startStubGateway();
      bridge = require("../../bridge");
    });
    after(() => stub.close());
    beforeEach(async () => {
      stub.reset();
      await h.clearFirestore();
      await h.seed("drivers/drv1", {
        displayName: "Driver One",
        phone: "0200000001",
        isApproved: true,
        walletBalance: 100,
        totalEarnings: 100,
        commissionOwed: 0,
      });
    });

    const request = () =>
      h.callCallable(bridge.initiateBridgePayout, "drv1", {
        amount: 50,
        phone: "0200000001",
        network: "MTN",
      });

    async function assertNothingWritten() {
      const d = await h.read("drivers/drv1");
      assert.equal(d.walletBalance, 100, "funds were held");
      assert.equal(d.totalEarnings, 100);
      assert.equal(d.pendingWithdrawal, undefined);
      for (const col of ["withdrawals", "transactions", "ledger", "payments"]) {
        assert.equal((await h.db().collection(col).get()).size, 0, `${col} was written`);
      }
      assert.equal(stub.requests.length, 0, "a request reached the gateway");
    }

    test("R2-01 a refused gateway host stops the payout before the funds hold", async () => {
      const saved = process.env.BRIDGE_API_BASE;
      process.env.BRIDGE_API_BASE = "https://api.bridgeagw.com";
      try {
        await assert.rejects(request(), /temporarily unavailable/);
      } finally {
        process.env.BRIDGE_API_BASE = saved;
      }
      await assertNothingWritten();
    });

    test("R2-02 a refused callback URL stops the payout before the funds hold", async () => {
      const saved = process.env.BRIDGE_CALLBACK_BASE_URL;
      process.env.BRIDGE_CALLBACK_BASE_URL = PROD;
      try {
        await assert.rejects(request(), /temporarily unavailable/);
      } finally {
        process.env.BRIDGE_CALLBACK_BASE_URL = saved;
      }
      await assertNothingWritten();
    });

    test("R2-03 an invalid payments mode stops the payout before the funds hold", async () => {
      const saved = process.env.PAYMENTS_MODE;
      process.env.PAYMENTS_MODE = "live";
      try {
        await assert.rejects(request(), /temporarily unavailable/);
      } finally {
        process.env.PAYMENTS_MODE = saved;
      }
      await assertNothingWritten();
    });
  });

  // ── R-1: only Bridge secrets are declared (Paystack's was removed); any
  // other secret added later must be documented as a staging deploy blocker
  test("R1-01 the runbook blocks staging Functions deploys while a non-Bridge secret is declared", () => {
    const { execFileSync } = require("node:child_process");
    const fs = require("node:fs");
    const path = require("node:path");
    const out = execFileSync(
      process.execPath,
      [
        "-e",
        "require('./index.js'); console.log(JSON.stringify(require('firebase-functions/params')" +
          ".declaredParams.filter(p => p.constructor.name === 'SecretParam').map(p => p.name)))",
      ],
      {
        cwd: path.join(__dirname, "../.."),
        env: { ...process.env, GCLOUD_PROJECT: "demo-check", FIRESTORE_EMULATOR_HOST: "" },
      },
    );
    const secrets = JSON.parse(String(out).trim().split("\n").pop());
    const bridgeSecrets = ["BRIDGE_CLIENT_KEY", "BRIDGE_SECRET_KEY", "BRIDGE_SERVICE_ID"];
    for (const s of bridgeSecrets) assert.ok(secrets.includes(s), `${s} not declared`);

    const others = secrets.filter((s) => !bridgeSecrets.includes(s));
    const runbook = fs.readFileSync(path.join(__dirname, "../../PAYMENTS-STAGING.md"), "utf8");
    if (others.length > 0) {
      assert.match(runbook, /STAGING FUNCTIONS DEPLOY BLOCKED/, `undocumented deploy secrets: ${others}`);
      for (const s of others) assert.ok(runbook.includes(s), `runbook does not mention ${s}`);
    }
  });
});
