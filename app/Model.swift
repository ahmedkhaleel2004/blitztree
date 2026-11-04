import AppKit
import CryptoKit
import SwiftUI
import Foundation
import Observation

/// Zero-copy view over the Rust engine's flat tree arrays.
/// Read-only after init, so sharing it across threads is safe.
nonisolated final class Tree: @unchecked Sendable {
    private let handle: OpaquePointer
    let count: Int
    let parents: UnsafePointer<UInt32>
    /// What the list, maps and percentages show: allocated bytes with APFS
    /// clones counted once (the engine's unique size).
    let size: UnsafePointer<UInt64>
    /// Allocated bytes counting every clone in full.
    let allocated: UnsafePointer<UInt64>
    let logical: UnsafePointer<UInt64>
    let nFiles: UnsafePointer<UInt32>
    let flags: UnsafePointer<UInt8>
    let childOff: UnsafePointer<UInt32>
    let childArr: UnsafePointer<UInt32>
    let nameOff: UnsafePointer<UInt32>
    let nameBlob: UnsafePointer<UInt8>
    let cleanupCount: Int
    let cleanupNodes: UnsafePointer<UInt32>
    let errors: UInt64
    /// When the scan started.
    let scannedAt: Date
    /// Loaded from the last launch's saved scan, not scanned just now.
    let isSaved: Bool

    init?(handle: OpaquePointer, saved: Bool = false) {
        let n = bz_take_tree(handle)
        guard n > 0,
              let parents = bz_parents(handle),
              let size = bz_unique(handle),
              let allocated = bz_alloc(handle),
              let logical = bz_logical(handle),
              let nFiles = bz_nfiles(handle),
              let flags = bz_flags(handle),
              let childOff = bz_child_off(handle),
              let childArr = bz_children(handle),
              let nameOff = bz_name_off(handle),
              let nameBlob = bz_name_blob(handle),
              let cleanupNodes = bz_cleanup_nodes(handle)
        else { return nil }
        self.handle = handle
        self.count = Int(n)
        self.parents = parents
        self.size = size
        self.allocated = allocated
        self.logical = logical
        self.nFiles = nFiles
        self.flags = flags
        self.childOff = childOff
        self.childArr = childArr
        self.nameOff = nameOff
        self.nameBlob = nameBlob
        self.cleanupCount = Int(bz_cleanup_count(handle))
        self.cleanupNodes = cleanupNodes
        self.errors = bz_errors(handle)
        self.scannedAt = Date(timeIntervalSince1970: bz_scanned_at(handle))
        self.isSaved = saved
    }

    deinit { bz_free(handle) }

    /// Save this scan for the next launch. Slow on big trees: call it off
    /// the main thread.
    func save(to file: String) -> Bool { bz_cache_save(handle, file) == 0 }

    /// Names from the root down to `i`, to find the same file in another scan.
    func namePath(_ i: Int) -> [[UInt8]] {
        ancestry(i).dropFirst().map { node in
            let start = Int(nameOff[node])
            return Array(UnsafeBufferPointer(start: nameBlob + start, count: Int(nameOff[node + 1]) - start))
        }
    }

    /// The node at `names` (see `namePath`), if this scan has it.
    func node(at names: [[UInt8]]) -> Int? {
        var cur = 0
        for name in names {
            // Compared in place: big folders have 100k siblings.
            let match = name.withUnsafeBytes { want in
                children(cur).first { child in
                    let start = Int(nameOff[Int(child)])
                    return Int(nameOff[Int(child) + 1]) - start == want.count
                        && (want.isEmpty || memcmp(nameBlob + start, want.baseAddress!, want.count) == 0)
                }
            }
            guard let match else { return nil }
            cur = Int(match)
        }
        return cur
    }

    /// `node(at:)` for many paths at once. Each folder's children are indexed
    /// by name the first time a path goes through it, so paths sharing a big
    /// folder don't each search it.
    func nodes(at paths: [[[UInt8]]]) -> [Int?] {
        var index: [Int: [[UInt8]: Int]] = [:]
        return paths.map { names in
            var cur = 0
            for name in names {
                if index[cur] == nil {
                    let kids = children(cur)
                    var byName = [[UInt8]: Int](minimumCapacity: kids.count)
                    for child in kids {
                        let start = Int(nameOff[Int(child)])
                        let count = Int(nameOff[Int(child) + 1]) - start
                        byName[Array(UnsafeBufferPointer(start: nameBlob + start, count: count))] = Int(child)
                    }
                    index[cur] = byName
                }
                guard let next = index[cur]?[name] else { return nil }
                cur = next
            }
            return cur
        }
    }

    func isDir(_ i: Int) -> Bool { flags[i] & 1 != 0 }

    /// Bytes shared with APFS clones and counted elsewhere.
    func cloned(_ i: Int) -> UInt64 { allocated[i] - size[i] }

    /// "+918 GB cloned", or "2.26 GB cloned" for a clone counted elsewhere
    /// in full (its size is zero). Nil when the cloned bytes are under a
    /// tenth of the node's allocated size or under 1 MB.
    func cloneNote(_ i: Int) -> String? {
        let c = cloned(i)
        guard c >= 1_000_000, c >= allocated[i] / 10 else { return nil }
        return size[i] == 0 ? "\(Fmt.size(c)) cloned" : "+\(Fmt.size(c)) cloned"
    }

    /// What deleting each node frees; blocks shared with APFS clones don't
    /// count. The nodes must not contain one another.
    func reclaimable(_ nodes: [UInt32]) -> [UInt64] {
        guard !nodes.isEmpty else { return [] }
        var out = [UInt64](repeating: 0, count: nodes.count)
        nodes.withUnsafeBufferPointer { ids in
            out.withUnsafeMutableBufferPointer {
                bz_reclaimable(handle, ids.baseAddress, UInt64(ids.count), $0.baseAddress)
            }
        }
        return out
    }

    func cleanupDescription(_ index: Int) -> String {
        guard let label = bz_cleanup_description(handle, UInt64(index)) else { return "" }
        return String(cString: label)
    }

    func name(_ i: Int) -> String {
        let start = Int(nameOff[i])
        let end = Int(nameOff[i + 1])
        let buf = UnsafeBufferPointer(start: nameBlob + start, count: end - start)
        return String(decoding: buf, as: UTF8.self)
    }

    func children(_ i: Int) -> UnsafeBufferPointer<UInt32> {
        let start = Int(childOff[i])
        let end = Int(childOff[i + 1])
        return UnsafeBufferPointer(start: childArr + start, count: end - start)
    }

    /// Human-facing path: the Data-volume firmlink prefix reads as "/".
    func displayPath(_ i: Int) -> String {
        let p = path(i)
        let prefix = "/System/Volumes/Data"
        if p.hasPrefix(prefix) {
            let rest = String(p.dropFirst(prefix.count))
            return rest.isEmpty ? "/" : rest
        }
        return p
    }

    /// Full path: root's name is the scanned path itself.
    func path(_ i: Int) -> String {
        var parts: [String] = []
        var cur = i
        while cur != 0 {
            parts.append(name(cur))
            cur = Int(parents[cur])
            if cur == Int(UInt32.max) { break }
        }
        var p = name(0)
        if p.hasSuffix("/") { p.removeLast() }
        for part in parts.reversed() { p += "/" + part }
        return p
    }

    /// Chain of ancestors from root to node (inclusive), for breadcrumbs.
    func ancestry(_ i: Int) -> [Int] {
        var chain = [i]
        var cur = i
        while cur != 0 && cur != Int(UInt32.max) {
            cur = Int(parents[cur])
            chain.append(cur)
        }
        return chain.reversed()
    }

    /// What a map draws for `node`: itself, or when it has no shape of its
    /// own (merged into an "A ▸ B" box, too deep for the rings) the nearest
    /// drawn folder that is mostly it. Nil when only a much larger folder is.
    func drawn(_ node: Int, isDrawn: (Int) -> Bool) -> Int? {
        var cur = node
        while !isDrawn(cur) {
            let parent = parents[cur]
            guard parent != UInt32.max, size[Int(parent)] <= 2 * size[node] else { return nil }
            cur = Int(parent)
        }
        return cur
    }
}

enum FDA {
    /// FDA-protected paths deny silently (no dialog), so probing is safe.
    static func isActive() -> Bool {
        let home = NSHomeDirectory()
        for p in ["\(home)/Library/Messages", "\(home)/Library/Mail", "\(home)/Library/Safari"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil {
                return true
            }
        }
        return false
    }

    @MainActor
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}

/// How the scan is drawn: WizTree-style boxes or DaisyDisk-style rings.
enum MapStyle: String {
    case treemap, rings
}

@Observable
@MainActor
final class ScanModel {
    var files: UInt64 = 0
    var dirs: UInt64 = 0
    var bytes: UInt64 = 0
    var scanning = false
    var elapsed: Double = 0
    var tree: Tree?
    var scanRoot: String = {
        // `BlitzTree /some/path` scans that path on launch (also handy for QA).
        if CommandLine.arguments.count > 1 {
            var isDir: ObjCBool = false
            let p = (CommandLine.arguments[1] as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                return p
            }
        }
        // Whole disk by default: the user-data volume of the boot volume group.
        return "/System/Volumes/Data"
    }()
    /// Coding agents found on this Mac (Claude Code, Codex) and the user's PATH.
    var agentEnv = AgentEnvironment()
    /// The agent cleanup on screen, if any.
    var agentRun: AgentRun?
    /// An agent being installed or signed in from the panel.
    var agentSetup: AgentSetup?
    /// The first scan after launch opens the Clean Up panel once.
    private var panelOpenedAfterLaunch = false

    /// The agent to use: the one picked last, else Claude Code, else Codex.
    var preferredAgent: InstalledAgent? {
        let ready = agentEnv.ready
        let picked = UserDefaults.standard.string(forKey: "bz.agent")
        return ready.first { $0.kind.rawValue == picked } ?? ready.first { $0.kind == .claude } ?? ready.first
    }

    func startAgent(_ agent: InstalledAgent) {
        guard let tree, !scanning, !cleanupTrash.running else { return }
        UserDefaults.standard.set(agent.kind.rawValue, forKey: "bz.agent")
        agentRun?.cancel()
        let run = AgentRun(agent: agent, env: agentEnv, tree: tree, scanRoot: scanRoot, known: cleanup) { [weak self] in
            guard let self, !self.scanning else { return }
            self.startScan()
        }
        withAnimation(.snappy) { agentRun = run }
    }

    /// After the launch scan: open the panel on the Clean Up button or the
    /// setup offer. Nothing goes to an agent until the user clicks.
    func openPanelAfterLaunchScan() {
        guard !panelOpenedAfterLaunch, agentEnv.loaded, tree != nil, !scanning,
              !cleanupTrash.running, agentRun == nil else { return }
        panelOpenedAfterLaunch = true
        panelRequests += 1
        // QA only: BZ_QA_SETUP=claude|codex presses the setup button.
        if preferredAgent == nil, let kind = ProcessInfo.processInfo.environment["BZ_QA_SETUP"].flatMap(AgentKind.init) { setUp(kind) }
    }

    /// Bumped to ask the window to open the Clean Up panel.
    var panelRequests = 0

    func setUp(_ kind: AgentKind) {
        agentSetup?.cancel()
        let installed = agentEnv.agents.first { $0.kind == kind }
        agentSetup = AgentSetup(kind: kind, installed: installed, envPath: agentEnv.path) { [weak self] env in
            guard let self else { return }
            agentEnv = env
            agentSetup = nil
            if let agent = env.ready.first(where: { $0.kind == kind }) { startAgent(agent) }
        }
    }
    /// A tree has been shown at least once, so the views exist (see ContentView).
    var hasShownTree = false
    /// The last scan's saved results are being read; the fresh scan waits.
    var loadingSaved = false
    /// Roots whose saved results were already offered this session. A
    /// rescan, often right after a trash, must not bring back the old tree.
    @ObservationIgnored private var savedOffered: Set<String> = []
    var viewRoot: Int = 0 {
        didSet {
            // A selection outside the folder on screen would read as over 100%.
            if let sel = selection, let tree, !tree.ancestry(sel).contains(viewRoot) { selection = nil }
        }
    }
    var selection: Int? = nil

    /// Select a node from a list, zooming out first if it is outside the
    /// folder on screen (it would have nothing to outline).
    func reveal(_ node: Int) {
        if let tree, !tree.ancestry(node).contains(viewRoot) { viewRoot = 0 }
        selection = node
    }
    var hovered: Int? = nil
    var freeBytes: UInt64 = 0
    /// Rebuildable folders worth deleting, largest first.
    var cleanup: [CleanupItem] = []
    let cleanupTrash = CleanupTrashBatch()
    /// Volume-used minus what the scan could see: root-only territory.
    var unscannedBytes: UInt64 = 0
    var showFreeSpace: Bool = UserDefaults.standard.bool(forKey: "bz.showFree") {
        didSet { UserDefaults.standard.set(showFreeSpace, forKey: "bz.showFree") }
    }
    var mapStyle: MapStyle = MapStyle(rawValue: UserDefaults.standard.string(forKey: "bz.mapStyle") ?? "") ?? .treemap {
        didSet { UserDefaults.standard.set(mapStyle.rawValue, forKey: "bz.mapStyle") }
    }

    /// The tree on screen is the last launch's saved scan, shown while the
    /// fresh scan runs. Its node IDs and sizes may be out of date, so actions
    /// that delete by node wait for the fresh scan.
    var showingSaved: Bool { tree?.isSaved == true }

    private var handle: OpaquePointer?
    private var timer: Timer?
    private var startedAt: Date?
    private var activity: NSObjectProtocol?
    private var volumeTask: Task<VolumeSpace, Never>?
    /// Bumped per scan, so a saved scan that loads late is never shown over
    /// a newer one.
    private var scanNumber = 0

    func startScan(path: String? = nil) {
        if scanning || cleanupTrash.running { return }
        if let path { scanRoot = path }
        tree = nil
        cleanup = []
        viewRoot = 0
        selection = nil
        hovered = nil
        files = 0; dirs = 0; bytes = 0; elapsed = 0
        lastPollAt = nil; maxPollGap = 0
        scanning = true
        startedAt = Date()
        scanNumber += 1
        // Keep the process out of App Nap / timer coalescing while scanning.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Disk scan"
        )
        // Foundation may ask a disk-management service about purgeable space.
        // Read it alongside the scan, before publishing the finished tree, so
        // the main thread never waits synchronously on that service.
        let volumePath = scanRoot
        volumeTask = Task.detached(priority: .userInitiated) { VolumeSpace.read(volumePath) }
        showSavedScan(of: scanRoot, scan: scanNumber)

        // 60 Hz: the elapsed time ticks every frame, so the screen keeps
        // moving while the engine assembles the tree after the last file is
        // counted (the counters sit still for that part).
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Common modes: keep polling while a control is being clicked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var lastPollAt: Date?
    private var maxPollGap: Double = 0

    /// Load the last saved scan of `root` and show it until the real scan
    /// finishes. The real scan starts once loading ends: run together, both
    /// compete for every core and the saved scan took 5x longer to appear.
    /// A missing or unusable file is skipped.
    private func showSavedScan(of root: String, scan: Int) {
        if savedOffered.isEmpty { Task.detached(priority: .utility) { ScanCache.removeAbandonedTemps() } }
        let file = ScanCache.file(for: root)
        guard ScanCache.enabled, savedOffered.insert(root).inserted, ScanCache.fitsInMemory(file) else {
            handle = bz_scan_start(root)
            return
        }
        loadingSaved = FileManager.default.fileExists(atPath: file)
        Task {
            let saved = await Task.detached(priority: .userInitiated) { () -> Tree? in
                guard let h = bz_cache_load(file, root) else { return nil }
                let saved = Tree(handle: h, saved: true)
                if saved == nil { bz_free(h) }
                return saved
            }.value
            if scan == scanNumber { loadingSaved = false }
            if scan == scanNumber, scanning, handle == nil { handle = bz_scan_start(root) }
            guard let saved, scan == scanNumber, scanning, tree == nil else { return }
            tree = saved
            hasShownTree = true
            let found = await Task.detached(priority: .userInitiated) { Cleanup.find(in: saved) }.value
            guard self.tree === saved else { return }
            cleanup = found
        }
    }

    private func poll() {
        guard let handle else {
            // A slow volume-space service must not freeze progress while the
            // already finished tree waits for its matching volume snapshot.
            if scanning { elapsed = -(startedAt?.timeIntervalSinceNow ?? 0) }
            return
        }
        if let last = lastPollAt { maxPollGap = max(maxPollGap, -last.timeIntervalSinceNow) }
        lastPollAt = Date()
        var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0
        var done: Int32 = 0
        bz_progress(handle, &f, &d, &b, &done)
        files = f; dirs = d; bytes = b
        elapsed = -(startedAt?.timeIntervalSinceNow ?? 0)
        if done != 0 {
            let doneAt = Date()
            let result = Tree(handle: handle)
            self.handle = nil
            if result == nil { bz_free(handle) }
            let pendingVolume = volumeTask
            volumeTask = nil
            Task {
                let space = await pendingVolume?.value ?? VolumeSpace(free: nil, used: nil)
                finishScan(result, space: space, doneAt: doneAt)
            }
        }
    }

    private func finishScan(_ result: Tree?, space: VolumeSpace, doneAt: Date) {
        timer?.invalidate()
        timer = nil
        if let saved = tree, saved.isSaved, let result {
            // Keep the folder on screen and the selection, found by path.
            let root = result.node(at: saved.namePath(viewRoot)) ?? 0
            let picked = selection.flatMap { result.node(at: saved.namePath($0)) }
            selection = nil
            hovered = nil
            cleanup = []
            tree = result
            viewRoot = root
            if let picked, result.ancestry(picked).contains(root) { selection = picked }
        } else {
            tree = result
        }
        if tree != nil { hasShownTree = true }
        if let result, ScanCache.enabled {
            let file = ScanCache.file(for: scanRoot)
            Task.detached(priority: .utility) {
                ScanCache.lock.withLock {
                    // Turned off or deleted while this scan finished.
                    guard ScanCache.enabled else { return }
                    if !result.save(to: file) { NSLog("BZ couldn't save the scan to %@", file) }
                    // Too big for this Mac to show; don't keep it on disk.
                    if !ScanCache.fitsInMemory(file) { try? FileManager.default.removeItem(atPath: file) }
                }
            }
        }
        if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
            // Queue latency includes awaiting metadata and UI updates; it is
            // not a measurement of uninterrupted main-thread blocking.
            DispatchQueue.main.async {
                NSLog("BZ hand-off: queued completion %.1f ms after engine done", -doneAt.timeIntervalSinceNow * 1000)
            }
            NSLog("BZ done at %.3f, longest gap between polls %.1f ms", doneAt.timeIntervalSinceReferenceDate, maxPollGap * 1000)
        }
        scanning = false
        if let tree {
            Task {
                let found = await Task.detached(priority: .userInitiated) { Cleanup.find(in: tree) }.value
                // A rescan may have replaced the tree while discovery ran.
                // Node IDs only belong to the scan that produced them.
                guard self.tree === tree else { return }
                cleanup = found
                openPanelAfterLaunchScan()
            }
            NSLog("BZ scan done: %llu nodes, %llu unreadable dirs", UInt64(tree.count), tree.errors)
        }
        freeBytes = space.free ?? 0
        // Coverage honesty: compare scanned bytes with what the volume
        // says it holds. The difference is root-only space (Spotlight
        // index, unified logs, …) no unelevated app can read.
        unscannedBytes = 0
        if let tree, let used = space.used {
            let seen = tree.size[0]
            if used > seen {
                unscannedBytes = used - seen
            }
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// Where each scanned folder's last finished scan is saved.
nonisolated enum ScanCache {
    /// ~/Library/Caches/<bundle id>/scan-<hash of the root>.bzcache.
    /// BZ_CACHE_DIR overrides the folder (QA and benchmarks).
    static func file(for root: String) -> String {
        let hash = SHA256.hash(data: Data(root.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(dir)/scan-\(hash).bzcache"
    }

    static var dir: String {
        ProcessInfo.processInfo.environment["BZ_CACHE_DIR"] ?? {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.ahmed.blitztree").path
        }()
    }

    /// "Save Results for Fast Launch" in the BlitzTree menu; on by default.
    static let enabledKey = "bz.saveResults"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Every saved scan, including temp files a quit cut short.
    static func savedFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix("scan-") && $0.contains(".bzcache") }.map { "\(dir)/\($0)" }
    }

    static func savedBytes() -> UInt64 {
        savedFiles().reduce(0) { sum, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
            return sum + size
        }
    }

    /// Whether showing the saved results during the fresh scan leaves room:
    /// both trees are in memory until it finishes. A whole-disk scan of 40M
    /// nodes saved 298 MB and took 2.6 GB loaded and 2.7 GB scanning, so the
    /// two take about 18 times the file's size. They may use half the RAM.
    static func fitsInMemory(_ file: String) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? UInt64) ?? 0
        return size * 18 <= ProcessInfo.processInfo.physicalMemory / 2
    }

    /// Held while a save writes and while saved results are deleted, so a
    /// save in flight can't put a file back after Delete Saved Results….
    static let lock = NSLock()

    static func deleteAll() {
        lock.withLock {
            for path in savedFiles() { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    /// Temp files a quit cut short: `scan-<hash>.bzcache.tmp-<pid>-<n>`
    /// whose process is gone.
    static func removeAbandonedTemps() {
        for path in savedFiles() {
            guard let range = path.range(of: ".tmp-") else { continue }
            let pid = path[range.upperBound...].split(separator: "-").first.flatMap { Int32($0) }
            guard let pid, pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

nonisolated private struct VolumeSpace: Sendable {
    let free: UInt64?
    let used: UInt64?

    static func read(_ path: String) -> VolumeSpace {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return VolumeSpace(
            free: values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) },
            used: path == "/System/Volumes/Data" ? volumeUsedBytes(path) : nil
        )
    }
}

/// Space used by this APFS volume alone, the figure `df` shows. statfs and
/// Foundation's systemSize/systemFreeSize describe the whole container,
/// which also holds the macOS system volume, VM swap and Recovery.
nonisolated func volumeUsedBytes(_ path: String) -> UInt64? {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
    var reply = (length: UInt32(0), used: UInt64(0))
    let status = withUnsafeMutableBytes(of: &reply) {
        getattrlist(path, &request, $0.baseAddress, $0.count, 0)
    }
    guard status == 0 else { return nil }
    // Packed buffer: u_int32_t length, then off_t at offset 4 (unaligned).
    return withUnsafeBytes(of: &reply) { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
}

nonisolated enum Fmt {
    static func size(_ b: UInt64) -> String { Int64(b).formatted(.byteCount(style: .file)) }
    static func num(_ n: UInt64) -> String { n.formatted() }
}
