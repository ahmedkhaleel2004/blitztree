# Path ordering without temporary paths

Baseline: `6e8483a` (the flat engine). Measured on an Apple M2 Max, 12 logical
CPUs, 32 GB RAM, macOS 26.5.2, Rust 1.94.0, release builds and warm caches.
Raw samples are in `results/2026-09-27-path-order/`.

Hard-link ownership, cleanup ties and CLI top-K selection need lexical path
order, but do not need a materialized path. `Tree::compare_paths` compares the
first divergent components through the existing parent/name arrays. Ancestors
sort before descendants. Siblings have a direct name comparison. No per-node
index, depth column or cached path is added.

The CLI heap now keeps node references and constructs paths only for its final
JSON entries. Recognition, limits, byte accounting and output order are unchanged.

## Complete CLI measurements

`benchmarks/cli.py` executes the real CLI, including startup, scan, reporting,
JSON output and teardown. Two warmup pairs precede seven alternating AB/BA pairs.
The entire parsed JSON is compared on every run, excluding only timestamps,
`scan_seconds` and the build version. Every report matched, including coverage.

| `quick-wins --limit 20` | Baseline median | Candidate median | Interpretation |
|---|---:|---:|---|
| 100,000 hard-linked files, `--min-bytes 0` | 77.42 ms | 62.87 ms | 18.8% lower end-to-end latency |
| `/Applications`, default 50 MB threshold, 995,807 nodes | 2.457 s | 2.466 s | No demonstrated speed change |

The hard-link fixture contains 200 projects, each with 500 links to the same
500 source files. It exercises a specific workload, not the average filesystem.
Its paired ranges were 72.72–78.85 ms before and 60.85–66.46 ms after.

Application scan ranges overlap: 2.389–2.705 s before and 2.381–2.636 s after.
Do not infer a whole-disk speedup from the synthetic result. Peak footprint was
9.57 → 9.55 MB on the hard-link fixture and 95.68 → 101.52 MB on applications;
these runs do not establish a memory reduction. No memory claim is made.

## Isolated top-K selection

Nine measured alternating pairs after warmup. These timings exclude scanning,
fixture construction and JSON serialization. Every selected node matches the
pre-change implementation.

| 250,000 files, top 20 | Baseline median | Candidate median |
|---|---:|---:|
| Equal sizes in one directory | 54.406 ms | 1.389 ms |
| Equal sizes across 1,000 projects | 52.523 ms | 2.172 ms |
| Varied sizes across 1,000 projects | 0.201 ms | 0.201 ms |

Equal sizes force the old heap to build a path for every visited file, even
when only 20 entries survive. Varied sizes usually let both heaps reject a node
using its size alone. The 24–39× selection result is specific to size ties and
must not be presented as a scan-speed multiplier.

## Reproduce

Build the baseline and candidate with `cargo build --release --locked --features
cli --bins`, retaining both executables. Then run:

```sh
cargo test --release --locked --features cli
python3 tests/test_cli.py
cargo test --release --features cli --bin blitztree report_order_benchmark -- --ignored --nocapture --test-threads=1
python3 benchmarks/cli.py --baseline /path/to/baseline/blitztree --candidate target/release/blitztree --path /Applications --output build/apps-cli.json
```

Generate the hard-link fixture in a fresh directory (run once):

```python
from pathlib import Path
root = Path("build/hardlink-fixture")
root.mkdir(parents=True, exist_ok=False)
for d in range(200):
    folder = root / f"project-{d:04}" / "packages/linked/node_modules/package"
    folder.mkdir(parents=True)
    for f in range(500):
        target = folder / f"file-{f:04}.js"
        if d == 0:
            target.write_bytes(b"x" * 128)
        else:
            target.hardlink_to(root / "project-0000/packages/linked/node_modules/package" / target.name)
```

Use that root with `benchmarks/cli.py --min-bytes 0`. Run timing experiments
sequentially, without overlapping builds or other benchmarks.

Correctness checks include all 250,000 pairwise comparisons in a tree containing
deep chains, roots, ancestors, Unicode and punctuation; top-K against a full sort
in both traversal orders; existing hard-link/cleanup/FFI tests; and 20 black-box
CLI tests. Timing tests remain opt-in.
