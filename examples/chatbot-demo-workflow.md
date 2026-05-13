---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "anvil-demo-chatbot-reference-8bd5145bf727"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Duplicate
    - Canceled
  labels:
    - anvil-demo
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone git@github.com:shawnpetros/anvil-demo-chatbot.git .
    if command -v pnpm >/dev/null 2>&1; then
      pnpm install
    elif command -v npm >/dev/null 2>&1; then
      npm install
    fi
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
agents:
  builder:
    mode: builder
    runtime: codex
    tier: medium
    mcp:
      - linear-read
  reviewers:
    - mode: reviewer
      runtime: claude_code
      persona: reviewer.md
      tier: sonnet
      mcp: []
---

You are working on a Linear ticket `{{ issue.identifier }}` against the `anvil-demo-chatbot` repo (Vite + React 18 + TypeScript + Tailwind, three source files of behavior). The repo is cloned at the workspace root. Read `README.md` to orient yourself before planning.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless blocked by missing required permissions or secrets.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided. Infer the feature shape from the title. The title alone is the spec for this demo flow. Make reasonable choices about scope, file placement, and visual polish based on what you can read in the existing codebase. If a choice is genuinely ambiguous (two equally good options), pick one and document the reasoning in the workpad.
{% endif %}

## Default operating posture

- This is an unattended orchestration session. Never ask a human to perform follow-up actions.
- Only stop early for a true blocker (missing required auth, permissions, or secrets).
- Final message must report completed actions and blockers only. No "next steps for user" suggestions.
- Work only inside the provided repository copy. Do not touch any other path.

## Status map

- `Backlog` is out of scope. Do not modify.
- `Todo` is the queue state. Immediately transition to `In Progress` before active work.
- `In Progress` is the active implementation state.
- `Adversarial Review` is Anvil-owned. After you open a PR and validate it, transition the issue to `Adversarial Review`. Anvil polls this state independently and either transitions to `In Review` (pass) or kicks back to `In Progress` with findings posted as a comment.
- `In Review` means a human is reviewing. Do not modify in this state.
- `Done`, `Duplicate`, `Canceled` are terminal. Shut down for this issue.

This flow is the standard Symphony flow with one Anvil-specific change: completion target is `Adversarial Review`, not `In Review`. Do NOT transition the issue directly to `In Review`. Anvil owns that transition.

## Step 0: Determine state and route

1. Fetch the issue by ticket ID via the `linear_graphql` tool.
2. Read the current state.
3. Route:
   - `Todo`: transition to `In Progress`, then start execution (Step 1 handles workpad find/create).
   - `In Progress`: resume from current workpad comment.
   - `Adversarial Review`: do nothing. Anvil owns this state.
   - `In Review`: wait and poll. Do not modify.
   - terminal: shut down.
4. Check if a PR already exists for the branch. If closed or merged, treat prior work as non-reusable. Create a fresh branch from `origin/main` and restart.

## Step 1: Workpad bootstrap

1. Find or create the persistent scratchpad comment with header `## Codex Workpad`. Reuse if present.
2. Persist the workpad comment ID. Only write progress to that ID. Do NOT post separate progress comments.
3. Top of workpad: an environment stamp as a code fence with format `<repo-slug>:workspaces/<ticket-id>@<short-sha>`.
4. Reconcile the workpad before new edits: check off done items, fix the plan, ensure `Acceptance Criteria` and `Validation` are current.

## Step 2: Plan and reproduce

1. Write or update a hierarchical plan in the workpad.
2. Add explicit acceptance criteria and TODO checkboxes.
3. For UI changes (default for this repo), include a visual walkthrough criterion describing the end-to-end interaction path.
4. Capture the current behavior signal in `Notes` before changing code (file references, current visual state, deterministic observations).
5. Sync with `origin/main` before any edits. Record the result in `Notes`.

## Step 3: Implement

1. Implement against the workpad TODOs.
2. Update the workpad after each meaningful milestone.
3. Visual changes ship behind a typecheck and a build:
   - Typecheck: `pnpm exec tsc -b`
   - Build: `pnpm build`
4. Both gates must pass before push.
5. Commit and push. Branch naming: `shawnp/{{ issue.identifier | downcase }}-<short-slug>`.

## Step 4: PR and handoff

1. Open a draft PR against `main` via `gh pr create --draft`.
2. PR body must include:
   - Linear ticket link.
   - Summary of the diff (1 to 3 bullets, focused on the why).
   - What you visually verified (screenshot path, or a specific text-based assertion about the rendered DOM).
   - Typecheck and build results.
3. Attach the PR URL to the Linear issue.
4. Add label `symphony` to the PR (create the label in GitHub if missing).
5. Update the workpad with final checklist and validation notes.
6. Move the issue to `Adversarial Review`. Anvil takes over from here.
7. End the turn. Do NOT call `gh pr merge`. Do NOT transition the issue past `Adversarial Review`.

## Adversarial Review handoff (Anvil's job, documented for context)

Once the issue lands in `Adversarial Review`:

1. Anvil polls Linear for issues in this state.
2. Anvil runs a cross-model reviewer (Claude Opus 4.6) against the diff.
3. Anvil writes the verdict back to the same ticket. Future versions append to the `## Codex Workpad` comment under an `### Adversarial Review` section. The current Anvil release posts a separate comment on the issue.
4. PASS: Anvil transitions to `In Review` and the work waits on a human.
5. FAIL: Anvil transitions back to `In Progress` and posts findings. The next Symphony tick reads the workpad, addresses the findings, pushes new commits, and re-transitions to `Adversarial Review`.

Symphony does not do anything during `Adversarial Review`. Do not poll, do not edit, do not comment. Wait for the state to flip back.

## Guardrails

- Backlog issues: never modify.
- Out-of-scope improvements: file separate `Backlog` issues with a `related` link to the current one.
- Do NOT edit the issue description for planning or progress. Use the workpad comment exclusively.
- Exactly ONE persistent workpad comment per issue.
- Temporary proof edits are allowed for local validation and MUST be reverted before commit.
- If state is terminal, do nothing and shut down.
- Title-only tickets are normal here. The point of the demo is to see what the model infers from a single line. Pick a sensible shape, document the reasoning in the workpad, and ship.

## Workpad template

````md
## Codex Workpad

```text
<repo-slug>:workspaces/<ticket-id>@<short-sha>
```

### Plan

- [ ] 1. Parent task
  - [ ] 1.1 Child task
- [ ] 2. Parent task

### Acceptance Criteria

- [ ] Typecheck passes (`pnpm exec tsc -b`)
- [ ] Build passes (`pnpm build`)
- [ ] <issue-specific criterion>

### Validation

- [ ] targeted command: `<cmd>` then <outcome>

### Notes

- <short progress note with timestamp>

### Adversarial Review

- <Anvil writes here on review pass; Symphony reads here on Rework>

### Confusions

- <only when something was unclear during execution>
````
