# cli-anything-blitztree tests

## Plan

Unit tests in `tests/CLIAnythingChecks.swift` call `Harness.prepare`, `Harness.split` and `Harness.render` in process. They cover unknown commands, duplicate and misplaced flags, empty values, a value that starts with `-`, non-ASCII digits, limit and timeout bounds, quote splitting, and the engine argument vector for `scan` and `cleanup list`.

Subprocess tests launch the built `cli-anything-blitztree` binary:

- `--help` and a `--json` usage error
- a missing engine, including `BLITZTREE_BIN` set to a path that is not executable (no PATH fallback)
- a relative `PATH` entry that contains `blitztree`, which must be ignored
- an absolute `PATH` entry, which is used when nothing sits beside the front
- `blitztree-engine` beside the front, which wins over an absolute `PATH` entry
- a fake engine whose stdout is copied through unchanged, including a non-zero exit
- an engine that sleeps past `--timeout`
- session record, `session status` and `session clear`, including a refusal to follow a symlink file or a symlink session directory, and a session created under an ancestor symlink
- human-readable output containing the reported path
- a scripted REPL (`status`, then `exit`)

End to end, against the real `blitztree` binary built with `--features cli`:

- `scan` of a temporary directory that holds one file, with stdout compared byte for byte to that same engine invocation and the engine's argument vector checked
- `cleanup list` of a large `node_modules` directory

A harness failure must be a non-zero exit. A missing engine is not reported as an empty successful scan.

The process exits on the first failed check, so a passing run covers the plan above: the `scan` stdout matches the engine's own stdout for the same invocation, and the engine receives `scan`, `--root`, the fixture path, `--min-bytes`, `1`, `--limit`, `20`.
