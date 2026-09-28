# Benchmarks

The [path-ordering measurements](benchmarks/PATH_ORDER.md) cover hard-link-heavy
trees and complete JSON CLI latency, including report construction and output.
They distinguish workload-specific gains from unchanged ordinary scan times.

The [September 27 performance audit](PERFORMANCE_AUDIT.md) records the latest
before/after scanner, rendering, pointer lookup, cleanup, and outline results,
with reproducible harnesses and raw samples. The comparisons below are the
earlier v0.5.0 measurements against other tools.

M4 MacBook (10 cores), macOS 27.0, APFS, warm cache, Full Disk Access for
every tool. The machine was in normal use (load average 5–9), so runs
alternate between tools and the table shows the median of five, with the
range in brackets.

Engines are timed with `cargo run --release --bin bench -- bulk <path>` and
disktree's own `disktree_core::scan::scan` with default options. Peak memory
is `/usr/bin/time -l`'s "peak memory footprint".

## Scan engines

| target | BlitzTree | [disktree](https://github.com/tobi/disktree) 0.10.1 | |
|---|---|---|---|
| home folder (3.1M entries, 227.9 GB) | **10.2 s** (9.9–10.4) | 14.7 s (14.4–15.9) | 1.43× |
| whole data volume (4.0M entries, 303.5 GB) | **12.6 s** (12.4–13.0) | 18.2 s (18.1–19.3) | 1.45× |
| peak memory, home folder | **362 MB** | 665 MB | 1.8× less |
| peak memory, whole volume | **454 MB** | 864 MB | 1.9× less |

For reference, on the home folder: a parallel `readdir` + per-file `lstat`
walk takes 14.4 s and `du -skx` takes 65.3 s.

## Apps

Both apps scanning `~/.t3` (720k entries, nothing that needs Full Disk
Access), three launches each, as reported in each app's status bar:

| | BlitzTree | disktree 0.10.1 |
|---|---|---|
| scan time | **1.4–1.5 s** | 3.1–3.2 s |
| memory after the scan | 237–279 MB | 242–272 MB |

The finished apps use about the same memory: both keep the whole tree
loaded for the UI.

BlitzTree scanning the whole data volume in the app takes 13.3–14.0 s when
the machine is quiet and up to 20 s under heavy load. The in-app time is the
engine scan plus about 0.15 s to hand the tree to the UI.

## Accuracy

- Home folder: both engines report 227.89 GB, the same as `du -skx`.
- Whole volume: both report 303.48 GB, and each top-level folder agrees to
  within 2 MB (files being written during the runs).
- `df` shows 318.7 GB used; the 15.2 GB gap is root-only system data
  (Spotlight index, logs and the like, 231 folders) that no unprivileged app
  can read. BlitzTree shows that gap in its status bar.
- BlitzTree counts every name of a hard-linked file in the file count but
  its bytes once; disktree drops the extra names. That is why BlitzTree lists
  about 1% more files for identical totals.

## Findings

- `searchfs(2)`, the closest thing macOS has to reading NTFS's MFT, was 5×
  slower than the parallel walk on an earlier 1.9M-entry volume (38 s vs
  7.1 s): it is one sequential kernel iteration over the catalog and cannot be
  split across cores. The code is kept in `src/searchfs.rs` for reference.
- Thread count sweet spot is about the core count. 32+ threads regress ~40%.
- Scan threads run at `QOS_CLASS_USER_INITIATED`. At a GUI app's default
  QoS they land on efficiency cores and the scan takes twice as long.
  `QOS_CLASS_USER_INTERACTIVE` scanned no faster (home folder in the app:
  8.8–9.6 s vs 9.3–9.4 s) but outranked the UI and the compositor, so the
  window skipped frames for ~0.2–0.4 s mid-scan. Leaving cores free instead
  cost speed: 4 workers took 14 s on the home folder, 6 took 11 s.
- Treemap render (1600×1600 px, /Applications): 100–190 ms on one thread
  originally, now ~5 ms layout + ~3 ms paint across 30 row bands, pixel-for-pixel
  the same image.
- The peak memory rows above predate the flat engine, which peaks at about
  half of v0.5.1 (see the audit's third pass).
