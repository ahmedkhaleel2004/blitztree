# S2 — Re-validate guards at trash/command time (TOCTOU)

**Severity:** Medium
**Source:** security-review-v0.5.1.md, finding S2

## Problem

`CleanupGuard.blockReason` runs exactly once, while the plan is still
streaming (`PlanItem.init`). The destructive steps run later:
`AgentRun.moveToTrash()` → `Self.trash(_:)` re-checks only
`FileManager.fileExists`, and `Self.runCommand` checks nothing. Minutes
can separate validation from action; anything that changed in between
is acted on anyway. Fail-open on a check that only exists at plan time.

## Fix

- Inside `Self.trash(_:)`: re-run `CleanupGuard.blockReason(path:)`
  for each path immediately before `trashItem`; on any non-nil reason,
  skip the path and fail the item with that reason.
- Inside `Self.runCommand`: re-run `CleanupGuard.blockReason(command:)`
  before spawning the process; fail closed.
- Dry-run path (`BZ_DEMO_DRYRUN`) unchanged.

## Acceptance criteria

- [x] `trash()` refuses to trash a path that `blockReason(path:)`
      rejects, even if the plan accepted it.
- [x] `runCommand` refuses a command the guard rejects.
- [x] No duplicate user-visible double-blocking: items blocked at plan
      time never reach the trash loop (behavior unchanged for them).
