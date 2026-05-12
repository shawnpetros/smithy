# Maiden Voyage Walkthrough

**Date:** 2026-05-12
**Tag:** `v2.0.0-alpha-1`
**Goal:** dispatch one real Linear ticket end-to-end through the v2.1 pipeline. Source of ground truth for the hardening sprint.

## What's about to happen

The Smithy wrapper supervises a Symphony daemon. The Symphony daemon polls Linear's Smithy Engineering project every 30s for tickets carrying `agent-ready`. PER-150 (the `:symphony_elixir → :smithy` rename) is the only such ticket. When Symphony picks it up:

1. Workspace created at `~/.smithy/workspaces/smithy/PER-150/`
2. `git clone git@github.com:shawnpetros/smithy.git .` into the workspace
3. Codex builder dispatched (per `agents.builder.runtime: codex`)
4. Builder reads the ticket, writes a workpad comment on Linear, plans the rename, makes the changes, opens a PR
5. Builder transitions PER-150 to `Adversarial Review`
6. Symphony spawns the Claude Code reviewer (per `agents.reviewers[0].runtime: claude_code`)
7. Reviewer reads the PR diff and the workpad, writes `REVIEW.md`
8. On `status: pass`, Symphony transitions to `Human Review`
9. Shawn reviews, merges, marks `Done`

## Pre-flight checklist (already complete)

- [x] v2.0.0-alpha-1 tagged on `spike/claude-code-adapter`
- [x] Wrapper escript built: `wrapper/bin/smithy`
- [x] Hold-harmless acknowledged: `~/.smithy/config.toml` has `acknowledged_at`
- [x] Smithy registered: `[[repos]]` entry with port 4001
- [x] launchd plist generated at `~/Library/LaunchAgents/com.shawnpetros.smithy.smithy.plist`
- [x] WORKFLOW.md targets `smithy-engineering-b3a1a7605988` Linear project
- [x] WORKFLOW.md gates on `agent-ready` label
- [x] WORKFLOW.md `agents:` block: codex builder + claude_code reviewer
- [x] PER-151/152/153 closed Done (already implemented in wrapper)
- [x] PER-150 is the only `agent-ready` ticket; first dispatch target

## Launch sequence

```bash
# 1. Ensure LINEAR_API_KEY is in env. Smithy reads it from the shell where
#    you start the daemon (or via launchd EnvironmentVariables; we use shell
#    inheritance in v1).
echo $LINEAR_API_KEY | head -c 8 && echo "..."

# 2. Start the daemon under launchd.
smithy daemon start smithy

# 3. Tail the stdout. First minute = boot, schema validation, Linear connect.
tail -f ~/.smithy/logs/smithy/stdout.log

# 4. In a second shell, watch the aggregate status.
smithy status
# or
smithy bellows

# 5. Open the per-repo dashboard.
smithy dashboard smithy
```

## What to watch for

**First ~30 seconds (boot):**
- "starting symphony" log line
- Workflow loaded and parsed (no schema errors)
- Phoenix endpoint up on port 4001 ("Running SymphonyElixirWeb.Endpoint with Bandit")
- StatusDashboard renders the empty header

**First poll cycle (~30s after boot):**
- Linear adapter authenticates
- Polling loop logs `Fetched N issues` with N ≥ 1
- PER-150 enters the running set

**Builder turn (codex):**
- StatusDashboard shows PER-150 with stage `In Progress`
- Workpad comment appears on Linear PER-150
- Codex CLI logs the model + reasoning effort
- Eventually: PR opens against `main`
- State transitions to `Adversarial Review`

**Reviewer turn (claude_code):**
- StatusDashboard shows PER-150 with stage `Adversarial Review`
- Claude Code subprocess spawns with `--setting-sources project,local --strict-mcp-config`
- Reviewer reads `gh pr diff <n>` from the workspace
- Writes `REVIEW.md` to workspace root
- Outcome: pass → transitions to `Human Review`; fail → transitions to `Rework` with findings in workpad

**Telemetry:**
- JSONL events at `~/.smithy/telemetry/<repo_slug>/<YYYY-MM-DD>.jsonl`
- (Token data still zero-filled per the known gap; wall-clock + outcome will be populated)

## Known landmines

1. **The harness doesn't expose tokens through `AppServer.run_turn/4` return** — Telemetry events will have nil token counts. Doesn't block the run; just no cost-per-ticket data yet.
2. **Tracker label CRUD is rescue-stubbed** — if the reviewer somehow needs to apply `auto-merge` (it doesn't on this ticket; auto-merge is operator-applied) or harness-blocked, the call no-ops with a warning. Won't fire on PER-150.
3. **Workpad client is a separate boundary from Tracker** — the new Workpad module uses `SymphonyElixir.Workpad.LinearClient` directly via the GraphQL `graphql/3` helper. The current orchestrator outcome handlers go through this. Tested in isolation; first real run is the actual proof.
4. **Self-update flow is not wired** — PER-154 carries `smithy:do-not-dispatch`. The `smithy:self-update` label exists but the drain/rebuild/respawn protocol is alpha-2.
5. **Wall-clock flake at `core_test.exs:517`** — pre-existing, unrelated to v2.1. Filed for the hardening sprint.

## If something goes wrong

**Daemon won't start:**
- Check `~/.smithy/logs/smithy/stderr.log`
- Confirm `LINEAR_API_KEY` is set in the shell that invoked `smithy daemon start`
- Confirm `symphony_binary` in `~/.smithy/config.toml` points at a buildable binary
- `cd elixir && mise exec -- mix escript.build` to rebuild

**Workflow file rejected:**
- `mise exec -- mix run -e 'SymphonyElixir.Workflow.load() |> IO.inspect()'` in the elixir/ dir
- Watch for schema errors; the agents block is new and may have a parse edge case

**Builder can't clone:**
- Confirm SSH key for `git@github.com:shawnpetros/smithy.git` is loaded (`ssh-add -l`)
- Workspace at `~/.smithy/workspaces/smithy/PER-150/` should contain the clone after the after_create hook

**Builder hangs:**
- Stall watchdog should fire after 5min of no activity (configured in the workflow `polling` block)
- `smithy status` shows `last_event` per ticket
- Kill the daemon, fix the issue, restart

**Reviewer doesn't fire:**
- Confirm Symphony transitioned to `Adversarial Review` (check ticket state in Linear)
- Confirm claude binary is on PATH (`which claude`)
- Reviewer runs in a fresh subprocess each time; check `~/.smithy/logs/smithy/stdout.log` for the spawn

## After the run

Whether it works or fails, capture findings:

1. Workpad comment on PER-150 (what the agents wrote)
2. Final Linear state of PER-150
3. PR (if opened) — URL, diff size, CI status
4. Telemetry JSONL — wall-clock durations across the run
5. Any errors in `~/.smithy/logs/smithy/stderr.log`
6. Subjective: did the cross-model handoff feel right? Where was friction?

File a follow-up post-mortem at `v2/history/2026-05-12-maiden-voyage-results.md` once the run completes.

## Stopping the daemon

```bash
smithy daemon stop smithy
# Confirm the launchd job is unloaded:
launchctl list | grep com.shawnpetros.smithy
```

## Next: hardening sprint

After maiden voyage, the harness builds the hardening tickets itself. Five children of a new "Smithy v2.1 alpha-1 hardening" epic, all `agent-ready`. Recommended dispatch order:

1. Wall-clock flake fix (cheap, low risk, unblocks "all green" CI)
2. Token data flow (medium, instruments existing module)
3. Label CRUD (medium, new behaviour callbacks + Linear adapter mutations)
4. Config extras round-trip (medium, fixes the TOML table dropping issue uncovered during maiden voyage prep)
5. Resilience audit (open-ended; meta-ticket for ongoing improvements)
