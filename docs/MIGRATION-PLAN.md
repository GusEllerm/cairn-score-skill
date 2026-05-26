# TrustGraph migration plan — rev 1

**Date:** 2026-05-26
**Trigger:** TrustGraph API has evolved since our MCP server and skill shipped. Live OpenAPI (`/openapi.json` on the deployed PoC) and upstream repo (`ryanchard/TrustGraph` @ `main`, updated 2026-05-23) examined.
**Premise:** the API is **additively** different — no endpoints we use were removed or renamed. The work is (a) absorbing new optional fields, (b) exposing hidden parameters we hardcoded, and (c) surfacing four net-new endpoints — most importantly an LLM-generated entity-summary surface.

---

## At-a-glance: what changed

| Surface | Status | Notes |
|---|---|---|
| `GET /v1/score` | additive | new optional `context`, `scorer` params; response gains `diagnostics` (already absorbed by `extra="allow"`) |
| `GET /v1/profile` | **major additive** | new optional fields: `summary` (LLM-generated synthesis + highlights), `displayed_context`, `pooled_events`, `context_chips` |
| `POST /v1/retrieve` | additive | new request param `context` (null pools); EventSnippet now carries `event_id`, `context`, `reviewer_external_id`, `reviewer_type` as required |
| `POST /v1/rank` | additive | new request params `context`, `min_confidence`, `min_score`, `limit_candidates`; `rank_dimension` shape narrowed to `{value, confidence}` (no `last_updated`) |
| `GET /v1/capabilities` | no change | same request + response shape |
| `POST /v1/scores` | additive | new optional `observed_at` for historical events |
| `POST /v1/scores/batch` | no change | tg-flush already aligned |
| `POST /v1/keys` | additive | new optional `label` (cosmetic) |
| `POST /v1/discover` | **net-new** | task-text → ranked entities; semantic search over rationale embeddings |
| `GET /v1/score/history` | **net-new** | time-bucketed trend (`window`/`bucket` with `s`/`m`/`h`/`d` suffixes) |
| `POST /v1/score/batch` | **net-new** | batch read up to 100 refs (writes have `/v1/scores/batch` — singular vs plural separates read from write) |
| `GET /v1/scorers` | net-new | list active scorers; supports the shadow-execution feature. Probably internal — skip for MCP. |
| `GET /v1/entities` | net-new | browse all entities; web-UI feature. Skip for MCP. |
| `GET /skill/SKILL.md` | informational | upstream now publishes its own canonical skill — diverges from ours in coverage but not contract |

---

## The headline: LLM-generated entity summaries

The biggest semantic shift is `ProfileOut.summary` (nullable `SummaryOut`). When an entity has ≥ 3 events and the worker has caught up, `GET /v1/profile` returns:

```json
"summary": {
  "synthesis": "Reviewers consistently praise X for accuracy on extraction tasks but flag timeouts under load…",
  "highlights": [
    {"text": "Strong accuracy on document extraction", "event_ids": ["…", "…", "…"]},
    {"text": "Timeouts above ~50 concurrent requests",  "event_ids": ["…", "…"]}
  ],
  "n_events_at_generation": 12,
  "n_reviewers_at_generation": 4,
  "model": "claude-sonnet-4-6",
  "prompt_version": 1,
  "generated_at": "2026-05-24T17:00:00Z"
}
```

Each highlight cites real `event_id`s retrievable via `/v1/retrieve`. This is a **server-side LLM cost** the user is already paying for — we should surface it directly in `score` (profile mode) rather than have the calling LLM redo the synthesis.

---

## Per-endpoint delta (was → now → action)

### `GET /v1/score` → `ScoreReadingOut`

| Field / param | Was (our `ScoreSummary`) | Now | Action |
|---|---|---|---|
| `composite_score` | float | float | no-op |
| `confidence` | float | float | no-op |
| `last_updated` | str \| None | str \| None | no-op |
| `diagnostics` | not modeled | **required** object (scorer state: alpha, beta, n_eff, mu for `beta_decay`) | add explicit `dict[str, Any]` field (extra="allow" already tolerates it but explicit makes diagnostics first-class) |
| param `context` | hardcoded "general" | optional | accept on `score` tool |
| param `scorer` | not exposed | optional (omit = production default) | accept on `score` tool, default omit |

### `GET /v1/profile` → `ProfileOut`

| Field / param | Was (our `EntityProfile`) | Now | Action |
|---|---|---|---|
| existing 9 fields | matched | matched | no-op |
| `summary` | not modeled | `SummaryOut \| None` (LLM synthesis + highlights) | **add** `SummaryOut` + `HighlightOut` models, expose in `score` tool's profile mode |
| `displayed_context` | absorbed silently | `str \| None` | promote to explicit field |
| `pooled_events` | not modeled | `array \| None` (recent events across all contexts) | add `list[Event] \| None` |
| `context_chips` | not modeled | `array \| None` (per-context summary chips) | add `list[ContextChip] \| None` |
| param `context` | hardcoded | optional | accept on `score` tool |
| param `top_failure_modes` | hardcoded | optional integer cap | accept on `score` tool |
| param `top_capability_tags` | hardcoded | optional integer cap | accept on `score` tool |
| `top_capability_tags[]` entry | tag, n_events | tag, n_events, **last_seen** | add `last_seen` to `CapabilityTagRow` |

### `POST /v1/retrieve` → `RetrieveIn`/`RetrieveOut`

| Field / param | Was | Now | Action |
|---|---|---|---|
| Request body (`entity`, `query`, `k`, `filters`, `include_aggregates`) | matched | matched | no-op |
| Request `context` | not exposed | optional (null pools across contexts) | accept on `retrieve` tool |
| `EventSnippet.event_id` | not modeled (we drop it) | **required** | add to `Event` model — required for highlight citation cross-referencing |
| `EventSnippet.observed_at` | optional | **required** | tighten to required (we already tolerate missing — server now guarantees it) |
| `EventSnippet.context` | not modeled | **required** | add to `Event` model |
| `EventSnippet.reviewer_external_id` | not modeled | **required** | add to `Event` model |
| `EventSnippet.reviewer_type` | not modeled | **required** | add to `Event` model |
| Response `displayed_context` | optional | optional | no-op (we have it) |

### `POST /v1/rank` → `RankIn`/`RankOut`

| Field / param | Was | Now | Action |
|---|---|---|---|
| Request `capability_tag`, `rank_by`, `k`, `min_events`, `include_supporting_event` | matched | matched | no-op |
| Request `context` | not exposed | optional | accept on `rank` tool |
| Request `min_confidence` | not exposed | optional float | accept on `rank` tool |
| Request `min_score` | not exposed | optional float | accept on `rank` tool |
| Request `limit_candidates` | not exposed | optional integer (default 200) | accept on `rank` tool |
| `RankResult.rank_dimension` | `ScalarAggregate` (with `last_updated`) | `DimensionAggregate` (no `last_updated`) | our `ScalarAggregate` already has `last_updated` as `\| None = None` — backward-compatible parse |
| Response `capability_tag`, `ranked_by`, `candidates_considered`, `candidates_capped` | matched | matched | no-op |

### `GET /v1/capabilities` → `CapabilityListOut`

No deltas. Our `CapabilitiesResult` parses 1:1.

### `POST /v1/scores` → `ScoreEventIn`/`ScoreEventOut`

| Field | Was | Now | Action |
|---|---|---|---|
| Request body | matched | matched | no-op |
| Request `observed_at` | not exposed | optional ISO timestamp (for historical events) | accept on `rate` tool — useful for replay / catch-up flows |
| Response `{status, reviewee}` | matched | matched | no-op |

### `POST /v1/scores/batch` (tg-flush) → `ScoreBatchSubmitIn`/`Out`

| Field | Was | Now | Action |
|---|---|---|---|
| Request `{events: [...]}` | matched | matched | no-op |
| Response `{status, count, reviewees}` | matched | matched | tg-flush only checks for the `error` envelope — no parsing of the success body. Safe. |

### `POST /v1/keys` → `KeyMintIn`/`KeyMintOut`

| Field | Was | Now | Action |
|---|---|---|---|
| Request `reviewer_external_id` | matched | matched | no-op |
| Request `label` | not exposed | optional | optional cosmetic addition; **skip** unless we add a "name this key" UX |
| Response `{api_key, reviewer_external_id, created_at}` | matched | matched | no-op |

---

## Net-new endpoints — which to surface

| Endpoint | Decision | Why |
|---|---|---|
| `POST /v1/discover` | **add as MCP tool** | Highest-value addition. Answers "which tool fits this task?" — distinct from `rank` (which needs the tag) and `retrieve` (which needs the entity). Semantic search over rationale embeddings. |
| `GET /v1/score/history` | **add as MCP tool** | Answers "is X getting worse?" — already mentioned in our SKILL.md as a raw curl. Promote to a first-class tool. |
| `POST /v1/score/batch` | **add as MCP tool** | Perf win when evaluating multiple sources at once. Already in our SKILL.md as raw curl. |
| `GET /v1/scorers` | skip | Internal — shadow-execution config. Not actionable from the agent. |
| `GET /v1/entities` | skip | Browse-all entities is a web-UI feature; the agent flow is "I know the entity, look it up". |
| `GET /skill/SKILL.md` | informational | We track upstream as a reference but ship our own variant. See SKILL.md section below. |

---

## Phased migration plan

Phases are ordered low-risk → high-risk. Verify between each phase via live smoke tests (`uv run --locked python -c "import asyncio, server; asyncio.run(server.<tool>(...))"`).

### Phase 1 — Schema parity for existing tools (safe; additive only)

- Add Pydantic models: `SummaryOut`, `HighlightOut`, `ContextChip`
- Extend `EntityProfile` with `summary`, `displayed_context`, `pooled_events`, `context_chips`
- Extend `Event` with `event_id`, `context`, `reviewer_external_id`, `reviewer_type` (required)
- Extend `CapabilityTagRow` with `last_seen`
- Extend `ScoreSummary` with `diagnostics: dict[str, Any]`
- Smoke: parse one real response per endpoint into the updated model
- **Rollback:** revert the file — extra="allow" means responses still parsed if we miss a field

### Phase 2 — Expose hidden parameters on existing tools (safe; additive only)

- `score` tool: add optional `context: str = "general"`, `scorer: str | None = None`, `top_failure_modes: int | None`, `top_capability_tags: int | None`
- `retrieve` tool: add optional `context: str | None = None`
- `rank` tool: add optional `context: str = "general"`, `min_confidence: float | None`, `min_score: float | None`, `limit_candidates: int | None`
- `rate` tool: add optional `observed_at: str | None = None` (ISO datetime)
- Update tool descriptions to reflect new params (don't bloat — only mention non-obvious ones)
- Smoke: each tool with and without the new params

### Phase 3 — Add `discover` tool (net-new endpoint)

- Models: `DiscoverIn`, `DiscoverOut`, `DiscoverHit`
- Tool: `discover(query: str, k: int = 5)` returning `DiscoverOut`
- Handle 503 (embedding disabled — no fallback for discover) with a clean `ToolError`
- Description: "Use when you know the task but not which tool/entity does it. Returns ranked entities with matching rationales."
- Smoke: search for "send a slack message" → should return entities, each with a `best_event.rationale`
- **Skill parity:** add `scripts/tg-discover` wrapper

### Phase 4 — Add `score_batch` + `score_history` tools (net-new endpoints)

- `score_batch(refs: list[EntityRef]) -> list[ScoreReadingOut]` — fan-out lookup, up to 100 refs
- `score_history(type, external_id, window, bucket)` returning `list[HistoryBucket]` (each bucket: `start`, `end`, `count`, `mean_score`, `stddev_score`)
- Both unauthenticated like other reads
- Smoke: history of `canary://known-good` over 7d/1d should show buckets

### Phase 5 — SKILL.md parity + new wrapper scripts

- Add `scripts/tg-discover` (compact: one entity per line with `external_id similarity rationale-truncated`)
- Add `scripts/tg-history` (or extend `tg-score` with `--history` flag)
- Add `scripts/tg-score-batch` (reads refs from stdin JSONL, prints one line per ref)
- Update SKILL.md:
  - Add `/v1/discover` to Workflow 3
  - Add note that `/v1/profile` may carry an LLM summary (worth quoting directly to the user)
  - Add the 4-endpoint disambiguation table from upstream (capabilities / discover / rank / retrieve)
- Update `references/queries.md` similarly

### Phase 6 — Tool description tuning

- Update each MCP tool's description to mention new params it now accepts
- Add proactive trigger to the skill description for "which tool for X" → discover
- Smoke (Claude Desktop): prompt "find me a slack-sending tool" → should fire `discover` before fetching anything

### Phase 7 — README + paired claude.ai skill rebuild

- README tools table: 6 → 9 tools
- Note about LLM summaries surfaced through `score` (so users understand a chunk of model-generated text may appear)
- Rebuild `dist/trustgraph-skill.zip` so the claude.ai surface stays aligned

---

## Resolved scope (2026-05-26)

1. **Scope:** all 7 phases — full migration in one branch sequence.
2. **Wrappers:** yes — add `tg-discover`, `tg-history`, `tg-score-batch` matching the existing wrapper pattern (one compact line per record).
3. **Skill stance:** **light overlay** — we keep our wrappers, rubric, and procedural framing; we adopt upstream's structure / examples / disambiguation tables verbatim where they overlap, and periodically resync.
4. **`label` field on key mint:** skip — cosmetic only.

---

## Appendix A — files touched per phase

- **Phase 1:** `mcp-server/server.py` (response models only)
- **Phase 2:** `mcp-server/server.py` (tool signatures + docstrings)
- **Phase 3:** `mcp-server/server.py` (+ models + new tool); `skill/scripts/tg-discover` (new); `skill/SKILL.md` (mention)
- **Phase 4:** `mcp-server/server.py` (+ models + 2 new tools); optional wrappers
- **Phase 5:** `skill/SKILL.md`, `skill/references/queries.md`, `skill/scripts/tg-*` (depending on Q2)
- **Phase 6:** `mcp-server/server.py` (descriptions); `skill/SKILL.md` (frontmatter `description:`)
- **Phase 7:** `README.md`; `dist/trustgraph-skill.zip` (rebuilt from `skill/`)

## Appendix B — verification harness

Reuse the smoke pattern from MCP-PLAN rev 5 Phase 0:

```bash
cd mcp-server && uv run --locked python -c "
import asyncio, server
asyncio.run(server.<tool>(<args>))
"
```

For each phase, smoke against:
- A known entity with high event count (best for testing summary surface)
- The canary `data_source / canary://known-good`
- A brand-new ephemeral entity (tests 0.5/0.0 prior path)

## Appendix C — non-goals (deliberately out of scope)

- **Adopting upstream's CLAUDE.md commit conventions** — they use `Co-Authored-By: Claude` trailer; our repo's classifier rejects fabricated Anthropic attribution. Keep our pattern.
- **Surfacing `GET /v1/scorers`** — internal config.
- **Surfacing `GET /v1/entities`** — web-UI browse, not an agent workflow.
- **Per-context summaries** — upstream's spec marks this as a future follow-on; we'd get nothing from anticipating it.
- **Implementing client-side summary regeneration** — when `summary: null`, just say so; don't have the calling LLM try to synthesize from raw events. (We can mention the option but defaulting to it would defeat the server's cost-control gating.)
