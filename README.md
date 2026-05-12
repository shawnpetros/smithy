<p align="center">
  <img src="v2/assets/hero.png" alt="Smithy - agent-native workflow harness" width="900" />
</p>

# Smithy

> A workshop for forging coding-agent work into shipped code.

Smithy is a thin multi-repo conductor that supervises [Symphony](https://github.com/openai/symphony) instances. You give it repos; it manages the daemons. Each daemon is a per-repo Symphony fork that polls Linear, dispatches coding agents, runs an adversarial cross-model review pass, and writes back to Linear in a single per-ticket comment thread.

Two binaries. Two responsibilities.

## Architecture

```
wrapper/bin/smithy  (the conductor)
├── Repo registry   ~/.smithy/config.toml
├── launchd/systemd plist generation per registered repo
├── CLI surface
│   ├── smithy acknowledge                      hold-harmless gate
│   ├── smithy add-repo <slug> <path>           register repo, generate plist
│   ├── smithy remove-repo <slug>
│   ├── smithy daemon {start|stop|restart} [slug]
│   ├── smithy status                           aggregate TUI (aliases: bellows, forge)
│   ├── smithy dashboard [slug]                 LiveView browser launcher
│   └── smithy logs <slug>                      tail daemon log
├── Heartbeat collation  (queries each Symphony HTTP API)
└── Self-update coordination  (drain -> rebuild -> respawn)
        |
        | supervises (via launchd/systemd)
        v
elixir/bin/symphony  (Symphony fork, one per registered repo)
├── Polling loop  (Linear, every 30s)
├── Per-issue workspaces  (~/.smithy/workspaces/<slug>/<ticket>)
├── State machine  (Todo -> In Progress -> Adversarial Review -> Human Review -> Done)
├── Phoenix LiveView dashboard  (localhost:<port>)
├── Workpad comment management  (single Linear comment per ticket)
└── Three-axis agent dispatch
    mode:    builder | reviewer | triager
    runtime: codex   | claude_code
    persona: priv/personas/<name>.md
    mcp:     named bundle whitelist
    tier:    reasoning effort / model tier
        |
        | spawns
        v
Agent subprocess  (Codex CLI or Claude Code CLI)
```

Smithy owns multi-repo orchestration and operator CLI. Symphony owns the per-repo harness: polling, workspaces, state machine, dashboard, agent dispatch. Each layer talks to the next through a narrow, explicit boundary (launchd + heartbeat files between conductor and daemon; stdio + on-disk handoff artifacts between daemon and agent).

## What's a fork and what isn't

`elixir/` is a fork of [openai/symphony](https://github.com/openai/symphony). It stays Symphony with upstream lineage intact. The opinion layer lives here: three-axis agent config, reviewer and triager modes, persona and MCP bundle libraries, the `Adversarial Review` state slot, structured handoff parsers. The binary it builds is `elixir/bin/symphony`.

`wrapper/` is not a fork. It's Smithy-native code that has no equivalent upstream. It builds `wrapper/bin/smithy`.

## Why this shape

Symphony already does the hard part: OTP supervision, per-issue workspaces, Phoenix LiveView dashboard, Codex app-server integration. Forking it to add opinions is cheaper than rebuilding from scratch. Keeping the fork as a separate binary means upstream improvements pull through cleanly and Symphony users who don't want Smithy's conductor can still run Symphony directly (with or without Anvil as a sibling).

The conductor wraps N repos because a real project has more than one. Cross-model review (Codex builder, Claude reviewer; or reversed) is wired at the workflow level, not the operator level.

Full design rationale and failure-mode catalog: [`v2/SPEC.md`](v2/SPEC.md) and [`v2/edge-cases.md`](v2/edge-cases.md).

## Status

**Current release: `v2.0.0-alpha-1`.**

All blocks in the [v2.0.0-alpha-1 build plan](#whats-in-v200-alpha-1) are shipped and green. This is the maiden-voyage cut: the harness dispatches and reviews its own tickets.

## Install

Prerequisites: Erlang/Elixir via [mise](https://mise.jdx.dev/), Codex CLI on `PATH`, `claude` CLI on `PATH`, and a Linear API token.

```bash
git clone git@github.com:shawnpetros/smithy.git
cd smithy

# Build both escripts
cd wrapper && mise exec -- mix escript.build && cd ..
cd elixir  && mise exec -- mix escript.build && cd ..
```

After building, link the binaries wherever you want them on `PATH`:

```bash
ln -sf "$PWD/wrapper/bin/smithy" ~/.local/bin/smithy
ln -sf "$PWD/elixir/bin/symphony" ~/.local/bin/symphony
```

## First run

```bash
# 1. Acknowledge the hold-harmless gate (once per machine).
./wrapper/bin/smithy acknowledge

# 2. Register a repo and generate its launchd plist.
./wrapper/bin/smithy add-repo <slug> <path/to/repo> --workflow <path/to/WORKFLOW.md>

# 3. Start the per-repo daemon.
./wrapper/bin/smithy daemon start <slug>

# 4. Watch it.
./wrapper/bin/smithy status      # aggregate TUI; aliases: bellows, forge
./wrapper/bin/smithy dashboard <slug>   # opens the Symphony LiveView in a browser
./wrapper/bin/smithy logs <slug>        # tail the daemon log
```

After `add-repo`, a launchd plist lands at `~/Library/LaunchAgents/com.shawnpetros.smithy.<slug>.plist`. `daemon start` loads it; `daemon stop` unloads it. On restart after a self-update, launchd respawns automatically.

The first time you `daemon start`, if `~/.smithy/config.toml` has no `acknowledged_at`, the daemon prompts for acknowledgement before doing anything. Running `smithy acknowledge` ahead of time skips that prompt.

## WORKFLOW.md

Symphony reads a WORKFLOW.md at the repo root (or the path you passed to `add-repo`). The `agents:` frontmatter block configures the three-axis dispatch:

```yaml
agents:
  builder:
    mode: builder
    runtime: codex
    persona: builder-default.md
    mcp:
      - linear-read
    tier: medium

  reviewers:
    - mode: reviewer
      runtime: claude_code
      persona: reviewer.md
      mcp: []
      tier: sonnet

  triager:              # optional; spec-quality gate before builder runs
    mode: triager
    runtime: codex
    persona: triager.md
    mcp:
      - linear-read
    tier: low
```

Omit the `agents:` block entirely to get vanilla Symphony defaults (Codex builder, no reviewer, no triager).

A working example workflow for a Vite/React repo: [`examples/chatbot-demo-workflow.md`](examples/chatbot-demo-workflow.md).

## Three modes

**`builder`** - the existing Symphony worker. Reads the ticket, plans, implements, opens a PR, transitions to `Adversarial Review` (or `Human Review` if no reviewer is configured).

**`reviewer`** - ported from Anvil. Reads the PR diff and workpad; writes `REVIEW.md` at workspace root with structured findings. Never edits code. Schema:

```yaml
status: pass | fail
findings:
  - finding: "description"
    grade: blocker | polish | future
notes: |
  Optional prose context.
```

`status: fail` requires at least one `blocker` grade. Pass with polish-only findings moves to `Human Review`. Fail with a blocker moves to `Rework` with findings appended to the workpad.

**`triager`** - optional spec-quality gate. Runs before the builder on `agent-ready` tickets. Evaluates whether the ticket is actionable (unambiguous target, clear delta, testable acceptance criterion). FLAG'd tickets move to `Backlog` with a `needs-spec` label and a structured gap comment.

## Two runtimes

**`codex`** (default) - spawns `codex app-server` via JSON-RPC over stdio. `tier` maps to `model_reasoning_effort`: `high`, `medium`, `low`. Standard invocation adds `--ignore-user-config` to drop `~/.codex/config.toml`.

**`claude_code`** - spawns `claude --print --output-format stream-json` per turn, continued via `--continue <session_id>`. `tier` maps to model: `opus` -> `claude-opus-4-7`, `sonnet` -> `claude-sonnet-4-6`, `haiku` -> `claude-haiku-4-5`. Both runtimes use `--setting-sources project,local` and `--strict-mcp-config` with a per-spawn generated MCP config.

Cross-model review (builder on one runtime, reviewer on another) is the default configuration for the Smithy workflow. The adapters are interchangeable; mode logic doesn't care which runtime it's on.

## Anvil

[Anvil](https://github.com/shawnpetros/anvil) was the standalone Rust adversarial-review daemon. Its reviewer logic is now `mode: reviewer` inside the Symphony fork. Smithy users don't need Anvil as a separate process; the reviewer runs in-process as a Symphony agent.

Vanilla Symphony users (no Smithy conductor) can still run Anvil as a sibling. The contracts are compatible.

## What's in v2.0.0-alpha-1

In dependency order:

**Block A (Symphony fork core):** Three-axis `AgentConfig` schema (`mode`, `runtime`, `persona`, `mcp`, `tier`); `reviewers` list for forward-compatible panel review; `Tracker.active_states` default extended to include `Adversarial Review` and `Rework`; WORKFLOW.md frontmatter parsing for the `agents:` block.

**Block B (Runtime adapters):** Codex adapter formalized as a Runtime behaviour implementation; Claude Code adapter (`Smithy.Runtime.ClaudeCode`) with event parser and argv builder; `Smithy.Runtime` behaviour (`start_session/2`, `run_turn/4`, `stop_session/1`).

**Block C (Mode dispatch):** `Orchestrator.dispatch_issue/3` routes by mode; `AgentRunner` is mode-aware; `mode: reviewer` reads diff, spawns reviewer, parses REVIEW.md, transitions state; `mode: triager` spawns triager, parses TRIAGE.md; REVIEW.md and TRIAGE.md parsers with schema validation; `Smithy.Workpad` extracts workpad section management.

**Block D (Smithy wrapper):** `wrapper/bin/smithy` escript with all CLI subcommands; repo registry at `~/.smithy/config.toml`; launchd plist generation per registered repo (`wrapper/priv/templates/`); aggregate TUI querying each Symphony HTTP API; browser dashboard launcher.

**Block E (AGENTS.md + templates):** Universal `AGENTS.md` template at `elixir/priv/templates/AGENTS.md`; workflow template library at `elixir/priv/templates/workflows/`; persona library at `elixir/priv/personas/`; MCP bundle library at `elixir/priv/mcp_bundles/` (linear-read, github, playwright, context7).

## Roadmap

Near-term (v2 polish): unified cross-repo browser dashboard, SQLite run history, streaming worker stdout to dashboard, cost rollups, mediator mode after N failed review cycles, BlockedBy dependency gating, GitHub App identity.

Further out (v3): reviewer panels (length-N list, synthesizer aggregates findings), multi-tracker support, phased pipelines, completion ETA estimation.

See [`v2/SPEC.md`](v2/SPEC.md) for the full v2 polish and v3 ambitions sections.

## The naming family

- **[Anvil](https://github.com/shawnpetros/anvil)** is the standalone Rust adversarial-review daemon. Use it with vanilla Symphony if you don't want the Smithy conductor. Anvil's logic is ported into the Symphony fork as `mode: reviewer`; Smithy users don't need the separate process.
- **[Whetstone](https://github.com/shawnpetros/whetstone)** is a Rust executor for wave-protocol agent runs. Different shape, same family. Tickets aren't its native unit; waves are.
- **[Salazar](https://github.com/shawnpetros/salazar)** is an autonomous code-from-spec orchestrator on the Claude Agent SDK. Planner, generator, evaluator loop with hard validator gates.
- **[smithy-v1](https://github.com/shawnpetros/smithy-v1)** is the original Rust prototype, archived. v2 (this repo) is the path forward.

Forge metaphor for free: Smithy is the workshop, Anvil is the tool, Whetstone sharpens, Elixir is the language and the alchemical brew.

## Credits

Built on [OpenAI Symphony](https://github.com/openai/symphony). Credit where it's due: the runtime polish, the Phoenix LiveView dashboard, the OTP supervision, the Codex app-server integration - all upstream. Smithy adds the conductor wrapper and the opinion layer inside the fork.

## License

Apache-2.0, matching Symphony upstream. The upstream `LICENSE` and `NOTICE` files in this repo carry attribution.
