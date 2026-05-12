<p align="center">
  <img src="v2/assets/hero.png" alt="Smithy - agent-native workflow harness" width="900" />
</p>

# Smithy

> A workshop for forging coding-agent work into shipped code.

Smithy is an opinionated agent-native workflow harness, built as a fork of [OpenAI Symphony](https://github.com/openai/symphony) (Elixir, Apache-2.0). It polls Linear for issues, hands them to coding agents (Codex today, Claude Code in alpha-1), runs an adversarial cross-model review pass before any PR reaches a human, and writes back to Linear in a single per-ticket comment thread.

The harness itself is dumb. Intelligence lives in the agents that work on each ticket. Smithy is the workshop. The agents are the smiths. The tickets are the work.

## Status

**Current release: `v2.0.0-alpha-1-preview`.** The v2.1 architecture (rewritten 2026-05-11) is mostly built; final orchestrator wiring is the last brick. See [`v2/SPEC.md`](v2/SPEC.md) for the polished design and [`v2/edge-cases.md`](v2/edge-cases.md) for the failure-mode catalog.

What's in the preview:

- **Three-axis agent config** (mode, runtime, persona) plus per-agent MCP scoping and tier. Workflows declare an `agents:` block with `builder`, `reviewers` (list, length-1 in v1, length-N reviewer panels reserved for v2), and optional `triager`.
- **Two runtimes:** Codex (existing) and Claude Code (new). Cross-model adversarial review just works: configure builder on one runtime and reviewer on another.
- **Three modes:** `builder` (existing Symphony worker), `reviewer` (ports Anvil's adversarial-review logic inward; Anvil retires as a separate component for Smithy users), `triager` (front-of-queue spec-quality gate).
- **Smithy CLI wrapper** (`wrapper/` subdirectory): multi-repo supervisor with `smithy status` aggregate TUI, `smithy dashboard` browser launcher, `smithy bellows`/`forge` themed aliases, `smithy logs`, `smithy daemon`, `smithy add-repo`/`remove-repo`. launchd plists generated per registered repo.
- **Structured handoff parsers** for REVIEW.md and TRIAGE.md with graded findings (blocker/polish/future) and decision (proceed/flag).
- **Persona library** at `priv/personas/` with markdown templates Anvil-style. Repo-local overrides supported.
- **MCP bundle library** at `priv/mcp_bundles/` with linear-read, github, playwright bundles. Workers spawn with `--strict-mcp-config` so user-scope MCP servers don't leak.
- **Universal AGENTS.md template** at `elixir/priv/templates/AGENTS.md`. Both Codex and Claude Code read it; one source of truth for repo conventions.

What's NOT yet wired (lands in `v2.0.0-alpha-1` proper):

- Orchestrator/AgentRunner refactor to actually route tickets through mode dispatch based on state. Today the new modes are usable as library calls but not invoked by the polling loop.
- Self-update flow (`smithy:self-update` label + drain-rebuild-respawn protocol).
- Linux systemd unit template (macOS launchd ships in preview; Linux is a follow-up).

The Rust v1 prototype lives at [`shawnpetros/smithy-v1`](https://github.com/shawnpetros/smithy-v1) and is archive material. v2.1 ports the concepts to the Symphony Elixir fork.

## What v2 does (target shape)

```
Ready for Dev
   │
   ▼
spec quality gate ──FLAG──▶ Backlog (needs-spec)
   │ PROCEED
   ▼
runtime selection by label  (codex / claude-code / default)
   │
   ▼
In Progress  ──▶  worker forges code, opens PR
   │
   ▼
Adversarial Review  ──▶  cross-model reviewer reads the diff
   │
   ├─ FAIL ──▶ back to Todo with findings appended to workpad
   ├─ BLOCKED ──▶ harness-blocked label, into In Review
   └─ PASS ──▶  In Review (or auto-merge if label set) ──▶ Done
```

## The opinion layer

| Capability | What it does | Status |
|---|---|---|
| **Label-gated ticket pickup** | Only act on issues carrying configured labels. Lets one team mix harness work with human-only work. | alpha-0 ✅ |
| **`Adversarial Review` state slot** | New state between `In Progress` and `Human Review`. Reviewer agent (external in alpha-0, in-process in alpha-1) polls and writes a verdict. | alpha-0 ✅ (slot only; reviewer alpha-1) |
| **Cross-model review** | Codex builds, Claude reviews; Claude builds, Codex reviews. Reviewer runs in a fresh session with no visibility into the build's reasoning. | alpha-1 |
| **Dual runtimes** | Codex AND Claude Code, selected per ticket via label. | alpha-1 |
| **Spec quality gate** | Front-of-queue triage drops underspec'd tickets out of the queue with a structured comment listing what's missing. | alpha-2 |
| **Workpad single-thread pattern** | One persistent Linear comment per ticket. All progress, plans, review verdicts append to it. Reads like a story, not a stream of notifications. | inherited from Symphony, formalized in v2 |
| **Linear OAuth identity** | Smithy's commits, comments, and state moves audit-trail to a service account, not the operator's personal API key. | alpha-3 |
| **Label-gated autonomous merge** | Tickets carrying `auto-merge` skip the human gate and merge after review passes. Opt-in per ticket. | alpha-3 |
| **SQLite history dashboard** | Per-run model-summarized logs. Cost rollups (per-day, per-tenant, per-runtime). | alpha-4 |
| **Max-retry circuit breaker** | After N attempts, applies `harness-blocked`, transitions to `In Review`, posts a multi-attempt failure summary. | alpha-4 |
| **Bootstrap PR pattern** | `smithy bootstrap <repo>` clones a target repo, generates `AGENTS.md` and `.codex/skills/` via a fresh agent session, opens a PR. | alpha-5 |

## Why fork

OpenAI's Symphony is genuinely good. Phoenix LiveView dashboard, OTP supervision, per-issue workspaces, structured logging, the Codex app-server runtime. Reproducing that surface in another language would burn weeks before a single opinion gets layered on top. The fork inherits the runtime; Smithy's value is the opinions.

Apache-2.0 lets the fork redistribute and credit upstream. Smithy tracks Symphony main with discipline. Upstream improvements pull through; Smithy's opinions live in additive files and clearly-marked patches.

## Install (alpha-0)

Same prerequisites as Symphony: Erlang/Elixir via mise, Codex CLI, a Linear API token. Then:

```bash
git clone git@github.com:shawnpetros/smithy.git
cd smithy/elixir
mise trust && mise exec -- mix deps.get
```

Copy `examples/chatbot-demo-workflow.md` to your project root as `WORKFLOW.md` (or write your own; that file is documented as a template). Run:

```bash
mise exec -- ./bin/symphony /path/to/your/WORKFLOW.md
```

(The binary name is still `symphony` in alpha-0; rename to `smithy` lands in alpha-1.)

For the `Adversarial Review` reviewer, run [Anvil](https://github.com/shawnpetros/anvil) as a sibling process pointed at the same Linear team and project. Anvil writes its verdict back to the same `## Codex Workpad` comment Smithy's worker is already using.

## The naming family

- **[Anvil](https://github.com/shawnpetros/anvil)** is the standalone Rust adversarial-review daemon. Use it with vanilla Symphony if you don't want the rest of Smithy's opinion layer. Anvil's reviewer logic folds into Smithy in alpha-1.
- **[Whetstone](https://github.com/shawnpetros/whetstone)** is a Rust executor for wave-protocol agent runs. Different shape, same family. Tickets aren't its native unit; "waves" are.
- **[Salazar](https://github.com/shawnpetros/salazar)** is an autonomous code-from-spec orchestrator on the Claude Agent SDK. Planner, generator, evaluator loop with hard validator gates.
- **[smithy-v1](https://github.com/shawnpetros/smithy-v1)** is the original Rust prototype, archived. v2 (this repo) is the path forward.

Forge metaphor for free: Smithy is the workshop, Anvil is the tool, Whetstone sharpens, Elixir is the language and the alchemical brew.

## Credits

Built on [OpenAI Symphony](https://github.com/openai/symphony). Credit where it's due: the runtime polish, the Phoenix LiveView dashboard, the OTP supervision, the Codex app-server integration, all upstream. Smithy adds the opinion layer.

## License

Apache-2.0, matching Symphony upstream. The upstream `LICENSE` and `NOTICE` files in this repo carry attribution.
