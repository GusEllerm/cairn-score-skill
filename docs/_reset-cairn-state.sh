#!/usr/bin/env bash
# Clean slate: wipe all cairn state from the local machine.
#
# Removes:
#   - ~/.claude/skills/cairn/      (Code skill files)
#   - ~/.cairn/                    (API key, queue, hook log, sentinels)
#   - Hook entries in ~/.claude/settings.json that reference cairn
#   - Env entries CAIRN_* in ~/.claude/settings.json
#   - mcpServers.cairn in Claude Desktop's config (if present)
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
#   bash docs/_reset-cairn-state.sh

set -euo pipefail

rm -rf ~/.claude/skills/cairn ~/.cairn

python3 - <<'PY'
import json, os

# ~/.claude/settings.json — drop cairn hooks + CAIRN_* env keys
p = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(p):
    c = json.load(open(p))
    for k in ("hooks", "env"):
        if k in c:
            c[k] = {
                kk: vv
                for kk, vv in c[k].items()
                if "cairn" not in str(vv).lower()
                and not kk.startswith("CAIRN_")
            }
            if not c[k]:
                del c[k]
    with open(p, "w") as f:
        json.dump(c, f, indent=2)
        f.write("\n")

# ~/Library/Application Support/Claude/claude_desktop_config.json (macOS) —
# drop the cairn MCP entry if present
p = os.path.expanduser("~/Library/Application Support/Claude/claude_desktop_config.json")
if os.path.exists(p):
    c = json.load(open(p))
    if "mcpServers" in c and "cairn" in c["mcpServers"]:
        del c["mcpServers"]["cairn"]
        if not c["mcpServers"]:
            del c["mcpServers"]
        with open(p, "w") as f:
            json.dump(c, f, indent=2)
            f.write("\n")

print("clean")
PY
