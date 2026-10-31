// Admin alert documents in the shape the admin console reads them: its alert
// bell lists admin_alerts where read == false, newest createdAt first, and
// shows each alert's `message` (ctsride-admin AdminAlertsBell). An alert
// without `read: false` or `createdAt` is never shown.
//
// Alerts carry ids, statuses and reason codes only: never completion codes,
// phone numbers, addresses or payment credentials, in the fields or in the
// message.

"use strict";

const admin = require("firebase-admin");

/**
 * @param {string} type    stable alert type
 * @param {string} message one line for the operator
 * @param {object} fields  ids, statuses and reasons for follow-up
 */
function adminAlert(type, message, fields = {}) {
  if (typeof type !== "string" || !type) throw new Error("admin alert needs a type");
  if (typeof message !== "string" || !message.trim()) {
    throw new Error(`admin alert ${type} needs a message`);
  }
  return {
    ...fields,
    type,
    message,
    read: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

module.exports = { adminAlert };
