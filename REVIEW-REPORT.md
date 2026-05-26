# trustgraph-skill review report

**Date:** 2026-05-26
**Scope:** mcp-server/ + skill/ + installer scripts + docs
**Method:** six specialised reviewers, parallel, each scoped to one concern (Python/MCP architecture, bash hygiene, security, API schema fidelity, skill prompt design, operational robustness).

---

## TL;DR

The codebase is structurally sound — the FastMCP lifespan, the `fcntl.flock` key-mint critical section, the per-chunk all-or-nothing flush rewrite, and the rate-tool client-side validation are all well-designed. The recent migration absorbed the major upstream API drift correctly.

But there are **eight high-severity issues**, two of which compound (a known prompt-injection mitigation is bypassed on three of four read surfaces, AND a documented debug log doesn't exist), plus seven medium-severity findings that converge on a few patterns worth changing rather than patching one-off.

**Top priorities to discuss:**
1. **`RATIONALE_TRUNCATE` is not enforced on `discover.best_event`, `EntityProfile.pooled_events`, or `summary.synthesis`** — security + agent context bloat.
2. **`k` validation desync (server max 50, our max 100)** and **profile cap fields (server max 20, ours max 50)** — guaranteed 422s on heavy use.
3. **`TRUSTGRAPH_DEBUG_LOG` documented but unimplemented** — README/code drift; users have no observability hook.
4. **No queue lock between `tg-rate` and `tg-flush`** — concurrent Code sessions silently drop ratings.
5. **401 on `/v1/scores` doesn't invalidate the cached key** — revoked keys keep failing until Desktop restart.
6. **SKILL.md tells the LLM to use bash wrappers** that don't exist on Claude Desktop or claude.ai.

---

## Cross-cutting themes (where multiple reviewers converged)

These are the highest-confidence findings — each flagged independently by two or more reviewers.

### 1. The 200-char rationale invariant is partial

**Flagged by:** security, skill design.

`retrieve()` truncates `event.rationale` to 200 chars (`server.py:621-624`), explicitly to bound prompt-injection exfil surface and context cost. But the same data class (`Event`) and similar free-text fields flow ungated through:

- `discover().best_event.rationale` — full length
- `score(detail="full").pooled_events[].rationale` and `.task` — full length
- `score(detail="full").summary.synthesis` and `.summary.highlights[].text` — server-LLM-mediated content, may have absorbed an injected rationale and laundered it into a paragraph the agent treats as authoritative

The doc note "treat rationale as user-supplied" appears in `retrieve` and `queries.md` but is absent from `discover` and the summary surface.

### 2. Validation desync between MCP tools and live server

**Flagged by:** API schema, indirectly by operational.

| Tool | Our `Field(...)` | Server enforces | Outcome |
|---|---|---|---|
| `retrieve.k` | `le=100` | `le=50` | guaranteed 422 above 50 |
| `rank.k` | `le=100` | `le=50` | guaranteed 422 above 50 |
| `score.top_failure_modes` | `le=50` | `le=20` | guaranteed 422 above 20 |
| `score.top_capability_tags` | `le=50` | `le=20` | guaranteed 422 above 20 |
| `rate.dimensions` (keys) | whitelist `DIMENSION_KEYS` | `additionalProperties: true` | we block ad-hoc snake_case keys the server accepts |
| All tools | `Literal["data_source", "capability"]` | enum includes `"agent"` | we can't query/submit refs for agent entities |

The validation is *strictly tighter* than the server in every case — failures fail loud (422 with a clear message), so this isn't a data-corruption risk, just a usability one. But four of these are guaranteed-failure-at-boundary, which suggests we copied old assumptions rather than reading the live spec.

### 3. Observability promises that don't exist

**Flagged by:** security, operational.

`README.md:60` advertises `TRUSTGRAPH_DEBUG_LOG` as an opt-in side log "mode 0600." Grep shows it is not implemented anywhere in `server.py` or any script. Users following the README to debug a malfunctioning MCP set the env var, restart Desktop, see no log file, and have no path forward except reading the hook log (which the MCP doesn't even write to).

### 4. Skill content tells the LLM to use wrappers the LLM may not have

**Flagged by:** skill design (also implicit in operational and API).

The SKILL.md voice (`scripts/tg-score data_source ...`) is bash-skill native. The same SKILL.md ships, unchanged, to:
- Claude Code — has the wrappers, works fine.
- Claude Desktop via MCP — does NOT have the wrappers, but has 9 MCP tools.
- claude.ai via the paired skill zip — does NOT have the wrappers, has nothing else either.

On the latter two surfaces, the model attempts a `scripts/tg-score …` command, gets "command not found," and may quietly skip the trust check rather than fall back. The MCP tool docstrings know nothing about the skill's framing; the skill's framing knows nothing about MCP.

### 5. Code/doc drift on rationale length

**Flagged by:** skill design.

- `rate()` MCP docstring says rationale ≤500 chars (and `Field(max_length=500)` enforces it).
- `references/rubric.md` says ≤2000 chars (the actual server limit).
- The bash `tg-rate` path doesn't enforce length client-side, so a 1500-char rationale built per rubric.md works via shell but is rejected by MCP.

---

## Per-surface findings

### Python / MCP architecture (`mcp-server/server.py`)

**Strengths:**
- Clean stdio shim with explicit rationale comment; logging redirected before any third-party import.
- `_request` helper centralises retry/timeout/error policy; tool bodies stay thin.
- Pydantic `extra="allow"` discipline is consistent and documented inline at the divergence points.

**Issues:**
- **[high]** Tool parameter `type` shadows the Python builtin (`score`, `retrieve`, `score_history`, `rate`). Pylance flags, footgun if future code uses `isinstance(x, type)` inside the function.
- **[high]** `ctx: Context[...] | None = None` workaround forces a `RuntimeError` guard in every tool body. FastMCP detects `Context`-typed parameters by annotation regardless of default; making it non-optional is the documented idiom and removes 8 unreachable guards. Current shape also exposes `ctx` as an optional argument in tool schemas — minor UX issue for hosts.
- **[med]** `score`'s union return type `ScoreSummary | EntityProfile` produces an `anyOf` in the tool output schema and an awkward branching body where four parameters (`top_failure_modes`, `top_capability_tags`, `scorer`) are silently ignored when the other branch is taken. Splitting into two tools (`score` + `profile`) would make schemas + docstrings + responses each stand alone.
- **[med]** `_request` retry only triggers on response-path 5xx. Connection-level errors (`httpx.TimeoutException`, `RequestError`) raise without retry, contradicting the "one retry on 5xx" intent if the failure surfaces as connection reset.
- **[low]** `Field(default_factory=list)` would be idiomatic; current `= []` works in Pydantic v2 but is a smell.

**Architectural suggestion:** the validation logic in `rate` (reserved prefixes, dimension key whitelist, metric key regex, tag normalisation) is procedural and would be reusable on a future `rate_batch` tool. Pulling it into a `RateInput` Pydantic model with `@model_validator` would (a) keep tool bodies to "validate → build body → submit," (b) give hosts a richer input schema, and (c) co-locate the rules.

### Bash / shell hygiene (`skill/scripts/` + installers)

**Strengths:**
- `mint-key.sh` lock pattern is correct: fd 9 held by parent shell, `<&9` dups OFD to python child for shared `LOCK_EX`, kernel releases on SIGKILL.
- Consistent `set -euo pipefail` and `command -v python3` preflight on every script.
- Atomic key write done right (mint-key.sh:84-88); same atomic pattern in `tg-flush` queue rewrite via `os.replace`.

**Issues:**
- **[high]** `install.sh:111` writes the anthropic key non-atomically (`(umask 077; printf > "$KEY_FILE")`). Concurrent reader or crash mid-write sees partial/empty file. Switch to mktemp+mv-f like `mint-key.sh`.
- **[med]** `tg-hook-postool:127` pipes synchronously to `tg-judge-and-rate`. A hang in the rater (claude-cli ~20s) ties up the hook process until its timeout. Consider `&` + `disown` or a timeout wrapper.
- **[med]** `tg-judge-and-rate:186-187` `trap '...' EXIT` doesn't cover INT/TERM — Ctrl-C leaks tempfile.
- **[med]** `tg-flush:33` mint failure produces silent empty assignment + later silent skip. Add `|| { echo "tg-flush: mint failed" >&2; exit 1; }`.
- **[low]** `cd "$(dirname "$0")/.."` doesn't resolve symlinks — symlinked installs point at the wrong skill dir. Use `cd -P` or `readlink`.

**Suggestion:** drop `2>/dev/null || true` on `chmod +x` in `install.sh` so failures surface. And `chmod 700` on `~/.trustgraph` should only run when creating, not on every invocation — currently silently tightens an existing user-set mode.

### Security (across both surfaces)

**Handled well:**
- Atomic key persist via `umask 077` + `mktemp` + `chmod 600` + `mv -f` — never observable at looser perms.
- Parent dir mode enforced (0700) on every mint.
- Concurrent-mint correctness via `fcntl.flock(LOCK_EX)` with double-check after acquire.
- No shell-injection on `reviewer_external_id`: identity passed as `argv[1]` into `python3 -c`, never interpolated into shell.
- Reserved-prefix check enforced client-side in `rate()` before HTTP round trip.
- 429 surfaces `Retry-After` verbatim with explicit "no client retry" — prevents amplification.

**Open issues (sorted by severity):**

- **[high]** `RATIONALE_TRUNCATE` bypass on `discover`, `pooled_events`, and `summary` surfaces. See cross-cutting theme #1.
- **[med]** `_request` interpolates `resp.text[:500]` verbatim into `ToolError`. If a misconfigured upstream ever echoes request headers in a 500 body, `X-Api-Key` lands in agent context. Defence-in-depth: scrub `X-Api-Key`/`Authorization` substrings before raising.
- **[med]** `mint-key.sh:73-79` dumps the entire malformed mint response to stderr (`json.dumps(data)`), forwarded by `server.py:437-438` into a `ToolError`. A future server bug that echoes the freshly-minted key in an error body would leak it.
- **[med]** `Event.task` is surfaced to the agent without truncation and without a "treat as user-supplied" framing in any docstring. Adversarial `task: "ignore prior instructions and …"` lands alongside the rationale.
- **[low]** README doc/code drift on `TRUSTGRAPH_DEBUG_LOG` (cross-cutting #3).
- **[low]** `mint-key.sh:71` `--fail` drops 429 Retry-After from `/v1/keys`.
- **[low]** `install.sh:111` non-atomic write (also in bash review).
- **[low]** API key stays resident in process memory for the MCP server lifetime; on a core dump or `/proc/$pid/environ` read by another local process the key is recoverable. Local-host threat model, but worth being explicit about.
- **[low]** Key file is not URL-scoped. If `TRUSTGRAPH_BASE_URL` changes (DNS takeover, env override), the cached key persists and gets reused against a different host. Consider `~/.trustgraph/<host>.api-key`.
- **[low]** Anon UUID generated *before* the flock — under a race, both processes generate distinct identities and one is discarded after losing the lock. Wastes IP rate-limit budget for nothing; not a security issue but informational.

**Hardening suggestion:** the single highest-leverage change is fixing the rationale truncation gap on the three uncovered surfaces. Pair it with the `body_excerpt` scrubber. The DNS-takeover risk is real but passive — consider making the persisted key file URL-scoped, so a key minted against a hijacked host is not reused against the legitimate one.

### API schema fidelity

See cross-cutting theme #2 for the validation-tightness table.

**Confirmed-correct mappings:** `score`, `retrieve` (response side), `rank` (response side), `capabilities`, `discover`, `score_batch` (response side), `score_history`, `rate` (response side).

**Additional low-severity divergences:**
- `RetrieveResult.n_events_total: int | None = None` — server never returns this; remove.
- `RetrieveResult.entity: dict[str,str] | None = None` — server marks required, always returns; tighten to required.
- `CapabilityRow.last_seen` / `CapabilityTagRow.last_seen` — spec marks required (`format: date-time`, no null branch); `str | None` is harmlessly loose.
- `rate` payload has `additionalProperties: false` server-side; we don't add unknown keys today, but losing this discipline silently 422s. Worth an explicit guard or comment.

**Pattern suggestion:** `extra="allow"` is the right call for forward-compat on read responses — it masks renames (exactly how `n_events → count` slipped through) but the cost of `extra="forbid"` is brittle on benign additions. Better mitigation: a periodic spec-diff job (`jq` diff the live OpenAPI against a snapshot, fail CI on rename-shaped changes). Same idea for the input `Literal` types: a small sync test asserting our enums equal `openapi.components.schemas.EntityByRef.properties.type.enum` would have flagged the `"agent"` omission.

### Skill design (SKILL.md + references/ + MCP tool docstrings)

**Strong design choices:**
- Frontmatter `description:` lists pre- and post-interaction triggers, names question patterns, AND defaults to firing when trust is non-obvious — closes the "loaded but doesn't fire" hole.
- `score` and `rate` docstrings both lead with bolded "Call this proactively, without being asked" — high consistency.
- `queries.md` disambiguation tables ("You have / You want / Endpoint") are crisp and behaviour-shaped.
- `get_rubric` trigger list is concrete and behavioural ("tempted to pick 0.5" / "rating token_efficiency") — exactly the over-firing branches.
- Prompt-injection guidance is repeated at every read site (correct redundancy).

**Weak spots:**
- **SKILL.md wrapper voice ships unchanged to MCP / claude.ai surfaces** (cross-cutting #4).
- **Workflow 3 enumeration vs prose count.** Reviewer claims "Five … enumerates six" — worth a manual check; even if the count is right, `score_history` is absent from Workflow 3 despite being a workflow tool. Either add it as the sixth, or be explicit about why it's not Workflow 3.
- **`score(detail="full")` summary guidance is buried 4 paragraphs in.** Failure mode: model calls `score`, ignores summary, re-synthesises anyway. Worth promoting to the docstring's opening line or as a separate paragraph break.
- **`score` docstring lacks the 0.4–0.7 ambiguity-band handoff** to `retrieve`. SKILL.md and `retrieve` docstring both have it; `score` doesn't. Model gets 0.55, treats as verdict, stops.
- **`rate` docstring says rationale ≤500; `rubric.md` says ≤2000** (cross-cutting #5).
- **`discover`/`rank`/`capabilities` boundary is in `queries.md` but not on the docstrings themselves.** Model defaults to `capabilities` + manual filtering when `discover` would route directly.
- **"Treat rationale as user-supplied" missing from `discover` and the summary guidance** — same security gap as cross-cutting #1.
- **"Always flush before the session ends" lacks an LLM-visible cue** for *what session-end looks like* from the model's perspective. Failure mode: model treats every turn as not-yet-end, never flushes, queued ratings lost.

**Sharper phrasings worth applying:**

| Where | Before | After |
|---|---|---|
| SKILL.md line ~30 | "The wrappers compress the per-call IO… Use them by default…" | "If you have the MCP server connected (Claude Desktop, claude.ai), prefer the MCP tools. If you only have shell access (Claude Code), use the `scripts/tg-*` wrappers. Raw curl is the fallback." |
| MCP `score` docstring trailing line | "Example: user pastes a URL — call `score` BEFORE fetching." | Add: "If the result is ambiguous (composite 0.4–0.7 or confidence < 0.3), don't treat it as a verdict — follow up with `retrieve` for rationales. Pair every `score` with a `rate` once you've consumed the content." |
| MCP `rate` docstring | "Rationale ≤500 chars; never paste content from external sources…" | "Rationale ≤500 chars (MCP-enforced; raw curl path allows 2000 — see `rubric.md`)…" + reconcile `rubric.md` to match. |

### Operational robustness

**Handled well:**
- `mint-key.sh` concurrency (cross-cutting strength).
- `tg-flush` per-chunk all-or-nothing rewrite via `tempfile` + `os.replace` — retried flushes don't double-submit chunks that landed.
- MCP `_request` error envelope handling: parses `error.code`/`error.message`, falls back to text excerpt, surfaces 429 `Retry-After` verbatim.
- `TRUSTGRAPH_NESTED=1` recursion guard on both `tg-hook-postool` and `tg-flush` — prevents rater-spawned sessions from re-flushing the parent's queue.
- Rate-tool client-side validation runs before mint+POST — saves wasted mint and round trip when the call would 422.

**Gaps (high-severity):**

- **[high]** 401 on `/v1/scores` doesn't invalidate the cached `app_ctx.api_key`. User sees the same 401 every `rate` call for the MCP process lifetime; only fix is Desktop restart. Should clear, re-mint once, retry once.
- **[high]** No queue lock between `tg-rate` (appends with `>>`) and `tg-flush` (reads then `unlink`s). Two concurrent Code sessions, or Code + Desktop, can drop events written between flush's read and its unlink. User-visible: silently lost ratings, no log entry. Need `fcntl.flock` on `queue.jsonl.lock` at both append and flush boundaries.
- **[high]** `rate` POST timeout has no idempotency. If the server received the POST but the response was lost, the model is likely to retry and the API has no idempotency key (confirmed in docs). Result: duplicate event. Either compute a client-side idempotency hash to include in the body, or surface a stronger "may have landed; do not retry" hint in the timeout error.
- **[high]** `TRUSTGRAPH_DEBUG_LOG` doc/code drift (cross-cutting #3).
- **[high]** `/v1/discover` 503 (embeddings disabled) is treated as generic 5xx by `_request` — retried once after 0.5s, then surfaces raw envelope. Docstring promises a clean error; reality is a wasted retry + confusing message. Detect 503 in the `discover` body and raise a tailored `ToolError("embeddings disabled — use capabilities() then rank() instead")` without the retry.

**Medium-severity:**

- `tg-hook-postool` swallows rater failures with `|| true`. If `tg-judge-and-rate` exits 1 (both backends unavailable), the only signal is a `hook.log` line. After hundreds of failed sessions the user wonders why their score corpus is empty. Add a counter file with N-strikes warning to user.
- `tg-judge-and-rate:56-57` reads the anthropic key with `$(<file)`, preserving trailing newline → embedded in HTTP header → 401. Editor-auto-newline footgun. Use `IFS= read -r KEY < file` or parameter expansion.
- `mint-key.sh` failure mode dumps the entire stderr (curl error etc.) into a `ToolError` in chat. No distinction between "API down" and "your install is broken." Classify exit code (127 vs HTTP-shaped) and emit one-line summary.
- `TRUSTGRAPH_MINT_SCRIPT` default is computed from `__file__`, brittle for non-standard install layouts.

**Low-severity:**

- `tg-flush:115-117` silently drops corrupted JSON lines. Should write to `queue.dead` with stderr count.
- `mint-key.sh:65` `cat` preserves trailing newline — current callers strip via `$(…)` or `.strip()`, but future caller via `read < <(…)` would carry it.
- `launchd` PATH may lack `/usr/bin/curl` SSL roots on Sonoma without Xcode CLT.
- A stray `print()` in a hot path post-startup would corrupt JSON-RPC frames; no runtime guard.

**Observability suggestions:**

- **Implement `TRUSTGRAPH_DEBUG_LOG`** as MCP-PLAN.md:289 spelled out — append-only JSONL with `{ts, tool, request_summary, response_status, duration_ms}` opened via `os.open(path, O_WRONLY|O_CREAT|O_APPEND, 0o600)`. Mirror in `tg-flush`.
- **Add `trustgraph-doctor`** (or `tg-status`): one-shot diagnostic printing key file presence + mode, queue size + oldest age, last successful flush, rater backend resolved + reachable, mint-key.sh executable. Single-command recovery starting point — the current "navigate hook.log" path is rough for downstream users.

---

## Notable techniques worth keeping

These are patterns the reviewers flagged as exemplary:

1. **`fcntl.flock` via inline `python3 -c`** in `mint-key.sh` — sidesteps macOS's missing `flock(1)` with a 1-line shim, holds the OFD on fd 9 across child invocations, kernel releases on SIGKILL.
2. **Atomic key persist** — `umask 077` + `mktemp` in same dir + `chmod 600` before write + `mv -f` rename. Dest never observable at looser perms.
3. **Per-chunk all-or-nothing queue rewrite** — failed chunk rewrites `queue.jsonl` with `events[i:]` via `tempfile` + `os.replace`. Retries don't double-submit.
4. **Stdio shim** — redirect stdout→stderr around third-party imports so chatty libraries don't corrupt the JSON-RPC frame.
5. **`TRUSTGRAPH_NESTED=1` recursion guard** — prevents rater subprocess from re-flushing the parent's queue.
6. **Client-side validation before HTTP round trip** in the `rate` tool — reserved prefixes, dimension whitelist, metric regex. Fails fast without wasting a mint on a guaranteed 422.

---

## Recommended action plan

Bucketed by effort and impact. Severity from the issues above.

### Must-fix (high severity, low cost)

| # | Fix | File(s) | Cross-ref |
|---|---|---|---|
| 1 | Truncate rationale + task on `discover`, `pooled_events`, `summary.synthesis`/`highlights[].text` | `server.py` | sec #1, skill design |
| 2 | Tighten `k` to `le=50` on retrieve+rank; `top_failure_modes`/`top_capability_tags` to `le=20` on score | `server.py` | API #2 |
| 3 | 401-on-rate → invalidate cached `app_ctx.api_key`, re-mint, retry once | `server.py` | ops |
| 4 | Add `fcntl.flock` on `queue.jsonl.lock` at both append and flush boundaries | `skill/scripts/tg-rate`, `tg-flush` | ops |
| 5 | Atomic write for anthropic key in `install.sh:111` | `skill/install.sh` | sec, bash |
| 6 | Detect 503 in `discover` body, raise tailored ToolError without retry | `server.py` | ops |
| 7 | Decide on `TRUSTGRAPH_DEBUG_LOG`: implement or remove README block | `server.py` + `README.md` | sec, ops |
| 8 | Rationalise rationale length cap (500 vs 2000) — one canonical value, update docs | `server.py`, `rubric.md` | skill design |

### Should-fix (medium, structural)

| # | Fix | File(s) |
|---|---|---|
| 9 | Split `score` into `score` + `profile` (two tools, no union return) | `server.py` |
| 10 | Make `ctx: Context[...]` non-optional, delete the 8 `if ctx is None` guards | `server.py` |
| 11 | Rename tool param `type` → `entity_type` (or `# noqa` if intentional) | `server.py` |
| 12 | Scrub `X-Api-Key`/`Authorization` from `_request` error excerpts | `server.py` |
| 13 | Whitelist mint-key.sh error shape — emit generic "unexpected mint response" rather than the raw blob | `skill/scripts/mint-key.sh` |
| 14 | Update SKILL.md framing to be surface-aware (MCP / wrappers / curl fallback) | `skill/SKILL.md` |
| 15 | Add ambiguity-band handoff + summary-relay rule to `score` docstring | `server.py` |
| 16 | Add `discover`/`rank`/`capabilities` disambiguation to each docstring | `server.py` |
| 17 | Allow `additionalProperties: true` on `dimensions` (drop whitelist or warn-only) | `server.py` |
| 18 | Add `"agent"` to entity `Literal` types | `server.py` |

### Nice-to-have (low / suggestions)

- 19. URL-scope the persisted key file (`~/.trustgraph/<host>.api-key`)
- 20. Build `trustgraph-doctor` diagnostic CLI
- 21. Periodic OpenAPI spec-diff job (catches silent renames)
- 22. Spec-sync test asserting our `Literal` enums equal OpenAPI enums
- 23. Move `rate` validation logic into a `RateInput` Pydantic model with `@model_validator`
- 24. Refactor `_request` to retry connection-level errors (matching the 5xx intent)
- 25. `IFS= read -r` for anthropic key to strip trailing newline (or strip in code)
- 26. `tg-flush` corrupted-line drop → write to `queue.dead` instead of silent skip
- 27. Async-ify the rater spawn in `tg-hook-postool` (background + disown)

### Won't-fix (or deferred)

- Process-memory key residency — local-host threat model; documentation note is enough.
- Anon UUID before lock — informational only, no real waste in practice.
- Symlink resolution in `cd "$(dirname "$0")"` — uncommon install pattern.

---

## Open questions for the discussion

1. **Scope of any action round.** Must-fix-only (8 items, ~1 day) or all the way through Should-fix (18 items, ~2-3 days) or full sweep including Nice-to-have?
2. **`score` split into `score`/`profile`** is a breaking change to the MCP tool list (9 → 10 tools, callers using `detail="full"` would migrate). Worth it for the cleaner schemas, or keep the union?
3. **Adopting `additionalProperties: true` on dimensions** opens the door to reviewer-specific axes (`helpfulness`, `engagement`, etc.) that don't roll up across reviewers. Server allows it; do we want the model to use it, or keep the whitelist as a quality guardrail?
4. **`TRUSTGRAPH_DEBUG_LOG`** — implement (MCP-PLAN.md:289 has the spec) or remove the README block? Implementing is ~30 lines; removing is one paragraph.
5. **`trustgraph-doctor`** — useful enough to build, or are the few users of this who'd hit problems comfortable in hook.log already?
