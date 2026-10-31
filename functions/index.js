const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule }        = require("firebase-functions/v2/scheduler");
const admin                 = require("firebase-admin");

admin.initializeApp();
const trips = require("./trips");


// Creates an empty wallet when a passenger's users document is created.
// The document path belongs in the options: passing it as a separate
// argument (as before) left the trigger with no document filter, so it fired
// on every document created anywhere and crashed in the SDK, never creating
// a wallet. create() never overwrites a wallet the app's createWallet
// callable made first (it fails with ALREADY_EXISTS instead).
exports.createPassengerWallet = onDocumentCreated(
  { region: "europe-west2", document: "users/{userId}" },
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const data = snap.data();
    if (data?.role !== 'passenger') return;

    const walletRef = admin.firestore()
      .collection('wallets')
      .doc(event.params.userId);

    try {
      await walletRef.create({
        userId:    event.params.userId,
        balance:   0.0,
        currency:  'GHS',
        isActive:  true,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (e.code === 6) return; // ALREADY_EXISTS: the wallet is already there
      throw e;
    }
  }
);



// ── Retired ride-dispatch and acceptance paths (2026-10-16) ─────────────────
// onDriverAlertCreated (trigger on driver_alerts) and acceptTrip (callable)
// were removed:
//  • onDriverAlertCreated trusted the client-written alert (service type,
//    pickup) and set the trip to noDriversAvailable when no driver matched,
//    so any signed-in user could end another passenger's search. Its call
//    signature was also invalid, so the deployed copy had no document filter
//    and crashed on every invocation. onTripCreatedNotify (notifications.js)
//    is the one ride dispatcher: it reads the trip itself.
//  • acceptTrip assigned any searching trip to any caller with a drivers
//    document (no approval, service, availability checks). No app or the
//    admin panel calls it, and production logs show no invocations in the
//    30 days before removal. Rides are claimed by the Driver App's
//    transaction, which firestore.rules checks (trips claim branch).
// Removing an export does not delete a deployed function: see the deploy
// notes (firebase functions:delete onDriverAlertCreated acceptTrip).

// ── expireStaleTrips — runs every 2 minutes ───────────────────────────────────

exports.expireStaleTrips = onSchedule(
  { schedule: "every 2 minutes", timeZone: "Africa/Accra", region: "europe-west2", minInstances: 0 },
  async () => {
    const db  = admin.firestore();
    const now = new Date();
    const cutoff = new Date(now.getTime() - 2 * 60 * 1000); // 2 min ago

    const staleSnap = await db
      .collection("trips")
      .where("status",    "==", "searching")
      .where("createdAt", "<=", admin.firestore.Timestamp.fromDate(cutoff))
      .get();

    const batch = db.batch();
    staleSnap.docs.forEach((doc) => {
      batch.update(doc.ref, {
        status:    "noDriversAvailable",
        expiredAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    await batch.commit();
    console.log(`Expired ${staleSnap.docs.length} stale trips`);
  }
);

// ── Wallet functions ──────────────────────────────────────────────────────────

const wallet = require("./wallet");
exports.createWallet              = wallet.createWallet;
exports.getWalletBalance          = wallet.getWalletBalance;
exports.deductWalletBalance       = wallet.deductWalletBalance;
exports.getTransactionHistory     = wallet.getTransactionHistory;
exports.requestWithdrawal         = wallet.requestWithdrawal;
exports.approveDriver             = wallet.approveDriver;
exports.getPendingDrivers         = wallet.getPendingDrivers;

// ── Notification functions ────────────────────────────────────────────────────

const notifications = require("./notifications");
exports.onTripStatusChanged     = notifications.onTripStatusChanged;
exports.onGasOrderStatusChanged = notifications.onGasOrderStatusChanged;
exports.onGasOrderCreated       = notifications.onGasOrderCreated;
exports.onDeliveryStatusChanged = notifications.onDeliveryStatusChanged;
exports.onWalletChanged         = notifications.onWalletChanged;
exports.onGasSupplierRiderOfferChanged = notifications.onGasSupplierRiderOfferChanged;
exports.checkDocumentExpiry     = notifications.checkDocumentExpiry;
exports.onTripCreatedNotify = notifications.onTripCreatedNotify;

// ── Trip lifecycle (fare validation + wallet deduction + driver credit) ────────
exports.onTripCreated       = trips.onTripCreated;
exports.onTripCompleted     = trips.onTripCompleted;
exports.onDeliveryCompleted = trips.onDeliveryCompleted;
exports.onGasOrderCompleted = trips.onGasOrderCompleted;

// ── Escrow + Financial integrity ──────────────────────────────────────────────
const escrow = require("./escrow");
exports.holdBalance          = escrow.holdBalance;
exports.attachEscrowToOrder  = escrow.attachEscrowToOrder;
exports.adminAttachEscrow    = escrow.adminAttachEscrow;
// Paystack (initializePaystackPayment, verifyPaystackPayment,
// paystackWebhook) was removed: The Bridge Solutions is the only payment
// provider. Removing an export does not delete a deployed function; see the
// rollout notes in PAYMENTS-STAGING.md.
exports.releaseStuckEscrows  = escrow.releaseStuckEscrows;
exports.dailyReconciliation  = escrow.dailyReconciliation;

// ── Cancellation refunds ──────────────────────────────────────────────────────
exports.onTripCancelled      = trips.onTripCancelled;
exports.onDeliveryCancelled  = trips.onDeliveryCancelled;
exports.onGasOrderCancelled  = trips.onGasOrderCancelled;
exports.resetDailyEarnings = wallet.resetDailyEarnings;
exports.getDriverWallet          = wallet.getDriverWallet;
exports.requestDriverWithdrawal  = wallet.requestDriverWithdrawal;
exports.migrateWallets = wallet.migrateWallets;
exports.refundEscrowOnError = escrow.refundEscrowOnError;
// Cancels wallet deliveries whose hold was never linked (no money moves).
exports.expireUnpaidWalletDeliveries = escrow.expireUnpaidWalletDeliveries;
exports.broadcastNotification = notifications.broadcastNotification;
exports.onDeliveryCreated = notifications.onDeliveryCreated;
// Dispatches a wallet delivery once its hold is linked to it.
exports.onDeliveryPaymentAttached = notifications.onDeliveryPaymentAttached;
// Wallet Gas orders are offered to drivers once their hold is linked.
exports.onGasOrderPaymentAttached = notifications.onGasOrderPaymentAttached;
// Observe-only server check of the client-supplied delivery fare: records
// deliveryFareChecks/{id} and alerts admins; never changes the order.
exports.onDeliveryFareValidation =
  require("./delivery_fare_validation").onDeliveryFareValidation;
// Alert-only: delivery settlements stuck in "processing" (no money movement).
exports.detectStuckDeliverySettlements =
  require("./settlement_monitor").detectStuckDeliverySettlements;

// ── Bridge payment integration (collection + payout) ──────────────────────────
const bridge = require("./bridge");
exports.initiateBridgeTopUp    = bridge.initiateBridgeTopUp;
exports.bridgeTopUpCallback    = bridge.bridgeTopUpCallback;
exports.checkBridgeTopUpStatus = bridge.checkBridgeTopUpStatus;
exports.initiateBridgePayout   = bridge.initiateBridgePayout;
exports.bridgePayoutCallback   = bridge.bridgePayoutCallback;

// ── Passenger ratings → driver aggregate ─────────────────────────────────────
const ratings = require("./ratings");
exports.onTripRated     = ratings.onTripRated;
exports.onDeliveryRated = ratings.onDeliveryRated;
exports.onGasOrderRated = ratings.onGasOrderRated;


const adminAlerts = require("./admin_alerts");
exports.onDriverSubmittedForReview = adminAlerts.onDriverSubmittedForReview;

// ── withdrawal approval ─────────────────────────────────────
const withdrawalApproval = require("./withdrawal_approval");
exports.approveWithdrawal = withdrawalApproval.approveWithdrawal;
exports.rejectWithdrawal = withdrawalApproval.rejectWithdrawal;
exports.resolveUnconfirmedPayout = withdrawalApproval.resolveUnconfirmedPayout;

// ── Server-side acceptance (accept_job.js, dispatch_policy.js) ──────────────
const gasAcceptance = require("./accept_gas_order");
exports.acceptGasOrder = gasAcceptance.acceptGasOrder;
const jobAcceptance = require("./accept_job");
exports.acceptRide = jobAcceptance.acceptRide;
exports.acceptDelivery = jobAcceptance.acceptDelivery;
// Server-owned Delivery quotes (road route + approved rate card).
exports.quoteDelivery = require("./delivery_quotes").quoteDelivery;
// Legacy name (Driver 1.0.0+1, May 2026): same server acceptance as acceptRide.
exports.acceptTrip = jobAcceptance.acceptTrip;

// ── Completion codes held where the driver cannot read them ──────────────────
exports.verifyCompletionCode = require("./completion_codes").verifyCompletionCode;

// ── Passenger map markers (driver_map) ───────────────────────────────────────
exports.syncDriverMap = require("./driver_map").syncDriverMap;

// ── Driver device tokens: one device, one driver ─────────────────────────────
exports.onDriverTokenSaved = require("./driver_tokens").onDriverTokenSaved;

// ── Gas supplier orders: options, quotes, priced orders (gas_supplier_orders.js)
// Gated by settings/gas_supplier_fulfilment; orders are created as awaiting_payment.
const gasSupplierOrders = require("./gas_supplier_orders");
exports.listGasSupplierOptions = gasSupplierOrders.listGasSupplierOptions;
exports.quoteGasSupplierOrder = gasSupplierOrders.quoteGasSupplierOrder;
exports.createGasSupplierOrder = gasSupplierOrders.createGasSupplierOrder;

// ── Gas supplier settlement ledger (gas_settlement_ledger.js) ───────────────
// Accounting only, super-admin callables. Payouts: gas_supplier_payouts.js.
const gasSettlement = require("./gas_settlement_ledger");
exports.adminPostGasSupplierEntitlements = gasSettlement.adminPostGasSupplierEntitlements;
exports.adminReverseGasSupplierEntitlements = gasSettlement.adminReverseGasSupplierEntitlements;
exports.adminPrepareGasSettlementStatements = gasSettlement.adminPrepareGasSettlementStatements;
exports.adminProposeGasCommissionTerms = gasSettlement.adminProposeGasCommissionTerms;
exports.adminDecideGasCommissionTerms = gasSettlement.adminDecideGasCommissionTerms;
exports.adminResolveGasSettlementDebt = gasSettlement.adminResolveGasSettlementDebt;

// ── Gas supplier linked riders (gas_supplier_riders.js) ─────────────────────
// Super-admin callables, not gated by the fulfilment flag: link a driver to one
// supplier, revoke the link, list a supplier's riders with their audit trail.
const gasRiders = require("./gas_supplier_riders");
exports.adminLinkGasSupplierRider = gasRiders.adminLinkGasSupplierRider;
exports.adminRevokeGasSupplierRider = gasRiders.adminRevokeGasSupplierRider;
exports.adminListGasSupplierRiders = gasRiders.adminListGasSupplierRiders;

// ── Gas supplier-order fulfilment (gas_supplier_fulfilment.js) ──────────────
// GATED OFF: every callable but cancellation refuses unless
// settings/gas_supplier_fulfilment has enabled == true. One schedule (every minute): the
// supplier response deadline (supplierResponseMinutes, default 10 minutes).
const gasFulfilment = require("./gas_supplier_fulfilment");
exports.gasSupplierOrderingStatus = gasFulfilment.gasSupplierOrderingStatus;
exports.payGasSupplierOrder = gasFulfilment.payGasSupplierOrder;
exports.supplierRespondGasOrder = gasFulfilment.supplierRespondGasOrder;
exports.supplierHandOverGasOrder = gasFulfilment.supplierHandOverGasOrder;
exports.supplierRequestGasDriver = gasFulfilment.supplierRequestGasDriver;
exports.supplierCompleteGasOrder = gasFulfilment.supplierCompleteGasOrder;
exports.listGasSupplierJobs = gasFulfilment.listGasSupplierJobs;
exports.listMyGasSupplierJobs = gasFulfilment.listMyGasSupplierJobs;
exports.acceptGasSupplierJob = gasFulfilment.acceptGasSupplierJob;
exports.supplierListGasRiders = gasFulfilment.supplierListGasRiders;
exports.supplierAssignGasRider = gasFulfilment.supplierAssignGasRider;
exports.declineGasSupplierRiderOffer = gasFulfilment.declineGasSupplierRiderOffer;
exports.listMyGasSupplierEarnings = gasFulfilment.listMyGasSupplierEarnings;
exports.arriveGasSupplierStation = gasFulfilment.arriveGasSupplierStation;
exports.completeGasSupplierOrder = gasFulfilment.completeGasSupplierOrder;
exports.cancelGasSupplierOrder = gasFulfilment.cancelGasSupplierOrder;
exports.adminCancelGasSupplierOrder = gasFulfilment.adminCancelGasSupplierOrder;
exports.adminReleaseGasSupplierDriver = gasFulfilment.adminReleaseGasSupplierDriver;
exports.expireUnansweredGasSupplierOrders = gasFulfilment.expireUnansweredGasSupplierOrders;

// ── Gas supplier settlement payouts (gas_supplier_payouts.js) ───────────────
// Supplier statements: Mobile Money via Bridge, OFF unless
// settings/gas_supplier_payouts has enabled == true, marked paid only by a
// super admin with Bridge evidence. Driver statements: credited to the
// driver wallet by a super admin (not behind that switch).
// One schedule: prepares the previous day's statements (accounting only).
const gasPayouts = require("./gas_supplier_payouts");
exports.adminApproveGasSupplierPayout = gasPayouts.adminApproveGasSupplierPayout;
exports.adminResolveGasSupplierPayout = gasPayouts.adminResolveGasSupplierPayout;
exports.adminSettleGasDriverStatement = gasPayouts.adminSettleGasDriverStatement;
exports.prepareDailyGasSettlementStatements = gasPayouts.prepareDailyGasSettlementStatements;
