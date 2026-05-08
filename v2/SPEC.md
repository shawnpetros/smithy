# Smithy v2 Architecture Spec

**Status:** Draft. The polished v2 design that the public release of Smithy is built against.
**Authors:** Shawn Petros, with Claude (Anthropic Opus 4.7) as paired engineer.
**Inputs:**
- `history/2026-05-06-v1-pilot-spec.md` (the v1 cut, authored after running an end-to-end Symphony pilot against a real Linear ticket)
- Pilot post-mortem (private)
- Session transcript dated 2026-05-06 where the v2 wishlist was articulated

> **Symphony** in this document refers to OpenAI's open-source coding-agent harness (github.com/openai/symphony, Apache-2.0). It polls an issue tracker (Linear in this version), creates a per-issue workspace, and runs an OpenAI Codex CLI session against each ticket via Codex's app-server mode. Workflow is configured via a single `WORKFLOW.md` file. Smithy v2 is a fork of Symphony with targeted opinion layers.

---

## Goal

Smithy v2 is a fork of OpenAI Symphony plus a layered set of opinions that make it usable as a polished, multi-tenant agent harness. v2 promotes most of what Symphony's spec deferred to "future work" into shipping defaults:

1. Dual agent runtimes (Claude Code AND Codex) selected per ticket via label.
2. Cross-model adversarial review (different model family reviews than builds).
3. Spec sufficiency triage at the front of the queue, dropping bad tickets out before they reach a builder.
4. Linear OAuth identity so Smithy commits, comments, and state moves audit-trail to a service account, not a personal API key.
5. Label-gated autonomous merge (opt-in, label-scoped) and label-driven runtime routing.
6. SQLite-backed run history with model-summarized logs surfaced in the dashboard.
7. Token cost tracking with per-tenant rollups and spend-cap alerts.
8. Max-retry circuit breaker with `harness-blocked` escalation.
9. Bootstrap-PR pattern for new target repos (`smithy bootstrap <repo>`).
10. Workpad reuse: a single per-ticket comment thread with progress notes (Symphony's native pattern, kept).

The v1 spec in `history/` was the conservative cut. v2 is the all-in-one.

---

## Why fork

Symphony's polish is real. Its Phoenix LiveView dashboard, Codex app-server integration, supervised polling loop, per-issue workspaces, and structured logging are six months of OpenAI's engineering effort that Smithy gets for free. Reproducing that surface in Rust would burn weeks for parity, before adding any opinion layer.

The fork inherits Symphony's bones. Smithy v2 adds the opinions on top:

| Symphony provides | Smithy v2 adds |
|---|---|
| Polling loop, per-issue workspaces, dispatch with bounded concurrency | Dual-runtime dispatch (Claude Code + Codex) |
| Codex app-server runtime | Claude Agent SDK runtime, label-driven routing |
| Phoenix LiveView dashboard | SQLite-backed history tab, model-summarized run logs, cost rollups |
| `WORKFLOW.md` state machine | Spec sufficiency triage step, Adversarial Review state |
| `tracker.labels` queue gate (added during v1 pilot, currently in fork only) | Full label vocabulary (`agent-ready`, `needs-spec`, `harness-blocked`, runtime labels, autonomous-merge label) |
| Personal-API-key Linear access | Linear OAuth client + Smithy service-account identity |
| `gh auth token` borrow | GitHub App identity |
| Codex sandbox seatbelt | Custom seatbelt profile (allow `.git/` writes + network only) |
| Per-issue retries with no ceiling | Max-retry circuit breaker with `harness-blocked` escalation |
| Persistent worktrees (good for warm review) | Configurable retention policy |

---

## Architecture overview

Smithy v2 keeps Symphony's elixir + OTP runtime intact. The opinion layer plugs in at four extension points: configuration schema, the `WORKFLOW.md` state machine, the dispatch worker, and the LiveView dashboard.

```
Ticket flow (v2):

[ agent-ready label applied by human ]
              |
              v
[ Ready for Dev ]
              |
              v
       spec quality gate (front-of-queue triage)
              |
        ----- ----- 
       |           |
       v           v
   FLAG (drop      PROCEED
   to Backlog
   + needs-spec)   |
                   v
        runtime selected by label
        (codex OR claude OR default)
                   |
                   v
[ In Progress ] (worker spawned, workpad comment opened, progress notes streamed)
                   |
                   v
[ Adversarial Review ] (different model family reviews)
                   |
        ----- ----- ----- 
       |           |     |
       v           v     v
   FAIL        PASS   BLOCKED
   (back to    |     (harness-blocked
   Todo with   |      label, In Review)
   findings)   |
               v
   [ autonomous-merge label set? ]
               |
        ----- -----
       |           |
       v           v
   YES (auto    NO (human
   merge +      review at
   close)       In Review)
                   |
                   v
              [ Done ]
```

---

## Core capabilities (v2)

### 1. Dual agent runtimes

Each ticket carries a runtime label that selects which agent stack handles it. Defaults to the configured `default_runtime` if no label is present. v1 supports `runtime/codex` (Codex CLI app-server mode, inherited from Symphony) and `runtime/claude-code` (Claude Agent SDK headless mode). Other runtimes can be added by extending the dispatch enum.

The runtime decision is captured at dispatch time and recorded in the run row so history queries can group by runtime.

### 2. Cross-model adversarial review

Adversarial review runs in a separate model family from the build. If the build was Claude Code, review is Codex (or whatever model family is configured for review of Claude builds). If the build was Codex, review is Claude. The persona swap is via prompt; the model swap is via configured pairing in `WORKFLOW.md`.

The review agent receives the diff via `gh pr diff <n>` from a fresh clone of the workspace at the build commit. Warm-workspace review (current behavior) was empirically tested; cold-clone review is the v2 default because it forces the review to read the diff rather than navigate the workspace mid-build.

### 3. Spec sufficiency triage

A triage step at the front of the queue runs before dispatch. The triage agent answers four questions about the ticket:

- **Where:** is the file / module / feature unambiguously identified?
- **What:** is there a clear delta requested (feature, fix, refactor, doc) and a clear scope?
- **Acceptance:** is the success criterion testable or otherwise verifiable?
- **Ambiguity:** are there punt phrases ("we should discuss," "TBD"), missing product decisions, or multiple plausible implementations?

If any answer is no, the triage agent FLAGs the ticket: applies the `needs-spec` label, removes `agent-ready`, moves to Backlog, and posts a structured gap comment listing which questions failed.

If all four pass, triage exits and dispatch proceeds.

Trivial tickets (typo fixes, version bumps, obvious one-liners) bypass triage if the title alone is sufficient spec; the triage prompt has a proportionality clause.

Triage actions are atomic: one model turn, then the triage agent ends. Failed triage does not retry; the ticket sits in Backlog until a human re-specs and re-applies `agent-ready`.

### 4. Adversarial review pass

After the build worker exits with a PR open, the orchestrator transitions the Linear ticket to `Adversarial Review`. This triggers the reviewer agent (cross-model per §2). The reviewer evaluates the diff against the spec on a structured rubric: correctness, scope creep, security implications, test coverage, and red-flag patterns documented in the target repo's `AGENTS.md`. The reviewer writes `REVIEW.md` with a structured PASS / FAIL / BLOCKED verdict.

- PASS: orchestrator transitions to `In Review` (or to `Done` if the autonomous-merge label is set, see §5).
- FAIL: orchestrator transitions back to Todo with findings appended to the workpad comment under `### Adversarial Review` (see §11). The next build attempt reads that section as authoritative review feedback.
- BLOCKED: orchestrator applies `harness-blocked` label, transitions to `In Review`, posts the block reason in the workpad. Human triages.

Independent context: the reviewer runs in a fresh model session, with no prompt visibility into the build worker's reasoning. The reviewer sees only the diff, the spec (Linear ticket body and comments), and the repo's `AGENTS.md`.

### 5. Label-gated autonomous merge

A ticket carrying the `auto-merge` label, when it passes adversarial review, is merged and closed automatically. No `In Review` human gate. This is opt-in per ticket.

The `auto-merge` label is human-applied. The harness never sets it. Operators apply it for low-risk changes (dependency bumps, doc updates, isolated bug fixes with full test coverage). For higher-risk work, leave the label off and the human review at `In Review` is required as in v1.

This is the "we don't want that kinda craziness yet, but it should be capable" capability.

### 6. Linear OAuth identity

Smithy authenticates to Linear as a service account via OAuth, not as the operator's personal API key. Commits, ticket comments, state transitions, and label edits audit-trail to a "Smithy" identity. Operators can revoke Smithy's OAuth grant without invalidating their own API key.

Setup is one-time per Smithy installation: an admin runs `smithy auth setup` which walks through the OAuth flow and stores the refresh token in the operator's keychain. The orchestrator reads the access token at startup and refreshes as needed.

The OAuth scope is constrained: read tickets and labels, comment, transition state, apply or remove a label whitelist (defaulting to the four labels in §11). No admin scopes, no team management, no integration management.

GitHub identity follows the same pattern. Smithy installs as a GitHub App per target repo; the orchestrator authenticates as the installation. No personal `gh` token borrow in v2.

### 7. SQLite history + model-summarized logs

The dashboard gets a `/history` tab. Each row is a run, each click expands to a per-run detail view. Per-run detail shows:

- Linear ticket ID + title
- Runtime used (codex / claude-code / etc.)
- Outcome (pass / fail / blocked / cancelled)
- Token cost (input / output / total) per session within the run
- Model-summarized log: a short summary of what the agent did, generated by a small post-run summarization call against the full session log
- Link to the raw stream-json log file on disk

The model-summarized log is the headline upgrade. Reading raw stream-json is operator-hostile; a one-paragraph "what happened" summary makes the dashboard usable.

Persistence is SQLite via Ecto. Three tables: `runs` (one row per ticket attempt), `sessions` (one row per agent invocation, multiple per run when retries happen), `state_transitions` (one row per Linear state move). The `runs` table includes the cached workpad text and the run summary so the detail view does not need to re-summarize.

### 8. Token cost tracking + rollups

Every model call records its token usage and dollar cost. The dashboard surfaces:

- Per-run cost (visible on the run row)
- Per-day total (top-of-dashboard widget)
- Per-tenant rollup (when multiple Linear teams are configured, one rollup per team)
- Per-runtime cost share (codex vs claude vs other)

Spend-cap alerts trigger when a run exceeds the per-run cap (configurable, defaults to $5) or when the daily rollup exceeds the daily cap (defaults to $50). Alerts are non-blocking by default; the harness keeps running but logs a warning. Strict mode (config flag) blocks new dispatches when the daily cap is hit.

### 9. Max-retry circuit breaker

After N attempts (configurable, defaults to 3), the orchestrator stops retrying and applies `harness-blocked`, transitions the ticket to `In Review`, and posts a comment summarizing the failure modes across attempts. Workspace and branch are preserved so a human can pick up where the harness left off.

This closes the "no max-attempt count" footgun from the v1 pilot post-mortem.

### 10. Bootstrap PR pattern

For a target repo to be agent-ready, it needs `AGENTS.md` and (if Codex is used) `.codex/skills/`. v2 ships `smithy bootstrap <repo>` which clones the repo, generates the bootstrap files via a fresh agent session, and opens a PR with the bootstrap addition. Once that PR merges, the target repo is in the rotation.

This formalizes the closed-loop bootstrap learning from the pilot post-mortem.

### 11. Workpad reuse pattern

Symphony's native pattern: a single per-ticket comment thread on Linear, owned by the harness, where progress notes accumulate throughout the ticket's lifecycle. Triage outcome, dispatch start, build progress checkpoints, review verdict, merge / handoff outcome, all in one thread.

v2 keeps this pattern as-is. It's measurably better than the v1 approach of emitting separate comments per state transition. Reading one thread reads like a story; reading scattered comments reads like noise.

Section ownership inside the workpad:

- `### Plan`, `### Acceptance Criteria`, `### Validation`, `### Notes`: the build worker owns these. Reviewer reads but does not edit.
- `### Adversarial Review`: the reviewer owns this. Each review pass appends a dated subsection with PASS / FAIL / BLOCKED verdict and structured findings. On a FAIL bounce-back to Todo, the build worker reads this section first before re-planning.
- `### Confusions`: either agent may append.

Append semantics, not overwrite. Each iteration adds a new dated subsection rather than replacing the prior one. The workpad becomes a chronological record of the ticket's full lifecycle, including reviewer pushback and rebuild responses. Operators reviewing a ticket post-merge can read the full back-and-forth in one place.

---

## Linear state machine (v2)

```
Backlog ─▶ Ready for Dev ─▶ In Progress ─▶ Adversarial Review ─▶ In Review ─▶ Done
   ▲             │              │                │                  │
   │             │ FLAG          │                │ FAIL             │ auto-merge
   │             │ (needs-spec)  │                │                  │ (skip In Review)
   │             ▼              │                ▼                  │
   └────────────────────────────┴──────────────── Todo                │
                                                                      │
   harness-blocked ◀─── BLOCKED ◀───────── reviewer ─────────── max-retry circuit ◀─── (any state)
```

---

## Label vocabulary (v2)

| Label | Applied by | Effect |
|---|---|---|
| `agent-ready` | Human | Queue gate. Without this, the harness ignores the ticket. |
| `needs-spec` | Triage agent | Removes `agent-ready`, moves to Backlog. Ticket is parked until a human re-specs. |
| `harness-blocked` | Reviewer or circuit breaker | Moves to `In Review`. Human picks up. |
| `auto-merge` | Human (per ticket) | After review passes, merge and close without human gate. |
| `runtime/codex` | Human (per ticket) | Force the Codex runtime for this ticket. |
| `runtime/claude-code` | Human (per ticket) | Force the Claude Code runtime for this ticket. |

If neither runtime label is present, the configured `default_runtime` runs. If both are present, the dispatcher errors and posts a comment asking the operator to pick one.

---

## Trust model + sandbox

- **Merge gate:** label-driven. `auto-merge` skips human review; absence keeps the human gate.
- **Auth (Linear):** OAuth identity for Smithy as a service account. No personal API key in production.
- **Auth (GitHub):** GitHub App per target repo. No `gh` token borrow.
- **Worker isolation:** Codex runs in a custom seatbelt profile that allows `.git/` writes and network only. The full-access mode used in the v1 pilot is not the v2 default.
- **Tool denylist:** Linear API write tools are stripped from each spawned worker. Workers see Linear via MCP read-only. State moves come from the orchestrator.
- **Network:** outbound HTTPS only. Localhost-bound LiveView dashboard.
- **Operator action required:** OAuth setup (one-time), label application (per ticket), human approval at `In Review` unless `auto-merge` is set.

---

## Phase build order

Each phase depends on the previous. Phases below are spec-level, not Linear-ticket level. The actual Linear ticket queue should map roughly 1-to-1 with the bullets inside each phase.

### Phase 0: Fork prep

- Clone `openai/symphony` as the base of the new public Smithy v2 codebase.
- Add NOTICE file with Apache-2.0 attribution.
- Strip OpenAI-specific demo paths and any branding that isn't Smithy's to keep.
- Update Symphony's `mix.exs` package metadata to `:smithy`.
- Sweep for personal-leak content (paths, customer names, tenant UUIDs).
- Tag base commit as `v2.0.0-alpha-fork-base`.

### Phase 1: Configuration schema and label vocabulary

- Extend Symphony's config schema with the v2 label vocabulary.
- Implement label-driven dispatch (queue gate, runtime selection, auto-merge gate).
- Migrate the v1 pilot's `tracker.labels` filter into the formal schema.

### Phase 2: Spec quality gate

- Author the triage prompt (the four-question rubric).
- Wire triage as a step before dispatch in `WORKFLOW.md`.
- Add the FLAG action: apply `needs-spec`, remove `agent-ready`, move to Backlog, post structured comment.
- Test against a sample of underspec'd tickets.

### Phase 3: Dual runtime dispatch

- Add Claude Code runtime alongside the existing Codex runtime.
- Implement runtime selection from labels.
- Author the Claude Code worker prompt and disallowed-tools list.
- Verify both runtimes produce comparable handoff artifacts (`RESULT.md` shape).

### Phase 4: Adversarial review with cross-model swap

- Wire the Adversarial Review Linear state.
- Implement reviewer dispatch on the In Progress to Adversarial Review transition.
- Configure the cross-model pairing (Codex builds → Claude reviews; Claude builds → Codex reviews).
- Author the reviewer prompt and `REVIEW.md` schema.
- Test retroactively on the v1 pilot's PR.

### Phase 5: Persistence + history dashboard

- Add Ecto repo, migrations, schemas (`runs`, `sessions`, `state_transitions`).
- Hook orchestrator events into persistence.
- Add the `/history` LiveView page.
- Add the per-run summary call at run end.
- Cache run summary on the `runs` row to avoid re-summarization.

### Phase 6: Cost tracking + rollups

- Capture token usage on every model call.
- Compute per-run, per-day, per-tenant, per-runtime rollups.
- Add the dashboard widgets.
- Implement spend-cap alerts (warn mode in v2; strict mode opt-in).

### Phase 7: OAuth identity

- Build the OAuth flow for Linear (`smithy auth setup`).
- Build the GitHub App installation flow.
- Migrate the orchestrator to read OAuth tokens from the keychain.
- Document the per-installation setup process.

### Phase 8: Circuit breaker + bootstrap pattern

- Add max-retry circuit breaker.
- Add `harness-blocked` escalation path.
- Build `smithy bootstrap <repo>` command.
- Document the closed-loop bootstrap pattern.

### Phase 9: Sandbox hardening

- Author the custom Codex seatbelt profile (allow `.git/` writes + network).
- Test against the v1 pilot scenario to confirm builds still work.
- Make the custom seatbelt the v2 default; full-access becomes opt-in.

### Phase 10: Public release

- README, LICENSE, NOTICE, CONTRIBUTING, CODE_OF_CONDUCT.
- Hero image (already generated; see `assets/hero.png`).
- Quickstart walkthrough.
- Migration guide from vanilla Symphony.
- Tag `v2.0.0`.

---

## Out of scope for v2 (v3 candidates)

- Reviewer-model rotation (rotate among multiple model families instead of a fixed pair).
- Cross-tracker support (Jira, GitHub Issues, Asana). Linear-only in v2.
- Public or remote-access dashboard. Localhost-bound in v2.
- Multi-operator support (concurrent operators on the same Smithy installation).
- Hosted Smithy (managed-Smithy SaaS).
- Cross-repo coordination (one harness instance per target repo).
- Cost budgets per ticket (currently per-run / per-day caps; per-ticket spend ceilings deferred).

---

## Open questions

1. **OAuth client registration.** Public Smithy needs a published OAuth client ID for users to register against. Where does that live? A single Smithy-org client (operators register their own Linear workspace against it) or per-installation (each operator registers their own OAuth client). Single-org is simpler for users; per-installation is simpler for the maintainer. Defaulting to per-installation in v2; revisit if user demand surfaces.
2. **Custom seatbelt profile coverage.** The v1 pilot ran in `dangerFullAccess` mode. The v2 default seatbelt allows `.git/` writes and outbound network. Need to test against the v1 pilot scenario and confirm the build still passes. If gaps surface, document them and ship `dangerFullAccess` as a fallback config flag.
3. **Workpad reuse on retries.** When a ticket retries (FAIL back to Todo), does the workpad comment reset or continue accumulating? Continuing reads as a coherent story; resetting separates attempts. Defaulting to continuing.
4. **Per-tenant rollup definition.** What counts as a "tenant" when one Smithy installation drives multiple Linear teams? Currently defined as one rollup per Linear team. Could also be per-repo or per-label-group.
5. **Auto-merge revert path.** If `auto-merge` lands a bad change, how does the operator find out and roll it back? v2 ships a Slack/email alert on every auto-merged PR, with a one-line summary and the PR URL. v3 may add automated revert via a `revert` label.

---

## What this is NOT

- Not a from-scratch reimplementation. Smithy v2 is a Symphony fork with layered opinions.
- Not a workflow product on its own. Smithy is the harness layer. Higher-level workflow logic (multi-stage pipelines, routing rules, customer-specific orchestration) is the operator's responsibility and lives outside this repo.
- Not a hosted product. v2 is a local-install OSS tool. Hosted-Smithy is a v3-or-later question.
- Not a one-shot port. v2 is built phase by phase, with each phase shippable on its own. The phase ordering above is the recommended sequence; phases can ship in different orders if dependencies permit.
