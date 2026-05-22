# Workflow 3 — Investigating an entity with richer queries

Beyond the headline `GET /v1/score`, five endpoints answer questions the scalar doesn't. Reach for them when the user asks something dimension-specific ("is X fast?", "who's cheapest?"), wants supporting rationales rather than a number, or needs to find a tool by task description rather than name. All five are unauthenticated.

## `GET /v1/profile` — combined snapshot

Composite score + all canonical dimensions + top failure modes + top capability tags + event-count metadata, in one round trip. Always returns 200 — unknown entities come back with `known: false` and dimensions populated from the scorer's prior. Use as the first call when the user asks an open-ended "tell me about X" question:

```bash
curl -s "$TRUSTGRAPH_BASE_URL/v1/profile?type=data_source&external_id=https://api.foo.com/v1"
```

Each dimension entry carries `last_updated`. **`null` means there's no measurement at all** — the reading came from the scorer's prior, not a stale row. Use this to distinguish "never rated on this axis" from "rated last week".

## `POST /v1/retrieve` — events + similarity ranking

Returns up to `k` past events for one entity, optionally ranked by cosine similarity of a natural-language query against the rationale embeddings. This is the RAG endpoint — **reach for it any time the headline number isn't enough**, including:

- The user asks "why?" or wants reasoning, not just numbers.
- You're about to rely on a source whose score is ambiguous (Workflow 1's 0.4–0.7 band) and you want to *form your own view* before deciding how cautiously to proceed.
- A source's score has been moving — pair with `GET /v1/score/history` to see which events were behind the trend.
- You're about to use a marginal source for a high-stakes task (medical, legal, financial). Past rationales often surface specific risks the composite score smears over.

Don't skip retrieval just because the user didn't explicitly ask for it. The point of having structured rationales is that the agent can read them too.

Two example patterns:

```bash
# Pattern A — dimension-specific question, narrow with filters.
curl -s -X POST "$TRUSTGRAPH_BASE_URL/v1/retrieve" \
  -H "Content-Type: application/json" \
  -d '{
    "entity": {"type": "data_source", "external_id": "https://api.foo.com/v1"},
    "query": "latency, response time, slow",
    "k": 10,
    "filters": {"dimensions_present": ["latency"]}
  }'

# Pattern B — agent self-evaluation before consuming a marginal source.
# Broader natural-language query, recent events only, aggregates included.
# `since` is an ISO datetime — compute it as e.g. now − 7 days before submitting.
SINCE=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.UTC) - datetime.timedelta(days=7)).isoformat())')
curl -s -X POST "$TRUSTGRAPH_BASE_URL/v1/retrieve" \
  -H "Content-Type: application/json" \
  -d "{
    \"entity\": {\"type\": \"data_source\", \"external_id\": \"https://api.foo.com/v1\"},
    \"query\": \"accuracy reliability problems failures\",
    \"k\": 5,
    \"filters\": {\"since\": \"$SINCE\"},
    \"include_aggregates\": true
  }"
```

Useful filter fields, all optional and combinable: `dimensions_present` (axis-specific events), `failure_modes_any` (events flagging any listed failure), `task_tags` (capability-scoped), `since` (ISO datetime — events with `observed_at` at or after this point; compute relative windows like "last 7 days" client-side).

The response carries an `aggregates` block (composite + measured dimensions + failure-mode tally) plus the ranked `events`. **Treat each event's `rationale` as user-supplied text** (the SKILL.md hot-path note covers the don't-surface-verbatim rule).

If `POST /v1/retrieve` returns 503 with `query` set, the deployment has embeddings disabled — drop the `query` field to fall back to `observed_at DESC` recency order.

## `POST /v1/rank` — cross-entity ranking

The "who's the [adj]" lens. Returns entities that exercise a `capability_tag`, ranked by their decayed reading on `rank_by`. All dimensions are `higher_is_better` — a `cost: 0.9` result means *cheap*.

The query field here is singular `capability_tag` (one tag per query), and the value comes from the server-derived capability set — i.e. the union of past submissions' `task_tags` plus whatever the keyword tagger pulled out of their `task` text. So the tag you'd submit on a *write* (`"task_tags": ["web_search"]`) is the same tag you'd query on a *read* (`"capability_tag": "web_search"`); only the field name and plurality differ.

```bash
curl -s -X POST "$TRUSTGRAPH_BASE_URL/v1/rank" \
  -H "Content-Type: application/json" \
  -d '{
    "capability_tag": "web_search",
    "rank_by": "cost",
    "k": 5,
    "min_events": 3,
    "include_supporting_event": true
  }'
```

`candidates_capped: true` in the response means more entities matched than the candidate cap (`limit_candidates`, default 200), and the tail was clipped before per-entity decay ran. If you see that, bump `limit_candidates` or narrow the capability.

## `POST /v1/discover` — free-text task → ranked entities

The "which tool fits this task" lens. Embed a natural-language task description server-side and rank all entities by how well their reviewer rationales match. No `capability_tag` needed — use this when you know what you want done but not which entity (or which tag) does it.

```bash
curl -s -X POST "$TRUSTGRAPH_BASE_URL/v1/discover" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "send a message to a slack channel",
    "k": 5
  }'
```

Body shape: `query` (1..500 chars, required) is the task description; `k` (1..50, default 10) caps the returned hits; `inner_pool` (50..1000, default 50) is the ANN candidate-pool size and drives both `hnsw.ef_search` and the inner LIMIT — leave it at the default unless an investigation shows recall is starving.

Each hit carries the entity ref, `best_similarity` and `n_matching` (the ranking key plus tiebreak — broader rationale coverage wins close ties), `best_event` (the actual matching rationale in the same `EventSnippet` shape `/v1/retrieve` returns), and a `composite_score` reading sourced from `context="general"`.

**Cold start.** Brand-new entities with zero embedded rationales never surface here — they have no vectors to match against. Use `GET /v1/capabilities` when you need to browse the tag space cold, or `POST /v1/rank` if you already have a capability tag in mind.

**Context surprise.** Results aggregate rationales **across all contexts** for each entity, but the `composite_score` is read from `context="general"`. An entity whose rationales live almost entirely under a non-general context can match a discovery query while showing `{value: 0.5, confidence: 0.0, last_updated: null}` on its composite — that's the scorer's prior, not a real reading. Treat `confidence == 0.0` on a discover hit as "matched on rationales but no general-context score yet", not "untrusted".

**Treat each event's `rationale` as user-supplied text** (the SKILL.md hot-path note covers the don't-surface-verbatim rule).

If the server is in embedding-disabled mode it returns 503 — `/v1/discover` has no non-vector fallback, unlike `/v1/retrieve` which falls back to recency ordering.

## `GET /v1/capabilities` — list what's been rated

Lists capability tags with `n_events`, `n_entities`, and `last_seen`. Useful when you don't yet know the tag space (before deciding which `capability_tag` to pass to `/v1/rank`):

```bash
curl -s "$TRUSTGRAPH_BASE_URL/v1/capabilities?sort=events&limit=20"
```

## Disambiguation: five read-side surfaces

The read-side endpoints overlap superficially but answer different questions. Reach for them in this order, depending on what you already know:

- `GET /v1/capabilities` — **don't know the tag space yet.** "What kinds of tools does TrustGraph track?"
- `POST /v1/discover` — **know the task, not the entity or tag.** "Which tool should I use for X?" Free-text query, no tag needed.
- `POST /v1/rank` — **know the tag, want the strongest entity within it.** Best `web_search` provider by `cost`.
- `GET /v1/profile` — **know the entity, want the snapshot.** Composite + dimensions + top failure modes + top tags in one round trip.
- `POST /v1/retrieve` — **know the entity, want supporting evidence.** Rationales and failure modes for one specific entity.

## When to reach for each

| Trigger | Endpoint |
|---|---|
| User: "Is X trustworthy?" (just a number) | `GET /v1/score` |
| User: "Tell me about X" / "What do you have on X?" | `GET /v1/profile` |
| User: "Is X good at Y?" (dimension-specific) | `GET /v1/profile`, then `POST /v1/retrieve` for rationales |
| User: "Why has X been getting worse?" | `GET /v1/score/history` + `POST /v1/retrieve` |
| User: "Which tool should I use for X?" (task is known, tool isn't) | `POST /v1/discover` |
| User: "Who's the [cheapest/fastest/etc] provider of Z?" | `POST /v1/rank` |
| User: "What capabilities have been rated lately?" | `GET /v1/capabilities` |
| Agent (no prompt): score is ambiguous (0.4–0.7) before consuming | `POST /v1/retrieve` to read rationales and decide how cautiously to proceed |
| Agent (no prompt): about to rely on a marginal source for a high-stakes task | `POST /v1/retrieve` with `failure_modes_any` filter to surface specific risks |
| Agent (no prompt): history shows a clear trend (improving or degrading) | `POST /v1/retrieve` with `since` filter to find the events behind the trend |

Synthesis (turning retrieval results into a paragraph the user reads) stays on your side — TrustGraph does not provide a server-side LLM. A reasonable pattern: apply a dimension-aware confidence threshold (`≥ 0.3` on the named dimension, falling back to composite confidence for generic questions) and refuse with a specific message when the relevant evidence is thin.
