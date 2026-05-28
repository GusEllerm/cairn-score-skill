# Claude Desktop — custom-instruction text for proactive Cairn behavior

Claude Desktop's MCP tool descriptions are advisory — they tell the model what tools exist, not when to use them. To get the always-fire behavior the Code skill gets from `PostToolUse` hooks, paste the block below into Claude Desktop's personalization panel:

**Settings → Profile → "What personal preferences should Claude consider in its responses?"**

Then start a fresh conversation. Every conversation from then on will apply the rules.

---

## Paste this:

```
Cairn trust-check protocol — apply automatically without asking:

BEFORE consuming a non-trivial web source or invoking an MCP tool whose reputation isn't established this session, call `mcp__cairn__score` with the entity type ("data_source" for URLs, "capability" for MCP servers / tools) and external_id (the URL or `mcp://<server-name>`). Skip for file reads, well-known docs sites already accepted (docs.python.org, en.wikipedia.org, mdn.io, etc.), URLs already discussed in this conversation, and plainly low-stakes one-shot replies.

AFTER consuming or invoking, even if I didn't ask, call `mcp__cairn__rate` with the same type/external_id, a holistic 0–1 score, and any signal you have: task (≤500 chars), rationale (≤2000 chars), dimensions (object with keys from accuracy / latency / cost / reliability / safety / token_efficiency / context_efficiency — all higher-is-better), failure_modes (snake_case tags), metrics (raw measurements).

The system only learns from submitted ratings — silent skipping erodes the signal. Pair every score call with a rate call once you've formed an impression.

When I ask "which tool for X?" or similar, `discover` searches the Cairn rating corpus (other reviewers' evidence), which is different from the tools you have access to in this session. Surface the discover results as evidence ("cairn has rated X / has no track record for Y"), don't conflate with available tools.
```

---

## Alternative: invoke the bundled prompt per conversation

The MCP server now ships a selectable prompt called `cairn-proactive` that contains the same protocol text. To invoke it for a single conversation instead of pinning it globally:

1. In a new conversation, click the `/` command picker (or type `/` in the message box).
2. Select **cairn-proactive** from the list.
3. Send the message — the protocol becomes part of the conversation context.

This is useful when you want the auto-firing behavior sometimes (e.g. browsing untrusted sources) but not for every conversation (e.g. asking Claude to draft a letter).

---

## Why both options?

- **Pinned custom instruction** = always on. Best if Cairn is integral to your workflow.
- **Per-conversation prompt** = opt-in. Best if most of your conversations don't need it.

The two methods don't conflict — having the personalization pinned doesn't break the prompt invocation; the prompt just becomes a redundant reaffirmation.
