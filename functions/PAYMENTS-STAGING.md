# Payments: environments, staging and local tests

Bridge (`api.bridgeagw.com`) is the only active payment gateway, used for
mobile-money top-ups and driver payouts. Paystack is **retired**: do not
configure it anywhere new (see "Paystack" below).

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
- Paystack: refused everywhere except production.

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
   loads. The retired Paystack code still declares `PAYSTACK_SECRET_KEY`
   (`wallet.js`, `escrow.js`), so a staging deploy today would either fail
   (non-interactive) or prompt you to create a Paystack secret in staging.
   Do neither. Do not create a placeholder secret either.

   STAGING FUNCTIONS DEPLOY BLOCKED until the separate Paystack retirement
   change has removed both `defineSecret("PAYSTACK_SECRET_KEY")` declarations.
   Confirm with:

       GCLOUD_PROJECT=demo-check node -e "require('./index.js'); console.log(require('firebase-functions/params').declaredParams.filter(p => p.constructor.name === 'SecretParam').map(p => p.name))"

   The output must list only `BRIDGE_CLIENT_KEY`, `BRIDGE_SECRET_KEY` and
   `BRIDGE_SERVICE_ID`. Then deploy only the functions under test:

       firebase deploy --project staging --only "functions:initiateBridgeTopUp,functions:bridgeTopUpCallback,functions:checkBridgeTopUpStatus,functions:initiateBridgePayout,functions:bridgePayoutCallback,functions:approveWithdrawal,functions:rejectWithdrawal,functions:createWallet,functions:createPassengerWallet"

7. Register the staging callback URLs with Bridge if they require it (unknown):
   `https://europe-west2-<staging-id>.cloudfunctions.net/bridgeTopUpCallback`
   and `.../bridgePayoutCallback`.
8. Verify: `bash ../rules-tests/scripts/check-deployed-rules.sh <staging-id>` and
   `firebase functions:list --project staging`.

Always pass `--project`. `.firebaserc` still defaults to production.

## Production deploy freeze (until B1)

A full `firebase deploy --only functions` from this repository would deploy
`approveWithdrawal` and `rejectWithdrawal` (not live today) with known payout
defects, and the current `initiateBridgePayout`, which fails after holding
funds. Do not deploy payout functions to production before B1.

## Paystack (retired)

No Paystack credentials, callbacks or staging endpoints are to be configured.
Remaining references are documented in the B0 report; removal is a separate,
tightly scoped change. Until then the production endpoints are unchanged, and
`config.js` refuses Paystack calls in every other environment.

## Open questions for Bridge

See the B0 report. Until they are answered, do not assume Bridge offers
callback signatures, IP allow-lists, idempotency headers, a sandbox, or a
transaction-status API.


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