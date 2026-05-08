---
title: "Agent-Native Workflow Harness v1 Architecture Spec"
date: "2026-05-06"
type: spec
classification: internal
status: draft
tags:
  - spec
  - harness
  - agent-native-workflow
  - symphony
  - architecture
  - v1
related:
  - v1 pilot post-mortem (private)
---

# Agent-Native Workflow Harness v1 Architecture Spec

**Status:** Draft, first-pass with sane defaults. Open questions in the final section.
**Authors:** Shawn Petros, with Claude (Anthropic Opus 4.7) as paired engineer.
**Inputs:** an agent-native workflow PRD (private) and a bare-harness pilot post-mortem (private) from running Symphony end-to-end against a real Linear ticket.

> **Symphony** in this document refers to OpenAI's open-source coding-agent harness ([github.com/openai/symphony](https://github.com/openai/symphony)). It polls an issue tracker (Linear in this version), creates a per-issue workspace, and runs an OpenAI Codex CLI session against each ticket via Codex's app-server mode. Workflow is configured via a single `WORKFLOW.md` file. License: Apache-2.0.

---

## Goal

Define the v1 build scope of an agent-native workflow harness. The v1 takes a small, well-scoped Linear ticket end-to-end: from `Ready for Dev`, through autonomous spec-sufficiency triage at front-of-queue, through implementation by a worker agent, through an autonomous adversarial review pass, and into `In Review` for human approval. The base is the Symphony Elixir implementation, forked with targeted additions. Anything beyond `In Review` (merge, deploy) stays a human responsibility in v1.

---

## Non-goals (v1)

- Multi-model dispatch (label routes the work to a different agent stack, e.g. Codex vs. Claude Code). Defer to v2.
- Auto-merge after adversarial review pass. Defer to v2; requires an explicit human authorization model that does not exist yet.
- Containerization (Docker per agent, k8s orchestration, microVM isolation). Defer to v2 when there are multiple operators.
- Custom Codex seatbelt profile that allows `.git` writes and network while staying otherwise restrictive. v2 hardening project.
- Cross-tracker support beyond Linear. v2+.
- Token cost budgets per ticket. v2, once cost data accumulates.
- Public dashboard or remote-access UI. v1 is single-operator, localhost-only.

---

## Inputs already shipped

The bare-harness pilot delivered one fork modification: a `tracker.labels` filter in Symphony's config schema and Linear adapter that gates dispatch to tickets carrying at least one matching label. Two-file delta in the fork. This is the queue-gate mechanism v1 builds on.

---

## Architecture overview

Symphony's Elixir implementation already provides the operational skeleton: a polling loop, per-issue workspaces, dispatch with bounded concurrency, retry and exponential backoff, a Phoenix LiveView dashboard, a JSON state API, and structured logging.

v1 adds four components on top of that base, sequenced as a pipeline a ticket flows through:

```
Ticket flow (v1):

[ agent-ready label applied by human ]
              |
              v
[ Ready for Dev ]----> spec triage ----FLAG----> [ Backlog ] + needs-spec label
              |               |
              |               PROCEED
              v               |
[ In Progress ] <-------------+
              |
              | implement, commit, push, open draft PR
              v
[ Adversarial Review ] ----> reviewer agent
              |                       |
              |                       fail
              |<----------------------+
              | pass
              v
[ In Review ] ----> human approves ----> [ Done ]
```

The v1 stays single-process. Symphony's existing sandbox config is loosened to `dangerFullAccess` as an explicit, documented trade-off; v2 will tighten this.

---

## Component additions

| Component | Where it lives | What it does | Hard dependencies |
|---|---|---|---|
| Spec sufficiency triage | Prompt body in `WORKFLOW.md` (Step 0.5) | Front-of-queue evaluation: PROCEED to work, or FLAG back to Backlog with `needs-spec` label | None |
| Adversarial Review state | Linear team workflow + workflow config | New state between `In Progress` and `In Review`. Acts as the trigger for the reviewer agent. | Linear team config change |
| Reviewer agent dispatch | Symphony fork: new module + orchestrator hook | On state transition into `Adversarial Review`, spawns a fresh Codex session with a review-only prompt | Adversarial Review state, Symphony fork |
| SQLite persistence | Symphony fork: new Ecto repo + migrations + schema | Persists run metadata, session metadata, state transitions, error events. Survives daemon restarts. | Symphony fork, Ecto wiring |
| History dashboard tab | Symphony fork: new Phoenix LiveView page at `/history` | Lists past runs with filters; click into a run for workpad cache, session summary, state-transition log | SQLite persistence |
| Label queue gate | Symphony fork (shipped during pilot) | `tracker.labels` filter restricts dispatch to tickets carrying at least one matching label | None (done) |

---

## Linear state machine (v1)

States in order:

- `Backlog`: out of scope. Harness does not claim or modify content.
- `Ready for Dev`: queued for spec triage. Must carry the queue-gate label.
- `In Progress`: worker agent has triaged PROCEED, planned, and is implementing.
- `Adversarial Review`: worker has committed and pushed; reviewer agent is running.
- `In Review`: human review of an autonomously-passed PR.
- `Done` / `Duplicate` / `Canceled`: terminal.

Agent-performed transitions:

| From | To | Trigger | By |
|---|---|---|---|
| `Ready for Dev` | `In Progress` | spec triage PROCEED | worker |
| `Ready for Dev` | `Backlog` | spec triage FLAG (also: `needs-spec` add, queue-gate remove) | worker |
| `In Progress` | `Adversarial Review` | PR opened, branch pushed, gates green | worker |
| `Adversarial Review` | `In Review` | reviewer pass | reviewer |
| `Adversarial Review` | `In Progress` | reviewer fail (with findings comment) | reviewer |

Human-performed transitions:

- `In Review` to `Done` after PR merge.
- `In Review` to `In Progress` if review feedback requires changes.

---

## Label vocabulary (v1)

| Label | Applied by | Removed by | Meaning |
|---|---|---|---|
| `agent-ready` | human | worker (on FLAG) | queue gate. Required for harness eligibility. Human applies after spec'ing a ticket well enough for the harness. |
| `needs-spec` | worker (on FLAG) | human | ticket content is insufficient. Pairs with state move to `Backlog`. Human re-spec's, removes label, re-adds `agent-ready`. |
| `harness-blocked` | worker / reviewer | human | environment or repo-baseline issue prevents the harness from completing. Pairs with state move to `In Review` plus a workpad comment. Distinct from `needs-spec`, which is about ticket content. |

The pilot's `symphony` label is renamed to `agent-ready` for v1, since the harness identity is no longer "the bare Symphony pilot." Migration: a one-time script removes `symphony` and adds `agent-ready` on existing eligible tickets.

---

## Spec sufficiency triage (Step 0.5)

A new step inserted into the worker prompt between routing (Step 0) and workpad creation (Step 1). The agent answers four questions in one turn from the ticket title, description, attachments, linked materials, and a brief targeted exploration of the repo:

1. **Where**: Can I point to a specific file, component, or system this change touches?
2. **What**: Is the change a defined behavior, or a discussion-stage idea (e.g. "we should discuss," "TBD")?
3. **Acceptance**: How is completion verified? Are there explicit criteria, or are they derivable from existing patterns?
4. **Ambiguity**: Are there product or design decisions I cannot reasonably make from the ticket alone?

**Proportionality clause:** trivial changes obvious from the title (typo fixes, version bumps) use the title itself as the spec. Don't demand formal acceptance for one-line changes.

**Decision:**

- **PROCEED** if Where + What + Acceptance answer with high confidence. Continue to Step 1 (workpad bootstrap).
- **FLAG** if any of:
  - The description contains punt language ("we should discuss," "TBD," "needs scoping").
  - After targeted repo exploration, the affected file or component is not identifiable.
  - The change requires product or design decisions not provided.
  - There are multiple plausible implementations and the ticket gives no signal which is correct.
  - Acceptance is undefined and not derivable from existing patterns.

**FLAG actions (atomic, one turn, then end):**

1. Add `needs-spec` label.
2. Remove `agent-ready` label.
3. Move state to `Backlog`.
4. Post a workpad comment with the structured gap list (see template below).
5. End the turn. Do not create the rest of the workpad.

**FLAG comment template:**

```markdown
## Harness: spec sufficiency triage failed

This ticket cannot be executed autonomously in its current form. Specific gaps:

- [list each unanswered triage question with a one-sentence note]

To re-queue: address the gaps above, remove `needs-spec`, add `agent-ready`, and move to `Ready for Dev`.
```

Spec triage is a one-turn evaluation. If the answer is uncertain, FLAG. A FLAG is reversible by the human; a stuck multi-turn loop on an underspec'd ticket is not.

---

## Adversarial review pass

The reviewer agent runs as a separate Codex session, dispatched on the `In Progress` to `Adversarial Review` state transition. It does not share the worker's session context; this is a deliberate design choice for review independence.

**Reviewer's task:**

- Read the PR diff via `gh pr diff <n>`.
- Read the worker's workpad comment for the ticket.
- Run the same gate commands the worker ran (typecheck, tests, lint).
- Audit for:
  - Spec compliance against the ticket's acceptance criteria.
  - Security issues (prompt injection vectors, hardcoded credentials, IAM scope creep, untrusted-input handling).
  - Code quality regressions (significant complexity adds, layering violations, dead code introduced).
  - Missing edge cases derivable from existing patterns or sibling components.
  - Scope creep beyond the ticket.
  - Test coverage gaps for the diff (especially: did the worker write a render test for component changes per the testing convention).
- Post findings as a separate Linear comment on the ticket, header `## Adversarial Review`. Findings graded `[blocker]`, `[polish]`, or `[future]`.

**Decision:**

- Pass: zero `[blocker]` findings. Transition to `In Review`. Mark PR ready for review (no longer draft) is OPTIONAL in v1; defaulting to NO (PR stays draft until human approves).
- Fail: one or more `[blocker]` findings. Transition back to `In Progress`. Worker re-runs to address findings on next dispatch tick.

**v1 reviewer model:** Codex with a different prompt than the worker. v2 may rotate to a different model family for cross-perspective review.

**v1 sandbox:** same as worker (`dangerFullAccess`).

**Workspace lifetime:** the worker's workspace persists during adversarial review. Reviewer reads from it directly. v2 may move to "cold review" by destroying the workspace and re-cloning the PR branch into a fresh workspace, forcing the reviewer to fetch the diff from origin rather than reading worktree state.

---

## Persistence layer (SQLite via Ecto)

A new Ecto repo wired into the Symphony fork. SQLite for v1 because: file-backed, no external service, fits a single-operator harness, easy to inspect with the standard sqlite3 CLI.

**Schema (three tables):**

- `runs`
  - `id` (uuid)
  - `issue_identifier` (string, indexed)
  - `project_slug` (string)
  - `started_at`, `ended_at` (utc datetime)
  - `final_state` (string: completed, blocked, errored, cancelled)
  - `total_tokens` (int, sum across sessions)
  - `error_summary` (text, nullable)

- `sessions`
  - `id` (uuid)
  - `run_id` (fk runs)
  - `role` (string: worker | reviewer)
  - `started_at`, `ended_at` (utc datetime)
  - `turn_count` (int)
  - `input_tokens`, `output_tokens` (int)
  - `exit_reason` (string: completed, max_turns, error, cancelled)

- `state_transitions`
  - `id` (uuid)
  - `run_id` (fk runs)
  - `from_state`, `to_state` (string)
  - `transitioned_by` (string: agent | human)
  - `at` (utc datetime)

**Hooks:** orchestrator emits events at run start, run end, session start, session end, and on every Linear state transition observed via reconciliation. Persistence module subscribes to these events.

**Restart behavior:** on daemon restart, hydrate the in-memory orchestrator state for any run whose most recent state transition is non-terminal. SPEC §7.4 already calls for tracker-driven recovery; SQLite makes recovery cheaper because the orchestrator does not have to re-derive run history from Linear alone.

---

## History dashboard tab

Adds `/history` to the existing Phoenix LiveView dashboard. Default view: list of recent runs (last 100), filterable by issue identifier, project, final state, date range. Each row links to a run-detail page showing:

- Workpad comment text (cached from Linear at run end; stored in `runs.workpad_cache` text column).
- Per-session summary (one paragraph generated by a small LLM call after run end; cached).
- State transition log (rendered from `state_transitions`).
- Pointer to the workspace logs file on disk.

Run-summary generation: a small model is called at run end to summarize the session log into a one-paragraph "what happened." Cached in the runs table so the dashboard renders past runs without live LLM access.

**v1 summary model:** Codex with a short summarization prompt against the session log file. v2 may switch to a cheaper dedicated summary model.

---

## Trust model and sandbox

- **Sandbox:** `thread_sandbox: danger-full-access`, `turn_sandbox_policy.type: dangerFullAccess`, `shell_environment_policy.inherit=all`. Documented trade-off.
- **Merge gate:** human review at `In Review`. The harness opens draft PRs only and never merges. The adversarial review pass is a quality gate, not a trust gate.
- **Auth:** GitHub token via `GH_TOKEN`/`GITHUB_TOKEN` env, exported by the operator before harness launch. Linear API token via `LINEAR_API_KEY` env. No tokens written to `WORKFLOW.md`, SQLite, or any committed artifact.
- **Network:** enabled by sandbox setting. Outbound HTTPS only; no inbound exposure beyond the localhost-bound LiveView dashboard.
- **Operator action:** still required to launch the daemon, apply the queue-gate label, and approve at `In Review`. The harness is autonomous between those bookends only.

---

## Phase 0 build order (sequenced)

Each step depends on the previous.

1. **Done during pilot.** `tracker.labels` filter merged into the Symphony fork.
2. **Linear team config.** Add `Adversarial Review` state to the team workflow. Update workflow config's `active_states` list to include it.
3. **Step 0.5 prompt.** Author the spec sufficiency triage step in `WORKFLOW.md`. Validate the rubric by running it against a sample of existing underspec'd tickets and confirming FLAG fires correctly.
4. **Reviewer dispatch.** Wire reviewer agent dispatch in the Symphony fork. Trigger on `In Progress` to `Adversarial Review` transition observed via Linear reconciliation. Spawn a fresh Codex session with the reviewer prompt.
5. **Reviewer prompt.** Author the reviewer prompt body. Test retroactively on the pilot's PR. Tune the rubric until findings are actionable and not noise.
6. **SQLite persistence.** Add Ecto repo, migrations, schema. Hook into orchestrator events. Verify daemon-restart hydration.
7. **History dashboard.** Add LiveView page at `/history` with filterable run list and run-detail view. Wire up the per-run summary call at run end.
8. **Label migration.** Rename `symphony` to `agent-ready` on existing eligible tickets via a one-time script.
9. **Second pilot.** Run a second ticket end-to-end through the new pipeline. Document findings as a follow-on post-mortem to validate or revise the architecture before any external rollout.

---

## Out of scope for v1 (explicit deferrals)

- Multi-model dispatch by label.
- Auto-merge after adversarial review.
- Custom Codex seatbelt profile (replacing dangerFullAccess).
- Containerization per agent.
- Cross-tracker support.
- Reviewer-model rotation.
- Token cost budgets / spend limits.
- Public or remote-access dashboard.
- Cross-repo coordination (one harness instance per target repo for v1).

---

## Open questions for review

1. **Queue-gate label naming.** `agent-ready` is the proposed v1 label. Alternatives: `agent-eligible`, `auto`, `harness`. Pick one before the migration step (Phase 0 step 8).
2. **Reviewer's PR-diff access path.** `gh pr diff <n>` from the reviewer's workspace is simpler. The Linear GraphQL tool's GitHub attachment integration may offer richer metadata but breaks if attachment URLs are temporary. Defaulting to `gh`.
3. **Workspace lifetime during adversarial review.** Worker workspace persists for the reviewer in v1. v2 may switch to cold review with a fresh clone. Worth empirically testing in the second pilot whether warm vs. cold review changes the finding rate.
4. **Per-run summary model choice.** Defaulting to Codex with a short summarization prompt for v1, since Codex is already in the harness. Alternative: a cheaper dedicated summary model. Defer the cost optimization until run volume is real.
5. **`.codex/skills/` directory location.** Currently vendored into each target repo. Stays vendored for v1; multiple repos becomes a maintenance issue at v2 scale and may move to a shared registry.
6. **Naming the harness as a product.** Currently unnamed. Decision needed before any external-facing artifact (customer-facing material, public fork, public repo). Not a Phase 0 blocker; needed before external announcement.
7. **Should `harness-blocked` move tickets to `In Review` or to `Backlog`?** v1 default: `In Review`, because a human triages whether the block is real or environmental. Alternative: `Backlog` with a comment. Affects how operators discover blocked tickets.

---

## What this is NOT

- This is not the agent-native workflow PRD. The PRD covers product framing, market thesis, and partner motion. This document covers v1 build architecture only.
- This is not the post-mortem. The post-mortem captures the empirical results from the bare-harness pilot.
- This is not a final spec. It is a first-pass draft with sane defaults. The open-questions section identifies decisions that need to be resolved before Phase 0 is complete.
