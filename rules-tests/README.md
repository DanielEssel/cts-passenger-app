# Firestore rules tests

Runs the CTSGo Firestore rules against the local emulator only. The project id
`demo-ctsgo-rules` is a demo project, so nothing connects to production.

Requirements: Node 22+, firebase-tools 15+, and Java 21+ (the emulator refuses
older JDKs). If your default `java` is older:

    export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 PATH=$JAVA_HOME/bin:$PATH

Commands (from this folder):

    npm install
    npm test                    # ../firestore.rules (currently what is deployed)
    npm run test:driver-rules   # the driver repo's firestore.rules, for comparison
    npm run check-deployed      # read-only: compare live rules with this repo

Test ids: `*-S*` are security tests (a write that must be denied); `*-P*` replay
writes the passenger and driver apps make today and must keep succeeding.
A failing `-S` test is an open hole in the rules under test, not a broken test.
