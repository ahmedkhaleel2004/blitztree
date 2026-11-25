import AppKit
import Foundation

@main
struct ScanFailureChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        guard let physical = realpath(fm.temporaryDirectory.path, nil) else { fatalError("tmp") }
        let base = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("blitztree-fail-\(UUID().uuidString)")
        free(physical)
        try fm.createDirectory(at: base.appendingPathComponent("real"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data(repeating: 1, count: 5000).write(to: base.appendingPathComponent("real/a.bin"))
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("link").path, withDestinationPath: "real")

        let model = ScanModel()
        // An empty path gives no engine handle: the scan must end as failed, not spin.
        model.startScan(path: "")
        precondition(!model.scanning, "a scan with no handle is not left running")
        precondition(model.scanFailed && model.tree == nil, "and it reads as failed")

        // A new scan is allowed after the failure, and clears it.
        model.startScan(path: base.appendingPathComponent("link").path)
        precondition(model.scanning && !model.scanFailed)
        let deadline = Date().addingTimeInterval(20)
        while model.scanning && Date() < deadline {
            runLoop(for: 0.01)
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(!model.scanning, "the scan through a symlinked root finished")
        precondition(!model.scanFailed, "and did not fail")
        precondition(model.tree?.count == 2, "root and a.bin were read through the link (\(String(describing: model.tree?.count)))")
        print("PASS: failed-scan state, rescan after failure, symlinked root")
    }

    private static func runLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
