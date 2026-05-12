# Smithy v1 Edge Cases & Failure Modes

**Status:** Draft, written as input to v2.1 spec.
**Date:** 2026-05-11
**Context:** Decisions through this point of the brainstorm:
- Smithy is a thin launchd/systemd wrapper around N Symphony instances.
- Symphony fork grows three orthogonal config axes: `mode`, `runtime`, `persona`.
- Anvil's reviewer logic ports INTO Symphony as `mode: reviewer`.
- Defaults match vanilla Symphony if unconfigured.

This doc enumerates the failure modes worth specifying behavior for, grouped by where they originate.

---

## 1. Build/review oscillation

**Scenario:** Builder opens PR. Reviewer FAILs with findings. Builder rebuilds. Reviewer FAILs again with overlapping or different findings. Loop.

**Failure modes:**
- Infinite oscillation between Adversarial Review and Rework states. No `[blocker]` is ever fully resolved because the builder addresses one and introduces another.
- Reviewer disagrees with itself across attempts (model nondeterminism on the same diff).
- Builder addresses findings cosmetically but the underlying problem remains. Reviewer raises adjacent findings each time.

**Spec'd behavior:**
- **Max retry counter** on the run. After N attempts (default 3, configurable per workflow), apply `harness-blocked`, transition to In Review, post a summary of findings across all attempts. (This is the v2 SPEC §9 circuit breaker.)
- **Mediator escalation** (PER-41 reference). After M failed review cycles (default 2, configurable), spawn a higher-tier model in a `mode: mediator` invocation. Mediator reads all prior REVIEW.md outputs + the current diff. Outputs `MEDIATION.md` with one of three verdicts: SCOPE_TRIM (narrow the ticket and re-dispatch), APPROVE_WITH_CAVEAT (override reviewer, transition to Human Review with a note), or HUMAN_ESCALATE (apply `harness-blocked`). M and N are independent; mediator fires BEFORE max-retry.
- **Findings deduplication across attempts.** Each REVIEW.md is appended to the workpad under a dated `### Adversarial Review` subsection. Builder reads the FULL history before re-planning, not just the most recent. Helps break "addressed N-1 finding, introduced N+1 finding" oscillation by surfacing the pattern.

## 2. Test flakes during reviewer validation

**Scenario:** Reviewer runs `mix test` or equivalent. A test fails. Was it a real bug or a flake?

**Failure modes:**
- Reviewer FAILs the build on a flaky test, sending it back to a builder that can't reproduce.
- Reviewer ignores a real test failure because it ran the test once and it passed.
- Test environment differs between builder and reviewer (paths, env vars, services).

**Spec'd behavior:**
- **Test-retry policy:** reviewer retries any failing test once. If it passes on retry, log as "flaky, not blocking." If it fails twice, treat as real.
- **Test environment parity:** reviewer runs in the same workspace as the builder (warm-workspace review). Cold-clone review is deferred to v2 polish.
- **Reviewer cannot edit test code.** Reviewer's sandbox denies file writes except for `REVIEW.md`. If reviewer thinks a test is wrong, it's a `[future]` or `[polish]` finding, not a fix.
- **Long-running tests:** reviewer respects a per-test timeout from workflow config. Tests exceeding the timeout are logged as "timed out" and reviewer flags as `[future]` (investigate but don't block).

## 3. Self-update mid-flight

**Scenario:** A ticket carrying `smithy:self-update` is in `Adversarial Review`. Other tickets are in `In Progress` against the same Symphony instance.

**Failure modes:**
- Smithy rebuilds and respawns mid-flight, SIGKILLing other workers.
- Smithy waits for other workers to finish, but one of them hangs and self-update never completes.
- New code post-respawn has incompatible state schema; hydration fails and the daemon enters a crash loop.
- Self-update PR merges but compile fails post-merge. Daemon is on old code, but the codebase on disk is broken.

**Spec'd behavior:**
- **Drain timeout.** Wait up to T minutes (default 30) for other workers to reach a safe checkpoint (PR opened + pushed). After T, log warning and proceed; workers in progress are signaled SIGTERM with a 60s grace period.
- **Pre-rebuild snapshot.** Symphony writes a state snapshot to `~/.smithy/repos/<slug>/.pre-rebuild-state.json` before exiting. Includes in-flight ticket IDs + their current state. Post-respawn, Smithy hydrates from Linear state primarily (authoritative) and uses the snapshot only as a safety net for orchestrator-internal state (retry counters, etc.).
- **Compile-fail rollback.** If `mix compile` fails post-merge, the orchestrator:
  1. Posts a structured blocker comment to the self-update workpad.
  2. Applies `harness-blocked` label.
  3. Does NOT respawn (exit code 0, supervisor doesn't restart).
  4. Operator gets paged via the dashboard heartbeat going stale.
  Operator manually reverts the merge and restarts. Recovery doc lives in `docs/operations/self-update-recovery.md`.
- **Hydration mismatch.** If post-respawn the daemon can't parse the snapshot (incompatible schema), it logs a warning and rebuilds in-memory state from Linear alone. Snapshot is best-effort.
- **State schema versioning.** Snapshot files carry a `schema_version` field. New daemon refuses to hydrate a snapshot with a version newer than itself (downgrade scenario). Snapshots older than the daemon's current version go through a migration step.

## 4. Cross-repo ticket (single ticket touches multiple repos)

**Scenario:** A ticket carries `repo:smithy` AND `repo:substrate`. Or no `repo:*` label and the work spans both.

**Failure modes:**
- Two Symphony instances pick up the same ticket and race.
- Ticket completes on one repo but not the other; PR opens on smithy but substrate is untouched.
- Reviewer can't validate cross-repo because it can only see one workspace.

**Spec'd behavior for v1:**
- **Cross-repo tickets are out of scope.** Each Symphony instance filters tickets by `repo:<its_slug>`. A ticket carrying multiple `repo:*` labels is picked up by only the first instance that polls it (race). 
- **Mitigation:** workflow config's `tracker.labels` filter requires exactly one `repo:*` label. Tickets with zero or multiple are skipped and a one-time comment is posted: "harness skipped: ambiguous repo label."
- **Future v2:** spec out a cross-repo workflow. Probably requires a parent ticket with `smithy:master` that decomposes into per-repo children. Deferred.

## 5. PR feedback during Human Review

**Scenario:** Builder + reviewer done, ticket in `Human Review`. A human or bot leaves a PR comment. Days later, more comments arrive.

**Failure modes:**
- Symphony was polling the ticket but stopped at `Human Review`. New comments go unaddressed.
- Reviewer/bot leaves a comment after merge; nothing picks it up.
- Comments span multiple iterations; builder/reviewer don't know which is current.

**Spec'd behavior:**
- **Human transitions to `Rework`.** Symphony only re-engages when the human moves the state. PR feedback while in `Human Review` is a human's call to triage, not the harness's.
- **Rework flow.** Ticket in `Rework` triggers a fresh builder turn. Builder reads ALL workpad sections (Plan, Adversarial Review, Confusions) plus the full PR comment thread. Workpad gets a new `### Rework #<n>` subsection.
- **PR comments after merge** are out of scope. v1 doesn't reopen merged work.

## 6. Token cost runaway

**Scenario:** A single ticket hits a long agent loop. Tokens accumulate. Daily spend cap blown.

**Failure modes:**
- Per-run cost exceeds budget. Worker keeps spending.
- Daily cost rollup exceeds budget across runs. New runs keep dispatching.
- A bug in the prompt causes the model to loop on tool calls.

**Spec'd behavior:**
- **Per-run cost cap (configurable, default $5).** Claude Code has `--max-budget-usd` built-in; pass it through. Codex doesn't have a direct equivalent; track via token counts emitted on each turn and abort when threshold crossed. Aborted runs apply `harness-blocked`, post a "cost cap hit" comment.
- **Daily rollup soft warning, hard cap (configurable, defaults $50 warn / $100 hard).** Soft warning logs and dashboards a banner. Hard cap stops new dispatches until midnight UTC or operator clears via `smithy reset-cost-cap`.
- **Per-turn token watchdog.** If a single turn emits > 100k output tokens, abort the turn. Indicative of a tool-call loop.

## 7. Network failures

**Scenario:** Linear API is down. GitHub is down. Claude/Codex API is down.

**Failure modes:**
- Symphony's poll loop hangs on Linear.
- Worker mid-turn loses connectivity, agent state is lost.
- State transition writes to Linear fail; orchestrator and Linear diverge.

**Spec'd behavior:**
- **Linear poll: exponential backoff + jitter.** Symphony already does this. Confirm.
- **GitHub: retry 3x with backoff before failing the run.** PR open, comment write, label apply.
- **Agent API failure mid-turn:** agent returns error event. Worker logs, optionally retries the turn once, then ends the run with `harness-blocked` if still failing.
- **State transition failures:** orchestrator retries 3x, then logs `state_transition_pending` to the snapshot. Next poll cycle reconciles by re-reading Linear state and comparing to local state. Authoritative: Linear.

## 8. Workspace corruption

**Scenario:** Per-issue workspace ends up in a bad state. Git refs broken, lockfiles abandoned, branch diverged.

**Failure modes:**
- Worker can't run `git status` cleanly.
- Subsequent runs in the same workspace inherit corruption.

**Spec'd behavior:**
- **Reconcile-then-retry.** On worker failure that mentions git errors, run `git status` + `git stash` to capture state, then a fresh `git checkout main && git pull && git checkout -b <branch>`. Log the recovery.
- **Workspace nuke option.** Operator-triggered via `smithy nuke-workspace <ticket-id>`. Deletes the workspace and clones fresh from origin/main on next run. Use sparingly.
- **Symphony already has retention policy hooks.** Inherit upstream behavior; nothing new in v1.

## 9. Reviewer can't decide (no clean PASS/FAIL signal)

**Scenario:** Reviewer reads the diff. Diff partially addresses the ticket but has gaps. Strict PASS would let through incomplete work; strict FAIL would bounce work that's "mostly there."

**Failure modes:**
- Reviewer FAILs on `[future]` findings that should be follow-up tickets, not blockers.
- Reviewer PASSes work that's incomplete because none of the findings rise to `[blocker]`.

**Spec'd behavior:**
- **Anvil's grading is the contract.** `status: fail` requires at least one `[blocker]`. `[polish]` and `[future]` alone are advisory; reviewer must `status: pass` even with findings of those grades.
- **Reviewer-as-judge, not reviewer-as-architect.** Reviewer's job is "did this address the ticket," not "is this the best possible solution." Architectural concerns are `[future]` findings or separate tickets.
- **Workflow override.** Operators can configure per-repo strictness: `reviewer.strict_mode: true` treats `[polish]` as `[blocker]`. Default is false.

## 10. Concurrent worker conflicts in shared workspace

**Scenario:** Two workers in two repos race on a shared dependency (e.g., a mise/asdf tool version conflict).

**Failure modes:**
- Mid-run, one worker upgrades a global tool; the other's build breaks.
- Workspaces share a node_modules cache; concurrent npm installs corrupt it.

**Spec'd behavior:**
- **Workspaces are per-issue, fully isolated.** Symphony already does this. Verify.
- **Tool versions pinned per workspace** via `mise.toml` or `.tool-versions` per workspace. No shared global state.
- **Caches:** if a per-repo cache exists, it's read-only for workers. Updates happen via dedicated tickets, not as side effects.

## 11. Worker exceeds max_turns without finishing

**Scenario:** Worker hits `agent.max_turns` (default 20). Ticket still in `In Progress`. PR may or may not exist.

**Failure modes:**
- Orchestrator dispatches a new attempt. Worker rewinds and starts over, never progressing.
- Worker had useful state mid-implementation; new attempt loses it.

**Spec'd behavior:**
- **Persistent workspace.** Same workspace is used for the next attempt; state is preserved on disk.
- **Workpad-driven continuation.** New attempt reads workpad first, sees prior plan + completed checkboxes, picks up where last left off.
- **Max attempts counter.** After K attempts (default 3) on the same ticket without reaching `Adversarial Review`, apply `harness-blocked` and stop dispatching.

## 12. Linear OAuth token expires mid-run

**Scenario:** Smithy is using OAuth identity (v2 spec §6). Token refresh fails or expires.

**Failure modes:**
- State transition writes fail silently.
- Workpad updates lost.
- Worker continues, orchestrator thinks it's still running, Linear is out of sync.

**Spec'd behavior (v2 scope, not v1):**
- **Auto-refresh on every API call.** If refresh fails, pause polling, log warning, escalate via dashboard alert.
- **Pause, don't crash.** Existing workers complete their current turn; new dispatches block until OAuth is restored.
- **Manual unstick.** `smithy auth refresh` retries the OAuth flow.

For v1, personal API key is used. Token rotation is a human concern.

---

## Severity classification

For the v2.1 spec, edge cases split into:

**Hard requirements (spec these explicitly, ship with v1):**
- Max retry counter + harness-blocked (§1)
- Drain timeout + compile-fail rollback (§3)
- Cross-repo ambiguous label handling (§4)
- Rework flow from Human Review (§5)
- Per-run cost cap (§6)
- State transition retry + Linear reconciliation (§7)
- Reviewer grading contract (§9)
- Workpad-driven continuation (§11)

**Soft requirements (default behaviors, override-able by config):**
- Mediator escalation (§1)
- Test retry policy (§2)
- Per-turn token watchdog (§6)
- Per-tool timeouts (§2)
- Reviewer strict mode toggle (§9)

**Deferred (v2 polish or v3):**
- Cross-repo workflow with master decomposition (§4)
- Linear OAuth auto-refresh (§12)
- AI summarization of failure modes
- Cost rollups + per-tenant breakdowns
