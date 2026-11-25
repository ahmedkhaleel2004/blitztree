# cli-anything-blitztree

Swift command groups an agent can call to drive BlitzTree. The scan and Clean Up candidate rules are in the Rust `blitztree` engine. This program finds that executable, checks arguments, and prints the engine's JSON, or a short table of it.

`scan` and `cleanup list` are read-only. There is no delete command.

## Install

The engine:

```sh
cargo install --locked --path . --features cli --bin blitztree
```

The front, from the repository root:

```sh
zsh cli/build.sh
./build/cli-anything-blitztree --help
```

`./build.sh` installs this front and the engine at `BlitzTree.app/Contents/MacOS/`. The bundled engine is named `blitztree-engine`, because on a case-insensitive volume `blitztree` is the GUI executable `BlitzTree`. The front looks for the engine in this order: `BLITZTREE_BIN` when it is set, `blitztree-engine` beside itself, then an absolute `PATH` entry named `blitztree`. A relative `PATH` entry is ignored. A `BLITZTREE_BIN` that is set and not an executable file is an error, and the front does not continue to the other two.

Requires macOS 14 or later. The Swift sources compile with the flags in `cli/build.sh` (Swift 6, Apple Silicon).

## Use

```sh
./build/cli-anything-blitztree --json scan --root "$HOME/Downloads" --limit 20
./build/cli-anything-blitztree --json cleanup list --root "$HOME" --min-bytes 1
./build/cli-anything-blitztree status
```

No command starts a REPL (`help`, `exit`). `--json` copies the engine's schema-version-1 stdout through. It does not parse and re-encode a successful report. A newline is added only when the engine omitted one. That contract is [docs/AGENT_API.md](../docs/AGENT_API.md). A value that starts with `-` is rejected. `--limit`, `--min-bytes` and `--timeout` accept only ASCII digits.

The last successful root is stored in `~/.blitztree/cli-anything-session.json` (or `--session FILE`), mode 0600, under an exclusive lock. A symlink at that path, or at the directory that contains it, is refused.

## Tests

```sh
zsh tests/run-cli-anything.sh
```

The plan and the result of that run are in [TEST.md](TEST.md).
