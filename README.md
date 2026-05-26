# TrustGraph for Claude

[**TrustGraph**](https://github.com/ryanchard/TrustGraph) gives AI agents a shared memory for trust. Before fetching a URL or invoking a tool, your agent can ask: *"how has this performed for other reviewers?"* After using it, your agent submits a rating. Over many interactions, the corpus learns which sources and tools are reliable, and your agent benefits from everyone else's experience.

This repo wires TrustGraph into Claude. Pick the install path that matches how you use Claude:

| If you use… | You get | One-line install |
|---|---|---|
| **Claude Code** (CLI) | Background rating of every tool call. Invisible to the model; ratings happen automatically via `PostToolUse` hooks. Highest signal density. | `bash skill/install.sh` |
| **Claude Desktop** (app) | Ten MCP tools (`score`, `rate`, `discover`, `profile`, …) the model calls when relevant. Tool invocations are visible in chat. | Double-click `dist/trustgraph.mcpb` |
| **claude.ai** (web) | The skill loads via claude.ai's router and primes Claude to call TrustGraph endpoints via `curl`. No local install. | Upload `dist/trustgraph-skill.zip` at Settings → Capabilities → Skills |

All three coexist. The Code skill and Desktop MCP coordinate on a single key file (`~/.trustgraph/keys/<host>.key`), so installing more than one accumulates ratings under one reviewer identity. The unified installer (`bash skill/install.sh --desktop`) sets up Code + Desktop in one command.

---

## Before you install: reviewer identity

`mint-key.sh` (called automatically on first write) defaults to an **anonymous** identity (`agent://anon/<uuid>`). Fine for trying things out, but the resulting key is unrecoverable if you wipe `~/.trustgraph/` — your accumulated ratings stay in TrustGraph but become orphaned (attributed to a reviewer-uuid you can no longer reproduce).

**If you want longitudinal signal across reinstalls or fresh machines**, mint once with an explicit identity and back the key up:

```bash
# Pre-mint with a stable identity (any URI-shaped string — your name, an
# agent handle, etc. — but avoid the reserved `agent://trustgraph-*` and
# `agent://anthropic/*` prefixes).
bash skill/scripts/mint-key.sh --write agent://your-org/your-name

# The key is now persisted at ~/.trustgraph/keys/<host>.key (mode 0600).
# Back it up to your secret store of choice (1Password, keychain, etc).
```

All subsequent installs reuse this key, so every rating attributes to your chosen identity.

---

## Install path 1 — Claude Code

```bash
git clone https://github.com/GusEllerm/trustgraph-skill.git ~/code/trustgraph-skill
bash ~/code/trustgraph-skill/skill/install.sh
```

The installer prompts for a rater backend:

| Backend | How it auths | Cost / latency per rating | Best for |
|---|---|---|---|
| `api` | Anthropic API key from `console.anthropic.com` | ~$0.001 / ~2s | Heavy use; you have an API key |
| `claude-cli` | Reuses Claude Code's existing claude.ai login | ~$0.02–0.07 (subscription-billed) / ~20s | Light use; no extra setup |

Then **start a fresh Claude Code session** (or run `/hooks` in the current one) — hooks load at session start. Every WebFetch / WebSearch / MCP tool / `curl`-like Bash call now gets rated silently in the background; queued events flush to TrustGraph when the session ends.

**Verify:**
```bash
bash ~/.claude/skills/trustgraph/scripts/tg-doctor
```

**Update later:** `bash ~/code/trustgraph-skill/skill/update-skill.sh` (git pulls + re-runs the installer).

**Install Code + Desktop together:** add `--desktop` to the install command above.

---

## Install path 2 — Claude Desktop

Anthropic's `.mcpb` format ships the MCP server as a single double-clickable file. One-time build, then drag-to-install.

### Build the bundle

```bash
cd mcp-server && bash build-mcpb.sh
# → ../dist/trustgraph.mcpb (≈ 68 KB)
```

Requires Node ≥ 18. The script uses `npx` so no global install is needed.

### Install

```bash
open dist/trustgraph.mcpb        # macOS
# or drag the file onto Claude Desktop in Finder / Explorer.
```

Desktop's installer UI opens, lists the ten tools the bundle ships, and prompts for optional config (deployment URL, debug log path). Accept defaults for a first install. Restart Desktop when prompted.

**Verify:** open **Settings → Connectors** — `trustgraph` should show as active with all ten tools listed. For a deeper check, run `bash skill/scripts/tg-doctor` from the cloned repo.

### Get auto-firing behaviour

By default the model calls TrustGraph tools when it judges them relevant — it does not auto-fire on every URL fetch the way Code's hooks do. Two ways to enable always-fire:

- **Always-on:** paste the block from [`docs/desktop-personalize.md`](docs/desktop-personalize.md) into **Settings → Profile → Personalize**. Every conversation gets the rule.
- **Per-conversation:** click the **`+`** button in compose, pick **"Add from trustgraph"**, attach **`trustgraph-proactive`**. The protocol applies to that conversation only.

### Fallback: hand-edit JSON

If you can't run `npx` (no Node) you can register the MCP manually by merging this into `~/Library/Application Support/Claude/claude_desktop_config.json`:

```jsonc
{
  "mcpServers": {
    "trustgraph": {
      "command": "/absolute/path/to/uv",
      "args": ["--directory", "/absolute/path/to/trustgraph-skill/mcp-server", "run", "--locked", "python", "server.py"],
      "env": {
        "TRUSTGRAPH_MINT_SCRIPT": "/absolute/path/to/trustgraph-skill/skill/scripts/mint-key.sh",
        "PYTHONWARNINGS": "ignore"
      }
    }
  }
}
```

Find your `uv` path with `which uv` — Desktop's launchd environment doesn't include `~/.local/bin`. Then restart Desktop.

---

## Install path 3 — claude.ai

Upload `dist/trustgraph-skill.zip` at **claude.ai → Settings → Capabilities → Skills**. No local install. The skill router triggers on the description's keywords and gives Claude the documented `curl` patterns to call TrustGraph.

If the zip is stale or you've edited `SKILL.md`, rebuild:

```bash
cd skill && zip -r ../dist/trustgraph-skill.zip SKILL.md references/*.md
```

claude.ai enforces `description ≤ 1024 chars` on the SKILL.md frontmatter — the current description is ~870 chars, leaving 154 chars of headroom for tweaks.

---

## Configuration

The defaults work out of the box. Override when you need to:

| Env var | What it does | Default |
|---|---|---|
| `TRUSTGRAPH_BASE_URL` | TrustGraph deployment URL. **⚠️ The default is an experimental shared subdomain — for any non-experimental use, point this at your own deployment** to avoid DNS-takeover risk on the shared host. | `https://mep39camvm.us-east-1.awsapprunner.com` |
| `TRUSTGRAPH_DEBUG_LOG` | When set, every request/response writes to this file as JSONL (mode 0o600). Use for debugging why a call didn't behave. | unset |
| `TG_RATER_BACKEND` | `api` or `claude-cli` (Code skill only). Pick at install; set in env to override per-session. | (set by install) |

For Desktop `.mcpb` installs, set these via the installer UI's config form. For Code, they live in `~/.claude/settings.json`'s `env` block. For ad-hoc invocations, export them in your shell.

---

## Troubleshooting

**`tg-doctor` is the source of truth** — run it first. It checks the key file, queue, rater backend, mint-key.sh, and the TrustGraph API itself.

| Symptom | Likely cause | Fix |
|---|---|---|
| Hooks don't fire in Code | Session started before install | Quit and reopen Claude Code, or `/hooks` in the running session. |
| MCP not visible in Desktop | Desktop cached old config | Fully **Cmd+Q** Desktop (not just close window), reopen. Check **Settings → Connectors**. |
| MCP tools appear, but the `trustgraph-proactive` prompt doesn't show under `/` | MCP prompts surface under `+` in Desktop, not `/` | Click `+` in compose → "Add from trustgraph" → `trustgraph-proactive`. |
| Ratings not accumulating | Hook fired but rater failed | Set `TRUSTGRAPH_DEBUG_LOG=/tmp/tg.log` and inspect, or `tail ~/.trustgraph/hook.log`. |
| `~/.trustgraph/keys/` empty after install | Lazy-mint: the key only appears on first write | Trigger one rating (or run `bash ~/.claude/skills/trustgraph/scripts/mint-key.sh`). |

---

## Uninstall

```bash
# Code skill:
bash ~/.claude/skills/trustgraph/uninstall.sh
rm -rf ~/.claude/skills/trustgraph

# Desktop MCP (installed via .mcpb):
#   Settings → Connectors → trustgraph → uninstall

# Desktop MCP (installed via JSON / install.sh --desktop):
#   Remove the `trustgraph` entry from
#   ~/Library/Application Support/Claude/claude_desktop_config.json

# claude.ai skill:
#   Settings → Capabilities → Skills → remove

# Runtime state (key file, queue, hook log):
rm -rf ~/.trustgraph
```

Or do all of it in one shot:

```bash
bash docs/_reset-trustgraph-state.sh
```

---

## What's in this repo

- `skill/` — Claude Code skill (`SKILL.md`, `references/`, wrapper scripts, installer)
- `mcp-server/` — Python MCP server + `.mcpb` packaging
- `dist/` — built artifacts (gitignored; rebuilt by the commands above)
- `docs/` — test plan, design notes, migration history (for contributors)

---

## Learn more

- **TrustGraph service** — [github.com/ryanchard/TrustGraph](https://github.com/ryanchard/TrustGraph)
- **Model Context Protocol** — [modelcontextprotocol.io](https://modelcontextprotocol.io)
- **Issues + contributions** — [github.com/GusEllerm/trustgraph-skill](https://github.com/GusEllerm/trustgraph-skill)

## License

MIT — see [LICENSE](LICENSE).
