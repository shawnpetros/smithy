# AGENTS.md (Smithy-managed repo)

This repo is operated by Smithy v2.1. Read this file before any work.

Smithy is a multi-mode, multi-runtime agent harness forked from OpenAI Symphony.
Workers spawned against this repo come in three modes: `builder` (implements
tickets), `reviewer` (audits PR diffs), and `triager` (spec-quality gate).

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

When you finish your turn, write the appropriate handoff file at the workspace
root. The orchestrator parses these to decide the next state transition.

### Builder mode

Optional. Workpad is the primary handoff. If you write `RESULT.md`, follow this
shape:

```markdown
---
status: complete | partial | blocked
summary: |
  One paragraph of what shipped.
follow_ups:
  - title: "..."
    description: "..."
---
```

### Reviewer mode

Required. Write `REVIEW.md`:

```markdown
---
status: pass | fail
findings:
  - finding: "lens-prefix: specific issue"
    grade: blocker | polish | future
notes: |
  Longer prose context. Optional.
---
```

Rules:

- `status: fail` requires at least one `blocker` grade.
- `polish` and `future` findings keep `status: pass` (advisory only).
- Unknown grades reject the REVIEW.md.

### Triager mode

Required. Write `TRIAGE.md`:

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

`decision: flag` requires non-empty `gap_comment`.

## Linear state transitions

Workers DO NOT transition Linear state. The orchestrator owns all state moves.
Workers communicate intent via the handoff artifacts above.

Standard flow:

```
Backlog -> Todo -> (triager?) -> In Progress -> (reviewer?) -> Adversarial Review
                                                            -> Human Review
                                                            -> Merging -> Done
                                                            \-> Rework (loop)
```

## Tool restrictions

Workers operate with `--disallowedTools` filtering on Linear write tools:

- `mcp__linear__save_*`
- `mcp__linear__create_*`
- `mcp__linear__delete_*`

The orchestrator owns these. You communicate intent through workpad and handoff
files, not direct Linear writes.

## Validation

Before declaring work done, run repo-specific test commands. Common patterns:

- Elixir: `mix test`, `mix credo --strict`, `mix compile --warnings-as-errors`
- Rust: `cargo test`, `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`
- Node: `npm test`, `npm run lint`

The repo's `WORKFLOW.md` declares the canonical validation commands. Follow
them strictly. If a test fails, that's a blocker, not a polish finding.

## Branch and commit conventions

- Branch: `smithy/<ticket-id>-<short-slug>` (e.g., `smithy/per-150-rename`)
- Commit messages: imperative present tense subject ("add X behavior", not
  "added X behavior"). Body explains the why, not the what.
- Trailer line: `Co-Authored-By: Smithy <noreply@smithy.local>` (post-OAuth
  identity rollout this becomes the configured service account)

## Confusions

If something is unclear, ambiguous, or surprising during your turn, append a
note to the workpad's `### Confusions` section before exiting. The next worker
(or human reviewer) reads it before planning.

If a ticket is fundamentally underspecified for autonomous work, write a
TRIAGE.md with `decision: flag` and a clear `gap_comment`. Do NOT guess; flag
and let a human re-spec.

## Repo-specific rules

Append below this line. The above is the Smithy-managed prefix.

---
