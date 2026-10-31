# Payments: environments, staging and local tests

The Bridge Solutions (https://thebridgesolutions.com/, gateway
`api.bridgeagw.com`) is the only payment provider, used for mobile-money
top-ups and driver payouts. Paystack has been **removed** from the code
(see "Paystack" below).

## How environments are kept apart

| | Production | Staging | Local tests |
|---|---|---|---|
| Firebase project | `ctstransportapp` | a separate project (not yet created) | `demo-ctsgo-payments` (emulator only) |
| Non-secret config | `functions/.env.ctstransportapp` | `functions/.env.staging` (copy of `.env.staging.example`) | set by `test/payments/helpers.js`; `.env.local` for the Functions emulator |
| Bridge credentials | Secret Manager in production | Secret Manager in staging (separate values) | fake values from `.secret.local` or the test harness |
| `PAYMENTS_MODE` | `live` | `sandbox` | `stub` |

`functions/config.js` checks every Bridge request before anything is written,
and refuses it unless all of these agree:

- `live` only in `ctstransportapp`; `sandbox` never in `ctstransportapp`.
- Local runs (Functions or Firestore emulator, or any `demo-` project) only in
  `stub` mode and only to `127.0.0.1`/`localhost`.
- Outside local runs, https only; an empty or unknown mode disables payments.
- Callback URLs (deployed): https, host exactly
  `europe-west2-<this project>.cloudfunctions.net`, path `/<function>`.
  Custom domains, `run.app` URLs, other regions and other projects are refused,
  so no non-production project can name a production callback. Local runs:
  loopback only.
- Sandbox mode refuses the live gateway host `api.bridgeagw.com` until Bridge
  confirms how its sandbox is reached.

A refused request returns "Payments are temporarily unavailable." to the app
and logs the reason; it never falls back to another host.

## Local tests (no network beyond localhost)

Requirements: Node 22+, firebase-tools 15+, Java 21+ (the Firestore emulator
refuses older JDKs). If your default `java` is older:

    export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 PATH=$JAVA_HOME/bin:$PATH

From `functions/`:

    npm run test:payments:smoke      # must pass: harness, guard, wiring
    npm run test:payments:security   # B1 acceptance tests; most fail until B1

The tests call functions in-process against the Firestore emulator. Bridge is
replaced by a local stub (`startStubGateway` in `test/payments/helpers.js`) that
only mimics the response shape the code already reads. It does not describe
the real provider; update it when Bridge documentation is available.

## Creating staging (one-time, by the project owner)

1. Create a Firebase project on the Blaze plan with a budget alert. Use the
   functions region `europe-west2` and the same Firestore location as
   production (confirm production's location first).
2. Add an alias: `firebase use --add` → choose the project → name it `staging`.
3. Copy `functions/.env.staging.example` to `functions/.env.staging` and fill in
   the staging project ID. Leave `BRIDGE_API_BASE` empty until Bridge confirms
   a sandbox host; payments stay disabled until then.
4. Set staging-only Bridge credentials (never production's):

       firebase functions:secrets:set BRIDGE_CLIENT_KEY --project staging
       firebase functions:secrets:set BRIDGE_SECRET_KEY --project staging
       firebase functions:secrets:set BRIDGE_SERVICE_ID --project staging

5. Deploy rules and indexes (safe at any time):

       firebase deploy --only firestore:rules,firestore:indexes --project staging

6. **Gate before the first staging Functions deploy.** Every Functions deploy,
   even `--only functions:<name>`, checks *every* secret declared anywhere in
   the codebase, because `defineSecret` registers each secret when its file
   loads. The Paystack code and its `PAYSTACK_SECRET_KEY` declarations have
   been removed, so only the Bridge secrets remain. Do not create a Paystack
   or placeholder secret. Confirm before deploying with:

       GCLOUD_PROJECT=demo-check node -e "require('./index.js'); console.log(require('firebase-functions/params').declaredParams.filter(p => p.constructor.name === 'SecretParam').map(p => p.name))"

   The output must list only `BRIDGE_CLIENT_KEY`, `BRIDGE_SECRET_KEY` and
   `BRIDGE_SERVICE_ID`, plus `ROUTES_API_KEY` (below). Then deploy only the functions under test:

   **STAGING FUNCTIONS DEPLOY BLOCKED until `ROUTES_API_KEY` exists in that
   project.** Release v5 declares `ROUTES_API_KEY` (`delivery_quotes.js`: a
   Google Maps Platform key restricted to the Routes API, used server-side by
   `quoteDelivery` to measure Delivery routes). Because every deploy checks
   every declared secret, no Functions deploy from this source succeeds in a
   project without it — staging or production. Create a project-specific key
   (never the Passenger App's client key) and set it first:

       firebase functions:secrets:set ROUTES_API_KEY --project staging

   Then the functions under test:

       firebase deploy --project staging --only "functions:initiateBridgeTopUp,functions:bridgeTopUpCallback,functions:checkBridgeTopUpStatus,functions:initiateBridgePayout,functions:bridgePayoutCallback,functions:approveWithdrawal,functions:rejectWithdrawal,functions:createWallet,functions:createPassengerWallet"

7. Register the staging callback URLs with Bridge if they require it (unknown):
   `https://europe-west2-<staging-id>.cloudfunctions.net/bridgeTopUpCallback`
   and `.../bridgePayoutCallback`.
8. Verify: `bash ../rules-tests/scripts/check-deployed-rules.sh <staging-id>` and
   `firebase functions:list --project staging`.

Always pass `--project`. `.firebaserc` still defaults to production.

## Payment safety (local code; not yet deployed)

There is no global payment freeze. Safety is per transaction:

- Top-ups start normally and stay **pending** until their result is
  confirmed through a documented, authenticated mechanism. None exists yet
  (see "Open questions for Bridge"), so no top-up is credited automatically.
  `checkBridgeTopUpStatus` returns `awaitingVerification: true` once Bridge
  has reported a result that cannot be verified; the app then tells the
  customer not to pay again.
- `initiateBridgePayout` queues every request for admin review (no automatic
  payout), one open withdrawal per driver, from `walletBalance` only.
  `approveWithdrawal`, `rejectWithdrawal` and `resolveUnconfirmedPayout` are
  admin-only; the Admin app calls them and writes nothing itself.
- Callbacks never move money. `requestWithdrawal` and
  `requestDriverWithdrawal` are retired.

Deploy the Firestore rules (withdrawals and wallets admin-create) before any
of these. Do not run a full `firebase deploy --only functions` from this
repository.

## Paystack (removed)

`initializePaystackPayment`, `verifyPaystackPayment` and `paystackWebhook`,
the Paystack configuration guard and the `PAYSTACK_SECRET_KEY` declarations
were removed from the code, and the Passenger app no longer calls Paystack.
Removing an export does **not** delete a deployed function: after the
replacement code is deployed, the three deployed Paystack functions must be
deleted explicitly (`firebase functions:delete initializePaystackPayment
verifyPaystackPayment paystackWebhook --region europe-west2 --project
ctstransportapp`), and the Paystack webhook URL removed from the Paystack
dashboard. Both are production changes that need separate approval.

## Open questions for Bridge

See the B0 report. Until they are answered, do not assume Bridge offers
callback signatures, IP allow-lists, idempotency headers, a sandbox, or a
transaction-status API.

What the code knows today: outbound requests go to `POST {apiBase}/make_payment`
(`trans_type` CTM for top-ups, MTC for payouts) with HTTP Basic auth
(client key : secret key). Callbacks arrive as JSON
`{ trans_ref, trans_status, trans_id, amount }` with nothing that proves they
came from Bridge.

The provider's public website and merchant portal publish no API
documentation (checked 2026-10-16); the API host requires credentials. The
answers must come from The Bridge Solutions directly.

**Current behaviour:** `bridgeTopUpCallback` and
`bridgePayoutCallback` verify nothing they cannot verify. Every callback is
recorded in `bridge_callbacks` (one `bridge_callback_unverified` admin alert
per payment) and **never** credits a wallet, refunds a payout or marks one
paid. Payouts are settled only by an admin with `resolveUnconfirmedPayout`
after confirming the result with Bridge; top-ups stay pending (not credited)
until verification exists. `verifyBridgeCallback` in `bridge.js` is the
single place to implement verification once Bridge answers.

Questions to send Bridge (all needed before callbacks may move money):

1. Do callbacks carry a signature? Header name, algorithm (e.g. HMAC-SHA256),
   the exact bytes signed (raw body? which fields, in what order?), the key
   used (our secret key or a separate webhook secret), and any timestamp or
   nonce for replay protection with its tolerance.
2. If not signed: is there a fixed list of source IP addresses for callbacks,
   and is it guaranteed and announced before it changes?
3. Is there an authenticated transaction-status endpoint (path, method,
   parameters, response fields) we can call server-to-server to confirm a
   `trans_ref` before acting on its callback? Its rate limits?
4. The meaning of every `trans_status` (000, 001, 002, 003, others): which are
   final, and can a final status ever change?
5. Can a callback for one `trans_ref` arrive more than once, out of order, or
   with a different `trans_id`; which value identifies the payment uniquely?
6. Is `amount` in the callback always the requested amount, in GHS, as a
   number or a string; can a payment settle for a different amount?
7. For `make_payment`: when the HTTP request times out or returns 5xx, can the
   payout still be executed? Is resending the same `transaction_id`
   idempotent (rejected as a duplicate) or a second payment?
8. Which `make_payment` response codes guarantee that no money moved (safe to
   refund immediately)? Today only an explicit non-000/202 response code is
   treated that way.
9. Is there a sandbox (host, credentials, test numbers) and does it send
   callbacks?
10. Do callback URLs need registering with Bridge, per environment?


Account & Usage

Account
Auth method
Claude AI
Email
dessel015@gmail.com
Organization
dessel015@gmail.com's Organization
Plan
Claude pro
Usage
Session (5hr)
68%
Resets in 2h
Weekly (7 day)
100%
Resets in 19h
Manage usage on claude.ai
What’s contributing to your limits usage?
Day
Week
Approximate, based on local sessions on this machine — does not include other devices or claude.ai
Last 24h · these are independent characteristics of your usage, not a breakdown
93% of your usage was at >150k context
Longer sessions are more expensive even when cached. /compact mid-task, /clear when switching to new tasks.
MCP servers
% of usage
claude-vscode