import Foundation

@main
struct CleanupIntegrationChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.path
        guard let physical = realpath(temporary, nil) else { fatalError("cannot resolve temporary directory") }
        let temporaryURL = URL(fileURLWithPath: String(cString: physical))
        free(physical)
        let fixture = temporaryURL
            .appendingPathComponent("blitztree-cleanup-\(UUID().uuidString)")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home").path
        func directory(_ relative: String) throws -> String {
            let path = home + "/" + relative
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        let cache = try directory(".cache/uv")
        let other = try directory(".cache/other")
        let secret = try directory(".ssh/node_modules")
        try Data(repeating: 1, count: 8192).write(to: URL(fileURLWithPath: cache + "/data"))
        guard let handle = bz_scan_start(home) else { fatalError("fixture scan failed") }
        var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0, done: Int32 = 0
        while done == 0 {
            bz_progress(handle, &files, &dirs, &bytes, &done)
            if done == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard let tree = Tree(handle: handle) else { bz_free(handle); fatalError("fixture tree failed") }
        func spec(_ paths: [String], action: String = "trash", command: String = "") -> PlanItemSpec {
            PlanItemSpec(title: "Same title", detail: "Fixture", group: "safe", bytes: 999_999,
                         paths: paths, action: action, command: command)
        }
        func plan(_ value: PlanItemSpec) -> PlanItem { PlanItem(spec: value, tree: tree, home: home) }
        let valid = plan(spec([cache], action: "command", command: "uv cache clean"))
        precondition(valid.blocked == nil && valid.viaTrash && valid.paths == [cache])
        precondition(valid.bytes == tree.alloc[tree.node(at: cache)!], "use scanned bytes")
        let inferred = plan(spec([], action: "command", command: "uv cache clean"))
        precondition(inferred.paths == [cache] && inferred.blocked == nil)
        for value in [
            spec([other], action: "command", command: "uv cache clean"),
            spec([other], action: "command", command: "uv cache clean --all"),
            spec([secret]), spec([home]), spec([cache], action: "unknown"),
            spec([cache], command: "uv cache clean"),
        ] {
            let item = plan(value)
            precondition(item.blocked != nil && !item.selected && item.cleanupTargets.isEmpty)
        }
        let unscanned = try directory(".cache/created-after-scan")
        precondition(plan(spec([unscanned])).blocked != nil)
        let partial = plan(spec([secret, cache, cache + "/data", cache]))
        precondition(partial.paths == [cache] && partial.note != nil)
        precondition(partial.bytes == valid.bytes, "nested and duplicate targets counted once")
        precondition(plan(spec([], action: "command", command: "docker system prune -f")).blocked != nil)
        let original = plan(spec([cache], action: "command", command: "docker system prune -f"))
        precondition(original.blocked == nil && !original.selected && original.note != nil)
        for state in [PlanItem.Status.waiting, .running] {
            original.status = state
            precondition(original.pendingBytes == original.bytes, "running commands stay in the countdown")
        }
        original.status = .done
        precondition(original.pendingBytes == 0, "completed commands leave the countdown")
        original.status = .waiting
        valid.trashedBytes = valid.bytes / 2
        valid.status = .running
        precondition(valid.pendingBytes == valid.trashedBytes, "count only folders actually moved")
        valid.status = .failed("partial removal")
        precondition(valid.pendingBytes == valid.trashedBytes, "failed receipts remain visible")
        valid.trashedBytes = 0
        valid.status = .done
        precondition(valid.pendingBytes == 0)
        let simulatorID = "12345678-1234-1234-1234-123456789ABC"
        for command in ["xcrun simctl erase \(simulatorID)", "xcrun simctl runtime delete \(simulatorID)"] {
            let simulator = plan(spec([other], action: "command", command: command))
            precondition(simulator.blocked == nil && !simulator.selected && simulator.isCommand)
            precondition(simulator.cleanupTargets.isEmpty && simulator.bytes == tree.alloc[tree.node(at: other)!])
            precondition(plan(spec([unscanned], action: "command", command: command)).blocked != nil)
        }
        let changed = spec([], action: "command", command: "docker system prune -f --volumes")
        let final = PlanItem.reconcile([original.spec, changed], previous: [original], tree: tree)
        precondition(final[0] === original, "unchanged actions retain their captured identities")
        precondition(final[1].blocked != nil && !final[1].selected, "same title must not hide changed action")
        let newValid = spec([], action: "command", command: "docker builder prune -f")
        precondition(!PlanItem.reconcile([newValid], previous: [original], tree: tree)[0].selected)
        let invalidCommand = await AgentRun.runCommand("docker system prune -f --volumes", path: "/usr/bin")
        precondition(invalidCommand != nil, "execution must independently reject changed arguments")
        let relativeTool = await AgentRun.runCommand("docker system prune -f", path: ".:relative:")
        precondition(relativeTool != nil, "relative executable lookup must be refused")

        // Move only inside this disposable fixture: never use the user's Trash.
        let trash = fixture.appendingPathComponent("fake-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        func stage(_ relative: String) throws -> CleanupReceipt {
            let path = try directory(relative)
            let target = try CleanupPathSafety.capture(path: path, root: home, home: home)
            return try CleanupOperations.trash(target) { source in
                let destination = trash.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: source, to: destination)
                return destination
            }
        }
        let replacedPath = try directory(".cache/replaced")
        let stale = try CleanupPathSafety.capture(path: replacedPath, root: home, home: home)
        try fm.moveItem(atPath: replacedPath, toPath: replacedPath + "-old")
        _ = try directory(".cache/replaced")
        var movedStale = false
        do {
            _ = try CleanupOperations.trash(stale) { url in movedStale = true; return url }
            fatalError("replacement should fail validation")
        } catch { precondition(!movedStale) }

        let failed = try stage(".cache/partial")
        let good = try stage(".cache/success")
        for name in ["keep", "remove"] {
            try Data([1]).write(to: failed.url.appendingPathComponent(name))
        }
        let result = await CleanupOperations.remove([failed, good]) { path in
            if URL(fileURLWithPath: path).lastPathComponent == "keep" { return "injected removal failure" }
            do { try FileManager.default.removeItem(atPath: path); return nil }
            catch { return error.localizedDescription }
        }
        precondition(result.remaining.count == 1 && result.remaining[0].url == failed.url)
        precondition(!result.errors.isEmpty && fm.fileExists(atPath: failed.url.path + "/keep"))
        precondition(!fm.fileExists(atPath: good.url.path))
        let retry = await CleanupOperations.remove(result.remaining)
        precondition(retry.errors.isEmpty && retry.remaining.isEmpty && !fm.fileExists(atPath: failed.url.path))

        let linked = try stage(".cache/linked-child")
        let unrelated = fixture.appendingPathComponent("unrelated")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data([1]).write(to: unrelated.appendingPathComponent("keep"))
        try fm.createSymbolicLink(at: linked.url.appendingPathComponent("link"), withDestinationURL: unrelated)
        let unlinked = await CleanupOperations.remove([linked])
        precondition(unlinked.errors.isEmpty && fm.fileExists(atPath: unrelated.path + "/keep"),
                     "recursive removal must not follow a symlink child")

        let altered = try stage(".cache/altered")
        try fm.moveItem(at: altered.url, to: altered.url.appendingPathExtension("old"))
        try fm.createDirectory(at: altered.url, withIntermediateDirectories: true)
        let rejected = await CleanupOperations.remove([altered]) { _ in
            fatalError("a replaced Trash item must not reach the eraser")
        }
        precondition(rejected.remaining.count == 1 && !rejected.errors.isEmpty)
        let parent = try stage(".cache/parent")
        let movedTrash = trash.appendingPathExtension("old")
        try fm.moveItem(at: trash, to: movedTrash)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try fm.moveItem(at: movedTrash.appendingPathComponent(parent.url.lastPathComponent), to: parent.url)
        let changedParent = await CleanupOperations.remove([parent]) { _ in
            fatalError("a replaced Trash parent must not reach the eraser")
        }
        precondition(changedParent.remaining.count == 1 && !changedParent.errors.isEmpty)
        print("PASS: scanned plans, final action changes, guarded moves, receipt identity and partial removal")
    }
}
