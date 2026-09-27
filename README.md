<img src="assets/icon.png" width="128" alt="BlitzTree icon">

# BlitzTree

A fast, native disk-space treemap for macOS, in the spirit of WizTree. It scans a whole Mac (3.6M files) in about 14 seconds.

<p>
  <img src="assets/screenshot.png" width="49%" alt="BlitzTree treemap view of /Applications">
  <img src="assets/screenshot-rings.png" width="49%" alt="BlitzTree rings view of /Applications">
</p>

## Install

**[Download BlitzTree.dmg](https://github.com/ahmedkhaleel2004/blitztree/releases/latest/download/BlitzTree.dmg)** and drag the app into Applications. Requires Apple Silicon and macOS 14 or later.

The app is not notarized. On first launch, allow it in System Settings → Privacy & Security → **Open Anyway**, then grant Full Disk Access when prompted and relaunch.

## Features

- Cushion-shaded treemap colored by file type, with a synced Finder-style outline list
- Prefer DaisyDisk? Switch to rings in the toolbar: click a folder to zoom in, the middle to go back
- Zoom into folders, reveal in Finder, or move to Trash (with confirmation)
- Clean Up panel: finds folders that are safe to delete (caches, `node_modules`, Rust `target`, Xcode DerivedData and more) so you can trash them in one go
- AI cleanup: after each launch scan, your own Claude Code or Codex plans what can go, live in the panel, while the treemap lights up those folders. BlitzTree does the cleanup itself, in two steps you approve: move to Trash, then delete for good. No agent installed? One click sets up Codex (free with a ChatGPT account) or Claude Code
- Live progress while scanning, and an optional free-space block
- Native AppKit/SwiftUI, with the Liquid Glass design on macOS 26 and later
- No telemetry. BlitzTree itself never goes online; the AI cleanup runs your own agent, which sends folder paths and sizes from the scan (never file contents) to Anthropic or OpenAI

## Performance

| Home folder, 3.1M entries (M4) | Time |
|---|---|
| **BlitzTree** | **10.2 s** |
| Parallel `readdir` + `lstat` | 14.4 s |
| `du -skx` | 65.3 s |

- `getattrlistbulk(2)` reads a whole directory's metadata in one syscall instead of one `stat` per file.
- A Rust worker pool keeps many directories in flight, and scan threads run at user-initiated QoS: they stay on performance cores without starving the UI.
- The treemap is laid out once and painted on every core in parallel, so zooming redraws in a couple of frames.

Method, full results and a comparison with other tools: [BENCHMARKS.md](BENCHMARKS.md).

## Accuracy

Sizes are allocated bytes, matching `du`. Hard-linked files count once, the scan stays on one volume, and cloud-only iCloud folders are never downloaded. Root-only system data that no app can read is reported in the status bar instead of hidden.

## AI cleanup

The agent runs headless and read-only: it only writes a plan from the scan BlitzTree already has. BlitzTree then acts on it behind its own checks, whatever the plan says:

- Only paths inside your home folder, never Documents, Desktop, Photos, iCloud Drive, Mail, keychains or `~/.ssh` (build output such as `node_modules` inside them is allowed), never a git repository or a whole folder like `~/Library/Caches`
- Only each tool's own cache cleanup commands (`uv cache clean`, `brew cleanup`, `npm cache clean` and similar), with no shell syntax
- Caches of apps that are open are skipped until you quit them
- "Delete for good" removes only what this cleanup moved to the Trash

## Trust & permissions

BlitzTree asks for Full Disk Access so the scan can read every folder on the
disk, including the system-protected ones that normally stay out of reach.
Everything it launches — the agent CLIs and each allowlisted cleanup command —
inherits that same grant while it runs. The agent CLIs' own sandbox settings
are a CLI-level policy, not an OS guarantee for anything they spawn.

Cleanup commands (`uv cache clean`, `brew cleanup` and so on) are resolved
through the shell's PATH, by design: these tools live in Homebrew, `~/.local/bin`,
nvm and other tool-manager locations, and BlitzTree does not guess where they
are installed. Only commands matching a small allowlist of tool-specific
cleanup invocations are ever run, but what runs is whatever the PATH resolves —
the trust in your own PATH is residual.

## Build from source

Requires Xcode 26 or later and Rust.

```sh
./build.sh              # build/BlitzTree.app
./deploy.sh             # build and install to /Applications
cargo test --release    # engine tests
```

The Rust engine hands the finished tree to the Swift UI as flat arrays over a C interface, with no copying. `BlitzTree <path>` scans a specific folder.

## JSON CLI for agents and scripts

An optional, read-only CLI uses the same scan engine without opening the GUI
or launching an AI agent:

```sh
cargo build --locked --release --features cli --bin blitztree
./target/release/blitztree scan --root "$HOME/Downloads"
./target/release/blitztree quick-wins --root "$HOME" --limit 20
```

`scan` lists the largest directories and files as JSON. `quick-wins` includes
that inventory plus the Clean Up panel's existing candidates and labels. The
panel and CLI share one Rust implementation of the rules, with no new heuristics.
Both report incomplete scans; allocated bytes are not
a promise of reclaimable space. Neither command modifies the scanned files.

The CLI is built from source separately from the app. Its JSON dependency is
only compiled with the `cli` feature. See [the CLI contract and tests](docs/AGENT_API.md).

## License

MIT
