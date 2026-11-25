import AppKit
import SwiftUI
import Foundation
import Observation

/// Zero-copy view over the Rust engine's flat tree arrays.
/// Read-only after init, so sharing it across threads is safe.
nonisolated final class Tree: @unchecked Sendable {
    private let handle: OpaquePointer
    let count: Int
    let parents: UnsafePointer<UInt32>
    let alloc: UnsafePointer<UInt64>
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

    init?(handle: OpaquePointer) {
        let n = bz_take_tree(handle)
        guard n > 0,
              let parents = bz_parents(handle),
              let alloc = bz_alloc(handle),
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
        self.alloc = alloc
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
    }

    deinit { bz_free(handle) }

    func isDir(_ i: Int) -> Bool { flags[i] & 1 != 0 }

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

    /// The `limit` largest files anywhere in the scan, largest first. Chosen by
    /// the engine (the CLI's `largest_files` uses the same code).
    func largestFiles(limit: Int = 1000, minBytes: UInt64 = 0) -> [Int] {
        guard let list = bz_largest_files(handle, UInt32(limit), minBytes) else { return [] }
        defer { bz_largest_free(list) }
        let count = Int(bz_largest_count(list))
        guard count > 0, let ptr = bz_largest_nodes(list) else { return [] }
        return (0..<count).map { Int(ptr[$0]) }
    }

    /// Allocated bytes and file counts per extension under `root`, largest
    /// first, totalled by the engine in one pass over the files.
    func types(root: Int) -> [TypeRow] {
        guard root >= 0, root < count, let t = bz_types(handle, UInt32(root)) else { return [] }
        defer { bz_types_free(t) }
        let n = Int(bz_types_count(t))
        guard n > 0, let off = bz_types_ext_off(t), let blob = bz_types_ext_blob(t),
              let alloc = bz_types_alloc(t), let files = bz_types_files(t) else { return [] }
        return (0..<n).map { i in
            let ext = Array(UnsafeBufferPointer(start: blob + Int(off[i]), count: Int(off[i + 1] - off[i])))
            return TypeRow(ext: ext, alloc: alloc[i], files: files[i])
        }
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
            guard parent != UInt32.max, alloc[Int(parent)] <= 2 * alloc[node] else { return nil }
            cur = Int(parent)
        }
        return cur
    }
}

/// One extension's share of a folder. `ext` is ASCII-lowercased bytes
/// without the dot, empty for files without an extension.
nonisolated struct TypeRow: Sendable, Identifiable {
    let ext: [UInt8]
    let alloc: UInt64
    let files: UInt64
    var id: [UInt8] { ext }
    var name: String { String(decoding: ext, as: UTF8.self) }
    /// Its colour group, from the table the treemap paints with.
    var kind: TypeColor.Kind { TypeColor.kind(ofExtension: name) }
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
    var viewRoot: Int = 0 {
        didSet {
            // A selection outside the folder on screen would read as over 100%.
            if let sel = selection, let tree, !tree.ancestry(sel).contains(viewRoot) { selection = nil }
            if viewRoot != oldValue { refreshTypes() }
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
    /// Volumes the Scan menu lists; kept current by `watchVolumes`.
    var volumes: [ScanVolume] = [.bootFallback]
    private var volumeObservers: [NSObjectProtocol] = []
    private var volumeListGeneration: UInt64 = 0

    /// Lists mounted volumes now and again whenever one mounts, unmounts or
    /// is renamed.
    func watchVolumes() {
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
        refreshVolumes()
    }

    /// Re-reads the volume list off the main thread: a slow disk spinning
    /// up must not stall the window. The newest request wins.
    func refreshVolumes() {
        volumeListGeneration &+= 1
        let generation = volumeListGeneration
        Task {
            let found = await Task.detached(priority: .utility) { ScanVolume.mounted() }.value
            guard generation == volumeListGeneration else { return }
            volumes = found
        }
    }
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

    // MARK: file types

    var showTypes: Bool = UserDefaults.standard.bool(forKey: "bz.showTypes") {
        didSet {
            UserDefaults.standard.set(showTypes, forKey: "bz.showTypes")
            refreshTypes()
        }
    }
    /// Extensions under `typesRoot`, largest first; empty while hidden.
    var typeRows: [TypeRow] = []
    /// The folder `typeRows` describes: the view root they were made for.
    var typesRoot: Int = 0
    /// The extension picked in the list (see `TypeRow.ext`).
    var selectedType: [UInt8]?
    /// What the treemap highlights: the picked type while the list is shown.
    var highlightedType: [UInt8]? { showTypes ? selectedType : nil }
    private var typesTask: Task<Void, Never>?

    /// Re-total the folder on screen, off the main thread. Only while the
    /// list is shown; a zoom or a new tree calls this again.
    func refreshTypes() {
        typesTask?.cancel()
        guard showTypes, let tree else {
            typeRows = []
            return
        }
        let root = viewRoot
        typesTask = Task.detached(priority: .userInitiated) { [tree] in
            let rows = tree.types(root: root)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.tree === tree, self.viewRoot == root, self.showTypes else { return }
                self.typeRows = rows
                self.typesRoot = root
                // A type with no files in this folder has nothing to light.
                if let picked = self.selectedType, !rows.contains(where: { $0.ext == picked }) {
                    self.selectedType = nil
                }
            }
        }
    }

    private var handle: OpaquePointer?
    private var timer: Timer?
    private var startedAt: Date?
    private var activity: NSObjectProtocol?
    private var volumeTask: Task<VolumeSpace, Never>?

    func startScan(path: String? = nil) {
        if scanning || cleanupTrash.running { return }
        if let path { scanRoot = path }
        tree = nil
        cleanup = []
        typesTask?.cancel()
        typeRows = []
        selectedType = nil
        viewRoot = 0
        selection = nil
        hovered = nil
        files = 0; dirs = 0; bytes = 0; elapsed = 0
        lastPollAt = nil; maxPollGap = 0
        scanning = true
        startedAt = Date()
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
        handle = bz_scan_start(scanRoot)

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
        tree = result
        if tree != nil { hasShownTree = true }
        if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
            // Queue latency includes awaiting metadata and UI updates; it is
            // not a measurement of uninterrupted main-thread blocking.
            DispatchQueue.main.async {
                NSLog("BZ hand-off: queued completion %.1f ms after engine done", -doneAt.timeIntervalSinceNow * 1000)
            }
            NSLog("BZ done at %.3f, longest gap between polls %.1f ms", doneAt.timeIntervalSinceReferenceDate, maxPollGap * 1000)
        }
        scanning = false
        // Used and free change as files come and go; the menu is usable again.
        refreshVolumes()
        if let tree {
            Task {
                let found = await Task.detached(priority: .userInitiated) { Cleanup.find(in: tree) }.value
                // A rescan may have replaced the tree while discovery ran.
                // Node IDs only belong to the scan that produced them.
                guard self.tree === tree else { return }
                cleanup = found
                openPanelAfterLaunchScan()
            }
            refreshTypes()
            NSLog("BZ scan done: %llu nodes, %llu unreadable dirs", UInt64(tree.count), tree.errors)
        }
        freeBytes = space.free ?? 0
        // Coverage honesty: compare scanned bytes with what the volume
        // says it holds. The difference is root-only space (Spotlight
        // index, unified logs, …) no unelevated app can read.
        unscannedBytes = 0
        if let tree, let used = space.used {
            let seen = tree.alloc[0]
            if used > seen {
                unscannedBytes = used - seen
            }
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

nonisolated struct VolumeSpace: Sendable {
    let free: UInt64?
    let used: UInt64?

    static func read(_ path: String) -> VolumeSpace {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return VolumeSpace(
            free: free(important: values?.volumeAvailableCapacityForImportantUsage,
                       available: values?.volumeAvailableCapacity),
            used: path == "/System/Volumes/Data" ? volumeUsedBytes(path) : nil
        )
    }

    /// Free space as Finder counts it. APFS adds purgeable space to the
    /// important-usage figure; exFAT, FAT and NTFS answer it with 0, so
    /// those fall back to the plain free count.
    static func free(important: Int64?, available: Int?) -> UInt64? {
        if let important, important > 0 { return UInt64(important) }
        if let available { return UInt64(max(0, available)) }
        return important.map { UInt64(max(0, $0)) }
    }
}

/// A mounted volume the Scan menu offers.
nonisolated struct ScanVolume: Sendable, Equatable, Identifiable {
    let name: String
    /// What scanning this volume reads.
    let path: String
    let isInternal: Bool
    let total: UInt64
    let free: UInt64
    var used: UInt64 { total > free ? total - free : 0 }
    var id: String { path }

    static let bootDataPath = "/System/Volumes/Data"
    /// Shown until the first enumeration finishes, or if it finds nothing.
    static let bootFallback = ScanVolume(
        name: "Macintosh HD", path: bootDataPath, isInternal: true, total: 0, free: 0)

    /// One mount as plain values, so the menu's rules can be checked
    /// without the mount existing.
    struct Facts: Sendable {
        var path: String
        var name: String?
        var isRootFileSystem = false
        var isLocal = true
        var isBrowsable = true
        var isInternal: Bool?
        var total: Int?
        var available: Int?
        var availableForImportantUsage: Int64?
    }

    init(name: String, path: String, isInternal: Bool, total: UInt64, free: UInt64) {
        self.name = name; self.path = path; self.isInternal = isInternal
        self.total = total; self.free = free
    }

    init?(_ facts: Facts) {
        // Hidden mounts (VM, Preboot, Recovery, cryptexes, autofs) are
        // system plumbing, not something to scan.
        guard facts.isBrowsable else { return nil }
        // Network shares are left out; Choose Folder... still reaches them.
        // Each directory read is a server round trip, so the engine's
        // parallel walk turns a large share into a long scan that loads the
        // server, and a stalled share can hang the read entirely. The
        // capacity a server reports may be a quota rather than its disk.
        guard facts.isLocal else { return nil }
        if facts.isRootFileSystem {
            // `/` is the sealed system snapshot; the user's data is on the
            // Data volume, which is what Macintosh HD scans everywhere else.
            name = "Macintosh HD"
            path = Self.bootDataPath
            isInternal = true
        } else {
            name = facts.name ?? (facts.path as NSString).lastPathComponent
            path = facts.path
            isInternal = facts.isInternal ?? false
        }
        total = UInt64(max(0, facts.total ?? 0))
        free = min(total, VolumeSpace.free(important: facts.availableForImportantUsage,
                                           available: facts.available) ?? 0)
    }

    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey,
        .volumeIsBrowsableKey, .volumeIsInternalKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]

    /// Mounted local volumes, the boot volume first. Reads every mount's
    /// metadata, so call it off the main thread.
    static func mounted() -> [ScanVolume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap { url -> ScanVolume? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return ScanVolume(Facts(
                path: url.path, name: v.volumeLocalizedName,
                isRootFileSystem: v.volumeIsRootFileSystem ?? false,
                // Unknown counts as remote and hidden: left out, not guessed in.
                isLocal: v.volumeIsLocal ?? false, isBrowsable: v.volumeIsBrowsable ?? false,
                isInternal: v.volumeIsInternal, total: v.volumeTotalCapacity,
                available: v.volumeAvailableCapacity,
                availableForImportantUsage: v.volumeAvailableCapacityForImportantUsage))
        }
        // Macintosh HD stays on the menu even if its mount could not be read.
        let boot = volumes.first { $0.path == bootDataPath } ?? bootFallback
        return [boot] + volumes.filter { $0.path != bootDataPath }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
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
