# S3 — Resolve symlinks before guard checks

**Severity:** Low
**Source:** security-review-v0.5.1.md, finding S3

## Problem

`blockReason(path:)` uses `(path as NSString).standardizingPath` only —
a purely lexical transformation. `FileManager.trashItem` follows a
symlink in the final path component, so a path whose last component is
a symlink pointing into a protected folder (e.g. `~/Documents`) passes
the protected-prefix check on string match while the action lands on
the protected target.

## Fix

In `blockReason(path:)`, resolve before matching:

```swift
let p = (path as NSString).resolvingSymlinksInPath
    .standardizingPath
```

Keep the existing `.git` and running-app checks after resolution. Note
`resolvingSymlinksInPath` also expands `~` internally; verify home
prefix logic still matches after resolution.

## Acceptance criteria

- [x] A symlinked path resolving into any `protected` folder is
      blocked.
- [x] Ordinary paths behave identically to today.
- [x] Check interaction with `PlanItem`'s `expandingTildeInPath`
      (already applied upstream of the guard). *(No conflict:
      `resolvingSymlinksInPath` re-expands `~` the same way the
      `NSHomeDirectory`-based prefix check expects.)*
