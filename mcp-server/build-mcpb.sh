#!/usr/bin/env bash
# Build the trustgraph MCP as a .mcpb bundle for one-click Desktop install.
#
# Usage:
#   cd mcp-server && bash build-mcpb.sh
#
# Output: ../dist/trustgraph.mcpb (gitignored — built per release).
#
# Prereqs:
#   - npm i -g @anthropic-ai/mcpb   (provides the `mcpb` CLI)
#   - A sibling skill/ directory containing scripts/mint-key.sh
#
# What it does:
#   1. Sanity-checks the bundled mint-key.sh source (since the MCP shells out
#      to it for the read-or-mint-and-persist critical section).
#   2. Copies skill/scripts/mint-key.sh into mcp-server/bundled/ so the
#      manifest's TRUSTGRAPH_MINT_SCRIPT can point at the bundle-local
#      path (${__dirname}/bundled/mint-key.sh) — no external dep at runtime.
#   3. Runs `mcpb pack .` which zips per .mcpbignore and writes the artifact.
#
# Distribution: ship dist/trustgraph.mcpb via GitHub Releases (or the
# trustgraph project's own download page). Users double-click in Claude
# Desktop → auto-install → the trustgraph MCP appears with all 10 tools and
# the proactive prompt registered.

set -euo pipefail
cd "$(dirname "$0")"

if ! command -v mcpb >/dev/null; then
  echo "build-mcpb.sh: 'mcpb' CLI not on PATH" >&2
  echo "  install with: npm i -g @anthropic-ai/mcpb" >&2
  exit 127
fi

# 1. Validate the sibling skill checkout
MINT_SRC="../skill/scripts/mint-key.sh"
if [[ ! -f "$MINT_SRC" ]]; then
  echo "build-mcpb.sh: $MINT_SRC missing — can't bundle the mint script" >&2
  echo "  is the sibling skill/ directory present? (this script assumes a" >&2
  echo "  same-repo layout; if you've split repos, adjust MINT_SRC)" >&2
  exit 1
fi

# 2. Stage bundled assets
mkdir -p bundled
cp "$MINT_SRC" bundled/mint-key.sh
chmod +x bundled/mint-key.sh
echo "  ✓ bundled mint-key.sh (from $MINT_SRC)"

# 3. Pack
OUT_DIR="../dist"
OUT_FILE="$OUT_DIR/trustgraph.mcpb"
mkdir -p "$OUT_DIR"
rm -f "$OUT_FILE"
mcpb pack . "$OUT_FILE"

# 4. Report
size=$(du -h "$OUT_FILE" | cut -f1)
echo
echo "  ✓ built $OUT_FILE ($size)"
echo
echo "  Install: drag $OUT_FILE onto Claude Desktop, or open it from Finder."
echo "  Inspect manifest: mcpb info $OUT_FILE"
