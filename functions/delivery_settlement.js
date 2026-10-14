// Verifies that the escrow named on a completed delivery really is that
// delivery's payment before anything is released.
//
// The delivery document is written by the passenger app, which can set any
// escrowId. Settlement therefore checks the escrow itself: it must exist,
// belong to the delivery's passenger, be attached to exactly this delivery
// (referenceId / referenceType, set by attachEscrowToOrder) and still be
// HELD. The same identity checks are repeated inside the release
// transaction (releaseEscrow's `expect`).
//
// Legacy and edge cases are blocked, not guessed: an escrow that was never
// attached (attach failed after the order was created) or that was already
// released or refunded is left untouched and the settlement is marked
// failed with an admin alert, so operations can verify and settle it by
// hand. The hourly escrow recovery keeps such escrows HELD and flags them.
//
// The held amount is the authoritative fare in the existing settlement
// design (escrow.amount). A difference from the order's estimatedFare is
// recorded and alerted but does not block settlement, because older app
// versions could hold and store figures computed a moment apart.

"use strict";

const DELIVERY_REFERENCE_TYPE = "delivery";
const DELIVERY_RELEASE_REASON = "delivery_completed";

const round2 = (n) => Math.round(n * 100) / 100;

/**
 * Decides whether a delivery's escrow may be settled. Pure.
 * @param {{deliveryId: string, passengerId: string, estimatedFare: any,
 *          escrowId: string, escrow: object|null}} input
 * @returns {{ok: true, mode: "release"|"already_released",
 *            amountMismatch: boolean} | {ok: false, reason: string}}
 */
function verifyDeliveryEscrow({ deliveryId, passengerId, estimatedFare, escrow }) {
  if (!escrow) return { ok: false, reason: "escrow_missing" };
  if (escrow.userId !== passengerId) return { ok: false, reason: "escrow_owner_mismatch" };
  if (escrow.referenceId == null || escrow.referenceId === "") {
    return { ok: false, reason: "escrow_unattached" };
  }
  if (escrow.referenceId !== deliveryId) return { ok: false, reason: "escrow_reference_mismatch" };
  if (escrow.referenceType !== DELIVERY_REFERENCE_TYPE) {
    return { ok: false, reason: "escrow_reference_type_mismatch" };
  }
  if (typeof escrow.amount !== "number" || !(escrow.amount > 0)) {
    return { ok: false, reason: "escrow_amount_invalid" };
  }

  const fare = typeof estimatedFare === "number" ? estimatedFare : Number(estimatedFare);
  const amountMismatch = !Number.isFinite(fare) || round2(fare) !== round2(escrow.amount);

  switch (escrow.status) {
    case "HELD":
      return { ok: true, mode: "release", amountMismatch };
    case "RELEASED":
      // Released for this very delivery by an earlier attempt that stopped
      // before marking the order: finish the bookkeeping, release nothing.
      return escrow.releaseReason === DELIVERY_RELEASE_REASON
        ? { ok: true, mode: "already_released", amountMismatch }
        : { ok: false, reason: "escrow_released_elsewhere" };
    case "REFUNDED":
      return { ok: false, reason: "escrow_refunded" };
    default:
      return { ok: false, reason: "escrow_unexpected_status" };
  }
}

/** A delivery settlement that must not go ahead; carries a stable reason. */
class SettlementBlockedError extends Error {
  constructor(reason, detail) {
    super(detail ? `${reason}: ${detail}` : reason);
    this.name = "SettlementBlockedError";
    this.reason = reason;
  }
}

module.exports = {
  verifyDeliveryEscrow,
  SettlementBlockedError,
  DELIVERY_REFERENCE_TYPE,
  DELIVERY_RELEASE_REASON,
};
