---
status: fail
findings:
  - finding: Parser panics on empty input; null-check missing in decode path.
    grade: blocker
  - finding: Rename `do_parse` to `parse_content` for clarity.
    grade: polish
notes: |
  Core logic is sound but the null-input crash is a production risk.
  Incremental fix; no need to restart from scratch.
---

Optional human-readable context the orchestrator ignores.
