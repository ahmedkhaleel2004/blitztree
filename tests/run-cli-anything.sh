#!/bin/zsh
# Build the Swift agent CLI and the Rust engine it drives, then run the checks.
set -euo pipefail
SELF=${0:A}
cd "${SELF:h}/.."
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
FLAGS=(-parse-as-library -swift-version 6 -default-isolation MainActor -target arm64-apple-macos14.0)
echo "==> blitztree engine"
cargo build --locked --release --features cli --bin blitztree
TMP=$(mktemp -d /tmp/blitztree-cli-anything.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
echo "==> cli-anything-blitztree"
swiftc cli/Harness.swift cli/main.swift app/Subprocess.swift "${FLAGS[@]}" -o "$TMP/cli-anything-blitztree"
swiftc cli/Harness.swift tests/CLIAnythingChecks.swift app/Subprocess.swift "${FLAGS[@]}" -o "$TMP/checks"
CLI_ANYTHING_BIN="$TMP/cli-anything-blitztree" \
  BLITZTREE_BIN="$PWD/target/release/blitztree" \
  "$TMP/checks"
