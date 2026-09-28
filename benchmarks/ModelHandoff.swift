import Foundation

@_silgen_name("bz_fixture_free_count")
private func fixtureFreeCount() -> UInt32

/// Headless regression test for publishing a finished tree before capacity
/// metadata. It never creates NSApplication, a window, or an agent run.
@main
struct ModelHandoff {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--measure") {
            measure()
        } else {
            regression()
        }
    }

    @MainActor
    private static func regression() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitztree-model-handoff-\(UUID().uuidString)")
        let oldPath = root.appendingPathComponent("old").path
        let newPath = root.appendingPathComponent("new").path
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: oldPath),
                                                     withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: newPath),
                                                     withIntermediateDirectories: true)
        } catch {
            fatalError("Could not create fixture directories: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let model = ScanModel()
        // Keep the test headless: autoStartIfReady is a no-op while discovery
        // is not loaded, and this harness never calls AgentLocator.
        model.agentEnv = AgentEnvironment(loaded: false)

        model.startScan(path: oldPath)
        wait(until: { model.tree?.name(0) == oldPath && !model.scanning },
             message: "old tree was not published")
        precondition(model.freeBytes == 0 && model.unscannedBytes == 0,
                     "capacity was visible before the old delayed snapshot")
        weak var oldTree: Tree?
        oldTree = model.tree

        // The old snapshot remains delayed while the second scan completes.
        model.startScan(path: newPath)
        precondition(model.freeBytes == 0 && model.unscannedBytes == 0,
                     "rescan did not reset unknown capacity")
        wait(until: { model.tree?.name(0) == newPath && !model.scanning },
             message: "new tree was not published")
        precondition(model.freeBytes == 0 && model.unscannedBytes == 0,
                     "new tree waited for capacity or retained stale capacity")
        pump(for: 0.15)
        precondition(oldTree == nil && fixtureFreeCount() >= 1,
                     "old tree remained retained while its volume snapshot was pending")

        wait(until: { model.freeBytes == 222 && model.unscannedBytes == 443 },
             message: "new volume snapshot was not applied")
        // Let the slower old snapshot complete. It must not overwrite the
        // matching values for the newer tree.
        pump(for: 0.45)
        precondition(model.freeBytes == 222 && model.unscannedBytes == 443,
                     "old volume snapshot overwrote the rescan")
        print("PASS: tree-first handoff, zeroed capacity, and stale-volume rejection")
    }

    @MainActor
    private static func measure() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitztree-model-latency-\(UUID().uuidString)")
        let path = root.appendingPathComponent("latency").path
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path),
                                                     withIntermediateDirectories: true)
        } catch {
            fatalError("Could not create latency fixture: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let model = ScanModel()
        model.agentEnv = AgentEnvironment(loaded: false)
        let started = Date()
        model.startScan(path: path)
        wait(until: { model.tree != nil }, message: "tree was not published")
        let treeMilliseconds = -started.timeIntervalSinceNow * 1000
        wait(until: { !model.scanning }, message: "scan did not finish")
        let doneMilliseconds = -started.timeIntervalSinceNow * 1000
        wait(until: { model.freeBytes == 777 }, message: "volume snapshot was not applied")
        let volumeMilliseconds = -started.timeIntervalSinceNow * 1000
        print(String(format: "tree_ms=%.1f scan_done_ms=%.1f volume_ms=%.1f free=%llu",
                     treeMilliseconds, doneMilliseconds, volumeMilliseconds, model.freeBytes))
    }

    @MainActor
    private static func wait(until condition: () -> Bool, message: String) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(condition(), message)
    }

    @MainActor
    private static func pump(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }
}
