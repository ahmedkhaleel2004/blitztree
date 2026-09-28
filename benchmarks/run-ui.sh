#!/bin/zsh
# Production Swift sources with synthetic fixtures or a real read-only scan.
set -euo pipefail
cd "$(dirname "$0")/.."
UI_BENCH_TMP=$(mktemp -d /tmp/blitztree-ui-bench.XXXXXX)
trap 'rm -rf "$UI_BENCH_TMP"' EXIT
# Freeze the source set while other audit work may still edit shared files.
mkdir "$UI_BENCH_TMP/app"
cp app/*.swift "$UI_BENCH_TMP/app/"
shasum -a 256 "$UI_BENCH_TMP/app/Cleanup.swift" "$UI_BENCH_TMP/app/CleanupCommand.swift" "$UI_BENCH_TMP/app/CleanupSafety.swift" "$UI_BENCH_TMP/app/CleanupOperations.swift" "$UI_BENCH_TMP/app/Model.swift" "$UI_BENCH_TMP/app/ContentView.swift"
UI_BENCH_INPUTS=(benchmarks/UIPerformance.swift)
UI_BENCH_LINK=()
UI_BENCH_HEADER=benchmarks/ui_fixture.h
if [[ "${1:-}" == --scan-path ]]; then
  shift
  [[ $# -ge 1 ]] || { print -u2 'Usage: run-ui.sh --scan-path PATH [PATH ...]'; exit 2; }
  [[ -f target/release/libblitztree.a ]] || { print -u2 'Build the Rust library first: cargo build --release'; exit 2; }
  UI_BENCH_INPUTS=(benchmarks/UICleanupScan.swift)
  UI_BENCH_LINK=(-L target/release -lblitztree)
  UI_BENCH_HEADER=app/bz.h
else
  clang -O2 -mmacosx-version-min=14.0 -c benchmarks/ui_fixture.c -o "$UI_BENCH_TMP/fixture.o"
  UI_BENCH_INPUTS+=("$UI_BENCH_TMP/fixture.o")
fi
swiftc "$UI_BENCH_TMP/app/Agent.swift" "$UI_BENCH_TMP/app/Cleanup.swift" \
  "$UI_BENCH_TMP/app/CleanupCommand.swift" "$UI_BENCH_TMP/app/CleanupSafety.swift" \
  "$UI_BENCH_TMP/app/CleanupOperations.swift" \
  "$UI_BENCH_TMP/app/ContentView.swift" "$UI_BENCH_TMP/app/Model.swift" \
  "$UI_BENCH_TMP/app/Treemap.swift" "$UI_BENCH_TMP/app/TreemapView.swift" "$UI_BENCH_TMP/app/SunburstView.swift" \
  "${UI_BENCH_INPUTS[@]}" benchmarks/UIReferenceCleanup.swift "${UI_BENCH_LINK[@]}" \
  -import-objc-header "$UI_BENCH_HEADER" \
  -O -parse-as-library -swift-version 6 -default-isolation MainActor \
  -target arm64-apple-macos14.0 -framework AppKit -framework SwiftUI \
  -o "$UI_BENCH_TMP/ui-bench"
"$UI_BENCH_TMP/ui-bench" "$@"
