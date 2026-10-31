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

const { verifyOrderEscrow, SettlementBlockedError } = require("./order_settlement");

/**
 * Decides whether a delivery's escrow may be settled. Pure. The shared
 * check (order_settlement.js) with the delivery's reference type and
 * release reason; estimatedFare only feeds the observe-only amount check.
 * @param {{deliveryId: string, passengerId: string, estimatedFare: any,
 *          escrowId: string, escrow: object|null}} input
 * @returns {{ok: true, mode: "release"|"already_released",
 *            amountMismatch: boolean} | {ok: false, reason: string}}
 */
function verifyDeliveryEscrow({ deliveryId, passengerId, estimatedFare, escrow }) {
  return verifyOrderEscrow({
    orderId: deliveryId, passengerId, escrow, expectedFare: estimatedFare,
    referenceType: DELIVERY_REFERENCE_TYPE, releaseReason: DELIVERY_RELEASE_REASON,
  });
}

module.exports = {
  verifyDeliveryEscrow,
  SettlementBlockedError,
  DELIVERY_REFERENCE_TYPE,
  DELIVERY_RELEASE_REASON,
};
