# S4 — Document FDA inheritance to child processes

**Severity:** Low (documentation)
**Source:** security-review-v0.5.1.md, finding S4

## Problem

Everything BlitzTree spawns — the agent CLIs and each allowlisted
cleanup command — inherits the app's Full Disk Access TCC grant. A
malicious binary earlier in the login-shell PATH (e.g. a fake `uv` in
`~/.local/bin`, which the app deliberately appends to PATH in
`AgentEnvironment`) would run with full-disk read. The agent CLIs'
"sandbox" settings are CLI-level policy, not an OS guarantee, for
anything they spawn.

## Fix (docs only)

- Add a short "Trust & permissions" section to the README: what FDA
  is needed for, that spawned tools inherit it, and that cleanup
  commands are resolved through the user's shell PATH by design
  (tools live in Homebrew, `~/.local/bin`, nvm…).
- Where practical, prefer absolute paths from a fixed search order for
  allowlisted cleanup commands; document the residual trust in the
  user's own PATH.
