---
status: fail
findings:
  - finding: Architecture is fundamentally wrong; the entire state machine is inverted and cannot be incrementally patched.
    grade: rebuild-from-scratch
  - finding: No test coverage for the happy path.
    grade: blocker
notes: |
  The core design assumption is broken. Incremental fixes will not get this to a shippable state.
  Start over from the spec.
---

Optional human-readable context the orchestrator ignores.
