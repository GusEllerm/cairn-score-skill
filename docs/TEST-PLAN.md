# trustgraph install test plan

Six install paths to exercise end-to-end. Tick boxes as you go. Each test is self-contained — the **Reset** step at the start of each clears any prior install state so tests don't bleed into each other.

**Repo clone path used in examples:** `/Users/gusellerm/Projects/trustgraph-skill`. Substitute your own if different.

---

## Pre-flight (once, before starting)

- [ ] Repo cloned and current
  ```bash
  cd /Users/gusellerm/Projects/trustgraph-skill && git pull --ff-only && git log -1 --oneline
  ```
- [ ] `uv` on PATH
  ```bash
  which uv && uv --version
  ```
- [ ] `python3` ≥ 3.11 on PATH
  ```bash
  python3 --version
  ```
- [ ] Claude Code (`claude` CLI) installed and logged in **(only required for Tests A, B, F)**
  ```bash
  command -v claude && claude --version
  ```
- [ ] Claude Desktop installed (foreground app) **(only required for Tests B, C, D, F)**
- [ ] `npm` + `@anthropic-ai/mcpb` installed **(only required for Test C — .mcpb build)**
  ```bash
  command -v npm && command -v mcpb
  # if mcpb is missing:  npm i -g @anthropic-ai/mcpb
  ```
- [ ] Clean slate: no prior install state
  ```bash
  bash docs/_reset-trustgraph-state.sh 2>/dev/null || cat <<'RESET' | bash
    rm -rf ~/.claude/skills/trustgraph ~/.trustgraph
    python3 -c "
    import json, os
    p = os.path.expanduser('~/.claude/settings.json')
    if os.path.exists(p):
        c = json.load(open(p))
        for k in ('hooks','env'):
            if k in c:
                c[k] = {kk:vv for kk,vv in c[k].items() if 'trustgraph' not in str(vv).lower() and not (kk.startswith('TG_') or kk.startswith('TRUSTGRAPH_'))}
                if not c[k]: del c[k]
        json.dump(c, open(p,'w'), indent=2); open(p,'a').write('\n')
    p = os.path.expanduser('~/Library/Application Support/Claude/claude_desktop_config.json')
    if os.path.exists(p):
        c = json.load(open(p))
        if 'mcpServers' in c and 'trustgraph' in c['mcpServers']:
            del c['mcpServers']['trustgraph']
            if not c['mcpServers']: del c['mcpServers']
            json.dump(c, open(p,'w'), indent=2); open(p,'a').write('\n')
    print('clean')
    "
  RESET
  ```

---

## Test A — Code skill via `install.sh` (interactive)

**Goal:** verify the Code-only install path works with the interactive backend prompt.

### Install

- [ ] **Reset** (re-run the clean-slate block above if needed)
- [ ] Run installer
  ```bash
  bash /Users/gusellerm/Projects/trustgraph-skill/skill/install.sh
  ```
- [ ] When prompted, pick `2` for `claude-cli` backend (or `1` + provide an Anthropic API key if you prefer the API backend)
- [ ] Installer prints `Installed (Claude Code skill).`

### Verify install state

- [ ] Skill files in place
  ```bash
  ls ~/.claude/skills/trustgraph/  # expect: SKILL.md  references/  scripts/  install.sh  uninstall.sh  update-skill.sh  README.md  LICENSE
  ```
- [ ] Hooks registered
  ```bash
  python3 -c "import json; c=json.load(open('$HOME/.claude/settings.json')); print(sorted(c.get('hooks',{}).keys()))"
  # expect: ['PostToolUse', 'PostToolUseFailure', 'Stop']
  ```
- [ ] `tg-doctor` all green (last-flush will warn — that's expected before first flush)
  ```bash
  bash ~/.claude/skills/trustgraph/scripts/tg-doctor
  ```

### Smoke test (Code skill)

- [ ] Quit and reopen Claude Code (or run `/hooks` in the current session)
- [ ] Ask Claude: **"Fetch https://news.ycombinator.com and summarise the front page."**
- [ ] After completion, check the hook log
  ```bash
  tail -50 ~/.trustgraph/hook.log
  # expect: "dispatching briefing (async)" + "rater exited 0"
  ```
- [ ] End that session (close the terminal or run `/exit`); the `Stop` hook should flush. Re-run `tg-doctor` and look for `last flush: Xs ago`.

### Teardown

- [ ] Uninstall
  ```bash
  bash ~/.claude/skills/trustgraph/uninstall.sh
  rm -rf ~/.claude/skills/trustgraph ~/.trustgraph
  ```

---

## Test B — `install.sh --desktop` (unified Code + Desktop)

**Goal:** verify one command installs both surfaces and they coexist.

### Install

- [ ] **Reset** (from pre-flight block)
- [ ] Run unified installer
  ```bash
  bash /Users/gusellerm/Projects/trustgraph-skill/skill/install.sh --desktop
  ```
- [ ] Pick backend as before
- [ ] Installer prints `registered → mcpServers.trustgraph` with absolute `uv` path

### Verify install state

- [ ] Code skill present at `~/.claude/skills/trustgraph/`
- [ ] Desktop config has the trustgraph entry
  ```bash
  python3 -c "import json; c=json.load(open('$HOME/Library/Application Support/Claude/claude_desktop_config.json')); print(json.dumps(c.get('mcpServers',{}).get('trustgraph'), indent=2))"
  ```
- [ ] Backup file created with `bak.install-` prefix in the Claude Desktop config directory

### Smoke test (Desktop side)

- [ ] **Fully quit** Claude Desktop (Cmd+Q on macOS) and reopen
- [ ] In a new conversation, open the 🔌 / MCP indicator — `trustgraph` should show **10 tools**
- [ ] Type `/` in compose — **`trustgraph-proactive`** should appear in the picker
- [ ] Test prompt: **"Tell me about the trust profile of `data_source / canary://known-good`."** — expect `profile` to be called, summary returned

### Smoke test (Code side, parallel)

- [ ] In a Claude Code session, ask: **"Fetch https://example.com"** — hooks should fire silently
- [ ] `tg-doctor` reports green for both key file (URL-scoped path) and queue

### Coexistence check

- [ ] Both surfaces share `~/.trustgraph/keys/mep39camvm.us-east-1.awsapprunner.com.key` — i.e. one reviewer identity for ratings from both
  ```bash
  ls ~/.trustgraph/keys/
  ```

### Teardown

- [ ] Code-side uninstall
  ```bash
  bash ~/.claude/skills/trustgraph/uninstall.sh
  rm -rf ~/.claude/skills/trustgraph
  ```
- [ ] Desktop-side: remove the MCP entry
  ```bash
  python3 -c "
  import json, os
  p = os.path.expanduser('~/Library/Application Support/Claude/claude_desktop_config.json')
  c = json.load(open(p))
  c.get('mcpServers', {}).pop('trustgraph', None)
  if 'mcpServers' in c and not c['mcpServers']: del c['mcpServers']
  json.dump(c, open(p,'w'), indent=2); open(p,'a').write('\n')
  print('cleaned')"
  ```
- [ ] Wipe runtime state
  ```bash
  rm -rf ~/.trustgraph
  ```
- [ ] Restart Claude Desktop so it forgets the now-removed MCP

---

## Test C — Desktop MCP via `.mcpb` (one-click production path)

**Goal:** verify the production install path the trustgraph project will eventually ship.

### Build

- [ ] **Reset** (from pre-flight block)
- [ ] Build the bundle
  ```bash
  cd /Users/gusellerm/Projects/trustgraph-skill/mcp-server && bash build-mcpb.sh
  ```
- [ ] Expect output ending with `built ../dist/trustgraph.mcpb (<size>)`
- [ ] Inspect what's inside (sanity)
  ```bash
  unzip -l /Users/gusellerm/Projects/trustgraph-skill/dist/trustgraph.mcpb
  # expect: manifest.json, pyproject.toml, uv.lock, server.py, bundled/mint-key.sh
  ```

### Install

- [ ] Open the `.mcpb` in Claude Desktop
  ```bash
  open /Users/gusellerm/Projects/trustgraph-skill/dist/trustgraph.mcpb
  ```
- [ ] Desktop's installer UI opens — review the tool list (10 tools), the prompt (1), and the user_config fields (deployment URL with the DNS-takeover note, debug log path)
- [ ] Accept defaults and install
- [ ] Desktop confirms install + may prompt to restart

### Verify

- [ ] In compose, MCP indicator shows `trustgraph` with **10 tools**
- [ ] `/` picker shows `trustgraph-proactive`
- [ ] Settings → Developer (or Extensions) shows `TrustGraph` as installed

### Smoke

- [ ] Pin the proactive prompt + test prompt: **"Tell me about the trust profile of `data_source / canary://known-good`."**
- [ ] Verify it called `profile` and surfaced the LLM summary

### Teardown

- [ ] Uninstall via Desktop's Extensions UI (look for a remove/uninstall control on the TrustGraph entry)
- [ ] Wipe runtime state
  ```bash
  rm -rf ~/.trustgraph
  ```
- [ ] Restart Desktop

---

## Test D — Desktop MCP via hand-edit JSON (fallback)

**Goal:** verify the fallback path still works for users without npm.

### Install

- [ ] **Reset** (from pre-flight block)
- [ ] Hand-edit `~/Library/Application Support/Claude/claude_desktop_config.json` and merge the block from `README.md` "Fallback: hand-edit JSON" section
- [ ] Make sure to use the absolute `uv` path (`which uv` value)
- [ ] Validate JSON
  ```bash
  python3 -c "import json; json.load(open('$HOME/Library/Application Support/Claude/claude_desktop_config.json')); print('valid')"
  ```

### Verify + smoke + teardown

- [ ] Fully quit and reopen Claude Desktop
- [ ] Verify same as Test C (10 tools, prompt selectable)
- [ ] Smoke: canary profile test
- [ ] Teardown: remove the JSON entry (same as Test B teardown) + wipe `~/.trustgraph`

---

## Test E — claude.ai web skill upload

**Goal:** verify the web-only install path works.

### Build the skill zip (if not already current)

- [ ] Rebuild from current source
  ```bash
  cd /Users/gusellerm/Projects/trustgraph-skill/skill && \
    rm -f ../dist/trustgraph-skill.zip && \
    zip -r ../dist/trustgraph-skill.zip SKILL.md references/rubric.md references/examples.md references/queries.md references/scoring-model.md
  ```

### Install

- [ ] Open `claude.ai` in browser → Settings → Capabilities → Skills (UI path may vary)
- [ ] Upload `dist/trustgraph-skill.zip`
- [ ] Skill appears in the list, with the description from `SKILL.md` frontmatter

### Smoke

- [ ] In a new claude.ai conversation, ask a trustgraph-related question (e.g. **"Check the trust score of https://example.com using trustgraph"**)
- [ ] Verify the skill loads (the description is the router signal) and Claude attempts the curl-based path documented in `references/queries.md`

### Teardown

- [ ] Remove the uploaded skill from claude.ai → Settings → Capabilities → Skills

---

## Test F — Coexistence across all surfaces

**Goal:** verify that with Code skill + Desktop MCP both installed, ratings from each surface accrue under the same reviewer identity (URL-scoped key file is shared via `fcntl.flock`).

### Setup

- [ ] **Reset** (from pre-flight block)
- [ ] Install both via the unified command
  ```bash
  bash /Users/gusellerm/Projects/trustgraph-skill/skill/install.sh --desktop
  ```
- [ ] Pick backend, restart Desktop, restart Code session

### Coexistence check

- [ ] Submit a rating from Code-side first
  - In a Claude Code session, fetch any URL — hooks fire, rate gets queued
  - End session → Stop hook flushes
  - Note the API key path: `cat ~/.trustgraph/keys/mep39camvm.us-east-1.awsapprunner.com.key` (47-char `tg_...` value)
- [ ] Submit a rating from Desktop-side
  - In a Desktop conversation, ask Claude to rate something via `mcp__trustgraph__rate`
  - Verify it succeeds (no second mint happens)
- [ ] Confirm key file unchanged
  - Re-run `cat ~/.trustgraph/keys/...` — same 47-char value as before
- [ ] `tg-doctor` reports both queue activity AND a recent `last flush`

### Failure-mode probes (optional but worthwhile)

- [ ] Concurrent rate: open two Code sessions, both hitting different URLs — verify both ratings accumulate (queue lock + fcntl ordering working)
- [ ] Stale key: `chmod 000` the key file, attempt a `rate` from Desktop, verify the 401-retry kicks in (mints fresh key, retries, succeeds). Restore: `chmod 600`.
- [ ] Debug log: set `TRUSTGRAPH_DEBUG_LOG=/tmp/tg.log` in either install, drive one rate, verify `/tmp/tg.log` exists at mode 600 with one JSONL line per request

### Teardown

- [ ] Both uninstalls (Code via `uninstall.sh`, Desktop via JSON delete)
- [ ] Wipe `~/.trustgraph`
- [ ] Restart Desktop

---

## Tracking summary

| Test | Path | Done | Notes |
|---|---|---|---|
| A | Code skill via `install.sh` | ☐ | |
| B | `install.sh --desktop` unified | ☐ | |
| C | `.mcpb` one-click Desktop install | ☐ | |
| D | Hand-edit JSON Desktop fallback | ☐ | |
| E | claude.ai web skill upload | ☐ | |
| F | Coexistence (Code + Desktop) | ☐ | |

**Production-readiness gate:** A, C, and F all green = ready for the trustgraph site integration.

**Stretch checks** if you have appetite:
- Run the `mcp-server/spec-check.sh` after each MCP install to confirm no spec drift
- Try installing on a fresh user account (or in a clean VM) to catch hardcoded-path assumptions
- Try with a `TRUSTGRAPH_BASE_URL` override to verify URL-scoped key isolation
