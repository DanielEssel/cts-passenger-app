'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { canHandleGasOrder } = require('./gas_dispatch_policy');

exports.acceptGasOrder = onCall(
  { region: 'europe-west2' },
  async (request) => {
    const uid = request.auth?.uid;

    if (!uid) {
      throw new HttpsError('unauthenticated', 'You must be signed in.');
    }

    const orderId = request.data?.orderId;

    if (typeof orderId !== 'string' || !orderId.trim()) {
      throw new HttpsError('invalid-argument', 'orderId is required.');
    }

    const db = admin.firestore();
    const orderRef = db.collection('gas_orders').doc(orderId);
    const driverRef = db.collection('drivers').doc(uid);

    try {
      const result = await db.runTransaction(async (txn) => {
        const [orderSnap, driverSnap] = await Promise.all([
          txn.get(orderRef),
          txn.get(driverRef),
        ]);

        if (!orderSnap.exists) {
          return {
            success: false,
            reason: 'order_not_found',
          };
        }

        if (!driverSnap.exists) {
          return {
            success: false,
            reason: 'driver_not_found',
          };
        }

        const order = orderSnap.data();
        const driver = driverSnap.data();

        // Order must still be available.
        if (order.status !== 'pendingApproval') {
          return {
            success: false,
            reason: 'order_unavailable',
          };
        }

        if (order.driverId != null) {
          return {
            success: false,
            reason: 'order_already_assigned',
          };
        }

        // Driver must be an approved, online, available delivery driver.
        if (
          driver.role !== 'driver_delivery' ||
          driver.isApproved !== true ||
          driver.isOnline !== true ||
          driver.isAvailable !== true
        ) {
          return {
            success: false,
            reason: 'driver_not_eligible',
          };
        }

        // Vehicle capability is authoritative on the server.
        if (!canHandleGasOrder(driver.vehicleType, order.refillType)) {
          console.warn(
            `Gas order ${orderId}: driver ${uid} rejected by vehicle policy`,
            {
              vehicleType: driver.vehicleType ?? null,
              refillType: order.refillType ?? null,
            },
          );

          return {
            success: false,
            reason: 'vehicle_not_eligible',
          };
        }

        // Assign the gas order and driver atomically.
        txn.update(orderRef, {
          driverId: uid,
          driverName: driver.displayName ?? driver.name ?? 'Driver',
          driverPhone: driver.phoneNumber ?? driver.phone ?? '',
          driverRating: driver.rating ?? 5.0,
          status: 'driverAssigned',
          acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        txn.update(driverRef, {
          isAvailable: false,
          currentTripId: orderId,
          currentTripType: 'gas_orders',
        });

        return {
          success: true,
          orderId,
        };
      });

      return result;
    } catch (error) {
      console.error(
        `Gas order ${orderId}: acceptance transaction failed`,
        error,
      );

      throw new HttpsError(
        'internal',
        'Unable to accept the gas order right now.',
      );
    }
  },
);
