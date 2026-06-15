# CTS Transport — Releasing to Testers (APK distribution)

Goal: get the passenger + driver apps onto testers' phones with **maps, places, and
directions working**, so testers DON'T need to run `flutter run --dart-define-from-file=env.json`.

## The core fact
`flutter build apk --release --dart-define-from-file=env.json` bakes your Dart keys
(MAPS_API_KEY, PLACES_API_KEY) INTO the APK. Testers just install the file and use it —
no `flutter run`, no env.json, no setup on their end.

Output file: `build/app/outputs/flutter-apk/app-release.apk`

## Why it "just works" for you (lucky break)
Your passenger release build uses the **debug keystore**
(`android/app/build.gradle:36` → `signingConfig = signingConfigs.getByName("debug")`).
That means the release APK has the **same SHA-1** as your `flutter run` builds — so the
Google Maps key (restricted to that SHA-1) keeps working. No new SHA-1 to register.
NOTE: debug-keystore signing is fine for handing testers an APK, but NOT acceptable for
the Play Store (you'd need a real release keystore there — see "Later: Play Store").

────────────────────────────────────────────────────────────────────────
## 🔴 STEP 0 — ROTATE THE LEAKED MAPS KEY (do this FIRST)
The passenger Maps key `AIzaSy...CbeU` was exposed in plaintext (in chat). Treat it as
compromised. Anyone could use it and run up your bill.

In Google Cloud Console → APIs & Services → Credentials:
1. Delete / regenerate the exposed key.
2. Create a NEW key for **Maps SDK for Android** (renders map tiles):
   - Application restriction: **Android apps**
   - Add package name: `com.cts.passenger` (+ the driver app's package)
   - Add your **debug SHA-1** (get it in Step 1)
3. Create / keep a key for **Directions + Places + Geocoding** (the Dart HTTP calls):
   - These are HTTP, so they CAN'T use Android-app restriction.
   - Restrict by **API**: enable ONLY Directions, Places, Geocoding.
   - Set usage quotas to cap abuse.
4. Update the key everywhere it's used (Step 3 below).

WHY: keys are extractable from any APK. Once testers have the app, the keys are "in the
wild." Restriction + quotas + a budget alert are what protect you.

────────────────────────────────────────────────────────────────────────
## STEP 1 — Get your debug SHA-1 (needed for the Maps key restriction)
```bash
cd ~/Desktop/Projects/cts-transport-passenger-app
keytool -list -v -keystore ~/.android/debug.keystore \
  -alias androiddebugkey -storepass android -keypass android 2>/dev/null | grep SHA1
```
Copy the SHA1 value into the Maps SDK for Android key's allowed fingerprints (Step 0.2).

────────────────────────────────────────────────────────────────────────
## STEP 2 — Set a billing budget alert (safety net)
Google Cloud Console → Billing → Budgets & alerts → Create budget.
Cap it low (e.g. alert at $10/month). Even with restricted keys, this stops a surprise bill.

────────────────────────────────────────────────────────────────────────
## STEP 3 — Put the new keys into the project
- Native Maps key → `android/app/src/main/AndroidManifest.xml` line ~18
  (`<meta-data android:name="com.google.android.geo.API_KEY" android:value="NEW_KEY"/>`)
- Dart keys → `env.json` (MAPS_API_KEY, PLACES_API_KEY)

────────────────────────────────────────────────────────────────────────
## STEP 4 — Build the passenger release APK
```bash
cd ~/Desktop/Projects/cts-transport-passenger-app
flutter build apk --release --dart-define-from-file=env.json
```
Result: `build/app/outputs/flutter-apk/app-release.apk`

(Optional smaller per-architecture builds: add `--split-per-abi` → most phones use
`app-arm64-v8a-release.apk`.)

────────────────────────────────────────────────────────────────────────
## STEP 5 — TEST THE RELEASE APK ON YOUR OWN PHONE FIRST (critical)
Don't send anything until you confirm maps work in the RELEASE build (not just debug):
```bash
cd ~/Desktop/Projects/cts-transport-passenger-app
flutter install --release          # installs release APK to connected phone
# or: adb install build/app/outputs/flutter-apk/app-release.apk
```
Open the app → book a ride → confirm:
- Map TILES render (not blank/grey)  ← if blank, the SHA-1/key restriction is wrong
- Place SEARCH works (Places key)
- ROUTE/directions draw (Directions key)

────────────────────────────────────────────────────────────────────────
## STEP 6 — Build the DRIVER app
First check what the driver app needs:
```bash
cd ~/Desktop/Projects/cts-transport-driver-app
grep -n "com.google.android.geo.API_KEY" -A1 android/app/src/main/AndroidManifest.xml
grep -n "signingConfig\|MAPS_API_KEY" android/app/build.gradle* 2>/dev/null
ls env.json 2>/dev/null && echo "driver HAS env.json" || echo "driver has NO env.json"
```
- If driver has NO env.json (native maps key only):
  ```bash
  flutter build apk --release
  ```
- If driver HAS env.json (uses Dart keys too):
  ```bash
  flutter build apk --release --dart-define-from-file=env.json
  ```
Then test the driver release APK on a phone the same way (Step 5).
Make sure the driver app's package name + SHA-1 are also on the Maps key's allow-list.

────────────────────────────────────────────────────────────────────────
## STEP 7 — Distribute to testers (Option A — direct APK)
Send BOTH APKs (passenger + driver) via WhatsApp / Google Drive / email.
- Testers acting as PASSENGERS install the passenger APK.
- Testers acting as DRIVERS install the driver APK.
- Testers enable "Install from unknown sources" (Android will prompt), then tap the APK.

This is the fastest path — zero infrastructure. Best for a handful of testers.

────────────────────────────────────────────────────────────────────────
## LATER: Play Store internal testing (Option B — when you scale up)
More setup, but gives a "real store install" + auto-updates:
1. Google Play Console account ($25 one-time).
2. Create a REAL release keystore (NOT the debug one):
   - `keytool -genkey -v -keystore ~/cts-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias cts`
   - Create `android/key.properties` + wire `signingConfigs.release` in build.gradle.
   - Add the NEW release SHA-1 to the Maps key restrictions.
3. Build an app bundle: `flutter build appbundle --release --dart-define-from-file=env.json`
   (optionally `--obfuscate --split-debug-info=out/symbols/` — keep the symbol files to
   decode crash reports).
4. Upload the `.aab` to Play Console → Internal testing track.
5. Add testers by email; they install from a Play Store link.
NOTE: bump `versionCode` (and `versionName`) in build.gradle before each upload.

────────────────────────────────────────────────────────────────────────
## QUICK REFERENCE — the two build commands
```bash
# Passenger (needs Dart keys)
cd ~/Desktop/Projects/cts-transport-passenger-app
flutter build apk --release --dart-define-from-file=env.json

# Driver (confirm if it needs env.json — see Step 6)
cd ~/Desktop/Projects/cts-transport-driver-app
flutter build apk --release        # add --dart-define-from-file=env.json IF it uses Dart keys
```

## GOTCHAS CHECKLIST
- [ ] Leaked Maps key rotated
- [ ] New Maps-SDK-Android key restricted to package + debug SHA-1
- [ ] Directions/Places/Geocoding key restricted by API + quotas
- [ ] Billing budget alert set
- [ ] Keys updated in AndroidManifest.xml AND env.json
- [ ] Release APK tested on a real phone (maps tiles + search + directions all work)
- [ ] Driver app build command confirmed (env.json or not)
- [ ] Both package names + SHA-1 on the Maps key allow-list