#!/usr/bin/env bash
# Clean slate: wipe all trustgraph state from the local machine.
#
# Removes:
#   - ~/.claude/skills/trustgraph/      (Code skill files)
#   - ~/.trustgraph/                    (API key, queue, hook log, sentinels)
#   - Hook entries in ~/.claude/settings.json that reference trustgraph
#   - Env entries TG_* / TRUSTGRAPH_* in ~/.claude/settings.json
#   - mcpServers.trustgraph in Claude Desktop's config (if present)
#
# Leaves alone:
#   - The clone at $PWD (this is the source, not install state)
#   - dist/*.mcpb, dist/*.zip (build artifacts)
#   - ANTHROPIC_API_KEY in env/key files (you may use it elsewhere)
#
# Idempotent: safe to re-run; produces no output on a clean machine
# except a trailing `clean` line.
#
# Usage:
#   bash docs/_reset-trustgraph-state.sh

set -euo pipefail

rm -rf ~/.claude/skills/trustgraph ~/.trustgraph

python3 - <<'PY'
import json, os

# ~/.claude/settings.json — drop trustgraph hooks + TG_/TRUSTGRAPH_ env keys
p = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(p):
    c = json.load(open(p))
    for k in ("hooks", "env"):
        if k in c:
            c[k] = {
                kk: vv
                for kk, vv in c[k].items()
                if "trustgraph" not in str(vv).lower()
                and not (kk.startswith("TG_") or kk.startswith("TRUSTGRAPH_"))
            }
            if not c[k]:
                del c[k]
    with open(p, "w") as f:
        json.dump(c, f, indent=2)
        f.write("\n")

# ~/Library/Application Support/Claude/claude_desktop_config.json (macOS) —
# drop the trustgraph MCP entry if present
p = os.path.expanduser("~/Library/Application Support/Claude/claude_desktop_config.json")
if os.path.exists(p):
    c = json.load(open(p))
    if "mcpServers" in c and "trustgraph" in c["mcpServers"]:
        del c["mcpServers"]["trustgraph"]
        if not c["mcpServers"]:
            del c["mcpServers"]
        with open(p, "w") as f:
            json.dump(c, f, indent=2)
            f.write("\n")

print("clean")
PY
