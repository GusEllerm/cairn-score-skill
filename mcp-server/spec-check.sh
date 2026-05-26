#!/usr/bin/env bash
# spec-check.sh — guard against silent upstream API drift.
#
# Fetches the live TrustGraph OpenAPI spec and diffs it against the snapshot
# at mcp-server/openapi.snapshot.json. Exits 0 on no drift, 1 on changes.
#
# Run before pulling upstream changes, after a deploy you didn't make, or as
# a CI step. Catches the kind of silent rename that motivated the original
# review (`top_failure_modes.n_events → count`) before it breaks production.
#
# Two outputs:
#   1. A structural diff of paths + schemas (what endpoints / shapes changed).
#   2. A Literal-enum sync check against the entity `type` enum (our Pydantic
#      Literal["data_source", "capability", "agent"] must equal the server's
#      EntityByRef.type enum).
#
# Usage:
#   bash mcp-server/spec-check.sh              # diff and exit code
#   bash mcp-server/spec-check.sh --update     # overwrite snapshot with live spec
#
# Env:
#   TRUSTGRAPH_BASE_URL  default: https://mep39camvm.us-east-1.awsapprunner.com

set -euo pipefail
command -v python3 >/dev/null || { echo "spec-check.sh: python3 required" >&2; exit 127; }
command -v curl    >/dev/null || { echo "spec-check.sh: curl required"    >&2; exit 127; }

: "${TRUSTGRAPH_BASE_URL:=https://mep39camvm.us-east-1.awsapprunner.com}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SNAPSHOT="$SCRIPT_DIR/openapi.snapshot.json"

if [[ ! -f "$SNAPSHOT" ]]; then
  echo "spec-check.sh: no snapshot at $SNAPSHOT" >&2
  echo "  Create one with: bash $0 --update" >&2
  exit 1
fi

LIVE=$(mktemp)
trap 'rm -f "$LIVE"' EXIT
curl -sS "$TRUSTGRAPH_BASE_URL/openapi.json" | python3 -m json.tool > "$LIVE"

if [[ "${1:-}" == "--update" ]]; then
  cp "$LIVE" "$SNAPSHOT"
  echo "spec-check.sh: snapshot updated → $SNAPSHOT"
  exit 0
fi

SNAPSHOT="$SNAPSHOT" LIVE="$LIVE" python3 <<'PY'
"""
Structural diff of two OpenAPI specs. Reports:
  - added/removed paths
  - added/removed methods within paths
  - added/removed schema names
  - per-schema added/removed properties (the rename-shaped change that
    silently broke n_events → count)
  - per-schema required-set deltas
Exits 1 if any deltas; 0 if clean.
"""
import json, os, sys

snap = json.load(open(os.environ["SNAPSHOT"]))
live = json.load(open(os.environ["LIVE"]))

problems = []

# Paths
snap_paths = set(snap.get("paths", {}).keys())
live_paths = set(live.get("paths", {}).keys())
for p in sorted(snap_paths - live_paths):
    problems.append(f"  REMOVED path: {p}")
for p in sorted(live_paths - snap_paths):
    problems.append(f"  ADDED path:   {p}")

# Methods within shared paths
for p in sorted(snap_paths & live_paths):
    snap_methods = set(k for k in snap["paths"][p] if k in ("get","post","put","patch","delete"))
    live_methods = set(k for k in live["paths"][p] if k in ("get","post","put","patch","delete"))
    for m in sorted(snap_methods - live_methods):
        problems.append(f"  REMOVED {m.upper()} {p}")
    for m in sorted(live_methods - snap_methods):
        problems.append(f"  ADDED   {m.upper()} {p}")

# Schemas
snap_schemas = set((snap.get("components") or {}).get("schemas", {}).keys())
live_schemas = set((live.get("components") or {}).get("schemas", {}).keys())
for s in sorted(snap_schemas - live_schemas):
    problems.append(f"  REMOVED schema: {s}")
for s in sorted(live_schemas - snap_schemas):
    problems.append(f"  ADDED schema:   {s}")

# Per-schema properties + required set
for s in sorted(snap_schemas & live_schemas):
    snap_s = snap["components"]["schemas"][s]
    live_s = live["components"]["schemas"][s]
    snap_props = set((snap_s.get("properties") or {}).keys())
    live_props = set((live_s.get("properties") or {}).keys())
    for prop in sorted(snap_props - live_props):
        problems.append(f"  REMOVED field: {s}.{prop}")
    for prop in sorted(live_props - snap_props):
        problems.append(f"  ADDED field:   {s}.{prop}")
    snap_req = set(snap_s.get("required") or [])
    live_req = set(live_s.get("required") or [])
    for r in sorted(snap_req - live_req):
        problems.append(f"  RELAXED required: {s}.{r} (was required, now optional)")
    for r in sorted(live_req - snap_req):
        problems.append(f"  TIGHTENED required: {s}.{r} (was optional, now required)")

# Literal enum sync — entity type, rank dimension
def _enum(spec, schema_name, prop):
    sch = spec.get("components", {}).get("schemas", {}).get(schema_name) or {}
    p = (sch.get("properties") or {}).get(prop) or {}
    return sorted(p.get("enum") or [])

for schema_name, prop in [("EntityByRef", "type"), ("RankIn", "rank_by")]:
    s_enum = _enum(snap, schema_name, prop)
    l_enum = _enum(live, schema_name, prop)
    if s_enum != l_enum:
        problems.append(f"  ENUM drift: {schema_name}.{prop} snapshot={s_enum} live={l_enum}")

if problems:
    print("spec-check.sh: drift detected vs snapshot")
    print()
    for p in problems:
        print(p)
    print()
    print(f"If the deltas are expected, refresh the snapshot:")
    print(f"  bash {os.path.basename(__file__) if '__file__' in dir() else 'spec-check.sh'} --update")
    sys.exit(1)

print("spec-check.sh: no drift vs snapshot")
PY