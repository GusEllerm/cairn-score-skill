#!/usr/bin/env bash
# Remove the trustgraph hook entries from ~/.claude/settings.json.
#
# Leaves alone:
#   - The skill files in ~/.claude/skills/trustgraph/ (rm -rf yourself if you also want them gone)
#   - ANTHROPIC_API_KEY in settings.json env (you may use it elsewhere)
#   - ~/.trustgraph/ (queue, key, log — rm -rf if you want a clean wipe)
#
# Usage:
#   bash uninstall.sh
#
# Honors:
#   SETTINGS  — override settings.json path (for testing); default ~/.claude/settings.json
#   DEST      — override skill location (used to identify which hooks belong to us);
#               default ~/.claude/skills/trustgraph

set -euo pipefail

command -v python3 >/dev/null || { echo "uninstall.sh: python3 required" >&2; exit 1; }

DEST="${DEST:-$HOME/.claude/skills/trustgraph}"
SETTINGS="${SETTINGS:-$HOME/.claude/settings.json}"

if [[ ! -f "$SETTINGS" ]]; then
  echo "uninstall.sh: no settings file at $SETTINGS; nothing to remove"
  exit 0
fi

SETTINGS="$SETTINGS" DEST="$DEST" python3 <<'PY'
import json, os

settings_path = os.environ["SETTINGS"]
dest = os.environ["DEST"]

with open(settings_path) as f:
    data = json.load(f)

hook_cmd = os.path.join(dest, "scripts", "tg-hook-postool")
flush_cmd = os.path.join(dest, "scripts", "tg-flush")
ours = {hook_cmd, flush_cmd}

hooks = data.get("hooks", {})

def strip(event):
    if event not in hooks:
        return 0
    removed = 0
    new_entries = []
    for entry in hooks[event]:
        kept_hooks = [h for h in entry.get("hooks", []) if h.get("command") not in ours]
        if len(kept_hooks) < len(entry.get("hooks", [])):
            removed += len(entry.get("hooks", [])) - len(kept_hooks)
        if kept_hooks:
            entry["hooks"] = kept_hooks
            new_entries.append(entry)
    if new_entries:
        hooks[event] = new_entries
    else:
        del hooks[event]
    return removed

total = 0
for event in list(hooks.keys()):
    total += strip(event)

if not hooks:
    data.pop("hooks", None)

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"  removed {total} trustgraph hook entr{'y' if total == 1 else 'ies'} from {settings_path}")
PY

echo
echo "Uninstalled hooks. The skill files at $DEST are untouched."
echo "To wipe everything trustgraph-related:"
echo "  rm -rf $DEST"
echo "  rm -rf \$HOME/.trustgraph"
echo "  # and remove ANTHROPIC_API_KEY from $SETTINGS env block if you don't use it elsewhere"
