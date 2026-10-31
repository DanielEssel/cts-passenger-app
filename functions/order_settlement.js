// Verifies that the escrow named on a completed order really is that
// order's payment before anything is released. Shared by Ride, Delivery
// and Gas completion.
//
// Order documents are written by the apps, which can set an escrowId.
// Settlement therefore checks the escrow itself: it must exist, belong to
// the order's passenger, be attached to exactly this order and service
// (referenceId / referenceType, set server-side by attachEscrowToOrder)
// and still be HELD. The same identity checks are repeated inside the
// release transaction (releaseEscrow's `expect`).
//
// Legacy and edge cases are blocked, not guessed: an escrow that was never
// attached (attach failed after the order was created) or that was already
// released elsewhere or refunded is left untouched and the settlement is
// marked failed with an admin alert, so operations can verify and settle
// it by hand. The hourly escrow recovery keeps such escrows HELD and flags
// them for review.

"use strict";

const round2 = (n) => Math.round(n * 100) / 100;

/**
 * Decides whether an order's escrow may be settled. Pure.
 * @param {{orderId: string, passengerId: string, referenceType: string,
 *          releaseReason: string, expectedFare?: any, escrow: object|null}} input
 * @returns {{ok: true, mode: "release"|"already_released",
 *            amountMismatch: boolean} | {ok: false, reason: string}}
 */
function verifyOrderEscrow({ orderId, passengerId, referenceType, releaseReason, expectedFare, escrow }) {
  if (!escrow) return { ok: false, reason: "escrow_missing" };
  if (!passengerId || escrow.userId !== passengerId) return { ok: false, reason: "escrow_owner_mismatch" };
  if (escrow.referenceId == null || escrow.referenceId === "") {
    return { ok: false, reason: "escrow_unattached" };
  }
  if (escrow.referenceId !== orderId) return { ok: false, reason: "escrow_reference_mismatch" };
  if (escrow.referenceType !== referenceType) {
    return { ok: false, reason: "escrow_reference_type_mismatch" };
  }
  if (typeof escrow.amount !== "number" || !(escrow.amount > 0)) {
    return { ok: false, reason: "escrow_amount_invalid" };
  }

  const fare = typeof expectedFare === "number" ? expectedFare : Number(expectedFare);
  const amountMismatch = !Number.isFinite(fare) || round2(fare) !== round2(escrow.amount);

  switch (escrow.status) {
    case "HELD":
      return { ok: true, mode: "release", amountMismatch };
    case "RELEASED":
      // Released for this very order by an earlier attempt that stopped
      // before marking the order: finish the bookkeeping, release nothing.
      return escrow.releaseReason === releaseReason
        ? { ok: true, mode: "already_released", amountMismatch }
        : { ok: false, reason: "escrow_released_elsewhere" };
    case "REFUNDED":
      return { ok: false, reason: "escrow_refunded" };
    default:
      return { ok: false, reason: "escrow_unexpected_status" };
  }
}

/** A settlement that must not go ahead; carries a stable reason. */
class SettlementBlockedError extends Error {
  constructor(reason, detail) {
    super(detail ? `${reason}: ${detail}` : reason);
    this.name = "SettlementBlockedError";
    this.reason = reason;
  }
}

module.exports = { verifyOrderEscrow, SettlementBlockedError };
