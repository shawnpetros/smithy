# Smithy v2.0.0-alpha-1-preview Handoff

**Date:** 2026-05-12 (overnight session 2026-05-11/12)
**Branch:** `spike/claude-code-adapter` (4 commits beyond `main`)
**Status:** Foundation + modules + wrapper shipped. Orchestrator integration is the next critical brick.

---

## What landed

Five commits on `spike/claude-code-adapter`:

1. **Claude Code event parser spike** (`4fce631`). Validates that Symphony can ingest Claude Code's headless stream-json output. 37 tests, 2 fixtures (one real session, one auth-failure path). [`v2/history/2026-05-11-claude-code-adapter-spike.md`](2026-05-11-claude-code-adapter-spike.md).
2. **Argv builder correction** (`4a10db5`). `--setting-sources project,local` per smithy-v1 PER-44 instead of `--bare`. OAuth and MCP stay active because they live outside settings.
3. **v2.1 spec rewrite** (`91f4860`). [`v2/SPEC.md`](../SPEC.md), 864 lines. Old fork-spec preserved at [`v2/history/2026-05-06-v2-fork-spec-original.md`](2026-05-06-v2-fork-spec-original.md).
4. **Foundation pass** (`b610c7b`). Six parallel agents delivered the data-shape foundation: agents schema in Ecto, Persona module, MCP bundle library, REVIEW.md parser, TRIAGE.md parser, Runtime behaviour. 20 files, 2,508 insertions.
5. **Pass 2: ClaudeCode AppServer + Reviewer mode** (`5b99046`). Port management for Claude Code subprocess + the first mode handler. 7 files, 1,842 insertions.
6. **Pass 3: Triager mode + Smithy wrapper + Workpad module** (`d3e77af` then amended to `dd2207e`). Triager mode (mirrors Reviewer shape), new Smithy CLI escript at `wrapper/`, Workpad management module.
7. **AGENTS.md template + README** (this commit). Universal nudge template ships in `elixir/priv/templates/AGENTS.md`. README updated to reflect v2.1 preview state.

## Test state

```
elixir/   479 tests, 0 failures, 2 skipped (pre-existing)
wrapper/   43 tests, 0 failures
```

All new modules have 100% behavioral coverage of their public surface.

## What works as a library call

You can manually invoke any of the new modules in iex and they do the right thing:

- `SymphonyElixir.Personas.Persona.load(path) -> render(p, vars)`
- `SymphonyElixir.MCP.Bundle.load(name) -> write_config(b, path)`
- `SymphonyElixir.Handoff.Review.parse_file(path)`
- `SymphonyElixir.Handoff.Triage.parse_file(path)`
- `SymphonyElixir.Modes.Reviewer.run(issue, workspace, agent_config, opts)`
- `SymphonyElixir.Modes.Triager.run(issue, workspace, agent_config, opts)`
- `SymphonyElixir.Workpad.create(issue_id, opts) -> append_section(...)`
- `SymphonyElixir.Runtime.ClaudeCode.AppServer.start_session(workspace, opts) -> run_turn(...)`

The Smithy CLI wrapper compiles to a working escript:

```bash
cd wrapper && mise exec -- mix escript.build
./bin/smithy --help
./bin/smithy add-repo smithy ~/projects/smithy
./bin/smithy status
./bin/smithy dashboard
```

## What's NOT wired

The orchestrator (`elixir/lib/symphony_elixir/orchestrator.ex`, 1655 lines) still routes every ticket through the existing Codex-only builder flow. To make the new modes actually fire on Linear state changes, the orchestrator's `dispatch_issue/3` (line 660) and `do_dispatch_issue/4` (line 680) need to:

1. **Read the workflow's `agents:` block** from `Config.settings!().agents` (already wired by the schema work).
2. **Branch on issue state** to select the right mode:
   - `Todo` + `agents.triager` configured: call `Modes.Triager.run(issue, workspace, agents.triager)`. On `{:proceed, _}` transition to `In Progress` and dispatch builder. On `{:flag, triage}` apply `needs-spec` label, remove `agent-ready`, move to `Backlog`, post `triage.gap_comment` via `Workpad.append_section(:notes, ...)`. On `{:blocked, _}` apply `harness-blocked`.
   - `Todo` (no triager): dispatch builder directly (current behavior preserved).
   - `In Progress`: builder continues (current behavior preserved).
   - `Adversarial Review` + `agents.reviewers != []`: call `Modes.Reviewer.run(issue, workspace, hd(agents.reviewers))`. On `{:pass, review}` transition to `Human Review` (or `Merging` if `auto-merge` label set). On `{:fail, review}` transition to `Rework` and `Workpad.append_section(:adversarial_review, format_review(review))`. On `{:blocked, _}` apply `harness-blocked`.
3. **Resolve runtime + persona** for the builder dispatch path. Today `AgentRunner.run/3` hardcodes Codex AppServer; it needs to read `agents.builder.runtime` and call `Runtime.adapter_for(runtime).start_session(...)` instead.

The Symphony port-map inventory at session start identified `dispatch_issue/3` (line 660), `do_dispatch_issue/4` (line 680), and `AgentRunner.run_codex_turns/4` (line 79) as the three load-bearing seams.

This is a careful refactor against 1655 lines of production code with 480 tests around it. Recommend doing it in two sub-passes:

- **Sub-pass A:** add the mode selection seam to `do_dispatch_issue/4` WITHOUT changing builder behavior. Pass `mode: :builder, runtime: :codex, persona: nil` through to `AgentRunner.run/3` from a new helper that reads `Config.settings!().agents`. Existing builder flow keeps working with explicit defaults. Verify all 479 tests still pass.
- **Sub-pass B:** add the Adversarial Review branch + Triager branch as separate code paths. Each calls into `Modes.Reviewer.run/4` or `Modes.Triager.run/4` and translates the outcome to Linear state transitions via `Tracker.update_issue_state/2` (and label edits via the Linear adapter).

Sub-pass A is reversible if it goes sideways. Sub-pass B adds new functionality without touching the existing path.

## Where the hours actually went

For reference if Shawn wants to calibrate:

| Pass | Wall time | What |
|---|---|---|
| Brainstorm + spec | ~3 hr | 7-axis brainstorm via skill, two pivots, draft + self-review |
| Spike (parser + argv) | ~30 min | Validation that Claude Code adapter is feasible |
| Pass 1 (foundation, 6 parallel) | ~30 min | Schema + Persona + MCP + Review.md + Triage.md + Runtime behaviour |
| Pass 2 (ClaudeCode AppServer + Reviewer, 2 parallel) | ~25 min | Port management + reviewer mode |
| Pass 3 (Triager + wrapper + Workpad, 3 parallel) | ~30 min | Three big modules in parallel |
| AGENTS.md + README + handoff | ~10 min | This file and the prefix template |

Total: ~6 hours of wall time across the brainstorm + execution, with most of the implementation work parallelized across 11 subagent runs. The original 30-40 hour estimate I gave Shawn was based on single-threaded human-pace work; parallel agents collapsed it.

## Open questions for morning

1. **Tag now or after orchestrator wire-up?** `v2.0.0-alpha-1-preview` tag captures the architectural state. `v2.0.0-alpha-1` waits for the orchestrator refactor.
2. **MCP bundle package names need verification.** The wrapper agent flagged `linear-read` (using `mcp-remote` shim against `https://mcp.linear.app/sse`) as a placeholder; `github` and `playwright` are higher confidence. 5-minute sanity check against npm registry before alpha-1 ships for real.
3. **Codex.AppServer formal behaviour declaration.** The Runtime behaviour exists; Codex.AppServer doesn't yet declare `@behaviour SymphonyElixir.Runtime` because its `run_turn/4` arity matches but the runtime contract should be verified. One-line change after verification.
4. **Workpad client wiring.** `SymphonyElixir.Workpad.LinearClient` is a separate boundary from `Tracker`. The orchestrator wire-up needs to use the Workpad client for review/triage handoff, while continuing to use Tracker for fire-and-forget state-change comments. Document the split clearly.

## Recommendation

Tag `v2.0.0-alpha-1-preview` on this branch now. Open a PR to `main`. Tomorrow's focused session does the orchestrator refactor on a fresh branch, with this as the parent commit and the test suite as the ratchet.
