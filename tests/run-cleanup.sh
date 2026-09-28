#!/bin/zsh
# Offline regression checks. All filesystem operations stay in disposable fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
CLEANUP_TEST_TMP=$(mktemp -d /tmp/blitztree-cleanup-checks.XXXXXX)
trap 'rm -rf "$CLEANUP_TEST_TMP"' EXIT
FLAGS=(-parse-as-library -swift-version 6 -default-isolation MainActor -target arm64-apple-macos14.0)
swiftc app/CleanupCommand.swift tests/CleanupCommandChecks.swift "${FLAGS[@]}" -o "$CLEANUP_TEST_TMP/commands"
"$CLEANUP_TEST_TMP/commands"
swiftc app/CleanupSafety.swift tests/CleanupSafetyChecks.swift "${FLAGS[@]}" -o "$CLEANUP_TEST_TMP/paths"
"$CLEANUP_TEST_TMP/paths"
cargo build --locked --release --lib
SOURCES=(app/*.swift)
SOURCES=(${SOURCES:#app/Main.swift})
swiftc "${SOURCES[@]}" tests/CleanupIntegrationChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/integration"
"$CLEANUP_TEST_TMP/integration"
