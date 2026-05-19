# trustgraph — Claude Code skill

A Claude Code skill that rates every external resource your agent touches —
WebFetch, WebSearch, MCP tools, curl invocations — invisibly in the background,
feeding ratings into the TrustGraph reputation API so your agent (and others)
can check before consuming an unknown source.

## Quick install

```bash
git clone https://github.com/GusEllerm/trustgraph-skill.git ~/.claude/skills/trustgraph && \
  bash ~/.claude/skills/trustgraph/install.sh
```

The installer prompts for a rater backend:
- **`api`** — direct Anthropic API. Needs an API key from `console.anthropic.com`. Cheap, fast.
- **`claude-cli`** — uses Claude Code's existing auth (claude.ai subscription). No API key needed. Slower, more subscription-quota.

Then start a fresh Claude Code session. Hooks fire automatically.

To update later: `bash ~/.claude/skills/trustgraph/update-skill.sh`

## What it does

- **Pre-check** (`scripts/tg-score`) — one-line reputation lookup before the agent commits to a marginal source.
- **Auto-rate** — a Claude Code `PostToolUse` hook builds a briefing from every WebFetch/WebSearch/MCP/curl call and feeds it to a Claude-Haiku-backed rater, which produces a calibrated `/v1/scores` body and queues it locally.
- **Auto-flush** — a `Stop` hook submits the queue as one batch when the session ends.
- **Manual queries** — `scripts/tg-retrieve` and `scripts/tg-rate` for ad-hoc use.

All of this happens outside the agent's conversation. The user sees nothing trustgraph-related in chat. The skill's content lives in `SKILL.md` + `references/` and is portable; only the hook registration is Claude Code-specific.

## Rater backends

The rater (`scripts/tg-judge-and-rate`) has two backends. Pick one at install time, or override per-session via `TG_RATER_BACKEND`.

| Backend | Auth | Cost per rating | Latency | Best for |
|---|---|---|---|---|
| `api`        | Anthropic API key | ~$0.0003 cached, ~$0.001 cold | ~2s | Heavy use; you have an API key |
| `claude-cli` | Claude Code subscription (claude.ai login) | ~$0.02–0.07 (subscription-billed) | ~20s | Light use; no API-key setup wanted |

The `api` backend hits `api.anthropic.com` directly with a tight tool-use prompt — fast, cheap, requires a key from `console.anthropic.com`. The `claude-cli` backend shells out to `claude -p` and uses whatever auth Claude Code is logged in with — no separate key, but ~60–200× more expensive per call and ~10× slower due to Claude Code's process+context overhead.

## Requirements

- Claude Code (the CLI; the hook system is Claude Code-specific)
- `python3`, `curl`, `bash` on `PATH`
- For the **api** backend: an Anthropic API key (Haiku 4.5 is the default rater model)
- For the **claude-cli** backend: a Claude Code login (`claude /login` — works with claude.ai subscription)
- Network access to the TrustGraph deployment (default `https://mep39camvm.us-east-1.awsapprunner.com`; override via `TRUSTGRAPH_BASE_URL`)

## Install

```bash
bash install.sh
```

The installer:

1. Copies the skill files to `~/.claude/skills/trustgraph/` (or wherever you pass as the first arg).
2. Marks the wrapper scripts executable.
3. **Prompts for the backend** (or use `TG_RATER_BACKEND=api|claude-cli` to skip).
4. For `api`: prompts for `ANTHROPIC_API_KEY` (hidden input) and saves to `~/.trustgraph/anthropic-key`, mode 600. **Not** put in `settings.json` env — that would clash with Claude Code's own auth.
5. Persists the backend choice to `~/.claude/settings.json` env as `TG_RATER_BACKEND`.
6. Merges three hook entries into `~/.claude/settings.json` (`PostToolUse`, `PostToolUseFailure`, `Stop`).

After installing, **start a fresh Claude Code session** (or run `/hooks` in the current one) to register the hooks. Verify with:

```bash
~/.claude/skills/trustgraph/scripts/tg-score data_source https://example.com
# → 0.50 0.00 null    (uninformed prior — entity unknown)
```

Then ask Claude to use any MCP tool or fetch a URL. The hook will fire silently; check `~/.trustgraph/hook.log` for evidence.

## How it works

```
Claude Code tool call (WebFetch/MCP/curl)
        │
        ▼
PostToolUse hook fires (async)
        │
        ▼
scripts/tg-hook-postool
  • parses tool_input/response
  • extracts entity (URL or mcp://server)
  • builds briefing JSON
        │
        ▼
scripts/tg-judge-and-rate
  • dispatches to api or claude-cli backend
  • passes skill content as system prompt
  • gets back a structured /v1/scores body
        │
        ▼
scripts/tg-rate   →   ~/.trustgraph/queue.jsonl
        │
        ▼  (at session end)
Stop hook → scripts/tg-flush
        │
        ▼
POST /v1/scores/batch   →   TrustGraph deployment
```

Files:

- `SKILL.md` — procedural skeleton
- `references/rubric.md` — score anchors, weight, dimensions, inversion rule
- `references/examples.md` — four worked submissions
- `references/queries.md` — `/v1/profile`, `/v1/retrieve`, `/v1/rank`, `/v1/capabilities`
- `references/scoring-model.md` — decay + confidence accrual
- `scripts/tg-score` `tg-rate` `tg-flush` `tg-retrieve` — manual wrappers
- `scripts/tg-judge-and-rate` — rater (both backends)
- `scripts/tg-hook-postool` — PostToolUse hook entry point
- `scripts/mint-key.sh` — mint a TrustGraph API key
- `install.sh`, `uninstall.sh` — setup / removal

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `TG_RATER_BACKEND` | (set by install to `api` or `claude-cli`) | `api` \| `claude-cli` \| `auto` |
| `ANTHROPIC_API_KEY` | (read from `~/.trustgraph/anthropic-key`) | For the api backend. NOT in `settings.json` env — keeps it out of Claude Code's auth path. |
| `TG_ANTHROPIC_KEY_FILE` | `~/.trustgraph/anthropic-key` | Override the key-file path |
| `TG_RATER_MODEL` | `claude-haiku-4-5-20251001` | Override the rater model |
| `TRUSTGRAPH_BASE_URL` | `https://mep39camvm.us-east-1.awsapprunner.com` | Override if you run your own TrustGraph deployment |
| `TRUSTGRAPH_API_KEY` | (auto-minted on first flush) | Persists at `~/.trustgraph/api-key` |
| `TRUSTGRAPH_QUEUE` | `~/.trustgraph/queue.jsonl` | Override the queue file location |
| `TRUSTGRAPH_KEY_FILE` | `~/.trustgraph/api-key` | Override the persisted key location |
| `TRUSTGRAPH_NESTED` | (unset) | Recursion guard. If `=1`, hooks bail out silently. Set automatically by `claude-cli` backend on its child process. |

## Disable / uninstall

Temporary disable (one session):

```jsonc
// in ~/.claude/settings.json
"disableAllHooks": true
```

Full uninstall:

```bash
bash ~/.claude/skills/trustgraph/uninstall.sh
# Optional: rm -rf ~/.claude/skills/trustgraph  ~/.trustgraph
```

## Known limitations

- Hooks fire on every Bash tool call. The script filters by network-verb (curl/wget/gh api/etc.) and exits silently for non-network commands. Adds ~10–20 ms per Bash call.
- The rater can occasionally produce mildly hallucinated rationale text (anchored to the briefing, with confabulation around it). The structural fields — score, weight, dimensions, failure_modes — are reliable; the prose rationale is best-effort.
- `/v1/scores` has no delete endpoint, so a misfire becomes a stale event in TrustGraph.
- Designed for Claude Code only. Claude Desktop has no equivalent hook system; the same scripts can be driven by a sidecar process if needed.

## License / authorship

Built collaboratively in a Claude Code session. Adapt freely.
