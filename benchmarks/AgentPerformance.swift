import AppKit
import Foundation

// Production launch is replaced with this counter in the frozen benchmark
// source only. No Process.run(), authentication, or network calls are made.
@MainActor
enum AgentBenchmarkLaunch {
    static var calls = 0
    static var agentStarts = 0
    static func record(_ input: String) {
        precondition(!input.isEmpty)
        calls += 1
    }
}

nonisolated final class AgentBenchmarkGate: @unchecked Sendable {
    static let shared = AgentBenchmarkGate()
    private let condition = NSCondition()
    private var enabled = false, entered = false, released = false
    func arm() {
        condition.lock(); defer { condition.unlock() }
        enabled = true; entered = false; released = false
    }
    func waitIfArmed() {
        condition.lock(); defer { condition.unlock() }
        guard enabled else { return }
        entered = true
        while !released { condition.wait() }
    }
    var hasEntered: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        enabled = false; released = true; condition.broadcast()
    }
}

nonisolated final class AgentCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String] = []
    func record(_ value: String) { lock.lock(); defer { lock.unlock() }; records.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return records }
}

nonisolated final class AgentBenchmarkTrash: @unchecked Sendable {
    static let shared = AgentBenchmarkTrash()
    private let lock = NSLock()
    private var moved: [Int] = []
    static func move(_ item: CleanupItem) throws {
        precondition(!Thread.isMainThread, "Trash work ran on the UI thread")
        shared.lock.lock(); shared.moved.append(item.node); shared.lock.unlock()
        AgentBenchmarkGate.shared.waitIfArmed()
        if item.node == 2 || item.node == 7 {
            throw NSError(domain: "OfflineTrash", code: item.node, userInfo: [NSLocalizedDescriptionKey: "injected failure"])
        }
    }
    var nodes: [Int] { lock.lock(); defer { lock.unlock() }; return moved }
}

private struct AgentFixture {
    var names = ["/fixture"]
    var parents = [UInt32.max]
    var sizes: [UInt64] = [0]
    var flags: [UInt8] = [1]
    var children: [[UInt32]] = [[]]
    @discardableResult
    mutating func add(_ name: String, to parent: Int = 0, bytes: UInt64 = 0, directory: Bool = true) -> Int {
        let id = names.count
        names.append(name); parents.append(UInt32(parent)); sizes.append(bytes)
        flags.append(directory ? 1 : 0); children.append([]); children[parent].append(UInt32(id))
        return id
    }
    func tree() -> Tree {
        var alloc = sizes
        var fileCounts = flags.map { $0 == 0 ? UInt32(1) : UInt32(0) }
        for id in (1..<names.count).reversed() {
            alloc[Int(parents[id])] += alloc[id]
            fileCounts[Int(parents[id])] += fileCounts[id]
        }
        var offsets: [UInt32] = [0], edges: [UInt32] = [], nameOffsets: [UInt32] = [0], blob: [UInt8] = []
        for id in names.indices {
            edges.append(contentsOf: children[id].sorted { alloc[Int($0)] > alloc[Int($1)] })
            offsets.append(UInt32(edges.count)); blob.append(contentsOf: names[id].utf8)
            nameOffsets.append(UInt32(blob.count))
        }
        let handle = bz_fixture_create(UInt32(names.count), parents, alloc, flags, offsets, edges, nameOffsets, blob)!
        // The shared fixture adapter initializes counts to zero. Fill its
        // owned storage before constructing the immutable production Tree.
        fileCounts.withUnsafeBufferPointer {
            UnsafeMutablePointer(mutating: bz_nfiles(handle)!).update(from: $0.baseAddress!, count: $0.count)
        }
        return Tree(handle: handle)!
    }
}

nonisolated private func specSignature(_ item: PlanItemSpec) -> String {
    [item.title, item.detail, item.group, String(item.bytes), item.paths.joined(separator: "\0"), item.action, item.command].joined(separator: "\u{1}")
}
nonisolated private func canonical(_ data: Data) -> String {
    guard let value = try? JSONSerialization.jsonObject(with: data),
          let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return String(decoding: data, as: UTF8.self) }
    return String(decoding: encoded, as: UTF8.self)
}
nonisolated private func eventSignature(_ event: AgentStreamReader.Event) -> String {
    switch event {
    case .activity(let value): return "activity:\(value)"
    case .item(let item): return "item:\(specSignature(item))"
    case .restart: return "restart"
    case .plan(let summary, let items): return "plan:\(summary):\(items.map(specSignature))"
    case .failed(let value): return "failed:\(value)"
    }
}
nonisolated private func eventSignature(_ event: ReferenceAgentStreamReader.Event) -> String {
    switch event {
    case .activity(let value): return "activity:\(value)"
    case .item(let item): return "item:\(specSignature(item))"
    case .restart: return "restart"
    case .plan(let summary, let items): return "plan:\(summary):\(items.map(specSignature))"
    case .failed(let value): return "failed:\(value)"
    }
}
nonisolated private func chunks(_ text: String, width: Int) -> [String] {
    var result: [String] = [], start = text.startIndex
    while start != text.endIndex {
        let end = text.index(start, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
        result.append(String(text[start..<end])); start = end
    }
    return result
}
private struct AgentPlanEnvelope: Decodable { let items: [PlanItemSpec] }

private func json(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}
private func plan(_ count: Int, pathLength: Int = 96, pathsPerItem: Int = 1) -> String {
    let items = (0..<count).map { index in
        let paths = (0..<pathsPerItem).map { pathIndex in
            "/fixture/文件-\(index)/" + (pathsPerItem == 1 ? "" : "\(pathIndex)/") + String(repeating: "p", count: pathLength)
        }
        return ["title": "Cache \(index) \\\"quoted\\\" 😀", "detail": "Rebuild {this} [cache] \\ safely\nnew line",
         "group": index.isMultiple(of: 2) ? "safe" : "ask", "bytes": 500_000_000 + index,
         "paths": paths,
         "action": "trash", "command": "", "extra": ["nested": ["braces": "{[\\\"}]"]]] as [String: Any]
    }
    return json(["summary": "Twelve caches, unchanged.", "items": items])
}
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
private func ms(_ work: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds; work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
private func paired(_ label: String, trials: Int = 9, before: () -> Void, after: () -> Void) {
    var old: [Double] = [], new: [Double] = []
    for trial in 0..<trials {
        if trial.isMultiple(of: 2) { old.append(ms(before)); new.append(ms(after)) }
        else { new.append(ms(after)); old.append(ms(before)) }
    }
    print(String(format: "%@ baseline_ms=%.6f optimized_ms=%.6f", label, old.sorted()[trials / 2], new.sorted()[trials / 2]))
    print("baseline_samples=\(old) optimized_samples=\(new)")
}

// Candidate alternative kept only in the benchmark until it demonstrates a
// worthwhile win over sorting the already-pruned candidate list.
private struct AgentCandidateHeap {
    let tree: Tree
    let limit: Int
    var nodes: [Int] = []
    func worse(_ a: Int, _ b: Int) -> Bool {
        tree.alloc[a] == tree.alloc[b] ? a > b : tree.alloc[a] < tree.alloc[b]
    }
    mutating func offer(_ node: Int) {
        if nodes.count < limit {
            nodes.append(node)
            var child = nodes.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard worse(nodes[child], nodes[parent]) else { break }
                nodes.swapAt(child, parent); child = parent
            }
        } else {
            guard worse(nodes[0], node) else { return }
            nodes[0] = node
            var parent = 0
            while 2 * parent + 1 < nodes.count {
                var child = 2 * parent + 1
                if child + 1 < nodes.count, worse(nodes[child + 1], nodes[child]) { child += 1 }
                guard worse(nodes[child], nodes[parent]) else { break }
                nodes.swapAt(child, parent); parent = child
            }
        }
    }
    var sorted: [Int] { nodes.sorted { worse($1, $0) } }
}

private func largestWithHeap(_ tree: Tree) -> ([Int], [Int]) {
    var folders = AgentCandidateHeap(tree: tree, limit: 250)
    var files = AgentCandidateHeap(tree: tree, limit: 80)
    var stack = [0]
    while let parent = stack.popLast() {
        for raw in tree.children(parent) {
            let i = Int(raw), size = tree.alloc[i]
            guard size >= 100_000_000 else { break }
            if tree.isDir(i) {
                stack.append(i)
                if let first = tree.children(i).first, tree.isDir(Int(first)),
                   Double(tree.alloc[Int(first)]) >= 0.95 * Double(size) { continue }
                folders.offer(i)
            } else if size >= 250_000_000 { files.offer(i) }
        }
    }
    return (folders.sorted, files.sorted)
}

@main
struct AgentPerformance {
    @MainActor
    static func main() async {
        let normal = plan(12)
        let single = plan(1)
        // Every character split across keys, escapes, UTF8, braces and nested
        // values; every append must emit the same new cards as the baseline.
        let cases = [normal, "", "{}", "{\"items\":[]}", String(normal.dropLast(30)),
                     "{\"items\":[{\"invalid\":true}," + String(single.dropFirst(single.firstIndex(of: "[")!.utf16Offset(in: single) + 1)),
                     "prefix\n" + normal + " trailing text", "{\"items\":[\"ignored\",null,12," + String(single.dropFirst(single.firstIndex(of: "[")!.utf16Offset(in: single) + 1))]
        for text in cases {
            for width in [1, 2, 3, 7, 16, 64, 1024] {
                var old = ReferencePartialPlanParser(), new = PartialPlanParser()
                for chunk in chunks(text, width: width) {
                    check(old.append(chunk).map(specSignature) == new.append(chunk).map(specSignature), "Partial parser emission changed at width \(width)")
                    check(!old.text.isEmpty == new.hasInput, "Partial parser input state changed")
                }
            }
        }
        for split in single.indices {
            var old = ReferencePartialPlanParser(), new = PartialPlanParser()
            for chunk in [String(single[..<split]), String(single[split...])] {
                check(old.append(chunk).map(specSignature) == new.append(chunk).map(specSignature), "Two-part split changed output")
            }
        }

        var random: UInt64 = 0xA6E17
        for iteration in 0..<200 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            var text = plan(Int(random % 24), pathLength: Int((random >> 8) % 160))
            if iteration.isMultiple(of: 2) { text = text.replacingOccurrences(of: "😀", with: "\\uD83D\\uDE00") }
            let decoded = try! JSONDecoder().decode(AgentPlanEnvelope.self, from: Data(text.utf8)).items.map(specSignature)
            var old = ReferencePartialPlanParser(), new = PartialPlanParser()
            var emitted: [String] = [], cursor = text.startIndex
            while cursor != text.endIndex {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                let end = text.index(cursor, offsetBy: Int(random % 67) + 1, limitedBy: text.endIndex) ?? text.endIndex
                let chunk = String(text[cursor..<end])
                let fresh = new.append(chunk).map(specSignature)
                check(old.append(chunk).map(specSignature) == fresh, "Randomized delta parity failed")
                emitted += fresh
                cursor = end
            }
            check(emitted == decoded, "Incremental parser disagreed with complete JSON decoder")
        }

        func stream(_ kind: AgentKind, plan: String, restart: Bool = false) -> Data {
            var records: [[String: Any]] = []
            func appendPlan() {
                switch kind {
                case .codex:
                    records.append(["method": "item/started", "params": ["item": ["type": "agentMessage"]]])
                    records += chunks(plan, width: 13).map { ["method": "item/agentMessage/delta", "params": ["delta": $0]] }
                    records.append(["method": "item/completed", "params": ["item": ["type": "agentMessage", "text": plan]]])
                case .claude:
                    records.append(["type": "stream_event", "event": ["type": "content_block_start", "content_block": ["type": "tool_use", "name": "StructuredOutput"]]])
                    records += chunks(plan, width: 13).map { ["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["partial_json": $0]]] }
                }
            }
            if kind == .codex {
                records.append(["id": 1, "result": [:]])
                records.append(["id": 2, "result": ["thread": ["id": "offline-thread"]]])
            }
            appendPlan()
            if restart { appendPlan() }
            if kind == .codex { records.append(["method": "turn/completed", "params": ["turn": ["status": "completed"]]]) }
            else { records.append(["type": "result", "structured_output": try! JSONSerialization.jsonObject(with: Data(plan.utf8)), "subtype": "success"]) }
            return Data((records.map(json).joined(separator: "\n") + "\n").utf8)
        }
        for kind in AgentKind.allCases {
            let bytes = Data("not-json\n\n".utf8) + stream(kind, plan: normal, restart: true)
            for width in [1, 7, 4096, 16384, bytes.count] {
                let oldCapture = AgentCapture(), newCapture = AgentCapture()
                let old = ReferenceAgentStreamReader(kind: kind, prompt: "offline", folder: "/fixture", write: { oldCapture.record("write:" + canonical($0)) }, done: { oldCapture.record("done") }, emit: { oldCapture.record(eventSignature($0)) })
                let new = AgentStreamReader(kind: kind, prompt: "offline", folder: "/fixture", write: { newCapture.record("write:" + canonical($0)) }, done: { newCapture.record("done") }, emit: { newCapture.record(eventSignature($0)) })
                if kind == .codex { old.begin(); new.begin() }
                for start in stride(from: 0, to: bytes.count, by: width) {
                    let chunk = bytes[start..<min(start + width, bytes.count)]
                    old.feed(chunk); new.feed(chunk)
                    check(oldCapture.values == newCapture.values, "JSONL event/write order changed for \(kind), width \(width)")
                }
            }
        }

        var fixture = AgentFixture()
        for i in 0..<400 {
            let parent = fixture.add("parent-\(i)")
            fixture.add("folder-\(i)", to: parent, bytes: UInt64(100_000_000 + (i % 5) * 500_000), directory: true)
            fixture.add("large-\(i)", to: parent, bytes: UInt64(250_000_000 + (i % 5) * 500_000), directory: false)
        }
        let pass = fixture.add("pass-through")
        fixture.add("largest-descendant", to: pass, bytes: 700_000_000)
        fixture.add("below-directory-threshold", bytes: 99_999_999)
        fixture.add("below-file-threshold", bytes: 249_999_999, directory: false)
        let tree = fixture.tree()
        let expected = ReferenceAgentPrompt.build(tree: tree, scanRoot: "/fixture", known: [], running: [])
        check(AgentPrompt.build(tree: tree, scanRoot: "/fixture", known: [], running: []) == expected, "Prompt ordering, thresholds, pass-through, or ties changed")

        let sortedNodes = AgentPrompt.largestNodes(in: tree)
        let heapNodes = largestWithHeap(tree)
        check(sortedNodes.folders == heapNodes.0 && sortedNodes.files == heapNodes.1, "Heap alternative changed tie-boundary selection")

        let agent = InstalledAgent(kind: .codex, path: "/offline-do-not-launch", signedIn: true)
        let env = AgentEnvironment()
        let early = AgentRun(agent: agent, env: env, tree: tree, scanRoot: "/fixture", known: [], onFinish: {})
        let earlyTask = early.preparationTask!
        early.cancel(); await earlyTask.value
        check(AgentBenchmarkLaunch.calls == 0, "Cancelled-before-start task launched")
        AgentBenchmarkGate.shared.arm()
        let during = AgentRun(agent: agent, env: env, tree: tree, scanRoot: "/fixture", known: [], onFinish: {})
        let duringTask = during.preparationTask!
        for _ in 0..<1000 {
            if AgentBenchmarkGate.shared.hasEntered { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        check(AgentBenchmarkGate.shared.hasEntered, "Detached prompt did not reach test gate")
        during.cancel(); AgentBenchmarkGate.shared.release(); await duringTask.value
        check(AgentBenchmarkLaunch.calls == 0, "Cancelled-during-preparation task launched")
        let completed = AgentRun(agent: agent, env: env, tree: tree, scanRoot: "/fixture", known: [], onFinish: {})
        let completedTask = completed.preparationTask!
        await completedTask.value
        check(AgentBenchmarkLaunch.calls == 1 && completed.preparationTask == nil, "Uncancelled preparation did not launch exactly once")
        let model = ScanModel()
        model.tree = tree
        model.agentEnv = AgentEnvironment(agents: [agent], loaded: true)
        let batch = model.cleanupTrash
        var selected = (0..<10).map { CleanupItem(node: $0, path: "/offline/\($0)", display: "item-\($0)", kind: "fixture", bytes: 1, verify: "") }
        var completions = 0
        var failures: [String] = []
        AgentBenchmarkGate.shared.arm()
        let trashTask = batch.start(selected) { _, result in
            check(!batch.running, "Busy flag stayed set during rescan callback")
            failures = result
            completions += 1 // Stands in for the panel's one rescan callback.
        }!
        selected.removeAll() // The batch must retain the originally captured items.
        check(batch.running, "Busy state was not set synchronously")
        model.openPanelAfterLaunchScan()
        check(model.panelRequests == 0, "Launch panel opened while trash was busy")
        check(batch.start(selected) { _, _ in completions += 1 } == nil, "Busy batch accepted duplicate work")
        for _ in 0..<1000 {
            if AgentBenchmarkGate.shared.hasEntered { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        check(AgentBenchmarkGate.shared.hasEntered, "Background trash work did not start")
        var heartbeat = 0
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(2)); heartbeat += 1 }
        check(heartbeat == 5 && batch.running && completions == 0, "UI did not remain responsive during blocked trash I/O")
        AgentBenchmarkGate.shared.release(); await trashTask.value
        check(AgentBenchmarkTrash.shared.nodes == Array(0..<10), "Batch did not preserve the captured selection")
        check(failures == ["item-2: injected failure", "item-7: injected failure"], "Per-item trash failures changed")
        check(completions == 1 && !batch.running, "Batch did not complete/rescan exactly once")
        check(batch.failures == failures, "Controller did not retain failures after the panel callback")
        failures = [] // Discard the panel's local copy, as closing the inspector does.
        await Task.yield()
        let retainedFailures = ["item-2: injected failure", "item-7: injected failure"]
        check(model.cleanupTrash.failures == retainedFailures, "Closing the panel lost cleanup failures")
        let successfulTask = batch.start([CleanupItem(node: 10, path: "/offline/10", display: "item-10", kind: "fixture", bytes: 1, verify: "")]) { _, result in
            check(result.isEmpty, "A successful batch inherited an earlier batch's callback failures")
        }!
        await successfulTask.value
        check(batch.failures == retainedFailures, "A later batch erased unacknowledged failures")
        batch.clearFailures()
        check(batch.failures.isEmpty, "Acknowledged cleanup failures were not cleared")
        model.openPanelAfterLaunchScan()
        model.openPanelAfterLaunchScan()
        check(model.panelRequests == 1, "Busy cleanup consumed or duplicated the one-shot launch panel")
        check(AgentBenchmarkLaunch.agentStarts == 0 && model.agentRun == nil, "An agent started without a click")
        print("PASS: incremental parser split parity; JSONL event/write parity (both agents); prompt byte equality; cancellation prevents launch; trash batch stays off-main, rejects duplicate starts, retains failures until dismissed, completes once")
        guard !CommandLine.arguments.contains("--check-only") else { return }

        for (label, text, width) in [("normal-12-items", normal, 16), ("12-items-144-paths", plan(12, pathLength: 384, pathsPerItem: 12), 24)] {
            let pieces = chunks(text, width: width)
            paired("partial_parser \(label) bytes=\(text.utf8.count) deltas=\(pieces.count)", before: {
                var parser = ReferencePartialPlanParser(); var count = 0
                for piece in pieces { count += parser.append(piece).count }
                check(count == 12, "Baseline parser lost item")
            }, after: {
                var parser = PartialPlanParser(); var count = 0
                for piece in pieces { count += parser.append(piece).count }
                check(count == 12, "Parser lost item")
            })
        }
        let shortLines = Data((0..<4000).map { json(["method": "item/started", "params": ["item": ["type": "reasoning", "id": "\($0)"]]]) + "\n" }.joined().utf8)
        let longLine = Data((json(["method": "unknown", "params": ["text": String(repeating: "x", count: 512_000)]]) + "\n").utf8)
        for (label, bytes, width) in [("16k-read-batches", shortLines, 16384), ("long-record-fragments", longLine, 512)] {
            let pieces = stride(from: 0, to: bytes.count, by: width).map { Data(bytes[$0..<min($0 + width, bytes.count)]) }
            paired("jsonl \(label) bytes=\(bytes.count)", before: {
                let capture = AgentCapture()
                let reader = ReferenceAgentStreamReader(kind: .codex, prompt: "offline", folder: "/fixture", write: { _ in }, done: {}, emit: { capture.record(eventSignature($0)) })
                for piece in pieces { reader.feed(piece) }
                check(capture.values.count == (label == "16k-read-batches" ? 4000 : 0), "Baseline JSONL count")
            }, after: {
                let capture = AgentCapture()
                let reader = AgentStreamReader(kind: .codex, prompt: "offline", folder: "/fixture", write: { _ in }, done: {}, emit: { capture.record(eventSignature($0)) })
                for piece in pieces { reader.feed(piece) }
                check(capture.values.count == (label == "16k-read-batches" ? 4000 : 0), "JSONL count")
            })
        }
        var large = AgentFixture()
        for project in 0..<2000 {
            let parent = large.add("project-\(project)")
            let build = large.add("build", to: parent)
            large.add("artifact.bin", to: build, bytes: UInt64(100_000_000 + project % 20 * 1_000_000), directory: false)
            let sources = large.add("sources", to: parent)
            for file in 0..<500 { large.add("source-\(file).swift", to: sources, bytes: 4096, directory: false) }
        }
        let largeTree = large.tree()
        let reference = ReferenceAgentPrompt.build(tree: largeTree, scanRoot: "/fixture", known: [], running: [])
        check(AgentPrompt.build(tree: largeTree, scanRoot: "/fixture", known: [], running: []) == reference, "Large prompt changed")
        let selectedNodes = AgentPrompt.largestNodes(in: largeTree)
        check(largestWithHeap(largeTree).0 == selectedNodes.folders, "Heap alternative changed large selection")
        paired("prompt_candidates pruned-sort-vs-heap nodes=\(largeTree.count)", before: {
            check(AgentPrompt.largestNodes(in: largeTree).folders == selectedNodes.folders, "Sorted selection changed")
        }, after: {
            check(largestWithHeap(largeTree).0 == selectedNodes.folders, "Heap selection changed")
        })
        paired("prompt nodes=\(largeTree.count)", before: { check(ReferenceAgentPrompt.build(tree: largeTree, scanRoot: "/fixture", known: [], running: []) == reference, "Baseline prompt") }, after: { check(AgentPrompt.build(tree: largeTree, scanRoot: "/fixture", known: [], running: []) == reference, "Prompt") })
    }
}
