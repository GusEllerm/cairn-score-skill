# Review action plan — rev 1

**Date:** 2026-05-26
**Source:** `REVIEW-REPORT.md` (six-reviewer parallel audit, post-migration)
**Resolved scope:** **full sweep** (27 items, ~1 week). See report for rationales; this doc is execution-only.

## Resolved design decisions (2026-05-26)

1. **Scope:** all 27 items — high + medium + nice-to-have.
2. **`score` tool:** split into separate `score` (always `/v1/score`) and `profile` (always `/v1/profile`). MCP tool count 9 → 10. Breaking for any caller of `score(detail="full")`.
3. **Dimension whitelist:** relax — allow ad-hoc snake_case keys (matching server `additionalProperties: true`). Canonical list stays documented via `get_rubric`.
4. **`TRUSTGRAPH_DEBUG_LOG`:** implement per MCP-PLAN.md:289 spec — append-only JSONL with `{ts, tool, request_summary, response_status, duration_ms}` opened via `os.open(O_WRONLY|O_CREAT|O_APPEND, 0o600)`. Mirror in `tg-flush`.
5. **`trustgraph-doctor`:** build as `skill/scripts/tg-doctor` matching the other tg-* wrappers (bash + inline python3, one line per check with ✓/✗).

## Phases

Ordered low-risk → high-risk, additive changes before refactors, observability before tests. Verify between each phase via live smoke tests (the same pattern as MIGRATION-PLAN's Phase 1).

### Phase 1 — Schema & validation tightening (low-risk, additive)

- Tighten `k` to `le=50` on retrieve + rank.
- Tighten `top_failure_modes` and `top_capability_tags` to `le=20` on score profile mode.
- Relax `DIMENSION_KEYS` whitelist on `rate` — allow snake_case ad-hoc keys (regex-validated); keep canonical list in `get_rubric`.
- Add `"agent"` to entity `Literal` types across `score`, `retrieve`, `rank`, `score_history`, `score_batch`.
- Drop phantom `RetrieveResult.n_events_total` (server never returns it).
- Tighten `RetrieveResult.entity` to required (server always returns it).
- Add explicit comment that `rate` payload assumes `additionalProperties: false` server-side.

**Smoke:** call retrieve(k=51), expect 422; relax k=50, expect ok. Submit rate with `dimensions: {"helpfulness": 0.8}`, expect 202.

### Phase 2 — Security gap closure

- Extend `RATIONALE_TRUNCATE` enforcement to `discover.best_event.rationale`, `EntityProfile.pooled_events[].rationale`/`.task`, and `EntityProfile.summary.synthesis`/`.highlights[].text`.
- Add `task` truncation + treat-as-user-supplied note on `retrieve`/`discover` docstrings.
- Scrub `X-Api-Key`/`Authorization` substrings from `_request` `body_excerpt` before raising `ToolError`.
- Whitelist `mint-key.sh` mint-response shape — emit generic "unexpected mint response" instead of dumping raw blob.
- `install.sh:111` atomic write (mktemp + chmod 600 + mv -f) for the anthropic key.
- URL-scope the persisted key file: store at `~/.trustgraph/<host>.api-key` rather than a flat name. Re-mint on URL change rather than reuse.

**Smoke:** craft a `summary.synthesis` >200 chars on an entity, call score profile, verify truncation. Trigger 422 with a mocked `X-Api-Key:...` body, verify scrubbed in ToolError.

### Phase 3 — Tool architecture refactor

- Split `score` → `score` (always `/v1/score`) + `profile` (always `/v1/profile`). Update tool docstrings, models, smoke tests.
- Make `ctx: Context[ServerSession, AppContext]` non-optional (drop `= None`). Delete the 8 `if ctx is None` guards.
- Rename tool param `type` → `entity_type` (with alias if the schema name should stay `type` from the host perspective).
- ~~Move `rate` validation into a `RateInput` Pydantic model with `@model_validator`.~~ Reconsidered during Phase 3c — the refactor would mostly mirror existing validation code (~50 added lines for the model + validators, replacing ~50 procedural lines in the tool body) with no behavior change and no concrete reuse target (`rate_batch` doesn't exist). The current procedural validation is readable and co-located. Revisit if a `rate_batch` tool lands later.
- `_request`: retry connection-level errors (`httpx.TimeoutException`, `RequestError`) on the same one-retry-after-0.5s budget as 5xx, matching the documented intent.

**Smoke:** `mcp.list_tools()` should now show 10 tools. Each tool should still parse a real live response.

### Phase 4 — Operational robustness

- 401 on `/v1/scores` → clear `app_ctx.api_key`, re-mint once via `_load_api_key`, retry once.
- Add `fcntl.flock` on `~/.trustgraph/queue.jsonl.lock` at both `tg-rate` append and `tg-flush` read/unlink boundaries.
- `discover` 503 → detect in tool body, raise tailored `ToolError("embeddings disabled — use capabilities() then rank() instead")` without retry.
- `tg-judge-and-rate:56-57` ANTHROPIC_API_KEY read: use `IFS= read -r KEY < file` to strip trailing newline.
- `mint-key.sh` failure surface: classify exit code (127 = missing deps, non-zero with HTTP body = API down) and emit a single one-line summary in `ToolError`, not the raw curl stderr.
- `tg-flush` corrupted-line drop → write to `~/.trustgraph/queue.dead` with stderr count, not silent skip.
- `tg-hook-postool` rater dispatch: spawn `tg-judge-and-rate` with `&` + `disown` (or a timeout wrapper) so a 20s claude-cli hang doesn't block the hook timeout.

**Smoke:** revoke a key out-of-band, call `rate`, verify it succeeds on the second attempt under the new identity. Spin two concurrent `tg-rate | tg-flush` loops, verify no events lost.

### Phase 5 — `TRUSTGRAPH_DEBUG_LOG` implementation

- Implement per MCP-PLAN.md:289 spec in `server.py`: open log file with `os.open(path, O_WRONLY|O_CREAT|O_APPEND, 0o600)` once at lifespan start (when env var set), write one JSONL line per `_request` call.
- Mirror in `tg-flush`: one line per chunk attempt with status + duration.
- Update README to reflect actual contents and file location.

**Smoke:** set `TRUSTGRAPH_DEBUG_LOG=/tmp/tg.log`, drive a few tool calls, verify lines appear with mode 0600.

### Phase 6 — `tg-doctor` diagnostic CLI

New script `skill/scripts/tg-doctor`. One-shot diagnostic that prints:

- Key file: present? mode 0600? last modified?
- Queue: file present? line count? oldest event age?
- Last successful flush: read from a new sentinel `~/.trustgraph/last-flush` (which `tg-flush` writes on success).
- Rater backend: `TG_RATER_BACKEND` resolved? backend tool on PATH? auth file (anthropic-key) present?
- `mint-key.sh`: executable? `curl`/`python3` reachable?
- TrustGraph API: HEAD `/livez` returns 200?

Output is human-skimmable, exit 0 if all green, non-zero with summary if any check fails.

**Smoke:** run on a fresh clean install (all red), then run on a fully-installed system (all green).

### Phase 7 — Skill content surface-awareness

- SKILL.md line ~30 rewrite: "If you have the MCP server connected (Claude Desktop, claude.ai), prefer the MCP tools (`score`, `profile`, `rate`, …). If you only have shell access (Claude Code), use `scripts/tg-*` wrappers. Raw curl is the fallback."
- `score` docstring (MCP): add ambiguity-band handoff (0.4–0.7 → call `retrieve`) and summary-relay rule (if `profile` returns a summary, relay verbatim) — promote out of mid-paragraph.
- `discover`/`rank`/`capabilities` docstrings: add the disambiguation lead-in ("don't know the tag?" → discover; "know the tag?" → rank; "browsing tag space?" → capabilities).
- Rationale length: reconcile to one canonical value. `rubric.md` says 2000 (matches server), MCP docstring says 500 (matches `Field(max_length=500)`). Either bump MCP to 2000 and rubric.md stays, or trim rubric.md to 500. **Recommendation: bump MCP to 2000 since the server allows it.**
- SKILL.md Workflow 3: add `GET /v1/score/history` as the sixth read endpoint (verify the count claim from the review).

### Phase 8 — CI / test infrastructure

- Spec-diff job: add a script that fetches `/openapi.json`, compares to a checked-in snapshot at `mcp-server/openapi.snapshot.json`, exits non-zero on differences. Run in CI (or document a `make spec-check` target).
- Spec-sync test: small Python file in `mcp-server/tests/test_spec_sync.py` asserting our `Literal` enums (entity `type`, rank dimensions, etc.) match the OpenAPI `enum` lists. Runs against the snapshot.
- Rebuild `dist/trustgraph-skill.zip` at the end so claude.ai surface stays current with the skill changes.

### Phase 9 — Cleanup + README refresh

- Update README tools table to 10 entries (post-split).
- Delete `MCP-PLAN.md` (long-finished; README already calls it "disposable scratch").
- Move `MIGRATION-PLAN.md` and `REVIEW-REPORT.md` into a `docs/` subdirectory (or delete if not load-bearing).
- Final commit log review.

## Verification harness

Reuse the per-tool live-API smoke pattern from MIGRATION-PLAN's Phase 1:

```bash
cd mcp-server && uv run --locked python -c "
import asyncio, server
asyncio.run(server.<tool>(<args>, ctx=fake_ctx))
"
```

Plus the canary entity (`data_source / canary://known-good`) and a high-event entity (`capability / tool://web-search`) as standing test fixtures.

## Open follow-ons (deliberately out of scope)

- Implementing a second rater backend (ALCF, per upstream's plans).
- Per-context summaries (also upstream follow-on).
- Memory residency of API key (local-host threat model — documentation note is enough).
- Symlink resolution in `cd "$(dirname "$0")"` (uncommon install pattern).
