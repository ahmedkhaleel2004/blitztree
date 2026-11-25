import AppKit
import Foundation

// MARK: - Guards (enforced here, never left to the model)

/// The regular apps that are running, read on the main actor (AppKit's
/// process list is main-actor API) so the guards can compare paths against
/// them anywhere.
nonisolated struct RunningApps: Sendable {
    struct App: Sendable {
        let id: String
        let name: String
    }

    let apps: [App]

    @MainActor
    static func current() -> RunningApps {
        RunningApps(apps: NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .map { App(id: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "") })
    }

    /// An app that must be quit before its files go, when one is running.
    func owner(of paths: [String]) -> String? {
        for app in apps {
            for path in paths {
                let parts = path.split(separator: "/").map(String.init)
                if !app.id.isEmpty, parts.contains(where: { $0 == app.id || $0.hasPrefix(app.id + ".") }) { return app.name }
                if app.name.count > 2, parts.contains(app.name) { return app.name }
            }
        }
        return nil
    }
}

nonisolated enum CleanupGuard {
    static let home = NSHomeDirectory()

    static var rebuildable: Set<String> { CleanupPathSafety.rebuildable }

    static func blockReason(command: String) -> String? {
        CleanupCommand.parse(command) == nil ? "Command or arguments not allowed" : nil
    }

    /// The Codex app keeps each chat's files in ~/Documents/Codex/<date>/<chat>
    /// (outputs, work). Returns that chat folder for a path at or inside one.
    static func codexChat(_ path: String) -> String? {
        CleanupPathSafety.codexChat(path)
    }

    /// Whether the project owning this build folder was used in the last two
    /// days: its git index (touched by every status, commit or checkout), the
    /// project folder or the folder itself changed recently, or Claude Code
    /// worked in the project since. A Codex chat
    /// counts as used when it started or Codex worked in it since (folder
    /// dates are no help there: Finder's .DS_Store writes bump them).
    static func recentlyUsed(_ path: String, within: TimeInterval = 2 * 86400) -> Bool {
        recentUse(path, within: within) != .unused
    }

    /// `recentlyUsed` keeping apart "used" from "the agents' session logs could
    /// not all be read": the second is not evidence of use, but it blocks too,
    /// because the folder cannot be shown unused.
    static func recentUse(_ path: String, within: TimeInterval = 2 * 86400) -> AgentSessions.Usage {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-within)
        if let chat = codexChat(path) {
            let day = ((chat as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if let started = try? Date(day + "T23:59:59Z", strategy: .iso8601), started > cutoff { return .used }
            return AgentSessions.usage(in: chat, root: AgentSessions.codex, since: cutoff)
        }
        let url = URL(fileURLWithPath: path)
        guard rebuildable.contains(url.lastPathComponent) else { return .unused }
        let project = url.deletingLastPathComponent()
        var stamps = [path, project.path]
        let git = project.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
            if isDir.boolValue {
                stamps.append(git.appendingPathComponent("index").path)
            } else if let text = try? String(contentsOf: git, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                // A worktree: its index lives in the main repository.
                let dir = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                stamps.append(URL(fileURLWithPath: dir, relativeTo: project).appendingPathComponent("index").path)
            }
        }
        if stamps.contains(where: { p in
            ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date).map { $0 > cutoff } ?? false
        }) { return .used }
        return AgentSessions.claudeUsage(in: project.path, since: cutoff)
    }


    /// The outcome of vetting the paths of one agent plan card.
    struct Vetting {
        /// Targets that passed every guard, in the order they were asked.
        let kept: [CleanupTarget]
        /// How many asked paths were refused.
        let excluded: Int
        /// Why the first refused path was refused.
        let firstExclusion: String?
        /// Why the whole card is refused: nothing asked, or nothing kept.
        let blocked: String?
        /// Whether the card starts ticked.
        let preselect: Bool
    }

    /// Vet the folders a Trash card (or a cache command that only clears its
    /// own folder) asks to remove: each must pass the path policy, be an item
    /// in this scan (a directory when `folderCache`), not belong to a running
    /// app and not be in recent use. Refused paths are counted, not kept; the
    /// card is blocked only when none are left. It starts ticked only when
    /// something is kept and the model put it in the "safe" group. A path in
    /// a Claude Code scratchpad must also be, or be inside, a folder the scan
    /// itself recognised as cleanable (the session check stands in for the
    /// recent-use one: a scratchpad is new by nature).
    ///
    /// Reads files and may run git and lsof (a worktree), so it is not for
    /// the main actor; the running apps are read there beforehand (`apps`).
    /// The paths of one card share one lsof and one Codex log scan.
    static func vet(asked: [String], tree: Tree, home: String, folderCache: Bool, specGroup: String,
                    apps: RunningApps) -> Vetting {
        let evidence = WorktreeEvidence()
        var kept: [CleanupTarget] = []
        var excluded = 0
        var firstExclusion: String?
        var reason: String?
        if asked.isEmpty { reason = "Nothing to remove" }
        let indexByNode = tree.cleanupIndexByNode()
        let candidates = Set(indexByNode.keys)
        for path in asked {
            do {
                let root = CleanupPathSafety.plannerRoot(for: path, home: home)
                // The engine's rule for this path (or the folder around it) names
                // a check; the capture runs it, and so does the trash boundary.
                let normalized = try CleanupPathSafety.normalize(path)
                let found = tree.node(at: normalized)
                let check = found.map { tree.cleanupCheck(for: $0, path: normalized, indexByNode: indexByNode) } ?? .policyOnly
                let target = try CleanupPathSafety.capture(path: path, root: root, home: home, check: check,
                                                           evidence: evidence)
                guard let node = found, node != 0 else {
                    throw CleanupOperations.failure("Path is not an item in this scan")
                }
                if folderCache && !tree.isDir(node) {
                    throw CleanupOperations.failure("The cache path is not a scanned directory")
                }
                let scratch = root != home
                if scratch, !tree.ancestry(node).contains(where: candidates.contains) {
                    throw CleanupOperations.failure("Only build output BlitzTree recognised can go from a Claude Code scratchpad")
                }
                // Inside a folder the engine sorts item by item (a cache folder,
                // ~/.claude/projects, ~/.codex/worktrees...) only what the scan
                // itself recognised may go, and it answers to that item's check.
                // (A tool's own cache folder named by its allowlisted command is not a model-chosen path.)
                if !scratch, !folderCache, CleanupPathSafety.isInsideEngineContainer(target.path, home: home),
                   !tree.ancestry(node).contains(where: candidates.contains) {
                    throw CleanupOperations.failure("Not a folder the scan recognised as removable")
                }
                if codexChat(target.path) == nil,
                   let app = apps.owner(of: [target.path]) {
                    throw CleanupOperations.failure("Quit \(app) to clean this")
                }
                if !scratch {
                    switch recentUse(target.path) {
                    case .used:
                        throw CleanupOperations.failure(codexChat(target.path) != nil
                            ? "A Codex chat you used in the last 2 days" : "In a project used in the last 2 days")
                    case .unknown:
                        throw CleanupOperations.failure("Couldn't read the coding agents' session logs to check recent use")
                    case .unused:
                        break
                    }
                }
                kept.append(target)
            } catch {
                excluded += 1
                firstExclusion = firstExclusion ?? error.localizedDescription
            }
        }
        if kept.isEmpty { reason = reason ?? firstExclusion ?? "Nothing to remove" }
        return Vetting(kept: kept, excluded: excluded, firstExclusion: firstExclusion,
                       blocked: reason, preselect: reason == nil && specGroup == "safe")
    }
}
