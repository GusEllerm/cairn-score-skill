#!/usr/bin/env bash
# Mints a TrustGraph API key and prints it on stdout.
#
# Usage:
#   Ephemeral (default):  TRUSTGRAPH_API_KEY=$(scripts/mint-key.sh)
#   Stable identity:      TRUSTGRAPH_API_KEY=$(scripts/mint-key.sh agent://your-org/your-agent)
#
# Reads TRUSTGRAPH_BASE_URL from the env; defaults to the hosted PoC.
# Each ephemeral invocation uses a fresh UUID — if a previous mint timed
# out, re-running gets a new claim rather than colliding on the unique
# constraint (which would return 409).
#
# python3 (not jq) handles JSON since python3 is essentially universal
# where Claude Code runs and jq often isn't installed.

set -euo pipefail

command -v python3 >/dev/null || { echo "mint-key.sh: python3 required but not on PATH" >&2; exit 127; }

: "${TRUSTGRAPH_BASE_URL:=https://mep39camvm.us-east-1.awsapprunner.com}"

REVIEWER_ID="${1:-agent://anon/$(python3 -c 'import uuid; print(uuid.uuid4())')}"

PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"reviewer_external_id": sys.argv[1]}))' "$REVIEWER_ID")

RESP=$(curl -sS -X POST "$TRUSTGRAPH_BASE_URL/v1/keys" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

python3 -c '
import sys, json
data = json.loads(sys.stdin.read())
if "api_key" not in data:
    sys.exit("mint failed: " + json.dumps(data))
print(data["api_key"])
' <<< "$RESP"
