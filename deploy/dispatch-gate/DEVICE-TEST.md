# Dispatch remediation — controlled-device test

## Rules for running this test
- Run against a staging or demo Firebase project with the new Functions and rules, never production.
- Use test accounts only.
- Record results as pass/fail plus a screenshot.
- Do not record tokens, phone numbers or exact locations in results.

## Setup

**Pickup point.** One fixed point, A.

**Drivers.** All approved and online unless noted. "Near" means within 2 km of A, set with the device's mock location.

| Account | role | vehicle / service | Placement / state |
|---|---|---|---|
| R-OK | hailing | motorcycle / okada | near |
| R-TX | hailing | taxi / taxi | near |
| R-PG | hailing | pragyia / pragyia | near |
| R-PGT | hailing | pragyia / **taxi** (wrong vehicle) | near |
| R-TX-FAR | hailing | taxi | 10.5 km from A |
| D-BK | delivery | motorcycle | near |
| D-TR | delivery | tricycle | near |
| D-MT | delivery | miniTruck | near |
| D-BK-FAR | delivery | motorcycle | 10.5 km from A |
| D-OFF | delivery | motorcycle | near, **offline** |
| D-UNAP | delivery | motorcycle | near, **unapproved** |
| D-SUSP | delivery | motorcycle | near, **suspended** (Admin app) |

**Devices.** Driver App 1.0.3 on every device. Driver App 1.0.2 on one extra
device, as a D-TR test account. Passenger App new build, plus one previous
passenger build.

**App states.** For each push scenario, run once with the app in each state:
- F: foreground;
- B: background (home button);
- T: terminated (swiped away).

## Scenarios (expected result for each)

### Ride (passenger books from A)
| # | Booking | Push + bell + list | No push, no list |
|---|---|---|---|
| R1 | Okada | R-OK | all others |
| R2 | Taxi | R-TX | R-PGT, R-TX-FAR, all delivery |
| R3 | Pragyia | R-PG | R-PGT, all others |
| R4 | R-PGT taps Accept on a Taxi ride (via an old build, or by forcing the list) | | Claim refused; trip stays searching |
| R5 | R-OK and a second Okada device both accept R1 | | Exactly one succeeds; the other sees "taken" |

### Delivery (pickup A)
| # | Booking | Receives | Refused |
|---|---|---|---|
| D1 | Okada / Small | D-BK | D-TR, D-MT, all ride drivers |
| D2 | Aboboya / Medium | D-TR | D-BK, D-MT |
| D3 | Aboboya / Large | D-TR | D-BK, D-MT |
| D4 | Mini Truck / Bulk | D-MT | D-BK, D-TR |
| D5 | D-TR accepts D2, goes offline and back online, then tries to accept D3 | | Refused: "Finish your current job…" |
| D6 | D-TR taps Accept on D2 and D3 at the same moment | | One assignment only; the driver's current job equals that order |
| D7 | Passenger cancels D2 after D-TR accepted | D-TR is available again; a new D3 can be accepted | |

### Gas (customer at A)
| # | Order | Receives | Refused |
|---|---|---|---|
| G1 | New cylinder | D-BK, D-TR, D-MT | all ride drivers |
| G2 | Exchange empty | D-BK, D-TR, D-MT | |
| G3 | Pickup and return | D-BK | D-TR, D-MT |
| G4 | Commercial bulk | D-TR, D-MT | D-BK |
| G5 | Tap the G1 push in states F, B and T | The app opens on the request list, never a "Not Found" screen. Accept succeeds for one driver; the others see the order disappear. | |

### Status and radius (repeat with D1 and R2)
| # | Driver | Expected |
|---|---|---|
| S1 | D-OFF, D-UNAP, D-SUSP | No push, no bell entry, empty list |
| S2 | D-BK-FAR, R-TX-FAR (10.5 km) | No push, no list |
| S3 | Move D-BK-FAR to 9.5 km, then book D1 again | It receives the push |

### Devices and accounts
| # | Steps | Expected |
|---|---|---|
| T1 | On D-BK's phone: airplane mode, sign out, airplane mode off, sign in as D-MT. Book D1 (D-BK's job). | D-MT's phone receives nothing for D1. D-BK's bell shows the entry; push goes nowhere. |
| T2 | Book D4 | D-MT's phone gets the push |
| T3 | Uninstall the app on D-TR, then book D2 | No push; D-TR's dead token is removed after the attempt (check the admin view: token present = no) |

### Older builds
| # | Steps | Expected |
|---|---|---|
| O1 | Previous Passenger build books Medium on Okada | Within seconds the booking ends as cancelled with a reason. The passenger gets "Okada can't carry a medium delivery… book again". Wallet: the hold is returned once. No driver is notified. |
| O2 | Driver App 1.0.2 as D-TR, with D1 booked | D1 may be listed (old filter), and Accept is refused once the new rules are live |
| O3 | Set `driverMinimumVersion = 1.0.3` on staging | 1.0.2 shows the blocking update dialog |

## Exit criteria
Every row passes in states F, B and T where a push is involved, and the
staging dispatch logs show no recipients for rejected jobs.
