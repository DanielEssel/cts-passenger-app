"use strict";

/**
 * Linked riders for gas suppliers (super admin only, not gated by the
 * fulfilment flag). A super admin links an approved driver to one supplier
 * (gas_supplier_riders/{driverUid}, one supplier per driver) and may revoke
 * the link. Every change appends a row to gas_supplier_rider_audit in the
 * same transaction. Revoking clears the rider's pending offer on a confirmed
 * order, which then waits for the supplier to assign someone else (spec
 * §2.2). A revoked link does not affect a job the rider already accepted.
 * Clients cannot write any of it.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { ORDERING_FLAG_DOC } = require("./gas_supplier_orders");
const { requireSuperAdmin } = require("./gas_settlement_ledger");

const db = () => admin.firestore();
const { FieldValue, Timestamp } = admin.firestore;

const OPTS = { region: "europe-west2", minInstances: 0 };
const RIDERS = "gas_supplier_riders";
const RIDER_AUDIT = "gas_supplier_rider_audit";
const ORDERS = "gas_supplier_orders";
const SUPPLIERS = "gas_suppliers";
const MEMBERS = "gas_supplier_members";
const AUDIT_LIMIT = 50;
const REASON_MAX = 500;

// ── Offer window ─────────────────────────────────────────────────────────────

/** The agreed initial window for a rider to accept an offer (spec §2.2). */
const DEFAULT_RIDER_ACCEPT_MINUTES = 5;
/** Whether the setting holds a usable window. Pure. */
const validRiderAcceptMinutes = (v) => Number.isInteger(v) && v >= 1 && v <= 60;
/** The window in minutes: the setting when valid, else the agreed default. Pure. */
function riderAcceptMinutes(flag) {
  const v = flag?.riderAcceptMinutes;
  if (v !== undefined && !validRiderAcceptMinutes(v)) {
    console.warn("riderAcceptMinutes is not a whole number from 1 to 60; using the default", DEFAULT_RIDER_ACCEPT_MINUTES);
  }
  return validRiderAcceptMinutes(v) ? v : DEFAULT_RIDER_ACCEPT_MINUTES;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

const refuse = (reason, message = "This action is not allowed.", code = "failed-precondition") =>
  new HttpsError(code, message, { reason });

function readRequest(data, allowed) {
  if (!data || typeof data !== "object" || Array.isArray(data)) throw new HttpsError("invalid-argument", "Invalid request.");
  const extra = Object.keys(data).filter((k) => !allowed.includes(k));
  if (extra.length) throw new HttpsError("invalid-argument", "Unexpected fields in request.", { reason: "unexpected_fields", fields: extra });
  return data;
}
const isId = (v) => typeof v === "string" && v.length > 0 && v.length <= 200 && !v.includes("/");
const requireId = (v, reason) => {
  if (!isId(v)) throw refuse(reason, "Invalid request.", "invalid-argument");
  return v;
};

/**
 * The driver's active link to this supplier, or null. Reads inside [tx];
 * used by assignment and acceptance (Task 5).
 */
async function activeRiderLink(tx, driverId, supplierId) {
  const snap = await tx.get(db().collection(RIDERS).doc(driverId));
  const link = snap.exists ? snap.data() : null;
  return link && link.status === "active" && link.supplierId === supplierId ? link : null;
}

const millis = (t) => (typeof t?.toMillis === "function" ? t.toMillis() : null);

// ── Link ─────────────────────────────────────────────────────────────────────

async function linkRider(actor, data) {
  const { supplierId, driverId } = readRequest(data, ["supplierId", "driverId"]);
  requireId(supplierId, "supplier_not_found");
  requireId(driverId, "driver_not_found");
  return db().runTransaction(async (tx) => {
    const linkRef = db().collection(RIDERS).doc(driverId);
    const [supplier, driver, adminDoc, member, linkSnap] = await Promise.all([
      tx.get(db().collection(SUPPLIERS).doc(supplierId)),
      tx.get(db().collection("drivers").doc(driverId)),
      tx.get(db().collection("admins").doc(driverId)),
      tx.get(db().collection(MEMBERS).doc(driverId)),
      tx.get(linkRef),
    ]);
    if (!supplier.exists || supplier.data().status !== "approved") throw refuse("supplier_not_found", "Supplier not found.");
    if (!driver.exists) throw refuse("driver_not_found", "Driver not found.");
    const d = driver.data();
    if (d.role !== "driver_delivery") throw refuse("driver_wrong_role", "Only delivery drivers can be linked.");
    if (d.isApproved !== true || d.signupStep === "suspended") throw refuse("driver_not_approved", "The driver is not approved.");
    if (adminDoc.exists) throw refuse("admin_cannot_be_rider", "An admin cannot be a rider.");
    if (member.exists) throw refuse("supplier_member_cannot_be_rider", "A supplier member cannot be a rider.");

    const current = linkSnap.exists ? linkSnap.data() : null;
    if (current?.status === "active") {
      if (current.supplierId !== supplierId) throw refuse("rider_linked_to_other_supplier", "The driver is linked to another supplier.");
      return { driverId, supplierId, status: "active", version: current.version };
    }
    const version = (current?.version ?? 0) + 1;
    tx.set(linkRef, {
      driverId, supplierId, status: "active", version, linkedBy: actor.uid, linkedAt: FieldValue.serverTimestamp(),
    });
    tx.set(db().collection(RIDER_AUDIT).doc(), {
      action: "link", driverId, supplierId, by: actor.uid, version, at: FieldValue.serverTimestamp(),
    });
    return { driverId, supplierId, status: "active", version };
  });
}

// ── Revoke ───────────────────────────────────────────────────────────────────

async function revokeRider(actor, data) {
  const { driverId, reason } = readRequest(data, ["driverId", "reason"]);
  requireId(driverId, "rider_not_found");
  const why = typeof reason === "string" ? reason.trim() : "";
  if (!why || why.length > REASON_MAX) throw refuse("reason_required", "A reason is required.", "invalid-argument");
  return db().runTransaction(async (tx) => {
    const linkRef = db().collection(RIDERS).doc(driverId);
    const [linkSnap, flag, offers] = await Promise.all([
      tx.get(linkRef),
      tx.get(db().doc(ORDERING_FLAG_DOC)),
      tx.get(db().collection(ORDERS).where("riderOffer.driverId", "==", driverId).where("status", "==", "confirmed")),
    ]);
    if (!linkSnap.exists) throw refuse("rider_not_found", "This driver is not a linked rider.");
    const link = linkSnap.data();
    if (link.status !== "active") throw refuse("already_revoked", "The link is already revoked.");

    const version = link.version + 1;
    const deadline = Timestamp.fromMillis(Date.now() + riderAcceptMinutes(flag.exists ? flag.data() : null) * 60 * 1000);
    let voidedOrderId = null;
    for (const o of offers.docs) {
      const offer = o.data().riderOffer;
      tx.update(o.ref, {
        riderOffer: FieldValue.delete(),
        lastRiderOffer: { driverId, seq: offer.seq ?? null, outcome: "revoked", at: Timestamp.now() },
        riderDeadlineAt: deadline,
      });
      voidedOrderId = voidedOrderId ?? o.id;
    }
    tx.update(linkRef, {
      status: "revoked", version, revokedBy: actor.uid, revokedAt: FieldValue.serverTimestamp(), revokeReason: why,
    });
    tx.set(db().collection(RIDER_AUDIT).doc(), {
      action: "revoke", driverId, supplierId: link.supplierId, by: actor.uid, version, reason: why,
      voidedOrderId, at: FieldValue.serverTimestamp(),
    });
    return { driverId, status: "revoked", version, voidedOrderId };
  });
}

// ── List ─────────────────────────────────────────────────────────────────────

async function listRiders(data) {
  const { supplierId } = readRequest(data, ["supplierId"]);
  requireId(supplierId, "supplier_not_found");
  const [links, audit] = await Promise.all([
    db().collection(RIDERS).where("supplierId", "==", supplierId).get(),
    db().collection(RIDER_AUDIT).where("supplierId", "==", supplierId).get(),
  ]);
  const riders = [];
  for (const l of links.docs) {
    const r = l.data();
    const driver = (await db().collection("drivers").doc(l.id).get()).data() ?? {};
    riders.push({
      driverId: l.id,
      name: driver.displayName ?? driver.name ?? null,
      vehicle: driver.vehicleType ?? null,
      status: r.status,
      version: r.version,
      linkedAt: millis(r.linkedAt),
      linkedBy: r.linkedBy ?? null,
      revokedAt: millis(r.revokedAt),
      revokeReason: r.revokeReason ?? null,
    });
  }
  riders.sort((a, b) => (b.linkedAt ?? 0) - (a.linkedAt ?? 0));
  // Sorted here, not by the query, so no composite index is needed.
  const rows = audit.docs
    .map((a) => ({ id: a.id, ...a.data(), at: millis(a.data().at) }))
    .sort((a, b) => (b.at ?? 0) - (a.at ?? 0))
    .slice(0, AUDIT_LIMIT);
  return { riders, audit: rows };
}

// ── Callables ────────────────────────────────────────────────────────────────

exports.adminLinkGasSupplierRider = onCall(OPTS, async (request) => linkRider(await requireSuperAdmin(request), request.data));
exports.adminRevokeGasSupplierRider = onCall(OPTS, async (request) => revokeRider(await requireSuperAdmin(request), request.data));
exports.adminListGasSupplierRiders = onCall(OPTS, async (request) => {
  await requireSuperAdmin(request);
  return listRiders(request.data);
});

Object.assign(exports, {
  RIDERS, RIDER_AUDIT, DEFAULT_RIDER_ACCEPT_MINUTES, riderAcceptMinutes, activeRiderLink,
  linkRider, revokeRider, listRiders,
});
