# Changelog

## Unreleased

- APFS clones count once. Copies made with `clonefile` (Finder copies, Chrome's code-signing clones in `/private/var/folders`) share their blocks, but every copy used to count in full, so a folder of clones could show hundreds of gigabytes it doesn't use. Sizes, percentages, the treemap and the rings now count a family of clones once, toward the copy with the lowest file id. Rows and tooltips show "+918 GB cloned" or "2.26 GB cloned" where that matters, and the status bar shows how much is shared by clones.
- Clean Up and AI cleanup sizes count only blocks no other file shares. Blocks shared with an APFS clone don't count as freed, because a clone elsewhere, even one changed since, can keep them on disk. The Clean Up panel lists folders that free at least 50 MB, largest first by what they free.
- JSON CLI: entries and the summary add `unique_bytes` and `cloned_bytes`. `allocated_bytes` keeps its meaning. Clean Up candidates are now selected and sorted by unique bytes.
- Scans read each file's clone id and sharing flags, which makes them about 10% slower. Asking for each file's private size as well made scans 3x slower, so BlitzTree asks for it only for Clean Up candidates.
- Launch shows the last results right away. After each scan, BlitzTree saves the results, compressed, to `~/Library/Caches/dev.ahmed.blitztree`. The first scan of that folder after the next launch shows them within a second or two, with "Results from 2 hours ago · refreshing 40%" and a progress bar in the status bar, while a fresh scan runs. The fresh results then replace them, keeping the folder on screen, the selection and open rows. To free the space they take, choose BlitzTree > Delete Saved Results…, or turn off BlitzTree > Save Results for Fast Launch. While they are on screen, picking folders in Clean Up, Move to Trash (in Clean Up and in the right-click menu) and "Clean up with Claude Code" wait for the fresh scan. Rescans within a session, such as the one after Move to Trash, start fresh. On a Mac where the saved results and the fresh scan together would take more than half the memory, BlitzTree doesn't keep them. Saved results from another version of BlitzTree, another disk, or a damaged file are ignored.

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
