# Security Review — BlitzTree v0.5.1

Reviewed from commit `6e8483a` (2025). Scope: the AI-cleanup pipeline
(`app/Agent.swift`, `app/Cleanup.swift`), the FFI boundary (`src/ffi.rs`),
the scan engine (`src/lib.rs`, `src/cleanup.rs`), and the build/release
scripts.

## Architecture verdict

The trust model is sound: **the LLM proposes, the app disposes.** All
destructive capability lives behind code-enforced guards
(`CleanupGuard`), the agent runs read-only (Claude Code
`--permission-mode dontAsk` with a `du`/`ls`/`stat`/`Read`-only tool
allowlist; Codex with `"sandbox": "read-only"`, `approvalPolicy: never`
on an ephemeral thread in an empty working folder), and deletion is
two-step: Trash → delete-for-good, where step two removes only the URLs
recorded from `trashItem`'s own output. Shell commands run through a
fixed allowlist plus a metacharacter ban (`; | & > < \` $ \n * \\`).

The v0.5.x additions are genuine improvements: the "Managed by macOS"
refusal for Apple containers/caches, the `recentlyUsed` guard that
protects build folders of projects touched in the last two days, and the
new JSON CLI in `src/cleanup.rs` with Python tests covering symlink
traversal and untrusted-name escaping.

## Findings (still open in v0.5.1)

### S1 — Path blocklist gaps: `~/Library/LaunchAgents` and peers are unprotected (Medium)

`CleanupGuard.protected` / `tooBroad` omit several sensitive `~/Library`
subfolders. A two-component path such as `~/Library/LaunchAgents` or
`~/Library/Cookies` passes the depth check (`rel.split("/").count >= 2`)
and is not an exact `tooBroad` match, so a hallucinating or injected
agent can get it into a plan. Files beneath (3 components) pass too.

Affected (non-exhaustive): `Library/LaunchAgents`, `Library/LaunchDaemons`,
`Library/Cookies`, `Library/Logs`, `Library/Saved Application State`,
`Library/Spelling`, `Library/Frameworks`, `Library/PrivilegedHelperTools`,
`Library/ScriptingAdditions`, `Library/Internet Plug-Ins`,
`Library/PreferencePanes`, `Library/Input Methods`, `Library/Fonts`,
`Library/Services`, `Library/StartupItems`, `Library/Tokens`,
`Library/Autoypt`-like helper dirs — anything that can alter app
behavior or persistence should be listed.

Recommendation: invert the logic for `~/Library` — deny by default and
allow only named subfolders known to be rebuildable — or add the full
sensitive set to `tooBroad`.

### S2 — No re-validation at action time (TOCTOU) (Medium)

`CleanupGuard.blockReason` runs once, while the plan is streaming
(`PlanItem.init`). `AgentRun.moveToTrash()` later re-checks only
`FileManager.fileExists`. Minutes can separate validation from action;
a path that becomes protected in between (or fails a re-check) is
trashed anyway. `Self.trash(_:)` at `app/Agent.swift` performs zero
guard checks.

Recommendation: re-run `blockReason(path:)` immediately before each
`trashItem` inside `Self.trash`, and `blockReason(command:)` inside
`runCommand`, failing the item closed.

### S3 — Guards are lexical; symlinks are not resolved (Low)

`blockReason` uses `standardizingPath` only. `trashItem` follows a
symlink in the last path component, so a symlink pointing into
`~/Documents` passes the protected-prefix check on string match.
Recommendation: `resolvingSymlinksInPath()` before the checks (and
check the resolved path, not just the lexical one).

### S4 — Child processes inherit Full Disk Access (Low, document)

Everything BlitzTree spawns — the agent CLIs and each allowlisted
cleanup command — inherits the app's TCC grant. A malicious binary
earlier in the login-shell PATH (e.g. a fake `uv` in `~/.local/bin`,
which the app deliberately appends) runs with full-disk read.
Mitigation: prefer absolute paths from a fixed search order for the
cleanup commands; document the trust assumption for the agent CLIs.

### S5 — Codex installer has no checksum (Low)

`AgentSetup.installScript` fetches the Codex tarball from GitHub
`releases/latest` with no checksum or signature verification and
installs it into `~/.local/bin`, from which it runs as an
FDA-inheriting child. Pin a known SHA-256 (or verify against a
checksum fetched from a second source) before `mv` into place.

### S6 — Command allowlist prefix matching admits extra arguments (Low)

`ollama rm <model>` (and friends) pass via `hasPrefix`; additional
arguments or flags to the tool are not excluded. Prefer exact-match
for commands that take no argument, or tokenize and validate.

## Verified non-issues

- FFI interior pointers are valid only until `bz_free`; freeing before
  the scan thread finishes is safe (the thread holds `Arc` clones).
- Scan engine is read-only; hard-link dedup via `(dev, fileid)`;
  dataless (iCloud) and mount-point directories are never descended.
- No telemetry; the app itself never goes online.
- The Rust JSON CLI resolves explicit symlink roots and escapes
  untrusted names (covered by `tests/test_cli.py`).
