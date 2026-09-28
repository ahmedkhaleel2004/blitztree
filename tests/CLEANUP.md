# Cleanup regression checks

Run `tests/run-cleanup.sh` on macOS with the project's Rust and Swift toolchains.
It compiles the production cleanup code, scans a disposable fixture with the Rust
engine, and checks:

- exact command arguments and rejection of extra flags or shell syntax;
- protected paths, symlink components, path replacement and verified Data-volume aliases;
- scan membership, known cache paths, measured sizes and final-plan changes;
- identity checks before moving or deleting an item;
- partial deletion failures, retained receipts and symlink children.
- upstream compatibility: Codex chat paths, exact single-simulator commands,
  and countdowns that retain running commands and failed Trash receipts.

Simulator commands use one UUID, never `all`, `booted`, or extra arguments.
Like other tool commands, their listed paths must occur in the scan, their sizes
come from that scan, and they require explicit selection. Runtimes outside the
scan remain blocked; this change does not add a separate simulator inventory.

All filesystem mutations remain inside temporary fixtures. Moves use a fixture
directory in place of the user's Trash; no cleanup tool, agent or GUI is launched.
The cloud-only fixture check is explicitly skipped if macOS will not set
`SF_DATALESS` on the temporary file system. The policy still rejects that flag.

The existing offline integration checks also apply:

```sh
benchmarks/run-agent.sh --check-only
benchmarks/run-ui.sh --check-only
```

The guards revalidate metadata immediately before filesystem operations. They do
not provide an atomic filesystem sandbox against concurrent hostile changes.
Agent startup, provider access and installation behavior are outside these checks.
