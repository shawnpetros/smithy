---
decision: flag
reasons:
  - "Where: identifies the user dashboard area but no specific module path"
  - "What: 'improve performance' is not a concrete delta"
  - "Acceptance: no testable criterion (no benchmark, no target metric)"
  - "Ambiguity: at least three plausible implementations (caching, query rewrite, pagination)"
gap_comment: |
  This ticket cannot be executed autonomously in its current form. Specific gaps:
  - Target module is unspecified. The dashboard spans lib/symphony_elixir/status_dashboard.ex, the LiveView modules, and the Presenter; pick one.
  - 'Improve performance' lacks a measurable target. Provide a baseline (e.g. p95 render time) and the target delta.
  - No testable acceptance criterion. Suggest a regression assertion or a benchmark threshold the builder can wire into the test suite.
  To re-queue: address the gaps above, remove `needs-spec`, add `agent-ready`,
  and move to Ready for Dev.
---

Triager notes (body text below the closing fence is informational and not
parsed by the orchestrator).
