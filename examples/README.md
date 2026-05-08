# examples/

Working example workflows for Smithy. Copy, adapt, drop into your project root as `WORKFLOW.md`.

## chatbot-demo-workflow.md

Wired against [`shawnpetros/anvil-demo-chatbot`](https://github.com/shawnpetros/anvil-demo-chatbot), a minimal Vite + React chatbot reference. Demonstrates two of Smithy's alpha-0 differentiators over vanilla Symphony:

- **`tracker.labels` queue gate** (Smithy adds this; Symphony picks up any ticket in the configured states): only Linear issues carrying the `anvil-demo` label are eligible for dispatch. Use this when one Linear team mixes harness-driven work with human-only work.
- **`Adversarial Review` state passthrough** in the workflow body: the build worker transitions to `Adversarial Review` instead of `Human Review` when the PR is ready, leaving an integration slot for an external reviewer agent (e.g. [Anvil](https://github.com/shawnpetros/anvil)). Smithy alpha-0 ships the state slot; the in-process cross-model reviewer lands in alpha-1.

To adapt for your own repo:

1. Copy `chatbot-demo-workflow.md` to your repo root as `WORKFLOW.md`.
2. Replace `tracker.project_slug` with your Linear project slug.
3. Replace `tracker.labels` with whatever label gates your queue.
4. Replace the `hooks.after_create` block with the clone + install commands for your repo.
5. Adjust the prompt body and instructions for your stack.
