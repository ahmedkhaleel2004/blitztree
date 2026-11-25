#!/bin/zsh
# Build the agent CLI. The scan engine is still the Rust `blitztree` binary.
set -euo pipefail
cd "$(dirname "$0")/.."
FLAGS=(-parse-as-library -swift-version 6 -default-isolation MainActor -target arm64-apple-macos14.0)
mkdir -p build
swiftc cli/Harness.swift cli/main.swift app/Subprocess.swift "${FLAGS[@]}" -o build/cli-anything-blitztree
echo "built build/cli-anything-blitztree"
