#!/usr/bin/env bash
# Read-only: compares the Firestore and Storage rules currently released on a
# Firebase project with the files in this repo. It never writes or deploys.
#
# Needs: gcloud logged in as an account with firebaserules.releases.get and
# firebaserules.rulesets.get on the project (Firebase Viewer is enough).
#
# Usage: bash scripts/check-deployed-rules.sh [projectId]
# Exit 0 if both match, 1 if either differs, 2 on an access error.

set -euo pipefail

PROJECT="${1:-ctstransportapp}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
API="https://firebaserules.googleapis.com/v1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TOKEN="$(gcloud auth print-access-token 2>/dev/null)" || {
  echo "gcloud is not logged in; run: gcloud auth login" >&2
  exit 2
}

get() {
  curl -sS -H "Authorization: Bearer ${TOKEN}" \
    -H "x-goog-user-project: ${PROJECT}" "$1"
}

get "${API}/projects/${PROJECT}/releases" > "$TMP/releases.json"

status=0
check() {
  local release_prefix="$1" local_file="$2" label="$3"
  local ruleset
  ruleset="$(python3 - "$TMP/releases.json" "$release_prefix" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
if "error" in d:
    sys.exit("ERROR " + d["error"].get("status", "") + ": " + d["error"].get("message", ""))
for r in d.get("releases", []):
    if r["name"].split("/releases/")[1].startswith(sys.argv[2]):
        print(r["rulesetName"], r.get("updateTime", ""))
        break
EOF
)" || exit 2
  if [ -z "$ruleset" ]; then
    echo "$label: no release found on $PROJECT"
    status=1
    return
  fi
  set -- $ruleset
  get "${API}/$1" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['source']['files'][0]['content'], end='')" \
    > "$TMP/deployed.rules"
  local deployed_sha local_sha
  deployed_sha="$(sha256sum "$TMP/deployed.rules" | cut -c1-16)"
  local_sha="$(sha256sum "$local_file" | cut -c1-16)"
  if [ "$deployed_sha" = "$local_sha" ]; then
    echo "$label: MATCH (released $2, sha256 $deployed_sha)"
  else
    echo "$label: DIFFERS (released $2, deployed $deployed_sha, repo $local_sha)"
    diff -u "$TMP/deployed.rules" "$local_file" | sed 's/^/    /' || true
    status=1
  fi
}

check "cloud.firestore" "$REPO_ROOT/firestore.rules" "Firestore"
check "firebase.storage" "$REPO_ROOT/storage.rules" "Storage"
exit $status
