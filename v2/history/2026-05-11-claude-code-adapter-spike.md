# Spike: Claude Code CLI Headless Adapter

**Date:** 2026-05-11
**Branch:** `spike/claude-code-adapter`
**Riskiest assumption tested:** Can the Symphony Elixir fork invoke Claude Code CLI in headless mode, parse its event stream cleanly, and extract the data the orchestrator needs (assistant content, usage, cost, errors)?
**Verdict:** **GO.** The adapter brick is straightforward.

---

## Why this spike

The v2.1 design depends on Symphony being runtime-agnostic: a single `mode + runtime + persona` config that can drive Codex OR Claude Code (OR future runtimes). Symphony already wraps Codex via the `codex app-server` JSON-RPC protocol over stdio. Adding Claude Code is an unknown until tested.

The unknown decomposes into:

1. Does Claude Code have a headless invocation that produces machine-readable output?
2. Is the output format stable and parseable?
3. Are the event shapes rich enough to drive Symphony's orchestrator (tool calls, content blocks, usage, cost, errors)?
4. Are there operational gotchas (hook injection, auth pitfalls, cost surprises)?

A failed answer to any of these means the runtime-adapter brick needs significant scope expansion. A clean pass means the brick is a tidy ~300-500 LoC piece of work.

## What I did

1. Captured two real Claude Code stream-json invocations as test fixtures.
2. Built a pure-function event parser (`SymphonyElixir.Runtime.ClaudeCode.EventParser`) that normalizes the JSONL stream into typed Elixir event tuples.
3. Wrote 37 unit tests covering every event type, malformed-line handling, blank-line handling, and end-to-end fixture parsing.
4. Ran the full Symphony test suite (267 tests) to confirm zero collateral damage.

All artifacts live at:

- `elixir/lib/symphony_elixir/runtime/claude_code/event_parser.ex`
- `elixir/test/symphony_elixir/runtime/claude_code/event_parser_test.exs`
- `elixir/test/support/fixtures/claude_stream_minimal.jsonl` (16 lines, real session, $0.20 of capture)
- `elixir/test/support/fixtures/claude_stream_bare_auth.jsonl` (3 lines, auth-failure path, free)

## Findings

### 1. Claude Code has clean headless mode

Flags that matter:

| Flag | Purpose |
|---|---|
| `-p` / `--print` | Non-interactive, exit after response |
| `--output-format stream-json` | JSONL on stdout, one event per line |
| `--input-format stream-json` | Realtime streaming input (for multi-turn) |
| `--include-partial-messages` | Emit content_block_delta events for token-by-token streaming |
| `--include-hook-events` | Include hook lifecycle in stream (default: included anyway) |
| `--max-budget-usd N` | Hard cost cap. Stream emits `result:error_max_budget_usd` on hit |
| `--bare` | Skip user-scope settings, hooks, plugins, OAuth/keychain |
| `--settings FILE` | Point at a custom settings JSON (auth, MCP servers, etc.) |
| `--system-prompt` / `--append-system-prompt` | Override or extend the system prompt |
| `--allowedTools` / `--disallowedTools` | Tool allow/deny lists |
| `--add-dir` | Grant tool access to extra directories |

This is more configurable than Codex's app-server. The `--max-budget-usd` flag in particular is a free win for the cost-cap edge case in `v2/edge-cases.md §6`.

### 2. Event taxonomy is small, stable, and JSONL

Observed event types in real captures:

| `type` | `subtype` / `event.type` | Frequency | Notes |
|---|---|---|---|
| `system` | `init` | once | Session metadata: id, model, cwd, tools, version |
| `system` | `hook_started` / `hook_response` | many | Local hook lifecycle. **Filterable noise.** |
| `assistant` | n/a | per message | Full message with `content[]` blocks (text, tool_use) and `usage` |
| `stream_event` | `content_block_start/delta/stop` | per chunk | Only when `--include-partial-messages` |
| `stream_event` | `message_delta` | once per message | Stop reason + final usage. Ignored. |
| `rate_limit_event` | n/a | once or none | Rate-limit window status |
| `result` | `success` / `error_max_budget_usd` / ... | once, terminal | `total_cost_usd`, `modelUsage`, `errors[]` |

The terminal `result` event has a `subtype` field that distinguishes success from various error modes. `is_error` is a separate boolean. Schema is consistent across success and failure paths.

### 3. Parser is pure and small

The parser module is ~200 lines of Elixir including the `@type` specs and module docs. It exposes:

- `parse_line/1` — one JSONL line → one event tuple (or `nil` for blank lines)
- `parse_stream/1` — full JSONL content → list of events
- `without_hooks/1` — convenience filter to strip hook noise

Event tuples are tagged and typed:

```elixir
{:init, %{session_id, model, cwd, tools, ...}}
{:assistant_message, %{text, content_blocks, model, usage}}
{:stream_delta, "partial text chunk"}
{:result, %{subtype, is_error, total_cost_usd, model_usage, errors}}
{:hook_started, "SessionStart:startup"}
{:malformed, "original line that failed to parse"}
{:ignored, "unknown_event_type"}
```

Pure-function design means the adapter that consumes these (the port-management piece) is decoupled from the parsing and can be tested independently. Future runtimes (e.g., adding a Cursor or Devin adapter) would write their own EventParser implementing the same tuple contract.

### 4. Tests pass cleanly

```
Finished in 0.08 seconds (0.08s async, 0.00s sync)
37 tests, 0 failures
```

Full Symphony suite:

```
267 tests, 0 failures, 2 skipped
```

The 2 skipped are pre-existing skips, not introduced by this spike.

### 5. The hook-injection cost trap (and the right fix, per smithy-v1 PER-44)

The first capture (without `--setting-sources` scoping) cost $0.19 for a trivial echo prompt because Shawn's personal CLAUDE.md `SessionStart` hooks injected 29,753 input tokens of context (memory, persona setup, etc.) into the session.

**Initial wrong guess in this spike:** use `--bare`, ship an `apiKeyHelper` settings file.

**Right answer, per smithy-v1's PER-44 worker:** `--setting-sources project,local`.

```
claude -p \
  --setting-sources project,local \
  --dangerously-skip-permissions \
  --model claude-{opus-4-7|sonnet-4-6|haiku-4-5} \
  --disallowedTools "mcp__linear__save_issue mcp__linear__save_comment ..." \
  --output-format stream-json \
  --verbose
```

Settings sources are orthogonal to auth. **OAuth and keychain credentials, plus user-scope MCP server configs, live OUTSIDE the `settings` system.** They persist across all `--setting-sources` values. Dropping the `user` scope skips:

- The operator's `~/.claude/settings.json` (which holds the SessionStart hooks Shawn uses for vault sync, wrapup digests, deaiify, etc.)
- The operator's user-scope CLAUDE.md (which holds the Argyle persona setup, brand voice rules, project heuristics)
- The operator's user-scope plugin registrations (superpowers, vercel, etc.)

What remains:

- OAuth or keychain auth (works as if interactive)
- Linear / GitHub / other MCP servers (still connect)
- Project-scope settings (target repo's `.claude/settings.json` if present)
- Local-scope settings (workspace overrides if present)

For Codex, the symmetric flag is `--ignore-user-config` (per smithy-v1 PER-46). Drops `~/.codex/config.toml` while CODEX_HOME auth persists. The orchestrator re-adds the Linear MCP server inline via `-c mcp_servers.linear.url=...` since user-scope MCP config is dropped along with user prompts/rules.

**Recommendation:** Symphony's ClaudeCode adapter always passes `--setting-sources project,local`. Codex adapter always passes `--ignore-user-config` with explicit MCP re-adds for shared servers. No `apiKeyHelper` plumbing needed; no `ANTHROPIC_API_KEY` env var needed.

### 5a. Universal AGENTS.md nudge (Shawn's follow-up idea)

Both Codex and Claude Code read project-root `AGENTS.md` (Codex natively; Claude Code via interop). Symphony's `smithy bootstrap <repo>` flow (or a manual setup step in v1) ships a minimal AGENTS.md that nudges both runtimes consistently:

- Workpad ownership conventions
- The structured RESULT.md / REVIEW.md handoff contract
- Repo-specific test commands and validation gates
- The "do not call Linear write tools" rule (defense-in-depth on top of `--disallowedTools` / Codex `disabled_tools`)
- Branch naming, commit message conventions

This keeps runtime-specific prompts thin (each runtime gets only what it can't get from AGENTS.md) and gives a single source of truth for "how Smithy expects agents to behave in this repo." Worth a separate brick in v2.1.

### 6. Auth-failure path is parseable

The `--bare` capture produced a 3-line stream:

- `system:init` (session metadata, with `apiKeySource: "none"`)
- One intermediate event
- `result:success` with `is_error: true, result: "Not logged in · Please run /login"`

Even on auth failure, the parser produces a clean event sequence and a final `result` event the adapter can react to. No malformed output. No hangs.

### 7. Multi-turn is supported but out of scope for v1 spike

Claude Code supports multi-turn via `--input-format stream-json` (stream user messages in over stdin while reading events on stdout) or via `--continue <session_id>` (new process resumes prior session). Symphony's existing Codex AgentRunner does multi-turn via the app-server protocol; the Claude side has an analog.

For v1, the simplest path: each Symphony "turn" is one Claude Code invocation. The session_id from the previous `system:init` event is passed to `--continue` on the next invocation. State persists in Claude Code's session store. No long-lived port needed.

This is simpler than Codex's pattern (which keeps the port alive across turns) and probably the right shape for Symphony's reviewer mode in particular, where a single-shot invocation that writes `REVIEW.md` is the unit of work.

## What's NOT proven by this spike

- Spawning the process from Elixir via `Port.open/2` and capturing stdout/stderr correctly. Symphony's existing Codex AppServer module proves the pattern works for one CLI; assumed it works for `claude` too. Not tested in this spike.
- Multi-turn session continuity via `--continue`. Untested.
- Tool-use round trips (assistant emits `tool_use` block, orchestrator executes the tool, replies via stream-json input). The parser handles `tool_use` content blocks correctly, but the full round-trip is not exercised.
- Real reviewer-mode flow end to end. Need a separate spike for "spawn Claude with reviewer persona, write REVIEW.md, parse the YAML output."
- Cost accounting accuracy across many runs. Need observation over time.

These are all bricks to lay AFTER the runtime adapter ships, not blockers to it.

## Recommendation

**GO on the runtime-adapter brick** with this scope:

1. Generalize the `EventParser` shape into a `SymphonyElixir.Runtime.Behaviour` (or similar) that defines the event tuple contract. Both Codex and ClaudeCode adapters implement it.
2. Build `SymphonyElixir.Runtime.ClaudeCode.AppServer` (mirroring `SymphonyElixir.Codex.AppServer`) for port management. Single-shot per turn with `--continue` for continuity.
3. Wire runtime selection into the `AgentRunner` via the `runtime/*` label on the ticket.
4. Ship a `claude_runtime.settings.json` template with `apiKeyHelper` example. Document the `--bare` requirement.
5. Add `--max-budget-usd` as the cost-cap mechanism for the Claude side. Codex side uses token-count watchdog (separate ticket).

Effort estimate: 400-600 LoC for the adapter, 200-300 LoC for tests, 1-2 days of focused work to land a first cut.

## Open questions raised by the spike

1. ~~Should `--bare` be the default?~~ **Resolved:** `--setting-sources project,local` per smithy-v1 PER-44. OAuth + MCP stay active because they live outside settings. No `apiKeyHelper` plumbing needed.
2. **Should we use `--continue <session_id>` for multi-turn, or `--input-format stream-json` to keep the port alive?** Continue-by-session-id is simpler but each turn pays a small startup cost. Streaming input is more efficient but more complex. I lean continue-by-session-id; the startup cost is negligible vs the model call.
3. **How do tool calls round-trip?** Codex's app-server has a native tool-call protocol. Claude Code's headless mode emits `tool_use` content blocks; the orchestrator needs to execute them and pass results back via `--input-format stream-json`. This is the most complex piece of the adapter and warrants a follow-up spike before the brick lands.
4. **Universal AGENTS.md template.** Per §5a, Symphony should ship a minimal AGENTS.md per repo that both runtimes read. Define the template content as part of v2.1 spec.

## Decision log

- 2026-05-11: Spike complete, GO verdict. Runtime adapter brick is bounded and tractable.
- Next: incorporate findings into v2.1 spec. Draft adapter ticket scope.
