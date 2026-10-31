// Server-side admin check for admin-only callables: the caller must be
// signed in and have an admins/{uid} document with active == true. The same
// rule as firestore.rules isAdmin(); admins/{uid}
// is writable only by super admins, so a client cannot grant itself the role.

"use strict";

const { HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

async function requireActiveAdmin(request) {
  const adminUid = request.auth?.uid;
  if (!adminUid) throw new HttpsError("unauthenticated", "Sign in required.");
  const adminDoc = await admin.firestore().collection("admins").doc(adminUid).get();
  if (!adminDoc.exists || adminDoc.data()?.active !== true) {
    throw new HttpsError("permission-denied", "Admins only.");
  }
  return { adminUid, adminEmail: adminDoc.data()?.email || null };
}

// Stricter check for money-moving callables: an active admin whose role is
// "super_admin". Same rule as firestore.rules isSuperAdmin().
async function requireSuperAdminRole(request) {
  const adminUid = request.auth?.uid;
  if (!adminUid) throw new HttpsError("unauthenticated", "Sign in required.");
  const adminDoc = await admin.firestore().collection("admins").doc(adminUid).get();
  if (!adminDoc.exists || adminDoc.data()?.active !== true || adminDoc.data()?.role !== "super_admin") {
    throw new HttpsError("permission-denied", "Super admins only.");
  }
  return { adminUid, adminEmail: adminDoc.data()?.email || null };
}

module.exports = { requireActiveAdmin, requireSuperAdminRole };
