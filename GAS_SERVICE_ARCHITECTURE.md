# CTSGo Gas Order Service

## Current Findings, Architecture Assessment & Business Model Options

**Status:** Assessment / Decision Required
**Service:** CTSGo Gas Refill & Delivery
**Purpose:** Document the current implementation, identified problems, and the possible operating models before further production development.

---

## 1. Executive Summary

The current CTSGo gas-order implementation has a functioning customer ordering, pricing, payment, driver-dispatch, and tracking foundation. However, the **gas supply/fulfillment side of the service has not yet been formally defined**.

This is important because the current delivery-fee and ETA calculation depends on the location of the nearest available gas-capable driver.

That approach is not suitable as the long-term pricing model because the driver's location is a dispatch concern, while the gas supply/refill location is a fulfillment concern.

The existing code already contains indications that the intended workflow was:

> Customer → Driver → Refill Station → Driver → Customer

There are existing fields and statuses for a refill station, but there is currently no implemented supplier/station management system behind them.

Therefore, the main decision required is not simply how to calculate the delivery fee. The business needs to determine **where the gas comes from and who supplies it**.

---

# 2. What Currently Exists

## 2.1 Gas ordering

The passenger can select gas-related order information including:

* Cylinder size
* Quantity
* Preferred gas brand
* Refill/order type
* Delivery address
* Pickup/delivery location
* Other order instructions

The gas order supports pricing consisting of:

* Gas/product price
* Brand premium
* Delivery fee
* Total price

Payment is integrated with the CTSGo wallet/escrow flow.

---

# 3. Existing Gas Data Model

The current `GasOrder` model already contains:

```text
pickupLocation
refillStation
deliveryLocation
pickupAddress
deliveryAddress
refillStationAddress
```

The `refillStation` is optional.

The newer `GasRefillRequest` model also contains:

```text
pickupLocation
deliveryLocation
preferredStation
preferredStationAddress
```

This indicates that the application was designed with the concept of a refill station in mind.

However, there is currently no proper station/supplier entity or management system.

There is no established structure such as:

```text
gasStations/{stationId}
```

containing the station's:

* Name
* Location
* Address
* Supplier/operator
* Brands
* Cylinder sizes
* Pricing
* Operating hours
* Availability
* Approval status

Therefore, `refillStation` currently represents a concept rather than a fully operational platform entity.

---

# 4. Existing Gas Workflow Indicators

The application already contains statuses such as:

```text
At Station
Arrived at Station
Refilling
Returning
Out for Delivery
Delivered
```

This strongly indicates that the original/intended workflow may involve the driver physically taking the customer's cylinder to a refill station and returning it after refilling.

The apparent workflow is therefore:

```text
Customer
   ↓
Driver collects cylinder
   ↓
Driver travels to refill station
   ↓
Cylinder is refilled
   ↓
Driver returns
   ↓
Customer receives cylinder
```

However, this workflow has not yet been connected to an actual supplier/station infrastructure.

---

# 5. Current Delivery-Fee Calculation

The current gas-order screen calculates distance by searching for currently available drivers.

Conceptually:

```text
Customer selects delivery address
          ↓
Find online/approved/available gas-capable drivers
          ↓
Calculate distance from driver → customer
          ↓
Select nearest driver
          ↓
Use that distance for pricing
```

The current implementation uses a straight-line Haversine distance rather than an actual road route.

It then applies an adjustment and a maximum cap.

The pricing engine itself is designed correctly to accept a distance:

```text
distanceKm
    ↓
GasPricing.compute()
    ↓
delivery fee
```

The problem is the **source of `distanceKm`**, not the basic pricing formula.

---

# 6. Problems Identified

## 6.1 Delivery fee can remain the same for different addresses

The current implementation has a fallback:

```dart
final oneWay = nearest != null
    ? ...
    : 5.0;
```

Therefore, when no suitable driver is found, the system defaults to approximately 5 km.

This means different customer addresses can receive the same estimated delivery distance and therefore the same delivery fee.

---

## 6.2 Pricing depends on driver availability

The customer's delivery fee can change depending on:

* Which drivers are online
* Which drivers are available
* Where those drivers currently are
* Whether a gas-capable driver has a valid location

This is undesirable because the price of the gas service should not fundamentally depend on which driver happens to be online when the customer places the order.

---

## 6.3 Driver location and gas supply location are different concepts

The driver is responsible for fulfilling/transporting the order.

The gas station or supplier is responsible for providing/refilling the gas.

Therefore:

```text
Driver location ≠ Gas supply location
```

Using driver location as the pricing origin mixes two separate parts of the system.

---

## 6.4 Straight-line distance is not road distance

The current calculation uses Haversine distance.

Haversine is useful for geographic proximity and dispatch-radius checks, but it does not represent the actual road distance a driver must travel.

For customer pricing and ETA, road routing should eventually be used.

---

## 6.5 Distance is capped at 30 km

The current calculation contains:

```dart
.clamp(1.0, 30.0)
```

Therefore, destinations beyond 30 km can effectively be treated as 30 km for pricing.

That means the pricing model currently does not distinguish properly between, for example:

```text
30 km
40 km
50 km
60 km
```

unless a separate service-area rule is introduced.

---

## 6.6 ETA is an estimate rather than an actual route ETA

The current ETA is approximately calculated using:

```text
distance × 3 minutes/km
```

plus handling time.

This is a rough heuristic and is not based on actual road travel time.

The screen also contains hardcoded values such as:

```text
~35 mins
~35 min avg
```

which can disagree with the calculated ETA.

---

# 7. Important Architectural Separation

The gas service should distinguish between **pricing**, **fulfillment**, and **driver dispatch**.

### Pricing

Should answer:

> How much does it cost to fulfill this gas order from the chosen/assigned supply source to the customer's location?

### Fulfillment

Should answer:

> Where will the customer's cylinder be refilled and where does the gas come from?

### Driver dispatch

Should answer:

> Which available driver should perform the physical transport?

These should not be treated as one calculation.

---

# 8. Required Future Flow

The eventual architecture should look more like:

```text
Customer selects address
        ↓
Determine gas fulfillment source
        ↓
Supplier / refill station
        ↓
Calculate actual route
        ↓
Distance + travel duration
        ↓
Calculate delivery/service fee
        ↓
Display price + ETA
        ↓
Customer confirms order
        ↓
Find suitable driver
        ↓
Driver collects cylinder
        ↓
Driver goes to supplier/refill station
        ↓
Cylinder is refilled
        ↓
Driver returns to customer
        ↓
Delivery completed
```

The exact flow depends on the business model selected below.

---

# 9. Business Model Options

## Option A — CTSGo-Owned / CTSGo-Operated Supply

CTSGo operates its own gas supply points or refill locations.

### Model

```text
Customer
   ↓
CTSGo
   ↓
CTSGo Supply Point
   ↓
CTSGo Driver
   ↓
Customer
```

### Advantages

* CTSGo controls the supply process.
* Pricing can be centrally controlled.
* Supply availability can be known.
* Station locations can be managed directly.
* Easier to build predictable routing and pricing.

### Requirements

CTSGo would need to manage:

* Gas inventory
* Refill stations
* Cylinder availability
* Gas prices
* Station operations
* Stock levels
* Staff/operators
* Compliance and safety requirements

### Implication

This is more operationally intensive and requires CTSGo to participate directly in the gas supply business.

---

# 10. Option B — Partner Gas Suppliers / Refill Stations

CTSGo partners with existing gas suppliers and refill stations.

### Model

```text
              Supplier A
             /
Customer → CTSGo → Supplier B
             \
              Supplier C
                    ↓
                  Driver
                    ↓
                 Customer
```

Each approved supplier/station becomes a platform entity.

Example future structure:

```text
gasStations/{stationId}
```

Potential information:

```text
stationId
name
supplierId
location
address
brands
cylinderSizes
pricing
operatingHours
isActive
isApproved
```

### Advantages

* CTSGo does not necessarily need to own gas stations.
* Existing suppliers already have gas infrastructure.
* The platform can grow geographically by adding suppliers.
* Supplier availability can become part of order fulfillment.

### Requirements

CTSGo needs:

* Supplier onboarding
* Supplier verification
* Station approval
* Supplier/station dashboard
* Station location
* Supported brands
* Supported cylinder sizes
* Availability
* Commercial agreements
* Commission/payment settlement
* Operational procedures

### Important

This is likely the most natural extension of the existing `preferredStation` concept, but it requires the business relationship with suppliers to be defined first.

---

# 11. Option C — CTSGo as a Gas Marketplace

CTSGo does not own the gas and does not necessarily operate the refill station.

Instead, CTSGo connects:

```text
Customer
   ↕
CTSGo Platform
   ↕
Gas Supplier
   ↕
Driver
```

The platform handles:

* Customer ordering
* Payment
* Dispatch
* Tracking
* Customer support
* Order management
* Supplier matching
* Driver coordination

The supplier provides the actual gas/refill service.

### Advantages

* Lower infrastructure ownership.
* Potentially easier geographic expansion.
* Multiple suppliers can participate.
* CTSGo becomes the technology/logistics layer.

### Requirements

The marketplace needs proper supplier infrastructure, including:

* Supplier accounts
* Supplier stations
* Supplier availability
* Supplier pricing
* Order acceptance
* Supplier settlement
* Platform commission
* Supplier performance tracking

---

# 12. Option D — Managed Supplier Model

Instead of immediately building a full supplier marketplace, CTSGo could initially operate with a small number of manually approved suppliers.

For example:

```text
CTSGo Admin
     ↓
Approved Supplier List
     ↓
Supplier / Station
     ↓
Gas Order
```

The customer may not even need to select a station.

CTSGo can assign the appropriate supplier internally.

### Advantages

* Much simpler initial implementation.
* Allows the gas service to launch without a full supplier portal.
* CTSGo can learn the operational process first.
* Supplier relationships can be tested before building a marketplace.
* Easier to control quality during the early stage.

### Possible evolution

```text
Phase 1
Managed suppliers

        ↓

Phase 2
Supplier/station records

        ↓

Phase 3
Supplier dashboard

        ↓

Phase 4
Automated supplier matching
```

This allows the technical platform to evolve with the actual business.

---

# 13. Station Selection Models

Once suppliers/stations exist, there are several ways an order could be assigned.

## Model 1 — Customer chooses station

Customer selects:

```text
Preferred station
```

The system calculates the route from that station to the customer's location.

### Benefit

Customer has control.

### Problem

Customer may select a station that:

* Does not support the requested cylinder size
* Does not have the required brand
* Is unavailable
* Is too far away
* Cannot fulfill the order

---

## Model 2 — CTSGo chooses the station

The customer simply enters the delivery address.

CTSGo determines the appropriate supplier/station.

Selection can consider:

* Distance
* Availability
* Brand
* Cylinder size
* Price
* Operating hours
* Supplier capacity

This is more automated.

---

## Model 3 — Supplier accepts the order

CTSGo sends the order to eligible suppliers.

A supplier accepts the order and becomes the fulfillment source.

This introduces supplier-side availability and acceptance into the workflow.

---

# 14. Pickup & Return Requires Special Treatment

The `Pickup & Return` service type is different from a simple gas delivery.

The likely physical journey is:

```text
Customer
   ↓
Driver collects cylinder
   ↓
Refill station
   ↓
Cylinder refill
   ↓
Driver returns
   ↓
Customer
```

Therefore the actual route can involve multiple legs.

The current pricing engine already recognizes this concept:

```text
Exchange / New / Commercial
→ 1 leg

Pickup & Return
→ 2 legs + round-trip surcharge
```

However, the actual route origin/destination information needs to be defined before this pricing model can be considered production-ready.

---

# 15. Pricing Architecture That Should Eventually Be Used

Once the business model is selected:

```text
Gas Product Price
        +
Brand Premium
        +
Service Fee
        +
Delivery / Logistics Fee
        =
Customer Total
```

The delivery component should be based on a legitimate operational route.

For example:

```text
Supplier/Station
       ↓
Customer
```

or, for pickup and return:

```text
Customer
   ↓
Station
   ↓
Customer
```

The driver should not be the source of the customer's base delivery price.

---

# 16. ETA Architecture

The ETA should eventually be based on actual route information.

Instead of:

```text
distance × 3 minutes/km
```

the system should obtain:

```text
road distance
+
estimated travel duration
+
operational handling time
```

For example:

```text
Supplier → Customer
        ↓
Road distance: 8.7 km
Travel time: 24 min
Handling: 15 min
        ↓
Estimated delivery: ~39 min
```

For pickup and return, the relevant legs should be included.

---

# 17. Production Security Requirement

The passenger application currently calculates and sends:

```text
deliveryFee
totalPrice
```

to the backend.

For production, the server/backend should not blindly trust client-calculated prices.

The backend should eventually:

1. Receive the order parameters.
2. Determine the valid supplier/station.
3. Determine/verify the applicable route.
4. Recalculate pricing.
5. Validate the amount being held in escrow.
6. Create/confirm the order using the server-approved amount.

The client should display the price, but the backend should remain authoritative.

---

# 18. What Should NOT Be Done

The following should not become the permanent solution:

### Do not use nearest online driver for gas pricing

Driver location is for dispatch.

### Do not use a fixed 5 km fallback

Different customer locations require different pricing.

### Do not silently cap every destination at 30 km

A service-area rule should explicitly determine what happens beyond the supported area.

### Do not use hardcoded `~35 mins`

ETA should correspond to the actual route and order type.

### Do not build a full supplier marketplace before the business model is agreed

The technical architecture should follow the actual operating model.

---

# 19. Immediate Technical Findings

The current gas-order implementation should therefore be considered **functionally incomplete rather than simply having a distance-calculation bug**.

The existing components are useful:

* Gas product pricing
* Brand pricing
* Cylinder sizes
* Order types
* Wallet payment
* Escrow
* Driver dispatch
* Driver tracking
* Gas order tracking
* Refill-related statuses
* Optional station fields

But the missing core component is:

> **A defined gas fulfillment source and operating model.**

---

# 20. Decisions Required From CTSGo Business/Client

Before making significant changes to the gas pricing architecture, the following questions should be answered.

### Supply

1. Who actually owns/supplies the gas?
2. Does CTSGo intend to buy and resell gas?
3. Or will existing gas suppliers provide the gas?

### Suppliers

4. Will gas suppliers officially partner with CTSGo?
5. Will suppliers be onboarded into the application?
6. Will suppliers accept/reject orders?
7. Will suppliers set their own prices?

### Stations

8. Does each supplier have one or multiple refill locations?
9. Does CTSGo need to know the exact physical location of each refill point?
10. Can customers select a preferred station?

### Drivers

11. Does the CTSGo driver collect the customer's cylinder?
12. Does the driver wait at the station?
13. Does the supplier refill the cylinder?
14. Can the driver leave the cylinder and return later?
15. Who is responsible for the cylinder while it is at the station?

### Pricing

16. Is the gas product price controlled by CTSGo?
17. Is it controlled by the supplier?
18. Is the delivery fee controlled centrally?
19. Does distance from supplier → customer determine delivery price?
20. Is there a maximum service radius?

### Commercial

21. How does CTSGo make money?
22. Supplier commission?
23. Driver delivery fee?
24. Markup on gas?
25. Combination of these?

---

# 21. Recommended Development Sequence

The gas service should not be expanded randomly. The recommended sequence is:

```text
1. Agree on business/operational model
                ↓
2. Define supplier/station concept
                ↓
3. Define physical order workflow
                ↓
4. Define who supplies and owns the gas
                ↓
5. Define driver responsibilities
                ↓
6. Define pricing model
                ↓
7. Implement supplier/station data model
                ↓
8. Implement route/distance calculation
                ↓
9. Implement accurate ETA
                ↓
10. Implement supplier/order assignment
                ↓
11. Move pricing validation to backend
                ↓
12. Test complete real-world workflow
```

---

# 22. Current Development Decision

### Do not yet replace the current distance calculation with another arbitrary distance calculation.

The correct question is first:

> **"Distance between which two operational points?"**

Once the gas fulfillment model is selected, that question becomes answerable.

The current nearest-driver distance calculation can remain temporarily as an implementation placeholder for testing, but it should not be treated as the final production pricing architecture.

---

# 23. Target End State

The mature CTSGo gas service should ultimately be able to answer all of these questions automatically:

```text
Where is the customer?
        ↓
What gas/cylinder is required?
        ↓
Which approved supplier can fulfill it?
        ↓
Which refill station will fulfill it?
        ↓
Does that station have the required gas/cylinder?
        ↓
What is the actual route?
        ↓
How much does fulfillment cost?
        ↓
What is the expected ETA?
        ↓
Which CTSGo driver should handle the order?
        ↓
Who is responsible at every stage?
        ↓
How is payment distributed?
```

Only after these questions are defined should the gas service be considered fully production-ready.

---

## Conclusion

The current gas-order issue is **not simply that different delivery addresses are receiving the same delivery fee**.

That symptom exposed a deeper architectural question:

> **CTSGo currently has a gas delivery workflow but does not yet have a clearly defined gas supply/fulfillment model.**

The code already anticipates refill stations, suppliers/stations are not yet implemented as operational entities.

The major business options are:

1. **CTSGo-owned supply**
2. **Partner gas suppliers/refill stations**
3. **Gas marketplace**
4. **Managed supplier model as an initial phase**

The technical implementation should follow the selected business model.

Until that decision is made, changing the distance formula alone risks producing a technically different calculation while preserving the underlying business problem.



To complete the Gas service quickly, I don't necessarily need to build a separate supplier app at this stage.

What I need from CTSGo is the list of **approved gas suppliers/refill stations** that we will work with, together with their:

• Station/supplier name
• Exact location/address
• GPS coordinates
• Contact details
• Gas brands available
• Cylinder sizes available
• Order/refill types supported
• Current prices
• Operating hours
• Any specific refill procedure the driver must follow

Once CTSGo provides the approved supplier/station information and confirms the commercial arrangement, I can configure the stations in the backend and finish wiring the Gas order flow around them.

For the initial launch, CTSGo can manage the suppliers/stations internally rather than requiring suppliers to create accounts in the app.

A supplier portal or supplier app can be added later if the business grows and automated supplier management becomes necessary.
