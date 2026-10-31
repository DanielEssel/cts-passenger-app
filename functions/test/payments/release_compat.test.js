// Release v5 compatibility, read from the app sources (no emulator):
//  - the new builds' versions meet the minimums the server and the release
//    plan use (Passenger 1.0.1, Driver 1.0.3), so raising
//    app_config/mobile to them never locks out the build that needs them;
//  - the Driver App lists open Delivery/Gas requests only from the offer
//    collections (order documents are not readable to unassigned drivers);
//  - the Passenger App creates orders without a completion code and prices
//    Gas with the server's constants (gas_pricing.js).

"use strict";

const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const { versionAtLeast } = require("../../escrow");
const pricing = require("../../gas_pricing");
const { offerFields } = require("../../order_offers");
const { GeoPoint } = require("firebase-admin/firestore");

const PASSENGER = path.join(__dirname, "../../..");
const DRIVER = path.join(__dirname, "../../../../../driver/cts-transport-driver-app-clean");
const read = (root, p) => fs.readFileSync(path.join(root, p), "utf8");
const pubspecVersion = (root) => /^version:\s*([0-9.]+)\+\d+\s*$/m.exec(read(root, "pubspec.yaml"))[1];

describe("release v5 compatibility", () => {
  test("RC-01 the builds meet the minimum versions the release raises to", () => {
    assert.ok(versionAtLeast(pubspecVersion(PASSENGER), "1.0.1"), pubspecVersion(PASSENGER));
    assert.ok(versionAtLeast(pubspecVersion(DRIVER), "1.0.3"), pubspecVersion(DRIVER));
    assert.equal(versionAtLeast("1.0.0", "1.0.1"), false, "released Passenger is below");
    assert.equal(versionAtLeast("1.0.2", "1.0.3"), false, "released Driver is below");
  });

  test("RC-02 the Driver App lists open requests from the offers only", () => {
    const src = read(DRIVER, "lib/features/driver/presentation/widgets/requests_section.dart");
    assert.match(src, /collection\('delivery_offers'\)/);
    assert.match(src, /collection\('gas_order_offers'\)/);
    assert.doesNotMatch(src, /collection\('deliveries'\)/);
    assert.doesNotMatch(src, /collection\('gas_orders'\)/);
    assert.doesNotMatch(src, /receiverName|receiverPhone/, "no contact fields read for open requests");
  });

  test("RC-03 the Passenger App writes no completion code on new orders", () => {
    for (const f of ["lib/features/delivery/models/delivery_request.dart", "lib/features/gas/models/gas_refill_request.dart"]) {
      const src = read(PASSENGER, f);
      assert.match(src, /if \(deliveryOtp != null\) 'deliveryOtp': deliveryOtp,/, f);
    }
    for (const f of ["lib/features/gas/presentation/screens/gas_order_screen.dart",
      "lib/features/delivery/presentation/delivery_vehicle_screen.dart"]) {
      assert.doesNotMatch(read(PASSENGER, f), /deliveryOtp:/, f);
    }
  });

  test("RC-04 the app prices Gas with the server's constants", () => {
    const dart = read(PASSENGER, "lib/features/gas/domain/gas_pricing.dart");
    assert.match(dart, new RegExp(`standardDistanceKm = ${pricing.STANDARD_DISTANCE_KM.toFixed(1)};`));
    assert.match(dart, new RegExp(`maxQuantity = ${pricing.MAX_GAS_QUANTITY};`));
    const screen = read(PASSENGER, "lib/features/gas/presentation/screens/gas_order_screen.dart");
    assert.match(screen, /distanceKm: GasPricing\.standardDistanceKm,/);
    // Brand multipliers (GasBrand.priceMultiplier) and built-in prices.
    const model = read(PASSENGER, "lib/features/gas/models/gas_refill_request.dart");
    const block = model.slice(model.indexOf("double get priceMultiplier"));
    for (const [brand, m] of Object.entries(pricing.GAS_BRAND_MULTIPLIER)) {
      if (brand === "any") continue;
      const hit = new RegExp(`GasBrand\\.${brand}\\s*=>\\s*([0-9.]+)`).exec(block);
      assert.ok(hit, `${brand} in the app`);
      assert.equal(Number(hit[1]), m, brand);
    }
    const svc = read(PASSENGER, "lib/core/services/pricing_service.dart");
    const gasDefaults = svc.slice(svc.indexOf("'gas': {"), svc.indexOf("'rideEnabled'"));
    for (const [k, v] of Object.entries(pricing.GAS_DEFAULTS)) {
      const hit = new RegExp(`'${k}':\\s*([0-9.]+)`).exec(gasDefaults);
      assert.ok(hit, `${k} default in the app`);
      assert.equal(Number(hit[1]), v, k);
    }
  });

  test("RC-05 an offer never carries a sealed, contact, schedule or code field, whatever the order holds", () => {
    const pt = new GeoPoint(5.55671, -0.18234);
    const everything = { passengerId: "p", status: "pending", pickupLocation: pt, dropoffLocation: pt,
      deliveryLocation: pt, pickupAddress: "1 A St, Osu, Accra", dropoffAddress: "2 B St, Osu, Accra",
      deliveryAddress: "1 A St, Osu, Accra", estimatedFare: 30, receiverName: "x", receiverPhone: "x",
      notes: "x", photoUrl: "x", passengerName: "x", passengerPhone: "x", deliveryOtp: "1234",
      pickupInstructions: "x", deliveryInstructions: "x", cylinderConditionNotes: "x", receiptEmail: "x",
      scheduledPickupAt: 1, scheduledDeliveryBy: 1, preferredStationAddress: "x", metadata: { a: 1 },
      verifiedPrice: { total: 62, deliveryFee: 12 } };
    const forbidden = ["passengerId", "pickupLocation", "dropoffLocation", "deliveryLocation", "pickupAddress",
      "dropoffAddress", "deliveryAddress", "receiverName", "receiverPhone", "notes", "photoUrl", "passengerName",
      "passengerPhone", "deliveryOtp", "pickupInstructions", "deliveryInstructions", "cylinderConditionNotes",
      "receiptEmail", "scheduledPickupAt", "scheduledDeliveryBy", "preferredStationAddress", "metadata",
      "verifiedPrice", "quoteId", "deliveryQuoteId"];
    // A delivery is offered only once its server quote is verified and stamped.
    const stampedDelivery = { ...everything, deliveryQuoteId: "q1", verifiedPrice: { version: "delivery-v2", quoteId: "q1",
      totalPesewas: 3000, total: 30, commissionPesewas: 450, commission: 4.5 } };
    assert.equal(offerFields("deliveries", everything), null, "no offer without a verified delivery price");
    for (const collection of ["deliveries", "gas_orders"]) {
      const o = offerFields(collection, collection === "deliveries" ? stampedDelivery : everything);
      assert.ok(o, collection);
      for (const k of forbidden) assert.equal(o[k], undefined, `${collection}.${k}`);
    }
  });

  test("RC-06 the Passenger App books Delivery on a server quote and never prices it itself", () => {
    const screen = read(PASSENGER, "lib/features/delivery/presentation/delivery_vehicle_screen.dart");
    assert.doesNotMatch(screen, /route_service|measureDeliveryRoute|deliveryFareBreakdown|calculateDeliveryFare/);
    assert.match(screen, /deliveryQuoteId: quote\.quoteId/);
    assert.match(screen, /estimatedFare: quote\.total/);
    assert.match(screen, /amount: quote\.total/);
    const domain = read(PASSENGER, "lib/features/delivery/domain/delivery_quote.dart");
    assert.match(domain, /httpsCallable\('quoteDelivery'\)/);
    assert.doesNotMatch(domain, /straightLine|Geolocator|distanceBetween/);
    const model = read(PASSENGER, "lib/features/delivery/models/delivery_request.dart");
    assert.match(model, /if \(deliveryQuoteId != null\) 'deliveryQuoteId': deliveryQuoteId,/);
  });
});
