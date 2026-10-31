// Completion-code gate for code-verified hand-overs (Gas).
//
// A gas order settles only when the order carries a stored code and the
// submitted code matches it. Without a usable stored code the order is
// held for review; operations may record a waiver for a legitimate
// historical order in completion_code_waivers/{collection}_{orderId}, a
// collection no client can read or write (no rules match it), and only then
// does settlement go ahead. Code values are never logged or copied.

"use strict";

// The apps generate 4 digits; 3–8 tolerates any digit code an order may carry.
const CODE_PATTERN = /^\d{3,8}$/;

/** A code as the apps write it: a short string of digits. */
const usableCode = (v) => typeof v === "string" && CODE_PATTERN.test(v.trim());

/**
 * Decides whether a delivered order may settle. Pure.
 * @param {{stored: any, submitted: any, waiver?: object|null,
 *          collection: string, orderId: string}} input
 * @returns {{ok: true, via: "code"|"waiver"} |
 *           {ok: false, outcome: "pending"|"mismatch"|"review", reason: string}}
 */
function checkCompletionCode({ stored, submitted, waiver = null, collection, orderId }) {
  if (!usableCode(stored)) {
    const waived = waiver != null && waiver.collection === collection &&
      waiver.orderId === orderId && typeof waiver.approvedBy === "string" && waiver.approvedBy !== "";
    return waived
      ? { ok: true, via: "waiver" }
      : { ok: false, outcome: "review", reason: "stored_code_missing" };
  }
  if (submitted == null || submitted === "") {
    return { ok: false, outcome: "pending", reason: "code_not_submitted" };
  }
  if (!usableCode(submitted)) return { ok: false, outcome: "mismatch", reason: "code_malformed" };
  if (submitted.trim() !== stored.trim()) return { ok: false, outcome: "mismatch", reason: "code_mismatch" };
  return { ok: true, via: "code" };
}

/** Where a waiver for [orderId] in [collection] lives. */
const waiverId = (collection, orderId) => `${collection}_${orderId}`;

module.exports = { checkCompletionCode, waiverId, usableCode, WAIVER_COLLECTION: "completion_code_waivers" };
