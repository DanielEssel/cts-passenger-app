// Gas supplier settlement payouts (gas_supplier_payouts.js): off unless
// switched on; super admins only; one Bridge request per attempt; a supplier
// payout is paid only when a super admin records Bridge's confirmation;
// driver statements are credited to the driver wallet exactly once. The
// Bridge request is replaced by a fake: nothing leaves the test.
// Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const p = require("../../gas_supplier_payouts");

const SUPER = "gsp-super", ADMIN = "gsp-admin", INACTIVE = "gsp-inactive", PAX = "gsp-pax", DRIVER = "gsp-driver";
const S = "sup1";
const SUP_STMT = `2026-10-27__supplier__${S}`;
const DRV_STMT = `2026-10-27__driver__${DRIVER}`;
const call = (fn, data, uid) => h.callCallable(fn, uid, data);

async function rejects(promise, code, reason) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, `${e.code}: ${e.message} ${JSON.stringify(e.details)}`);
    if (reason) assert.equal(e.details?.reason, reason, JSON.stringify(e.details));
    return true;
  });
}

/** What prepareStatements writes (gas_settlement_ledger.js). */
const statement = (id, party, partyId, netPesewas, o = {}) => ({
  statementId: id, businessDate: "2026-10-27", party, partyId, currency: "GHS",
  lines: [{ entryId: `o1__${party}__entitlement`, orderId: "o1", kind: "entitlement", amountPesewas: netPesewas }],
  creditsPesewas: netPesewas, debitsPesewas: 0, netPesewas, status: netPesewas > 0 ? "prepared" : "prepared_no_payout",
  payoutStatus: "not_started", payoutMethod: null, preparedBy: "test", preparedAt: new Date(), ...o,
});

/** A fake Bridge: each call records its request and answers with the next outcome. */
let sent;
let answers;
function bridgeAnswers(...list) {
  answers = list;
  p._setTransportForTests(async (req) => {
    sent.push(req);
    const a = answers.shift() ?? "000";
    if (a instanceof Error) throw a;
    return { data: { response_code: a } };
  });
}

after(() => { p._setTransportForTests(null); return h.fft.cleanup(); });
beforeEach(async () => {
  await h.clearFirestore();
  sent = [];
  bridgeAnswers("000");
  await h.seed(p.PAYOUT_FLAG_DOC, { enabled: true });
  await h.seed(`admins/${SUPER}`, { active: true, role: "super_admin", email: "s@test" });
  await h.seed(`admins/${ADMIN}`, { active: true, role: "admin" });
  await h.seed(`admins/${INACTIVE}`, { active: false, role: "super_admin" });
  await h.seed(`gas_suppliers/${S}`, { legalName: "Supplier A Ltd", tradingName: "Supplier A", status: "approved",
    payoutPreference: { method: "mtn_momo", accountNumber: "0241234567", accountName: "Supplier A Ltd" } });
  await h.seed(`drivers/${DRIVER}`, { walletBalance: 10, totalEarnings: 100 });
  await h.seed(`gas_settlement_statements/${SUP_STMT}`, statement(SUP_STMT, "supplier", S, 27000));
  await h.seed(`gas_settlement_statements/${DRV_STMT}`, statement(DRV_STMT, "driver", DRIVER, 2160));
  // Each line's claim, as prepareStatements creates it with the statement.
  for (const [id, party] of [[SUP_STMT, "supplier"], [DRV_STMT, "driver"]]) {
    await h.seed(`gas_settlement_claims/o1__${party}__entitlement`, { entryId: `o1__${party}__entitlement`, statementId: id, claimedAt: new Date() });
  }
});

const approve = (uid = SUPER, id = SUP_STMT) => call(p.adminApproveGasSupplierPayout, { statementId: id }, uid);
const resolve = (outcome, evidence = "Bridge ticket 12345", uid = SUPER) =>
  call(p.adminResolveGasSupplierPayout, { statementId: SUP_STMT, outcome, evidence }, uid);
const settleDriver = (uid = SUPER) => call(p.adminSettleGasDriverStatement, { statementId: DRV_STMT }, uid);
const stmt = (id = SUP_STMT) => h.read(`gas_settlement_statements/${id}`);

describe("rules", () => {
  test("GSP-U01 Mobile Money details map to Bridge, masked; anything malformed is refused", () => {
    const d = p.payoutDestination({ payoutPreference: { method: "telecel_cash", accountNumber: "0201234567", accountName: " Ama Mensah " } });
    assert.deepEqual(d, { network: "VOD", method: "telecel_cash", accountName: "Ama Mensah", phone: "233201234567", maskedNumber: "020****567" });
    assert.equal(p.payoutDestination({ payoutPreference: { method: "at_money", accountNumber: "0261234567", accountName: "Kofi" } }).network, "AIR");
    for (const bad of [null, {}, { method: "bank", accountNumber: "0241234567", accountName: "X Y" },
      { method: "mtn_momo", accountNumber: "241234567", accountName: "X Y" }, { method: "mtn_momo", accountNumber: "0241234567", accountName: "X" }]) {
      assert.equal(p.payoutDestination({ payoutPreference: bad }), null, JSON.stringify(bad));
    }
    assert.equal(p.previousBusinessDate(Date.parse("2026-10-28T02:00:00Z")), "2026-10-27");
  });
});

describe("authorization and switch", () => {
  test("GSP-A01 only active super admins may approve, resolve or settle", async () => {
    for (const uid of [ADMIN, INACTIVE, PAX, S, null]) {
      const code = uid ? "permission-denied" : "unauthenticated";
      await rejects(approve(uid), code);
      await rejects(resolve("paid", "Bridge ticket 1", uid), code);
      await rejects(settleDriver(uid), code);
    }
    assert.equal(sent.length, 0);
    assert.equal((await stmt()).payoutStatus, "not_started");
    assert.equal((await h.read(`drivers/${DRIVER}`)).walletBalance, 10);
  });

  test("GSP-A02 while supplier payouts are off nothing is sent; a payout in progress can still be resolved", async () => {
    await approve();
    for (const flag of [null, { enabled: false }, { enabled: "true" }]) {
      if (flag) await h.seed(p.PAYOUT_FLAG_DOC, flag); else await h.db().doc(p.PAYOUT_FLAG_DOC).delete();
      await rejects(approve(), "unavailable", "gas_supplier_payouts_disabled");
    }
    assert.equal(sent.length, 1, "only the approval made while on");
    assert.equal((await resolve("paid")).payoutStatus, "paid");
  });

  test("GSP-A03 driver statements are credited to the driver wallet while supplier payouts stay off; no Bridge request", async () => {
    await h.db().doc(p.PAYOUT_FLAG_DOC).delete();
    assert.equal((await settleDriver()).payoutStatus, "paid");
    assert.equal(Math.round((await h.read(`drivers/${DRIVER}`)).walletBalance * 100), 1000 + 2160);
    assert.equal(sent.length, 0);
  });
});

describe("supplier Mobile Money payout", () => {
  test("GSP-S01 approval sends exactly the statement's net to the supplier's Mobile Money, and pays nothing by itself", async () => {
    const r = await approve();
    assert.equal(r.outcome, "sent");
    assert.equal(sent.length, 1);
    assert.deepEqual({ ...sent[0], transactionId: undefined },
      { transactionId: undefined, amount: 270, phone: "233241234567", network: "MTN", name: "Supplier A" });
    const s = await stmt();
    assert.deepEqual([s.payoutStatus, s.payoutMethod, s.payout.outcome, s.payout.amountPesewas, s.payout.maskedNumber, s.payout.approvedBy],
      ["payout_in_progress", "mobile_money", "sent", 27000, "024****567", SUPER]);
    assert.equal(s.payout.transactionId, sent[0].transactionId);
    const payment = await h.read(`payments/${s.payout.transactionId}`);
    assert.deepEqual([payment.type, payment.supplierId, payment.amount, payment.status, payment.userId], ["gas_supplier_payout", S, 270, "pending", null]);
    assert.equal(await h.read(`ledger/gas_supplier_payout_${SUP_STMT}`), null, "accepted by Bridge is not paid");
  });

  test("GSP-S02 repeated and concurrent approvals send one request", async () => {
    const runs = await Promise.allSettled([approve(), approve(), approve()]);
    assert.equal(runs.filter((x) => x.status === "fulfilled").length, 1);
    await rejects(approve(), "failed-precondition", "payout_payout_in_progress");
    assert.equal(sent.length, 1);
  });

  test("GSP-S03 paid only on a recorded confirmation with evidence; once; never re-sent afterwards", async () => {
    await approve();
    await rejects(resolve("paid", "ok"), "invalid-argument", "evidence_required");
    await rejects(resolve("maybe"), "invalid-argument", "invalid_outcome");
    assert.equal((await stmt()).payoutStatus, "payout_in_progress");
    assert.equal((await resolve("paid")).payoutStatus, "paid");
    const s = await stmt();
    assert.deepEqual([s.payoutStatus, s.payout.outcome, s.payout.resolvedBy, s.payout.resolutionEvidence], ["paid", "confirmed_paid", SUPER, "Bridge ticket 12345"]);
    assert.equal((await h.read(`payments/${s.payout.transactionId}`)).status, "success");
    const row = await h.read(`ledger/gas_supplier_payout_${SUP_STMT}`);
    assert.deepEqual([row.type, row.amount, row.supplierId, row.toUserId], ["PAYOUT", 270, S, null]);
    await rejects(resolve("paid"), "failed-precondition", "payout_paid");
    await rejects(resolve("failed"), "failed-precondition", "payout_paid");
    await rejects(approve(), "failed-precondition", "payout_paid");
    assert.equal(sent.length, 1);
    assert.equal(await h.count("audit_log", "statementId", SUP_STMT), 3, "approved, sent, confirmed");
  });

  test("GSP-S04 a refusal fails the attempt; a new approval is a new attempt with a new transaction id", async () => {
    bridgeAnswers("001", "000");
    await rejects(approve(), "failed-precondition", "payout_refused");
    const failed = await stmt();
    assert.deepEqual([failed.payoutStatus, failed.payout.outcome], ["failed", "refused"]);
    await rejects(resolve("paid"), "failed-precondition", "payout_failed");
    await approve();
    const again = await stmt();
    assert.deepEqual([again.payoutStatus, again.payout.attempt], ["payout_in_progress", 2]);
    assert.notEqual(sent[0].transactionId, sent[1].transactionId);
  });

  test("GSP-S05 an unknown outcome is held for a person: alert, no re-send; confirmed failed may be approved again", async () => {
    bridgeAnswers(Object.assign(new Error("timeout of 20000ms exceeded"), { response: undefined }));
    await rejects(approve(), "unavailable", "payout_outcome_unknown");
    assert.deepEqual([(await stmt()).payoutStatus, (await stmt()).payout.outcome], ["payout_in_progress", "unknown"]);
    assert.equal(await h.count("admin_alerts", "type", "gas_supplier_payout_unconfirmed"), 1);
    const [unconfirmed] = (await h.db().collection("admin_alerts").where("type", "==", "gas_supplier_payout_unconfirmed").get()).docs.map((d) => d.data());
    assert.deepEqual([unconfirmed.read, unconfirmed.severity, typeof unconfirmed.message, typeof unconfirmed.createdAt?.toMillis], [false, "high", "string", "function"]);
    await rejects(approve(), "failed-precondition", "payout_payout_in_progress");
    assert.equal(sent.length, 1);
    assert.equal((await resolve("failed")).payoutStatus, "failed");
    assert.equal(await h.read(`ledger/gas_supplier_payout_${SUP_STMT}`), null);
    await approve();
    assert.equal(sent.length, 2);
  });

  test("GSP-S06 an unrecognised Bridge code is unknown, never paid", async () => {
    bridgeAnswers("002");
    await rejects(approve(), "unavailable", "payout_outcome_unknown");
    assert.equal((await stmt()).payout.outcome, "unknown");
  });

  test("GSP-S07 nothing sent (configuration refused): back to not started, may be approved again", async () => {
    bridgeAnswers(new p.NotSentError("Payments are temporarily unavailable."));
    await rejects(approve(), "unavailable", "payout_not_sent");
    assert.deepEqual([(await stmt()).payoutStatus, (await stmt()).payout.outcome], ["not_started", "not_sent"]);
    await approve();
    assert.equal((await stmt()).payoutStatus, "payout_in_progress");
  });

  test("GSP-S08 refused before sending: wrong party, nothing to pay, unapproved supplier, missing payout details", async () => {
    await rejects(approve(SUPER, DRV_STMT), "failed-precondition", "wrong_party");
    await rejects(approve(SUPER, "nope"), "failed-precondition", "statement_not_found");
    await h.seed(`gas_settlement_statements/${SUP_STMT}`, statement(SUP_STMT, "supplier", S, 0));
    await rejects(approve(), "failed-precondition", "nothing_to_pay");
    await h.seed(`gas_settlement_statements/${SUP_STMT}`, statement(SUP_STMT, "supplier", S, 27000));
    await h.db().doc(`gas_suppliers/${S}`).update({ status: "suspended" });
    await rejects(approve(), "failed-precondition", "supplier_not_approved");
    await h.db().doc(`gas_suppliers/${S}`).update({ status: "approved", payoutPreference: null });
    await rejects(approve(), "failed-precondition", "payout_details_missing");
    assert.equal(sent.length, 0);
    assert.equal((await stmt()).payoutStatus, "not_started");
  });
});

describe("stale attempts", () => {
  test("GSP-S09 a late Bridge answer never overrides an admin's resolution of a stale attempt", async () => {
    // While the request is out, the attempt goes stale and an admin records it as failed.
    p._setTransportForTests(async (req) => {
      sent.push(req);
      await h.db().doc(`gas_settlement_statements/${SUP_STMT}`).update({ "payout.sendingStartedAt": new Date(Date.now() - 11 * 60 * 1000) });
      await resolve("failed", "Bridge ticket 999 not paid");
      return { data: { response_code: "000" } };
    });
    await rejects(approve(), "aborted", "payout_attempt_superseded");
    const s = await stmt();
    assert.deepEqual([s.payoutStatus, s.payout.outcome], ["failed", "confirmed_failed"]);
    assert.equal(await h.count("admin_alerts", "type", "gas_supplier_payout_attempt_superseded"), 1);
  });

  test("GSP-S10 a fresh attempt still sending cannot be resolved", async () => {
    p._setTransportForTests(async (req) => {
      sent.push(req);
      await rejects(resolve("paid"), "failed-precondition", "payout_sending");
      return { data: { response_code: "000" } };
    });
    await approve();
    assert.equal((await stmt()).payoutStatus, "payout_in_progress");
  });
});

describe("resolution concurrency", () => {
  test("GSP-S11 concurrent 'paid' and 'failed' resolutions: exactly one wins; paid is recorded at most once", async () => {
    await approve();
    const runs = await Promise.allSettled([resolve("paid", "Bridge ref A1"), resolve("failed", "Bridge ref A2"), resolve("paid", "Bridge ref A3")]);
    assert.equal(runs.filter((x) => x.status === "fulfilled").length, 1);
    const s = await stmt();
    const ledgerRow = await h.read(`ledger/gas_supplier_payout_${SUP_STMT}`);
    if (s.payoutStatus === "paid") assert.ok(ledgerRow); else { assert.equal(s.payoutStatus, "failed"); assert.equal(ledgerRow, null); }
    assert.equal(sent.length, 1);
  });
});

describe("driver wallet settlement", () => {
  test("GSP-D01 a driver statement is credited to the driver's wallet exactly once", async () => {
    const runs = await Promise.allSettled([settleDriver(), settleDriver(), settleDriver()]);
    assert.equal(runs.filter((x) => x.status === "fulfilled").length, 1);
    await rejects(settleDriver(), "failed-precondition", "payout_paid");
    const d = await h.read(`drivers/${DRIVER}`);
    assert.deepEqual([Math.round(d.walletBalance * 100), Math.round(d.totalEarnings * 100)], [1000 + 2160, 10000 + 2160]);
    const s = await stmt(DRV_STMT);
    assert.deepEqual([s.payoutStatus, s.payoutMethod], ["paid", "driver_wallet"]);
    const row = await h.read(`ledger/gas_driver_settlement_${DRV_STMT}`);
    assert.deepEqual([row.type, row.toUserId, row.amount], ["EARNING", DRIVER, 21.6]);
    assert.equal(sent.length, 0, "no Bridge request for a wallet credit");
    await rejects(call(p.adminSettleGasDriverStatement, { statementId: SUP_STMT }, SUPER), "failed-precondition", "wrong_party");
  });
});

// ── Linked riders: payout guards and server-side reconciliation (spec §3.7) ──

const L = require("../../gas_settlement_ledger");

describe("payout guards and reconciliation", () => {
  const ACTOR = { uid: SUPER, email: "s@test" };
  /** A statement whose lines are [[orderId, amountPesewas], …], with each line's claim. */
  async function seedStatement(id, party, partyId, amounts, o = {}) {
    const lines = amounts.map(([orderId, amountPesewas]) => ({ entryId: `${orderId}__${party}__entitlement`, orderId, kind: "entitlement", amountPesewas }));
    const net = amounts.reduce((s, [, a]) => s + a, 0);
    await h.seed(`gas_settlement_statements/${id}`, statement(id, party, partyId, net, { lines, creditsPesewas: net, ...o }));
    for (const l of lines) await h.seed(`gas_settlement_claims/${l.entryId}`, { entryId: l.entryId, statementId: id, claimedAt: new Date() });
  }
  /** What reverseOrderEntitlements writes for a reversed, already-claimed line (gas_settlement_ledger.js). */
  async function seedDebt(statementId, party, partyId, orderId, amountPesewas, o = {}) {
    const debtId = `${orderId}__${party}__reversal`;
    await h.seed(`${L.DEBTS}/${debtId}`, {
      debtId, party, partyId, orderId, reversalEntryId: debtId, originalEntryId: `${orderId}__${party}__entitlement`, statementId,
      amountPesewas, currency: "GHS", stage: "before_payout", status: "outstanding", reversalReason: "Refunded",
      reversedBy: SUPER, version: 1, createdAt: new Date(), ...o,
    });
    await h.seed(`gas_settlement_claims/${debtId}`, { entryId: debtId, debtId, claimedAt: new Date() });
    return debtId;
  }
  const withhold = (debtId, expectedVersion = 1) =>
    L.resolveSettlementDebt(ACTOR, { debtId, action: "resolve", resolution: "withhold", expectedVersion, reason: "Withhold from this statement" });
  const pesewas = async () => Math.round((await h.read(`drivers/${DRIVER}`)).walletBalance * 100);
  const size = async (c) => (await h.db().collection(c).get()).size;

  test("GSP-LR01 two concurrent credits of one statement: one ledger row, one wallet increase by the payable amount, no payments record", async () => {
    await seedStatement(DRV_STMT, "driver", DRIVER, [["o1", 1600], ["o2", 560]], { withheldPesewas: 560, payablePesewas: 1600 });
    await seedDebt(DRV_STMT, "driver", DRIVER, "o2", 560, { status: "resolved", resolution: "withhold", version: 2 });
    const runs = await Promise.allSettled([settleDriver(), settleDriver()]);
    assert.equal(runs.filter((x) => x.status === "fulfilled").length, 1);
    assert.equal(runs.find((x) => x.status === "rejected").reason.details?.reason, "payout_paid");
    assert.equal(await pesewas(), 1000 + 1600, "credited once, by payablePesewas");
    const rows = (await h.db().collection("ledger").get()).docs;
    assert.deepEqual(rows.map((d) => d.id), [`gas_driver_settlement_${DRV_STMT}`]);
    assert.deepEqual([rows[0].data().type, rows[0].data().amount], ["EARNING", 16]);
    const audits = (await h.db().collection("audit_log").where("action", "==", "gas_driver_statement_settled").get()).docs.map((d) => d.data());
    assert.deepEqual(audits.map((a) => a.amountPesewas), [1600]);
    assert.equal(await size("payments"), 0, "a wallet credit is never a payment");
    const s = await stmt(DRV_STMT);
    assert.deepEqual([s.payoutStatus, s.payoutMethod, s.payout.method, s.payout.amountPesewas, s.netPesewas], ["paid", "driver_wallet", "driver_wallet", 1600, 2160]);
    assert.equal(sent.length, 0);
  });

  test("GSP-LR02 credit and approval refuse a statement whose lines, claims or debts do not reconcile; nothing changes and nothing is sent", async () => {
    const cases = [
      ["lines sum differs from net", "statement_lines_mismatch", async (id, party) =>
        h.db().doc(`gas_settlement_statements/${id}`).update({ netPesewas: (await stmt(id)).netPesewas + 1 })],
      ["no lines", "statement_lines_mismatch", (id) => h.db().doc(`gas_settlement_statements/${id}`).update({ lines: [] })],
      ["a line claimed by another statement", "statement_claims_mismatch", (id, party) =>
        h.db().doc(`gas_settlement_claims/o1__${party}__entitlement`).update({ statementId: "2026-10-26__x__y" })],
      ["a line with no claim", "statement_claims_mismatch", (id, party) => h.db().doc(`gas_settlement_claims/o1__${party}__entitlement`).delete()],
      ["an outstanding debt", "statement_has_outstanding_debt", (id, party, partyId) => seedDebt(id, party, partyId, "o1", 500)],
      ["a proposed, unapproved resolution", "statement_has_outstanding_debt", (id, party, partyId) =>
        seedDebt(id, party, partyId, "o1", 500, { status: "resolution_proposed", stage: "after_payout", version: 2 })],
    ];
    for (const [label, reason, breakIt] of cases) {
      for (const [id, party, partyId, run] of [[DRV_STMT, "driver", DRIVER, settleDriver], [SUP_STMT, "supplier", S, () => approve()]]) {
        await h.clearFirestore();
        await h.seed(p.PAYOUT_FLAG_DOC, { enabled: true });
        await h.seed(`admins/${SUPER}`, { active: true, role: "super_admin", email: "s@test" });
        await h.seed(`gas_suppliers/${S}`, { legalName: "Supplier A Ltd", tradingName: "Supplier A", status: "approved",
          payoutPreference: { method: "mtn_momo", accountNumber: "0241234567", accountName: "Supplier A Ltd" } });
        await h.seed(`drivers/${DRIVER}`, { walletBalance: 10, totalEarnings: 100 });
        await seedStatement(id, party, partyId, [["o1", party === "driver" ? 2160 : 27000]]);
        await breakIt(id, party, partyId);
        const before = await stmt(id);
        await rejects(run(), "failed-precondition", reason);
        assert.deepEqual(await stmt(id), before, `${label} (${party}): statement unchanged`);
        assert.deepEqual(await h.read(`drivers/${DRIVER}`), { walletBalance: 10, totalEarnings: 100 }, label);
        assert.equal(await size("ledger"), 0, label);
        assert.equal(await size("payments"), 0, label);
        assert.equal(await size("audit_log"), 0, label);
        assert.equal(sent.length, 0, `${label}: no transport call`);
      }
    }
    assert.equal(p.statementReconciliationProblem({ statementId: "a", netPesewas: 5, lines: [{ entryId: "e", amountPesewas: 5 }] }, { e: { statementId: "a" } }), null);
    assert.equal(p.statementReconciliationProblem({ statementId: "a", netPesewas: 5, lines: [{ entryId: "e", amountPesewas: 5.5 }] }, { e: { statementId: "a" } }), "statement_lines_mismatch");
    assert.equal(p.statementReconciliationProblem({ statementId: "a", netPesewas: 10, lines: [{ entryId: "e", amountPesewas: 5 }, { entryId: "e", amountPesewas: 5 }] },
      { e: { statementId: "a" } }), "statement_lines_mismatch", "a line listed twice");
    assert.equal(p.statementReconciliationProblem({ statementId: "a", netPesewas: 5, lines: [{ entryId: "e", amountPesewas: 5 }] }, {}), "statement_claims_mismatch");
    assert.equal(p.statementReconciliationProblem({ statementId: "a", netPesewas: 5, lines: [{ entryId: "e", amountPesewas: 5 }], withheldPesewas: 2, payablePesewas: 4 },
      { e: { statementId: "a" } }), "statement_payable_mismatch");
    assert.equal(p.payableOf({ netPesewas: 2160 }), 2160);
    assert.equal(p.payableOf({ netPesewas: 2160, payablePesewas: 0 }), 0);
    assert.equal(p.payableOf({ netPesewas: 2160, payablePesewas: 1600 }), 1600);
  });

  test("GSP-LR03 after a withhold the payable amount is credited or sent; a payable of zero is not_required with no money moved", async () => {
    // Driver: credited net − withheld, and only once the debt is resolved.
    await seedStatement(DRV_STMT, "driver", DRIVER, [["o1", 1600], ["o2", 560]]);
    const drvDebt = await seedDebt(DRV_STMT, "driver", DRIVER, "o2", 560);
    await rejects(settleDriver(), "failed-precondition", "statement_has_outstanding_debt");
    await withhold(drvDebt);
    assert.deepEqual(await settleDriver(), { statementId: DRV_STMT, payoutStatus: "paid", creditedGhs: 16 });
    assert.equal(await pesewas(), 1000 + 1600);
    assert.equal((await h.read(`ledger/gas_driver_settlement_${DRV_STMT}`)).amount, 16);

    // Supplier: Bridge is asked for payable / 100, and the confirmed payout records that amount.
    await seedStatement(SUP_STMT, "supplier", S, [["o1", 20000], ["o2", 7000]]);
    await withhold(await seedDebt(SUP_STMT, "supplier", S, "o2", 7000));
    await approve();
    assert.equal(sent.length, 1);
    assert.equal(sent[0].amount, 200);
    const s = await stmt();
    assert.equal(s.payout.amountPesewas, 20000);
    assert.equal((await h.read(`payments/${s.payout.transactionId}`)).amount, 200);
    await resolve("paid");
    assert.equal((await h.read(`ledger/gas_supplier_payout_${SUP_STMT}`)).amount, 200);

    // Payable zero: nothing is credited or sent.
    const D0 = `2026-10-28__driver__${DRIVER}`, S0 = `2026-10-28__supplier__${S}`;
    await seedStatement(D0, "driver", DRIVER, [["o3", 900]]);
    await withhold(await seedDebt(D0, "driver", DRIVER, "o3", 900));
    const walletBefore = await pesewas();
    assert.deepEqual(await call(p.adminSettleGasDriverStatement, { statementId: D0 }, SUPER), { statementId: D0, payoutStatus: "not_required", creditedGhs: 0 });
    assert.equal(await pesewas(), walletBefore);
    assert.equal(await h.read(`ledger/gas_driver_settlement_${D0}`), null);
    assert.equal((await stmt(D0)).payoutStatus, "not_required");
    await rejects(call(p.adminSettleGasDriverStatement, { statementId: D0 }, SUPER), "failed-precondition", "payout_not_required");
    await seedStatement(S0, "supplier", S, [["o3", 5000]]);
    await withhold(await seedDebt(S0, "supplier", S, "o3", 5000));
    const paymentsBefore = await size("payments");
    assert.deepEqual(await approve(SUPER, S0), { statementId: S0, payoutStatus: "not_required" });
    assert.equal(sent.length, 1, "no Bridge request for a payable of zero");
    assert.equal(await size("payments"), paymentsBefore);
    assert.equal((await stmt(S0)).payoutStatus, "not_required");
    await rejects(approve(SUPER, S0), "failed-precondition", "payout_not_required");
    assert.equal(await size("payments"), paymentsBefore);
  });

  test("GSP-LR04 a credit racing a withhold of the same statement: never both the full credit and the withhold", async () => {
    for (let i = 0; i < 4; i++) {
      await seedStatement(DRV_STMT, "driver", DRIVER, [["o1", 1600], ["o2", 560]]);
      await h.seed(`drivers/${DRIVER}`, { walletBalance: 10, totalEarnings: 100 });
      await h.db().doc(`ledger/gas_driver_settlement_${DRV_STMT}`).delete();
      const debtId = await seedDebt(DRV_STMT, "driver", DRIVER, "o2", 560);
      const [credit, withheld] = await Promise.allSettled([settleDriver(), withhold(debtId)]);
      // The withhold cannot lose: a credit never lands while the debt is outstanding.
      assert.equal(withheld.status, "fulfilled", JSON.stringify(withheld.reason?.details));
      if (credit.status === "rejected") {
        assert.equal(credit.reason.details?.reason, "statement_has_outstanding_debt");
        assert.equal(await pesewas(), 1000, "refused until the debt is resolved");
        await settleDriver();
      }
      assert.equal(await pesewas(), 1000 + 1600, `round ${i}: the reduced amount, once`);
      const st = await stmt(DRV_STMT);
      assert.deepEqual([st.payoutStatus, st.withheldPesewas, st.payout.amountPesewas], ["paid", 560, 1600]);
    }
    // The credit landed first (the debt's stored stage is still before_payout): the withhold is refused.
    await seedStatement(DRV_STMT, "driver", DRIVER, [["o1", 1600], ["o2", 560]]);
    await h.seed(`drivers/${DRIVER}`, { walletBalance: 10, totalEarnings: 100 });
    await h.db().doc(`ledger/gas_driver_settlement_${DRV_STMT}`).delete();
    await settleDriver();
    const debtId = await seedDebt(DRV_STMT, "driver", DRIVER, "o2", 560);
    await rejects(withhold(debtId), "failed-precondition", "debt_stage_changed");
    const st = await stmt(DRV_STMT);
    assert.equal(st.withheldPesewas, undefined);
    assert.equal(st.payablePesewas, undefined);
    assert.equal(await pesewas(), 1000 + 2160, "the full credit, and no withhold");
    assert.equal((await h.read(`${L.DEBTS}/${debtId}`)).status, "outstanding");
  });

  test("GSP-LR05 Bridge safeguards: unknown is never re-sent; a confirmed failure is followed by a new attempt with new ids at the payable amount", async () => {
    bridgeAnswers(Object.assign(new Error("socket hang up"), { response: undefined }), "000");
    await rejects(approve(), "unavailable", "payout_outcome_unknown");
    await rejects(approve(), "failed-precondition", "payout_payout_in_progress");
    assert.equal(sent.length, 1, "unknown is never re-sent");
    const first = (await stmt()).payout;
    await resolve("failed", "Bridge ticket 777 not paid");
    // A failed supplier payout is still before payout: a debt may be withheld before the new attempt.
    await seedStatement(SUP_STMT, "supplier", S, [["o1", 20000], ["o2", 7000]],
      { payoutStatus: "failed", payoutMethod: "mobile_money", payout: (await stmt()).payout });
    const debtId = await seedDebt(SUP_STMT, "supplier", S, "o2", 7000);
    await rejects(approve(), "failed-precondition", "statement_has_outstanding_debt");
    assert.equal(sent.length, 1);
    await withhold(debtId);
    await approve();
    assert.equal(sent.length, 2);
    const second = (await stmt()).payout;
    assert.notEqual(second.attemptId, first.attemptId);
    assert.notEqual(second.transactionId, first.transactionId);
    assert.notEqual(sent[1].transactionId, sent[0].transactionId);
    assert.deepEqual([second.attempt, second.previousStatus, second.amountPesewas, sent[1].amount], [2, "failed", 20000, 200]);
  });
  test("GSP-LR06 a debt reversed during an unconfirmed payout cannot be written off; after a confirmed failure the retry waits for a withhold and sends net − withheld", async () => {
    await seedStatement(SUP_STMT, "supplier", S, [["o1", 20000], ["o2", 7000]]);
    bridgeAnswers(Object.assign(new Error("socket hang up"), { response: undefined }), "000");
    await rejects(approve(), "unavailable", "payout_outcome_unknown");
    // The reversal while the attempt is unknown: an after-payout debt (what reverseOrderEntitlements writes).
    const debtId = await seedDebt(SUP_STMT, "supplier", S, "o2", 7000, { stage: "after_payout" });
    const writeOff = { debtId, action: "propose", resolution: "written_off", evidence: "Paid already per Bridge?", expectedVersion: 1, reason: "Assume paid" };
    await assert.rejects(L.resolveSettlementDebt(ACTOR, writeOff), (e) => e.details?.reason === "debt_payout_unconfirmed");
    await resolve("failed", "Bridge ticket 9 not paid");
    await rejects(approve(), "failed-precondition", "statement_has_outstanding_debt");
    await assert.rejects(L.resolveSettlementDebt(ACTOR, writeOff), (e) => e.details?.reason === "resolution_not_allowed");
    await withhold(debtId);
    await approve();
    assert.deepEqual(sent.map((x) => x.amount), [270, 200], "the full net only once, by the original attempt");
    const s = await stmt();
    assert.deepEqual([s.payout.attempt, s.payout.amountPesewas, s.withheldPesewas], [2, 20000, 7000]);
    assert.equal((await h.read(`${L.DEBTS}/${debtId}`)).resolution, "withhold");
  });
});
