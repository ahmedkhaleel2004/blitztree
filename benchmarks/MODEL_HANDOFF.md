# Tree-first scan handoff

`benchmarks/model-handoff.py` builds a headless Swift harness with a one-node
C scan fixture. It creates temporary directories only as scan labels, never
opens `NSApplication` or a window, and sets agent discovery as unloaded. The
normal run checks that:

- a completed tree is visible while delayed capacity is still unknown;
- a rescan resets `freeBytes` and `unscannedBytes` to zero;
- a delayed result from the previous scan cannot overwrite the current tree;
- the previous `Tree` is released before its volume query returns.

Run the regression check with:

```sh
python3 benchmarks/model-handoff.py --output /tmp/blitztree-model-handoff
```

Capacity arriving after the tree also invalidates the existing treemap and
ring bitmaps when free space is displayed. The rendering harness checks delayed
capacity, subsequent changes/reset, cache reuse when capacity is unchanged or
hidden, and the latest capacity after returning to the root. It preserves the
existing zoom behavior: treemap shows free space in subfolders too, while rings
only show it at the scan root.
Capacity is a value input to both SwiftUI representables so its arrival also
schedules an update of the native views.

```sh
python3 benchmarks/rendering.py --baseline bf3b1fc --check-only
```

This also checks unchanged pixels, geometry and hit testing against v0.5.2;
the existing layouts and visual styles are preserved.

`--measure` injects a 1.5-second volume delay and prints tree, scan-complete,
and capacity-application times. `--ref 6e8483a` builds the baseline
`app/Model.swift` with the same current agent/cleanup sources and the same
fixture. For three samples per side:

```sh
python3 benchmarks/model-handoff.py --measure --ref 6e8483a --runs 3 --output /tmp/blitztree-model-handoff-baseline
python3 benchmarks/model-handoff.py --measure --runs 3 --output /tmp/blitztree-model-handoff-candidate
```

The delay is an injected service stall used to verify ordering; these numbers
describe first-result behavior under that stall and do not claim a normal scan
speedup. On 2026-09-27, three runs on the same host produced:

| source | tree/scan-complete median | capacity median |
| --- | ---: | ---: |
| `6e8483a` baseline | 1506.2 ms | 1506.2 ms |
| current tree-first | 22.3 ms | 1505.8 ms |

The candidate's tree was available while the injected volume service was still
sleeping. The fixture has one synthetic node, so the result measures ordering
only; it says nothing about renderer or filesystem throughput.
