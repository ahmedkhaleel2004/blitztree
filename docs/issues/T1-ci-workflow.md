# T1 — CI: `cargo test` + Swift build on every push

**Severity:** — (process)
**Source:** project review; there is currently no CI at all (no
`.github/` directory).

## Problem

The project has Rust unit tests (`src/lib.rs`, `src/cleanup.rs`), a
Python CLI test suite (`tests/test_cli.py`), and a Swift UI — none of
which run anywhere automatically. Regressions surface only on the
developer's machine.

## Fix

`.github/workflows/ci.yml`:

- **macos-14 (or later) runner**, Apple Silicon image (`macos-14` is
  arm64) since the deployment target is arm64-only.
- Job 1 — engine:
  ```yaml
  - uses: dtolnay/rust-toolchain@stable
  - run: cargo test --release
  - run: cargo build --release
  ```
- Job 2 — CLI tests:
  ```yaml
  - uses: actions/setup-python@v5  { python-version: "3.12" }
  - run: cargo build --release
  - run: pytest tests/ -v          (pip install pytest)
  ```
- Job 3 — Swift build (best effort; the app needs Xcode 26 for full
  compatibility, so allow failure on older Xcode):
  ```yaml
  - run: ./build.sh
  ```
- Optional: `swiftc` syntax-only gate for older toolchains.

## Acceptance criteria

- [x] Workflow runs green on a push to `main`.
- [x] `cargo test` and `pytest` failures fail the build.
- [x] No secrets required; push access only.
