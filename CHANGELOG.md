# Changelog

## Unreleased

- Right-click or Control-click a file or folder in the list for the same menu as the treemap: Reveal in Finder, Copy Path, and Move to Trash.
- Control-click a file in the treemap, or a file or folder in the rings, for the same menu as right-click.
- Move to Trash from that menu takes the item out of the list, the map and the totals right away, without a rescan. If it can't be moved, BlitzTree says why instead of doing nothing.

## 0.5.6 — 2026-09-27

- BlitzTree updates itself. It checks GitHub for a new release once a day, downloads it in the background and installs it when you quit. Check for Updates… is in the BlitzTree menu. Updates are signed, and Full Disk Access carries over.
- Coming from 0.5.5 or earlier: download this version once by hand; from here on it updates itself.

## 0.5.5 — 2026-09-27

- AI cleanup only runs when you click "Clean up with Claude Code" (or Codex). Before, the first scan after launch started your agent on its own, which sent folder paths and sizes to Anthropic or OpenAI without asking. Now the panel opens on the button and nothing leaves your Mac until you click it.

## 0.5.4 — 2026-09-27

- AI cleanup: while "Delete for good" runs, the size counts down as each item finishes. Since deletes started running in parallel (0.4.1) the number disappeared until the whole delete was done.

## 0.5.3 — 2026-09-27

BlitzTree is now signed with a Developer ID and notarized by Apple: it opens with a normal double-click, with no Open Anyway step.

- AI cleanup can plan Xcode simulator runtimes and device data (through `xcrun simctl`) and the Codex app's chat folders in `~/Documents/Codex`. Chats used in the last 2 days are kept.
- Plan items and list selections light up on the treemap and rings even when their folder is drawn inside a combined "A ▸ B" box, and files light up too.
- Clicking a plan card or Reclaimable row outside the zoomed folder zooms out to it.

Updating from 0.5.2 or earlier: the new signature means macOS asks for Full Disk Access once more. Remove the old BlitzTree row in System Settings → Privacy & Security → Full Disk Access, add the new app, and relaunch.

## 0.5.2 — 2026-09-27

This release halves scan memory, doubles treemap render speed, and adds a read-only JSON CLI.

- Build the scan's flat tree during the walk: about half the peak memory, and the tree reaches the UI 3–4x sooner after the last directory is read.
- Treemap renders about 2x faster (each pixel shaded once) and hover redraws only what changed, with identical pixels.
- Selecting a file inside a very large folder in the list is about 2x faster.
- Optional read-only JSON CLI (`blitztree scan`, `blitztree quick-wins`) built from source with `--features cli`, sharing the Clean Up rules with the app (contributed by @512banque).
- Hard-linked files are credited to the same path on every scan, and incomplete subtrees are tracked.

Rust tests, CLI tests, rendering comparisons against 0.5.1 (identical pixels) and full-tree dumps against the previous engine (identical) passed. Scan wall time is unchanged: it is bound by the kernel. Measurements are in [PERFORMANCE_AUDIT.md](PERFORMANCE_AUDIT.md).

## 0.5.1 — 2026-09-27

This release improves scan memory use, rendering, post-scan responsiveness, and cleanup plan processing.

- Reduce scanner allocations and store sibling nodes as compact ranges. The measured applications scan used about 16% less peak memory with identical file, directory, and byte totals.
- Draw treemaps and complex Retina rings faster, and make pointer lookup much cheaper for large trees.
- Shorten post-scan UI stalls by isolating progress/status updates, reading volume metadata in the background, and reusing unchanged collapsed outline rows.
- Process streamed cleanup plans incrementally and skip small subtrees during cleanup and prompt preparation.
- Run manual Trash batches off the main thread, prevent duplicate batches and late agent launches after cancellation, and retain cleanup errors until dismissed.

Release builds, rendering comparisons, Rust tests, offline agent/cleanup tests, and native UI checks passed. Reproducible measurements and limitations are in [PERFORMANCE_AUDIT.md](PERFORMANCE_AUDIT.md). Scan-throughput measurements were inconclusive. Complex Retina ring strokes have small bounded antialiasing differences; geometry and hit behavior are unchanged.

Requires Apple Silicon and macOS 14 or later. This release is signed with the existing Apple Development identity but is **not notarized**. First-time installations may require **System Settings → Privacy & Security → Open Anyway**, followed by granting Full Disk Access and relaunching.
