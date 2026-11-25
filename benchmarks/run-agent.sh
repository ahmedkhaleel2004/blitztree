#!/bin/zsh
# Freeze production Swift and exercise agent data algorithms entirely offline.
set -euo pipefail
cd "$(dirname "$0")/.."
AGENT_BENCH_TMP=$(mktemp -d /tmp/blitztree-agent-bench.XXXXXX)
trap 'rm -rf "$AGENT_BENCH_TMP"' EXIT
mkdir "$AGENT_BENCH_TMP/app"
cp app/*.swift "$AGENT_BENCH_TMP/app/"
shasum -a 256 "$AGENT_BENCH_TMP/app/Agent.swift" "$AGENT_BENCH_TMP/app/Cleanup.swift" "$AGENT_BENCH_TMP/app/Model.swift"
python3 - "$AGENT_BENCH_TMP/app/Agent.swift" "$AGENT_BENCH_TMP/app/Cleanup.swift" "$AGENT_BENCH_TMP/app/Model.swift" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); source=p.read_text()
changes={
    'private var preparationTask: Task<Void, Never>?': 'var preparationTask: Task<Void, Never>?',
    'start(input: input, env: env)': 'AgentBenchmarkLaunch.record(input)',
    'AgentPrompt.build(tree: tree, scanRoot: scanRoot, known: known, running: running)': 'AgentBenchmarkGate.shared.waitIfArmed(); return AgentPrompt.build(tree: tree, scanRoot: scanRoot, known: known, running: running)',
}
for old,new in changes.items():
    assert source.count(old)==1, f'Expected one benchmark hook: {old}'
    source=source.replace(old,new)
p.write_text(source)
p=Path(sys.argv[2]); source=p.read_text()
old='''                        guard let target = item.target else {
                            throw CleanupOperations.failure("This folder could not be validated; rescan before cleaning")
                        }
                        // Revalidating at the boundary checks the folder again
                        // (it may have been used since the scan), rule check included.
                        receipts.append(try CleanupOperations.trash(target, move: move))'''
assert source.count(old)==1, 'Expected one manual-trash operation'
p.write_text(source.replace(old, '                        try AgentBenchmarkTrash.move(item)'))
p=Path(sys.argv[3]); source=p.read_text()
old='''    func startAgent(_ agent: InstalledAgent) {
'''
new='''    func startAgent(_ agent: InstalledAgent) {
        AgentBenchmarkLaunch.agentStarts += 1
'''
assert source.count(old)==1, 'Expected one agent start'
p.write_text(source.replace(old, new))
PY
clang -O2 -mmacosx-version-min=14.0 -c benchmarks/ui_fixture.c -o "$AGENT_BENCH_TMP/fixture.o"
AGENT_BENCH_SOURCES=("$AGENT_BENCH_TMP"/app/*.swift)
AGENT_BENCH_SOURCES=(${AGENT_BENCH_SOURCES:#*/Main.swift})
swiftc "${AGENT_BENCH_SOURCES[@]}" \
  benchmarks/AgentReference.swift benchmarks/AgentPerformance.swift "$AGENT_BENCH_TMP/fixture.o" \
  -import-objc-header benchmarks/ui_fixture.h \
  -O -parse-as-library -swift-version 6 -default-isolation MainActor \
  -target arm64-apple-macos14.0 -framework AppKit -framework SwiftUI \
  -o "$AGENT_BENCH_TMP/agent-bench"
"$AGENT_BENCH_TMP/agent-bench" "$@"
