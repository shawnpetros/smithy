# Smithy v2.1 Architecture Spec

**Status:** Draft, 2026-05-11. Replaces v2/history/2026-05-06-v2-fork-spec-original.md.
**Authors:** Shawn Petros, with Claude (Anthropic Opus 4.7, 1M context) as paired engineer.
**Inputs:**

- `v2/history/2026-05-06-v1-pilot-spec.md` (v1 pilot architecture, kept for context)
- `v2/history/2026-05-06-v2-fork-spec-original.md` (the prior v2 fork plan; superseded)
- `v2/history/2026-05-11-claude-code-adapter-spike.md` (Claude Code adapter validation)
- `v2/edge-cases.md` (12 failure modes specified for v1)
- 2026-05-11 brainstorm session (Shawn + Argyle)

---

## Goal

Smithy v2.1 is a thin multi-repo supervisor wrapping a configurable fork of OpenAI Symphony (Elixir). The fork stays close to upstream and grows three orthogonal config axes per agent invocation: `mode`, `runtime`, `persona`. Anvil's adversarial reviewer logic ports inward as `mode: reviewer`; Anvil retires as a separate component.

The opinion layer is mostly absorbed INTO Symphony itself rather than running above it. Smithy's job is to supervise N Symphony instances across N repos, surface an aggregate TUI, expose themed CLI affordances, and handle self-update.

This replaces the prior "orchestrator above Symphony with proto/ comms" pitch from 2026-05-11 morning. That pivot was overengineered for v1.

---

## Layered architecture

```
Smithy wrapper (the daemon supervisor + CLI)
├── Repo registry (~/.smithy/config.toml)
├── launchd/systemd plist generation per registered repo
├── CLI binary
│   ├── smithy status [--web|--json|--snapshot] [--interval 5s]
│   │                              → aggregate TUI, --web opens unified dashboard
│   ├── smithy dashboard [slug]    → no slug: aggregate web; with slug: that repo's LiveView
│   ├── smithy logs <slug>         → tail one repo's daemon log
│   ├── smithy bellows / forge     → themed status aliases
│   ├── smithy daemon {start|stop|restart} [slug]
│   ├── smithy add-repo <slug> <path> [--workflow PATH]
│   └── smithy remove-repo <slug>
├── Heartbeat collation (queries each Symphony's HTTP API)
└── Self-update flow coordination (drain → rebuild → respawn)
        │ supervises
        ▼
Symphony instance (one per registered repo)
├── Polling loop (Linear)
├── Per-issue workspaces (~/code/<repo>-workspaces/<ticket>)
├── State machine (existing + Adversarial Review state slot)
├── Phoenix LiveView dashboard (localhost:<assigned-port>)
├── TUI status board (existing, already shipped, displays in foreground mode)
├── Workpad comment management
├── SQLite run history (alpha-2)
├── Three-axis agent dispatch:
│   - mode    : builder | reviewer | triager
│   - runtime : codex | claude-code
│   - persona : markdown file (priv/personas/<name>.md)
│   - mcp     : whitelist of MCP bundle names
│   - tier    : opus | sonnet | haiku (runtime-specific tier mapping)
        │ spawns
        ▼
Agent subprocess (Codex CLI or Claude Code CLI)
├── One mode, one runtime, one persona per spawn
├── Reads ticket context + persona body via argv/stdin
├── Writes JSONL events to stdout (Symphony parses)
├── On exit: writes RESULT.md (builder) or REVIEW.md (reviewer) or TRIAGE.md (triager)
└── Symphony parses structured handoff, transitions Linear state
```

The carving: Smithy owns multi-repo orchestration and operator CLI. Symphony owns harness work for one repo (polling, workspaces, state machine, dashboard, persistence, agent dispatch). Agent subprocesses own one model turn each. No shared mutable state across layers; boundaries are launchd plus heartbeat files (Smithy ↔ Symphony) and stdio plus on-disk handoff artifacts (Symphony ↔ agent).

---

## Three-axis agent config

The core opinion shift in Symphony. A workflow declares its agents in YAML frontmatter:

```yaml
agents:
  builder:
    mode: builder
    runtime: codex
    persona: builder-default.md
    mcp:
      - linear-read
    tier: medium

  reviewer:
    mode: reviewer
    runtime: claude-code
    persona: reviewer.md
    mcp: []
    tier: sonnet

  triager:                      # optional; spec-quality gate
    mode: triager
    runtime: codex
    persona: triager.md
    mcp:
      - linear-read
    tier: low
```

**Three orthogonal axes:**

- **`mode`** selects state-machine behavior. `builder` opens PR and transitions to Adversarial Review. `reviewer` reads diff + workpad, writes REVIEW.md, transitions to In Review (PASS) or Rework (FAIL). `triager` evaluates ticket quality, transitions to In Progress (PROCEED) or Backlog (FLAG with `needs-spec` label).
- **`runtime`** selects the subprocess adapter. `codex` spawns `codex app-server`. `claude-code` spawns `claude --print --output-format stream-json --setting-sources project,local ...`. Adapters are interchangeable; mode logic doesn't care.
- **`persona`** is a markdown file at `priv/personas/<name>.md` (Symphony-bundled) or `<repo>/.smithy/personas/<name>.md` (repo-local). YAML frontmatter declares `name`, `description`, intended `mode`, intended `runtime`, optional `model_hint`. Body is the prompt template with `{{var}}` placeholders.

**Reviewer-as-list (forward-compatible for v2 panel review):**

```yaml
reviewers:                       # list form supported from day one
  - mode: reviewer
    runtime: claude-code
    persona: reviewer.md
  - mode: reviewer               # v2: panel review activates when N > 1
    runtime: codex
    persona: architect-reviewer.md
```

v1 only honors length-1. Length-N reviewer panels (per [v2-fork-spec §12 speccing-mode](history/2026-05-06-v2-fork-spec-original.md#12-speccing-mode-workflow-research-preview-alpha-3)) light up in v2 without a config migration.

**MCP scoping:** the `mcp:` field whitelists named bundles. Symphony assembles a `--mcp-config <generated>.json` at spawn time and passes `--strict-mcp-config` so user-scope MCP servers don't leak in. Bundles ship in `priv/mcp_bundles/<name>.json` (`linear-read`, `github`, `playwright`, `context7`); repos can override at `<repo>/.smithy/mcp_bundles/<name>.json`.

**Tier mapping:**
- claude-code: `opus` → `claude-opus-4-7`, `sonnet` → `claude-sonnet-4-6`, `haiku` → `claude-haiku-4-5`
- codex: `high` → `model_reasoning_effort=high`, `medium` → `medium`, `low` → `low`

**Defaults match vanilla Symphony if `agents:` block is omitted.**

```yaml
# Implicit default if agents: omitted
agents:
  builder:
    mode: builder
    runtime: codex
    persona: <embedded default body>
    mcp: []
    tier: medium
  reviewer: null    # no Adversarial Review state, drop-in upstream behavior
```

---

## Modes

### `mode: builder`

The existing Symphony worker behavior. Reads the ticket, plans, implements, opens a PR, transitions to Adversarial Review (or directly to Human Review if no reviewer is configured).

- Output artifact: `RESULT.md` at workspace root (optional; Symphony already uses the workpad as primary handoff).
- State transitions: `Todo → In Progress → Adversarial Review` (or `→ Human Review` if no reviewer).
- Owns workpad sections: `### Plan`, `### Acceptance Criteria`, `### Validation`, `### Notes`.

### `mode: reviewer`

Ported from Anvil. Reads the PR diff + workpad, writes `REVIEW.md` with structured findings, never edits code.

**REVIEW.md contract:**

```markdown
---
status: pass | fail
findings:
  - finding: "lens-prefix: description"
    grade: blocker | polish | future
notes: |
  Longer prose context. Optional.
---
```

**Validation rules:**
- `status: fail` requires at least one `blocker` grade. Polish-only or future-only findings keep `status: pass`.
- Unknown grades reject the REVIEW.md as malformed.
- Missing or malformed REVIEW.md results in BLOCKED; ticket stays in Adversarial Review with a workpad note for the operator.

**State transitions:**
- PASS → `Human Review` (or `Done` if `auto-merge` label is set per [v2-fork-spec §5](history/2026-05-06-v2-fork-spec-original.md))
- FAIL → `Rework` with findings appended to workpad under dated `### Adversarial Review` subsection
- BLOCKED → `harness-blocked` label, stays in Adversarial Review, operator triages

**Tool denylist:** reviewer agent receives `--disallowedTools mcp__linear__save_* mcp__linear__create_* mcp__linear__delete_*` (Claude Code) or equivalent (Codex `disabled_tools` config). Linear writes always come from the orchestrator.

**Workspace:** v1 uses warm workspace (the builder's workspace). v2 may switch to cold-clone review (per [v2-fork-spec §4](history/2026-05-06-v2-fork-spec-original.md)).

**Personas ship in `priv/personas/`:**
- `reviewer.md` (general code reviewer; default for `mode: reviewer`)
- `architect-reviewer.md` (spec/design documents, Opus tier)
- `data-model-reviewer.md` (schema audits, Opus)
- `devex-reviewer.md` (operator UX audits, Opus)
- `migration-reviewer.md` (cutover audits, Opus)

### `mode: triager`

The spec-quality gate. Runs front-of-queue on tickets carrying `agent-ready`. Evaluates the four questions from [v2-fork-spec §3](history/2026-05-06-v2-fork-spec-original.md):

1. **Where**: file/module/feature unambiguously identified?
2. **What**: clear delta requested?
3. **Acceptance**: success criterion testable?
4. **Ambiguity**: any punt phrases, missing decisions, multiple plausible implementations?

**Output:** `TRIAGE.md` at workspace root:

```markdown
---
decision: proceed | flag
reasons:
  - "Where: ✓ identifies lib/foo/bar.ex"
  - "What: ✓ adds X behavior"
  - "Acceptance: ✗ no testable criterion"
gap_comment: |
  This ticket cannot be executed autonomously in its current form. Specific gaps:
  - <bullet>
  - <bullet>
  To re-queue: address the gaps above, remove `needs-spec`, add `agent-ready`,
  and move to Ready for Dev.
---
```

**State transitions:**
- PROCEED → `In Progress`, builder dispatches immediately
- FLAG → applies `needs-spec` label, removes `agent-ready`, moves to `Backlog`, posts `gap_comment` to workpad

Triager is a one-turn invocation. Proportionality clause in the persona: trivial tickets (typos, version bumps) PROCEED on title alone.

### Future modes (v2+, defined for forward compatibility, not implemented in v1)

- `mode: mediator` — Opus arbiter after N failed review cycles (PER-41 reference; see [edge-cases.md §1](edge-cases.md#1-buildreview-oscillation))
- `mode: synthesizer` — aggregates panel review findings into SYNTHESIS.md (v2 speccing-mode)
- `mode: planner` — decomposes a master ticket into child issues (v2 master cascade)

---

## Runtimes

### Codex (unchanged from upstream)

Symphony's existing Codex AppServer integration. Spawns `codex app-server` via JSON-RPC over stdio. Multi-turn within a single port. Per-tier config via `-c model_reasoning_effort=<high|medium|low>`.

**Standard flags (per smithy-v1 PER-46):**

```
codex \
  -c mcp_servers.linear.url=<linear-mcp-url> \
  -c mcp_servers.linear.disabled_tools=[...] \
  -c model_reasoning_effort=<tier> \
  exec --ignore-user-config
```

`--ignore-user-config` drops `~/.codex/config.toml`. CODEX_HOME auth persists. Linear MCP server re-added inline.

### Claude Code (new)

Validated via spike on 2026-05-11. Spawns `claude --print --output-format stream-json` per turn. Multi-turn via `--continue <session_id>`.

**Standard flags (per smithy-v1 PER-44):**

```
claude -p \
  --setting-sources project,local \
  --dangerously-skip-permissions \
  --model claude-{opus-4-7|sonnet-4-6|haiku-4-5} \
  --disallowedTools "<space-separated denylist>" \
  --strict-mcp-config \
  --mcp-config <symphony-generated-mcp.json> \
  --output-format stream-json \
  --verbose
```

`--setting-sources project,local` drops user-scope settings (CLAUDE.md, SessionStart hooks). OAuth and keychain auth persist because they live outside settings. `--strict-mcp-config` plus the generated MCP file restricts MCP to the workflow's declared bundles.

**Event parsing:** `Smithy.Runtime.ClaudeCode.EventParser` (already implemented in spike). Pure-function JSONL parser, normalizes to typed Elixir event tuples.

**Argv construction:** `Smithy.Runtime.ClaudeCode.Argv` (already implemented in spike). Builds the flag list with tier/disallowed-tools/session-id/budget/etc. as opts.

**Port management:** TODO. Mirror `Smithy.Codex.AppServer` shape. Single-shot per turn with `--continue` between turns.

---

## State machine

Symphony's existing state machine with the Adversarial Review slot already added in alpha-0:

```
Backlog → Todo → (triager?) → In Progress → (reviewer?) → Adversarial Review
                                                        → Human Review
                                                        → Merging → Done
                                                        ↘ Rework → In Progress (loop)
```

Smithy v2.1 adds:

- **Triager pass before In Progress.** If `agents.triager` is configured, builder doesn't dispatch until triager returns PROCEED. FLAG'd tickets go to `Backlog` with `needs-spec` label.
- **Reviewer in Adversarial Review.** If `agents.reviewer` is configured (or `agents.reviewers` list is non-empty), the builder transitions to `Adversarial Review` on PR open instead of `Human Review`. Reviewer transitions onward based on REVIEW.md.
- **Auto-merge bypass.** Ticket with `auto-merge` label and PASS review skips `Human Review`, goes directly to `Merging` per [v2-fork-spec §5](history/2026-05-06-v2-fork-spec-original.md).
- **Circuit breaker.** After N retries (default 3), `harness-blocked` label applied, ticket moves to `Human Review` with multi-attempt summary in workpad. See [edge-cases.md §1](edge-cases.md#1-buildreview-oscillation).

`Tracker.active_states` in WORKFLOW.md is extended to include `Adversarial Review` and `Rework` by default. `Backlog`, `Human Review`, `Done` etc. remain outside the active set.

---

## Smithy wrapper

The thin supervisor. Two implementation options on the table:

- **Elixir escript** (one binary, ships in the same monorepo, shares the Symphony OTP runtime model). Recommended for v1; faster to iterate, no language context switch.
- **Rust binary** (faster startup, smaller, matches smithy-v1's shape). v2 candidate if performance becomes a concern.

v1 ships Elixir. The CLI surface is small enough that perf isn't the bottleneck.

### Repo registry

`~/.smithy/config.toml`:

```toml
default_runtime = "codex"
default_workflow = "WORKFLOW.md"

[[repos]]
slug = "smithy"
path = "/Users/shawnpetros/projects/smithy"
workflow = "WORKFLOW.md"      # path relative to repo root
port = 4001                   # auto-assigned at add-repo time

[[repos]]
slug = "substrate"
path = "/Users/shawnpetros/projects/substrate"
workflow = "WORKFLOW.md"
port = 4002

[[repos]]
slug = "content-pipeline"
path = "/Users/shawnpetros/projects/content-pipeline"
workflow = "WORKFLOW.md"
port = 4003
```

### launchd plist generation

`smithy add-repo <slug> <path>` writes a plist to `~/Library/LaunchAgents/com.shawnpetros.smithy.<slug>.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.shawnpetros.smithy.smithy</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/symphony</string>
    <string>--logs-root</string>
    <string>~/.smithy/logs/smithy</string>
    <string>--port</string>
    <string>4001</string>
    <string>~/projects/smithy/WORKFLOW.md</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>~/.smithy/logs/smithy/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>~/.smithy/logs/smithy/stderr.log</string>
</dict>
</plist>
```

`KeepAlive.SuccessfulExit=false` plus Symphony's exit code 75 for self-update means the supervisor brings the daemon back automatically after a self-update merge.

systemd unit template ships for Linux. Same shape.

### Aggregate TUI

`smithy status` queries each registered Symphony's HTTP API (`/api/v1/state` or equivalent) and renders an aggregate terminal TUI. Layout draws from Symphony's existing single-repo TUI:

```
╭─ SMITHY STATUS ─────────────────────────────────────────────────────╮
│ Repos: 3 active / 3 registered                                      │
│ Total Agents: 27/100 across repos                                   │
│ Throughput: 1,234,567 tps                                           │
│ Tokens: in 142,000,000 | out 8,300,000 | total 150,300,000          │
│ Generated: 2026-05-12T12:00:00Z                                     │
│ Next refresh: 1s                                                    │
├─ [smithy] Running ──────────────────────────────────────────────────┤
│  ID       STAGE          PID      AGE / TURN   TOKENS     SESSION  EVENT
│  MT-725   Todo           12345    1m 19s / 2   1,442,520  abcd...  command output streaming
├─ Backoff queue ─────────────────────────────────────────────────────┤
│  No queued retries                                                  │
│ ↑/↓ scroll • r refresh • ? help • q quit                            │
╰─────────────────────────────────────────────────────────────────────╯
```

Single source of polling: Smithy's CLI process queries each Symphony's HTTP API every refresh_interval; renders in foreground. Themed aliases (`smithy bellows`, `smithy forge`) show the same interactive view. `smithy status --snapshot` preserves one-shot terminal output for scripts, and `--json` remains one-shot structured output.

### Browser dashboard

`smithy dashboard <slug>` runs `open http://localhost:<port>/` on macOS (`xdg-open` on Linux), pointing at that repo's Symphony LiveView.

`smithy dashboard` (no slug) opens an aggregate web view served by Smithy itself. v1 ships this as a simple HTML page that iframes the per-repo LiveViews in a grid. v2 polish becomes a native unified dashboard.

### Self-update flow

Per [edge-cases.md §3](edge-cases.md#3-self-update-mid-flight). Single-task mode while a `smithy:self-update` ticket holds the queue; drain other workers to safe checkpoints; merge the PR; rebuild (`mix compile`); daemon exits 75; launchd respawns; new daemon hydrates from Linear state and transitions the self-update ticket to Human Review.

If compile fails post-merge: `harness-blocked` label, no respawn, heartbeat dashboard alerts operator. Recovery doc at `docs/operations/self-update-recovery.md`.

---

## Universal AGENTS.md template

Both Codex and Claude Code read project-root `AGENTS.md`. Symphony's `smithy add-repo` (or future `smithy bootstrap`) ships a minimal template to the target repo:

```markdown
# AGENTS.md (Smithy-managed repo)

This repo is operated by Smithy v2.1. Read this file before any work.

## Workpad

Every Linear ticket has a `## Smithy Workpad` comment (Smithy's convention).
All progress notes, plans, validation, review findings, and confusions go in
that single comment. Do not post separate update comments.

Workpad sections:
- `### Plan` (builder owns)
- `### Acceptance Criteria` (builder owns)
- `### Validation` (builder owns)
- `### Notes` (builder owns)
- `### Adversarial Review` (reviewer appends, dated subsections)
- `### Confusions` (any agent may append)

## Handoff artifacts

- Builder mode: write `RESULT.md` at workspace root on exit (optional;
  workpad is primary).
- Reviewer mode: write `REVIEW.md` at workspace root on exit (required).
  Schema: `status: pass|fail`, `findings: [{finding, grade}]`,
  `notes: |`. Grades: blocker | polish | future. `status: fail` requires
  at least one `blocker`.
- Triager mode: write `TRIAGE.md` at workspace root on exit.
  Schema: `decision: proceed|flag`, `reasons: []`, `gap_comment: |`.

## Linear state transitions

Workers DO NOT transition Linear state. The orchestrator owns all state
moves. Workers communicate intent via the handoff artifacts above.

## Tool restrictions

Workers operate with `--disallowedTools` filtering on Linear write tools.
Reviewer mode additionally cannot edit files outside `REVIEW.md`. Builder
mode can edit any file in the workspace.

## Validation

Run repo-specific test commands before declaring work done. The workflow
config declares the validation commands (or they're inferred from
mix.exs / Cargo.toml / package.json conventions).

## Branch and commit conventions

- Branch: `smithy/<ticket-id>-<short-slug>`
- Commit: imperative present tense, body explains why, trailer line
  `Co-Authored-By: Smithy <noreply@smithy.local>` (post-OAuth identity
  this becomes the service account).
```

Each repo can extend AGENTS.md with repo-specific rules (test commands, layering conventions, layering invariants). The Smithy-managed prefix above stays as the universal nudge.

---

## What ships in v1 (the "tomorrow morning" cut)

In dependency order. Each block is a separate commit; the full set ships as `v2.0.0-alpha-1`.

### Block A: Symphony fork core changes

1. **Schema extension.** Add `Agents` embedded Ecto schema (`config/schema.ex`) with `mode`, `runtime`, `persona`, `mcp`, `tier`. Add `reviewers` as a `embeds_many` list for forward compat. Update `Tracker.active_states` default to include `Adversarial Review`, `Rework`.
2. **Workflow.md frontmatter parsing.** `lib/symphony_elixir/workflow.ex` accepts the new `agents:` block. Fallback defaults preserve vanilla Symphony behavior.
3. **Persona module.** `lib/symphony_elixir/personas/persona.ex` + `personas/loader.ex`. Markdown + YAML frontmatter + `{{var}}` rendering. Library at `priv/personas/`.
4. **MCP bundle module.** `lib/symphony_elixir/mcp/bundle.ex`. Loads named bundles, generates `--mcp-config` JSON. Library at `priv/mcp_bundles/`.

### Block B: Runtime adapters

5. **Codex adapter formalization.** Existing `lib/symphony_elixir/codex/app_server.ex` gets a sibling `lib/symphony_elixir/runtime/codex.ex` that's the formal Runtime behaviour implementation. Existing call sites updated to call through the behaviour.
6. **ClaudeCode adapter implementation.** `lib/symphony_elixir/runtime/claude_code/app_server.ex` (port management; mirrors Codex's pattern). EventParser and Argv from the spike are already in place.
7. **Runtime behaviour.** `lib/symphony_elixir/runtime.ex` defines the behaviour: `start_session`, `run_turn`, `stop_session`. Both adapters implement it.

### Block C: Mode dispatch

8. **Mode dispatch refactor.** `Orchestrator.dispatch_issue/3` selects the right agent config (builder, optional triager, optional reviewer) and routes accordingly. `AgentRunner.run/3` becomes mode-aware.
9. **Reviewer mode.** `lib/symphony_elixir/modes/reviewer.ex`. Reads diff, spawns reviewer agent with `mode: reviewer` persona, parses `REVIEW.md`, transitions Linear state. Port of Anvil's `src/review.rs`.
10. **Triager mode.** `lib/symphony_elixir/modes/triager.ex`. Spawns triager agent, parses `TRIAGE.md`, transitions state.
11. **REVIEW.md parser.** `lib/symphony_elixir/handoff/review.ex`. Validates schema, grades, status invariants.
12. **TRIAGE.md parser.** `lib/symphony_elixir/handoff/triage.ex`. Validates schema, decisions.
13. **Workpad section management.** Extract `lib/symphony_elixir/workpad.ex` from existing inline Linear adapter logic. Owns section conventions (Plan, Acceptance Criteria, Adversarial Review, Confusions).

### Block D: Smithy wrapper

14. **Smithy CLI binary.** New monorepo subdirectory `wrapper/` (Elixir escript). Subcommands: `add-repo`, `remove-repo`, `daemon {start|stop|restart}`, `status`, `dashboard`, `logs`, `bellows`, `forge`.
15. **Repo registry.** `wrapper/config.ex` reads/writes `~/.smithy/config.toml`.
16. **launchd/systemd plist generation.** `wrapper/supervisor.ex`. Templates in `wrapper/priv/templates/`.
17. **Aggregate TUI.** `wrapper/tui.ex`. Queries each Symphony's HTTP API on a tick, renders unified ANSI block.
18. **Browser dashboard launcher.** `wrapper/dashboard.ex`. Shells out to `open` / `xdg-open`.
19. **Heartbeat collation.** Symphony exposes `/api/v1/state` already. Smithy reads from each registered repo's port.

### Block E: Self-update + AGENTS.md

20. **`smithy:self-update` label handling.** Per [edge-cases.md §3](edge-cases.md#3-self-update-mid-flight). Single-task mode + drain + rebuild + exit 75. Smithy ↔ Symphony coordination via heartbeat file in `~/.smithy/state/`.
21. **AGENTS.md template.** Ships in `priv/templates/AGENTS.md`. `smithy add-repo` writes it to the target repo if absent.
22. **Workflow template library.** `priv/templates/workflows/cross-model-codex-claude.yaml`, `same-model-cheap.yaml`, etc.

### Block F: Documentation + alpha-1 tag

23. **README rewrite.** Reflect v2.1 architecture, install steps, daemon mode, quickstart.
24. **Migration guide.** `docs/migrating-from-symphony-fork-v0.md` for users on the alpha-0 fork.
25. **Tag `v2.0.0-alpha-1`** on the `main` branch after PR merges.

---

## What's deferred (v2 polish, v3 ambitions)

Tracked here so future-us doesn't re-debate scope.

### v2 polish (weeks 6-12 after v1)

- Unified cross-repo browser dashboard (replaces the iframe grid)
- SQLite run history per Symphony instance (Phases 5 of [original v2 spec](history/2026-05-06-v2-fork-spec-original.md))
- Streaming worker stdout to dashboard via Phoenix PubSub
- Cost rollups: per-run, per-day, per-tenant, per-runtime
- Mediator mode (PER-41) after N failed review cycles
- BlockedBy dependency gating (PER-42 port from smithy-v1)
- Per-role model tier overrides (PER-36 port from smithy-v1)
- GitHub App identity (commits as service account, not operator)
- Linear OAuth identity (Phase 7 of [original v2 spec](history/2026-05-06-v2-fork-spec-original.md))

### v3 ambitions

- AI-summarized run logs ("complexity analysis" per Symphony blog)
- PR walkthrough video generation (per Symphony blog)
- Reviewer panel: length-N reviewer list, synthesizer aggregates findings (speccing-mode per [original v2 spec §12](history/2026-05-06-v2-fork-spec-original.md#12-speccing-mode-workflow-research-preview-alpha-3))
- Multi-tracker support (GitHub Issues, Jira) inspired by Contrabass
- Phased pipelines (plan → execute → verify) inspired by Contrabass
- Completion ETA estimation
- Hosted-Smithy as a managed SaaS

---

## Edge cases reference

See `v2/edge-cases.md` for full enumeration. 12 failure modes spec'd with proposed behavior:

1. Build/review oscillation (mediator escalation, findings dedup, max-retry circuit breaker)
2. Test flakes during reviewer validation
3. Self-update mid-flight
4. Cross-repo single ticket (out of scope for v1)
5. PR feedback during Human Review
6. Token cost runaway (`--max-budget-usd` cap, per-turn watchdog)
7. Network failures (retry-with-backoff, Linear-as-truth)
8. Workspace corruption
9. Reviewer can't decide (graded findings contract is the discipline)
10. Concurrent worker conflicts
11. max_turns exhausted without finishing
12. Linear OAuth token rotation (v2 scope)

Hard requirements (ship with v1): items 1, 3, 4, 5, 6, 7, 9, 11.

---

## Open questions

1. **Smithy wrapper in Elixir or Rust?** v1 ships Elixir (in-monorepo escript). Revisit if perf is a problem.
2. **Aggregate dashboard tech.** v1 ships iframe grid; v2 builds native unified dashboard. What framework? Phoenix LiveView (continuity, easy) or Next.js (matches your other tooling). Defer to v2.
3. **Codex Claude Code parity for `--max-budget-usd`-style cost cap.** Codex side needs per-turn token-count watchdog since no built-in cap exists. Implement in v1 or defer? Lean defer; document the asymmetry.
4. **Multi-turn for Claude Code: `--continue <session_id>` per turn, or streaming-input port?** Lean `--continue` per turn. Each turn is one spawn. Simpler.

---

## What this is NOT

- NOT a re-implementation of Symphony. v2.1 is a fork-plus-opinions, with the opinion layer mostly INSIDE the Symphony fork rather than above it.
- NOT a daemon orchestrator. Smithy is a thin CLI wrapper plus launchd plists. The daemons ARE the Symphony instances.
- NOT a SaaS. v1 is local-install, single-operator, multi-repo.
- NOT a cross-repo task coordinator. Each ticket maps to one repo. Cross-repo workflows are v3.
- NOT a re-implementation of Anvil. Anvil's logic ports inward; Anvil retires as a separate component for Smithy users (it can keep existing for vanilla Symphony users).
