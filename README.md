<p align="center">
  <img src="v2/assets/hero.png" alt="Smithy - agent-native workflow harness" width="900" />
</p>

# Smithy

> A workshop for forging coding-agent work into shipped code.

Smithy is a **conductor**: a thin Elixir escript that supervises N instances of a per-repo Symphony daemon. Two binaries, two responsibilities, clean separation.

- `wrapper/bin/smithy` - the conductor. CLI surface, repo registry, launchd plist generation, aggregate TUI, hold-harmless gate, multi-repo supervision. No upstream equivalent; Smithy-native.
- `elixir/bin/symphony` - the per-repo daemon. A fork of [OpenAI Symphony](https://github.com/openai/symphony) (Elixir, Apache-2.0). Polling loop, per-issue workspaces, state machine, Phoenix LiveView dashboard, agent dispatch. Symphony stays Symphony; the fork preserves upstream lineage and adds Smithy's opinion layer.

The conductor doesn't do harness work. The Symphony fork does. Smithy's conductor job is to start, stop, and observe N forks across N repos from one place.

## Status

**Current release: `v2.0.0-alpha-1`.**

v2.1 architecture is built and wired. See [`v2/SPEC.md`](v2/SPEC.md) for the canonical design and [`v2/edge-cases.md`](v2/edge-cases.md) for the failure-mode catalog.

## Architecture

```
wrapper/bin/smithy  (the conductor)
├── Repo registry (~/.smithy/config.toml)
├── launchd/systemd plist generation per registered repo
├── CLI
│   ├── smithy status [--web]         aggregate TUI; --web opens unified dashboard
│   ├── smithy dashboard [slug]       no slug: aggregate web; slug: that repo's LiveView
│   ├── smithy logs <slug>            tail one repo's daemon log
│   ├── smithy bellows / forge        themed status aliases
│   ├── smithy daemon {start|stop|restart} [slug]
│   ├── smithy add-repo <slug> <path> [--workflow PATH]
│   └── smithy remove-repo <slug>
├── Heartbeat collation (polls each Symphony's /api/v1/state)
└── Self-update coordination (drain → rebuild → respawn via exit 75)
        │ supervises
        ▼
elixir/bin/symphony  (the Symphony fork, one instance per registered repo)
├── Polling loop (Linear, configurable interval)
├── Per-issue workspaces (~/.smithy/workspaces/<repo>/<ticket>)
├── State machine (Linear states + Adversarial Review slot)
├── Phoenix LiveView dashboard (localhost:<assigned-port>)
├── Workpad single-thread management (one persistent Linear comment per ticket)
├── Three-axis agent dispatch:
│   ├── mode    : builder | reviewer | triager
│   ├── runtime : codex | claude-code
│   ├── persona : markdown file (priv/personas/<name>.md or repo-local)
│   ├── mcp     : whitelist of named MCP bundles
│   └── tier    : opus | sonnet | haiku (runtime-specific mapping)
        │ spawns
        ▼
Agent subprocess (Codex CLI or Claude Code CLI)
├── One mode, one runtime, one persona per invocation
├── Reads ticket context + persona via argv/stdin
├── Writes JSONL events to stdout; Symphony parses
└── On exit: RESULT.md (builder) | REVIEW.md (reviewer) | TRIAGE.md (triager)
```

The boundary contract: Smithy owns multi-repo orchestration and operator CLI. Symphony owns harness work for one repo. Agent subprocesses own one model turn each. No shared mutable state across layers; boundaries are launchd plus heartbeat files (conductor to Symphony) and stdio plus on-disk handoff artifacts (Symphony to agents).

## The fork vs. the conductor

`elixir/` **is** a fork of [`openai/symphony`](https://github.com/openai/symphony). It stays Symphony. Upstream lineage is preserved; improvements pull through. Smithy's opinions (modes, runtimes, personas, MCP scoping, Adversarial Review state slot) live inside the fork as additive files and clearly-marked patches.

`wrapper/` **is not** a fork. It's the Smithy-native conductor - nothing upstream to fork from. It exists only here.

## Why this shape

OpenAI's Symphony is genuinely good: Phoenix LiveView dashboard, OTP supervision, per-issue workspaces, structured logging, Codex app-server integration. Rebuilding that surface in another language burns weeks before the first opinion lands. Fork it, keep it close to upstream, and add opinions on top.

The conductor shape exists because real work spans repos. One developer, five active projects, five Symphony instances - you want one `smithy status` view and one `smithy daemon start` command, not five separate processes you manage by hand.

For depth: [`v2/SPEC.md`](v2/SPEC.md).

## Install

Prerequisites: Erlang/Elixir via mise, Codex CLI, Claude Code CLI, and a Linear API token.

```bash
git clone git@github.com:shawnpetros/smithy.git
cd smithy

# Build the conductor
cd wrapper && mise exec -- mix escript.build && cd ..

# Build the Symphony fork
cd elixir && mise exec -- mix escript.build && cd ..
```

Then put both binaries on PATH, or use the Makefile:

```bash
make install          # links wrapper/bin/smithy and elixir/bin/symphony into ~/.local/bin
make install PREFIX=/usr/local
```

For local iteration: `make rebuild` rebuilds both escripts without fetching deps; `make test` runs installer and project tests; `make clean` removes build artifacts; `make uninstall` removes the installed links.

## First run

```bash
# Acknowledge the hold-harmless gate (required before first daemon start)
./wrapper/bin/smithy acknowledge

# Register a repo
./wrapper/bin/smithy add-repo <slug> <path/to/repo> --workflow <path/to/WORKFLOW.md>
# example:
./wrapper/bin/smithy add-repo myapp ~/projects/myapp --workflow ~/projects/myapp/WORKFLOW.md

# Start the daemon for that repo
./wrapper/bin/smithy daemon start myapp
```

The daemon boots Symphony for `myapp`, writes a launchd plist (`~/Library/LaunchAgents/com.shawnpetros.smithy.myapp.plist`) so it survives reboots, and begins polling Linear for tickets carrying the labels in `WORKFLOW.md`.

## Operate

```bash
# Aggregate status across all registered repos
smithy status
smithy bellows    # themed alias
smithy forge      # themed alias

# Per-repo
smithy dashboard myapp   # opens Symphony's LiveView in the browser
smithy logs myapp        # tail the daemon log
smithy daemon stop myapp
smithy daemon restart myapp
```

## Three modes

Configured per-workflow via the `agents:` block in `WORKFLOW.md`:

| Mode | What it does |
|---|---|
| `builder` | Picks up a ticket, plans, implements, opens PR, transitions to Adversarial Review |
| `reviewer` | Reads PR diff + workpad, writes `REVIEW.md`, transitions to Human Review (pass) or Rework (fail) |
| `triager` | Evaluates ticket spec quality front-of-queue; flags underspec'd tickets to Backlog with a gap comment before the builder fires |

Example `agents:` block:

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
      runtime: claude-code
      persona: reviewer.md
      tier: sonnet
      mcp: []

  triager:
    mode: triager
    runtime: codex
    persona: triager.md
    tier: low
```

Omit the `agents:` block entirely and Symphony falls back to vanilla upstream behavior (codex builder, no reviewer, no triager).

## Two runtimes

| Runtime | How it spawns |
|---|---|
| `codex` | `codex app-server` via JSON-RPC over stdio, `--ignore-user-config` |
| `claude-code` | `claude --print --output-format stream-json --setting-sources project,local` |

Cross-model review is the default recommended config: configure builder on one runtime, reviewer on another. Neither agent sees the other's reasoning session.

Codex per-tier reasoning effort: `high`, `medium`, `low`. Claude Code per-tier model: `opus` maps to `claude-opus-4-7`, `sonnet` to `claude-sonnet-4-6`, `haiku` to `claude-haiku-4-5`.

Both runtimes receive `--strict-mcp-config` with a generated MCP config file that whitelists only the bundles declared in the workflow's `mcp:` field. User-scope MCP servers don't leak in.

## Anvil

[Anvil](https://github.com/shawnpetros/anvil)'s adversarial-review logic is ported into Symphony as `mode: reviewer`. The standalone Anvil daemon is no longer needed for Smithy users. Vanilla Symphony users can still run Anvil as a sibling daemon; it remains compatible. For Smithy users, set up a `reviewers:` block in `WORKFLOW.md` and Symphony handles the cross-model review in-process.

## What ships in v2.0.0-alpha-1

- Three-axis agent config (`mode`, `runtime`, `persona`) plus per-agent MCP scoping and tier
- Two runtimes: Codex and Claude Code; cross-model adversarial review works out of the box
- Three modes: `builder`, `reviewer`, `triager`; Adversarial Review state slot in the state machine
- Smithy conductor CLI (`wrapper/`): `status`, `dashboard`, `logs`, `daemon`, `add-repo`, `remove-repo`, `bellows`, `forge`, `acknowledge`
- launchd plist generation per registered repo (macOS; Linux systemd template ships in v2 polish)
- Structured handoff parsers for `REVIEW.md` and `TRIAGE.md` with graded findings and decision fields
- Persona library at `priv/personas/` with markdown templates; repo-local overrides supported
- MCP bundle library at `priv/mcp_bundles/`; workers spawn with `--strict-mcp-config`
- Universal `AGENTS.md` template at `elixir/priv/templates/AGENTS.md`

## Roadmap

**v2 polish** (weeks 6-12 after v1): unified cross-repo browser dashboard, SQLite run history, streaming worker stdout to dashboard, cost rollups, mediator mode after N failed review cycles, BlockedBy dependency gating, GitHub App identity, Linux systemd unit template.

**v3 ambitions**: AI-summarized run logs, reviewer panels (length-N reviewers + synthesizer), multi-tracker support (GitHub Issues, Jira), phased pipelines, hosted-Smithy as SaaS.

Full scope: [`v2/SPEC.md` - What's deferred](v2/SPEC.md#whats-deferred-v2-polish-v3-ambitions).

## The naming family

- **[Anvil](https://github.com/shawnpetros/anvil)** is the standalone Rust adversarial-review daemon. Use it with vanilla Symphony when you don't want Smithy's full opinion layer. Anvil's logic is ported inward for Smithy users.
- **[Whetstone](https://github.com/shawnpetros/whetstone)** is a Rust executor for wave-protocol agent runs. Different shape, same family. Tickets aren't its native unit; "waves" are.
- **[Salazar](https://github.com/shawnpetros/salazar)** is an autonomous code-from-spec orchestrator on the Claude Agent SDK. Planner, generator, evaluator loop with hard validator gates.
- **[smithy-v1](https://github.com/shawnpetros/smithy-v1)** is the original Rust prototype, archived. v2 (this repo) is the path forward.

Forge metaphor for free: Smithy is the workshop, Anvil is the tool, Whetstone sharpens, Elixir is the language and the alchemical brew.

## Credits

Built on [OpenAI Symphony](https://github.com/openai/symphony). The runtime polish, the Phoenix LiveView dashboard, the OTP supervision, the Codex app-server integration - all upstream. Smithy adds the opinion layer and the conductor.

## License

Apache-2.0, matching Symphony upstream. The upstream `LICENSE` and `NOTICE` files in this repo carry attribution.
