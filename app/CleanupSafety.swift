import Darwin
import Foundation

/// Stable metadata used to detect a path replacement between planning and an
/// operation.  This deliberately uses lstat: a symlink is a different object
/// from its target and is never silently followed by the guard.
nonisolated struct CleanupIdentity: Sendable, Equatable, Hashable {
    let device: UInt64
    let inode: UInt64
    let type: UInt16

    static func capture(path: String) throws -> CleanupIdentity {
        let normalized = try CleanupPathSafety.normalize(path)
        return try CleanupPathSafety.identity(of: normalized)
    }
}

nonisolated enum CleanupPathError: Error, LocalizedError, Equatable, Sendable {
    case invalidPath(String)
    case unavailable(String, Int32)
    case missing(String)
    case notDirectory(String)
    case symlink(String)
    case cloudOnly(String)
    case outsideRoot(String)
    case differentVolume(String)
    case changed(String)
    case protectedPath(String)
    case tooBroad(String)
    case gitPath(String)
    /// A linked git worktree that was recognised but did not pass verification.
    case gitWorktree(GitWorktreeError)
    /// Inside the temp folder of a Claude Code session that is still running.
    case sessionRunning(String)
    /// Inside a Claude Code session's temp folder, and whether that session
    /// still runs could not be read.
    case sessionUnverified(String)
    /// The check the engine's rule names for this folder did not pass.
    case checkFailed(localized: String, english: String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Invalid cleanup path: \(path)"
        case .unavailable(let path, let code): return "Cannot inspect \(path) (errno \(code))"
        case .missing(let path): return "Path is missing: \(path)"
        case .notDirectory(let path): return "Path component is not a directory: \(path)"
        case .symlink(let path): return "Symlinks are not allowed in cleanup paths: \(path)"
        case .cloudOnly(let path): return "Cloud-only path is not available locally: \(path)"
        case .outsideRoot(let path): return "Path is outside the authorized scan root: \(path)"
        case .differentVolume(let path): return "Path is on a different volume: \(path)"
        case .changed(let path): return "Path changed since it was checked: \(path)"
        case .protectedPath(let path): return "Protected path: \(path)"
        case .tooBroad(let path): return "Path is too broad to clean: \(path)"
        case .gitPath(let path): return "Git metadata path is protected: \(path)"
        case .gitWorktree(let error): return error.errorDescription
        case .sessionRunning(let path): return "A Claude Code session that is still running uses this: \(path)"
        case .sessionUnverified(let path): return "Couldn't check whether the Claude Code session using this has ended: \(path)"
        case .checkFailed(let localized, _): return localized
        }
    }

    var englishDescription: String {
        switch self {
        case .invalidPath(let path): return "Invalid cleanup path: \(path)"
        case .unavailable(let path, let code): return "Cannot inspect \(path) (errno \(code))"
        case .missing(let path): return "Path is missing: \(path)"
        case .notDirectory(let path): return "Path component is not a directory: \(path)"
        case .symlink(let path): return "Symlinks are not allowed in cleanup paths: \(path)"
        case .cloudOnly(let path): return "Cloud-only path is not available locally: \(path)"
        case .outsideRoot(let path): return "Path is outside the authorized scan root: \(path)"
        case .differentVolume(let path): return "Path is on a different volume: \(path)"
        case .changed(let path): return "Path changed since it was checked: \(path)"
        case .protectedPath(let path): return "Protected path: \(path)"
        case .tooBroad(let path): return "Path is too broad to clean: \(path)"
        case .gitPath(let path): return "Git metadata path is protected: \(path)"
        case .gitWorktree(let error): return error.englishDescription
        case .sessionRunning(let path): return "A Claude Code session that is still running uses this: \(path)"
        case .sessionUnverified(let path): return "Couldn't check whether the Claude Code session using this has ended: \(path)"
        case .checkFailed(_, let english): return english
        }
    }
}

/// A path inside a Claude Code session's temp folder,
/// `/private/tmp/claude-<uid>/<project>/<session id>/...`. The same shape the
/// Rust rule `agent_scratch` recognises (`in_claude_scratchpad`).
nonisolated struct ClaudeTemp: Sendable, Equatable {
    /// `/private/tmp/claude-<uid>`, in the spelling the path used.
    let root: String
    let sessionID: String
    /// `<root>/<project>/<session id>`.
    let sessionFolder: String
    /// How many components the path has below `<session>/scratchpad`; nil
    /// when it is not inside the scratchpad.
    let scratchDepth: Int?

    /// A path strictly inside the scratchpad, where planners may clean.
    var inScratchpad: Bool { (scratchDepth ?? 0) >= 1 }
}

/// The check the engine's rule names for a path (`bz_cleanup_verify`), kept
/// with the target so the one boundary every trash passes can run it. `folder`
/// is the folder the rule recognised: the target itself or the innermost
/// recognised folder around it, which is where the cache tag, the activity or
/// the worktree lives. Callers get it from `Tree.cleanupCheck`; `capture` has
/// no default for it, so each caller says which it has.
nonisolated struct CleanupCheck: Sendable, Equatable {
    /// "" none, else a `CleanupVerify` id.
    let verify: String
    let folder: String

    /// The engine recognised no rule around the path: only the path policy applies.
    static let policyOnly = CleanupCheck(verify: "", folder: "")
}

/// A captured path plus the roots and identity against which it can be
/// revalidated immediately before an operation.  Capturing and validating
/// perform metadata reads only; this type never moves, removes, or opens files.
nonisolated struct CleanupTarget: Sendable, Equatable {
    let path: String
    let root: String
    let home: String
    let identity: CleanupIdentity
    /// Every capture and validation runs it when it names a verifier.
    let check: CleanupCheck

    // These are intentionally kept with the target so replacing an authorized
    // root or home directory also invalidates an old plan.
    let rootIdentity: CleanupIdentity
    let homeIdentity: CleanupIdentity

    func validate() throws {
        _ = try CleanupPathSafety.validate(self)
    }
}

/// Shared path policy for the agent and the manual Clean Up panel.
nonisolated enum CleanupPathSafety {
    private static let dataRoot = "/System/Volumes/Data"
    private static let modeMask: UInt16 = 0o170000
    private static let modeDirectory: UInt16 = 0o040000
    private static let modeSymlink: UInt16 = 0o120000
    private static let modeRegular: UInt16 = 0o100000
    private static let dataLessFlag: UInt64 = 0x4000_0000

    /// Rebuildable names are shared with the agent's recent-use policy.
    static let rebuildable: Set<String> = [
        "node_modules", ".venv", "venv", "target", ".next", ".turbo", ".nuxt", ".svelte-kit",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", "DerivedData", ".gradle",
        ".parcel-cache", ".expo", "Pods",
    ]

    private static let protectedRelative = [
        "Documents", "Desktop", "Pictures", "Movies", "Music", ".ssh", ".gnupg", ".Trash",
        ".aws", ".kube", ".docker", ".azure", ".oci", ".netrc", ".zshrc", ".password-store",
        ".config/gcloud", ".config/gh", ".config/op", ".terraform.d", ".local/share/keyrings",
        "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Keychains",
        "Library/Photos", "Library/CloudStorage",
    ]

    private static let broadRelative: Set<String> = [
        "Library", "Library/Caches", "Library/Application Support", "Library/Containers",
        "Library/Group Containers", "Library/Developer", "Library/Preferences", ".config", ".cache",
        "Library/Developer/CoreSimulator", "Library/Developer/CoreSimulator/Devices",
        ".local", ".local/share", "Downloads",
    ]

    /// Folders that alter app behavior or persistence (launch agents, fonts,
    /// keychain helpers…): the folder and everything inside it is off limits.
    /// Unlike `Library/Caches`, no named subfolder of these is a rebuildable
    /// cache, so they block recursively.
    private static let neverCleanRelative = [
        "Library/LaunchAgents", "Library/LaunchDaemons", "Library/Cookies", "Library/Logs",
        "Library/Saved Application State", "Library/Spelling", "Library/Frameworks",
        "Library/PrivilegedHelperTools", "Library/ScriptingAdditions",
        "Library/Internet Plug-Ins", "Library/PreferencePanes", "Library/Input Methods",
        "Library/Fonts", "Library/Services", "Library/StartupItems", "Library/Tokens",
        "Library/Widgets", "Library/Metadata", "Library/Desktop Pictures",
        "Library/Screen Savers", "Library/Workflows", "Library/Automator",
        "Library/Contextual Menu Items", "Library/Compositions", "Library/DirectoryServices",
        "Library/Calendars", "Library/Accounts", "Library/Application Scripts",
    ]

    static func capture(
        path: String,
        root: String = NSHomeDirectory(),
        home: String = NSHomeDirectory(),
        check: CleanupCheck,
        evidence: WorktreeEvidence? = nil
    ) throws -> CleanupTarget {
        let p = try normalize(path)
        let r = try normalize(root)
        let h = try normalize(home)
        let rootObserved = try inspect(r, requireDirectory: true)
        let homeObserved = try inspect(h, requireDirectory: true)
        let targetObserved = try inspect(p, requireDirectory: false)
        let target = CleanupTarget(
            path: p, root: r, home: h, identity: targetObserved.identity, check: check,
            rootIdentity: rootObserved.identity, homeIdentity: homeObserved.identity
        )
        _ = try enforce(target, targetObserved: targetObserved, rootObserved: rootObserved,
                        homeObserved: homeObserved, evidence: evidence)
        return target
    }

    /// Revalidates `target` like `CleanupTarget.validate()` and returns the
    /// worktree verification that allowed it, when it is a linked git worktree.
    static func validatedWorktree(_ target: CleanupTarget) throws -> WorktreeInfo? {
        try validate(target)
    }

    static func normalize(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.utf8.contains(0) else {
            throw CleanupPathError.invalidPath(raw)
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw CleanupPathError.invalidPath(raw) }
        // Do not collapse a symlinked component followed by ".." before the
        // component-by-component lstat walk gets to inspect it.
        if (expanded as NSString).pathComponents.dropFirst().contains("..") {
            throw CleanupPathError.invalidPath(raw)
        }
        let components = (expanded as NSString).pathComponents
        guard components.first == "/" else { throw CleanupPathError.invalidPath(raw) }
        var normalized = "/"
        for component in components.dropFirst() where component != "." {
            normalized = (normalized as NSString).appendingPathComponent(component)
        }
        return normalized
    }

    /// The same narrow Documents exception used by the planner and path
    /// policy. Home aliases are accepted only when their identity matches.
    static func codexChat(_ path: String, home: String = NSHomeDirectory()) -> String? {
        guard let p = try? normalize(path), let h = try? normalize(home),
              let homeIdentity = try? identity(of: h),
              let homePath = homeAlias(p, home: h, homeIdentity: homeIdentity),
              let relative = relativePath(homePath, under: h) else { return nil }
        let parts = relative.split(separator: "/")
        guard parts.count >= 4,
              parts[0].caseInsensitiveCompare("Documents") == .orderedSame,
              parts[1].caseInsensitiveCompare("Codex") == .orderedSame,
              parts[2].wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
        return h + "/" + parts.prefix(4).joined(separator: "/")
    }

    fileprivate static func identity(of path: String) throws -> CleanupIdentity {
        let info = try readStat(path)
        return CleanupIdentity(
            device: UInt64(truncatingIfNeeded: info.st_dev),
            inode: UInt64(truncatingIfNeeded: info.st_ino),
            type: UInt16(truncatingIfNeeded: info.st_mode) & modeMask
        )
    }

    fileprivate static func validate(_ target: CleanupTarget) throws -> WorktreeInfo? {
        let rootObserved = try inspect(target.root, requireDirectory: true)
        guard rootObserved.identity == target.rootIdentity else {
            throw CleanupPathError.changed(target.root)
        }
        let homeObserved = try inspect(target.home, requireDirectory: true)
        guard homeObserved.identity == target.homeIdentity else {
            throw CleanupPathError.changed(target.home)
        }
        let targetObserved = try inspect(target.path, requireDirectory: false)
        guard targetObserved.identity == target.identity else {
            throw CleanupPathError.changed(target.path)
        }
        return try enforce(target, targetObserved: targetObserved, rootObserved: rootObserved,
                           homeObserved: homeObserved)
    }

    private struct Observed {
        let identity: CleanupIdentity
        let isDirectory: Bool
    }

    private static func inspect(_ path: String, requireDirectory: Bool) throws -> Observed {
        let components = (path as NSString).pathComponents
        guard components.first == "/" else { throw CleanupPathError.invalidPath(path) }
        var current = "/"
        for (offset, component) in components.dropFirst().enumerated() {
            current = (current as NSString).appendingPathComponent(component)
            let info = try readStat(current)
            let mode = UInt16(truncatingIfNeeded: info.st_mode) & modeMask
            if mode == modeSymlink { throw CleanupPathError.symlink(current) }
            if UInt64(truncatingIfNeeded: info.st_flags) & dataLessFlag != 0 {
                throw CleanupPathError.cloudOnly(current)
            }
            if offset < components.dropFirst().count - 1 && mode != modeDirectory {
                throw CleanupPathError.notDirectory(current)
            }
            if offset == components.dropFirst().count - 1 {
                let observed = Observed(
                    identity: CleanupIdentity(
                        device: UInt64(truncatingIfNeeded: info.st_dev),
                        inode: UInt64(truncatingIfNeeded: info.st_ino),
                        type: mode
                    ),
                    isDirectory: mode == modeDirectory
                )
                if requireDirectory && !observed.isDirectory {
                    throw CleanupPathError.notDirectory(path)
                }
                return observed
            }
        }
        // The root path itself is the only path without a non-root component.
        let info = try readStat("/")
        return Observed(
            identity: CleanupIdentity(
                device: UInt64(truncatingIfNeeded: info.st_dev),
                inode: UInt64(truncatingIfNeeded: info.st_ino),
                type: UInt16(truncatingIfNeeded: info.st_mode) & modeMask
            ),
            isDirectory: true
        )
    }

    private static func readStat(_ path: String) throws -> stat {
        var info = stat()
        let result = path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw CleanupPathError.missing(path) }
            throw CleanupPathError.unavailable(path, code)
        }
        return info
    }

    private static func enforce(
        _ target: CleanupTarget,
        targetObserved: Observed,
        rootObserved: Observed,
        homeObserved: Observed,
        evidence: WorktreeEvidence? = nil
    ) throws -> WorktreeInfo? {
        // A scan root is a boundary, never an actionable target.  Identity
        // also catches the equivalent /System/Volumes/Data spelling.
        guard targetObserved.identity != rootObserved.identity else {
            throw CleanupPathError.outsideRoot(target.path)
        }
        guard targetObserved.identity.device == rootObserved.identity.device else {
            throw CleanupPathError.differentVolume(target.path)
        }
        guard isWithinRoot(path: target.path, identity: targetObserved.identity,
                           root: target.root, rootIdentity: rootObserved.identity) else {
            throw CleanupPathError.outsideRoot(target.path)
        }
        _ = homeObserved // The identity check is part of the root policy below.
        try protectedPolicy(path: target.path, home: target.home, homeIdentity: homeObserved.identity)
        try claudeTempPolicy(target.path)
        let worktree = try rejectGitPaths(target.path, evidence: evidence)
        try enforceCheck(target, worktree: worktree, evidence: evidence)
        return worktree
    }

    /// Runs the check the engine's rule names for the target. This is the one
    /// place it runs, so the panel, the agent and any later caller get it from
    /// the same capture and revalidation. A worktree the git policy above just
    /// verified is not verified a second time.
    private static func enforceCheck(_ target: CleanupTarget, worktree: WorktreeInfo?,
                                     evidence: WorktreeEvidence?) throws {
        let check = target.check
        guard !check.verify.isEmpty else { return }
        guard isPath(target.path, under: check.folder) else {
            throw CleanupPathError.checkFailed(
                localized: "The check does not belong to this folder: \(target.path)",
                english: "The check does not belong to this folder: \(target.path)")
        }
        if check.verify == "git_worktree", check.folder == target.path, worktree != nil { return }
        if let reason = CleanupVerify.blockReason(verify: check.verify, path: check.folder, evidence: evidence) {
            throw CleanupPathError.checkFailed(localized: reason.localized, english: reason.english)
        }
    }

    /// Parses a Claude Code temp path for the current user. Component names
    /// compare case-insensitively: APFS would accept `/private/TMP/...` for
    /// the same folder, and a different spelling must not skip the session
    /// check. `/tmp` itself is a symlink, which `inspect` already refuses.
    static func claudeTemp(_ path: String, uid: uid_t = getuid()) -> ClaudeTemp? {
        guard let normalized = try? normalize(path) else { return nil }
        var parts = Array((normalized as NSString).pathComponents.dropFirst())
        var prefix = "/"
        let data = Array((dataRoot as NSString).pathComponents.dropFirst())
        if parts.count > data.count,
           zip(parts, data).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame }) {
            prefix = appendComponents(["/"] + parts.prefix(data.count))
            parts.removeFirst(data.count)
        }
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        guard parts.count >= 5, same(parts[0], "private"), same(parts[1], "tmp"),
              same(parts[2], "claude-\(uid)"), !parts[3].isEmpty,
              UUID(uuidString: parts[4]) != nil else { return nil }
        let root = appendPath(prefix, Array(parts.prefix(3)))
        let session = appendPath(root, [parts[3], parts[4]])
        let depth = parts.count >= 6 && same(parts[5], "scratchpad") ? parts.count - 6 : nil
        return ClaudeTemp(root: root, sessionID: parts[4].lowercased(), sessionFolder: session, scratchDepth: depth)
    }

    /// The root a planner's path is captured under. Plans stay inside the
    /// home, with one exception: build output in a Claude Code session's temp
    /// scratchpad is captured under that user's `claude-<uid>` temp folder,
    /// where `claudeTempPolicy` refuses it while its session still runs.
    static func plannerRoot(for path: String, home: String) -> String {
        claudeTemp(path).flatMap { $0.inScratchpad ? $0.root : nil } ?? home
    }

    /// Inside a Claude Code session's temp folder only the scratchpad's
    /// contents may go, and only once that session has stopped running.
    /// Every cleanup path passes here, whatever rule or planner named it.
    private static func claudeTempPolicy(_ path: String) throws {
        guard let temp = claudeTemp(path) else { return }
        guard temp.inScratchpad else { throw CleanupPathError.tooBroad(path) }
        switch AgentSessions.claudeSessionState(temp) {
        case .ended: return
        case .running: throw CleanupPathError.sessionRunning(path)
        case .unknown: throw CleanupPathError.sessionUnverified(path)
        }
    }

    private static func isWithinRoot(
        path: String, identity: CleanupIdentity, root: String, rootIdentity: CleanupIdentity
    ) -> Bool {
        if let match = matchingPrefix(path, under: root, insensitive: true),
           (try? self.identity(of: match.prefix)) == rootIdentity {
            return true
        }
        // macOS exposes the Data volume both at /System/Volumes/Data and via
        // firmlinked paths such as /Users.  Permit an alias only when lstat
        // proves that both spellings name the same object.
        if root == dataRoot {
            let alias = path.hasPrefix(dataRoot + "/") ? path : dataRoot + path
            return sameObject(path, identity, alias)
        }
        if path.hasPrefix(dataRoot + "/") {
            let dataRootAlias = root.hasPrefix(dataRoot + "/") ? root : dataRoot + root
            if matchingPrefix(path, under: dataRootAlias, insensitive: true) == nil { return false }
            return sameObject(root, rootIdentity, dataRootAlias)
        }
        if root.hasPrefix(dataRoot + "/") {
            let pathAlias = dataRoot + path
            return matchingPrefix(pathAlias, under: root, insensitive: true) != nil
                && sameObject(path, identity, pathAlias)
        }
        return false
    }

    private static func sameObject(_ first: String, _ firstIdentity: CleanupIdentity, _ second: String) -> Bool {
        guard let secondIdentity = try? identity(of: second) else { return false }
        return firstIdentity == secondIdentity && first != second
    }

    /// Why Clean Up would refuse `path`, judged on the path alone: the
    /// protected-folder policy and the `.git` rules, with no git run, no
    /// process check and no rule check. For a warning where no cleanup runs
    /// (the manual Move to Trash). Nil when the path would pass these, or
    /// cannot be judged; a `.git` file (maybe a linked worktree) is not judged.
    static func refusal(of path: String, home: String = NSHomeDirectory()) -> CleanupPathError? {
        guard let p = try? normalize(path), let h = try? normalize(home),
              let homeIdentity = try? identity(of: h) else { return nil }
        do {
            try protectedPolicy(path: p, home: h, homeIdentity: homeIdentity, refuseShallow: false)
            try rejectGitComponents(p)
            if let marker = try? readStat((p as NSString).appendingPathComponent(".git")),
               UInt16(truncatingIfNeeded: marker.st_mode) & modeMask != modeRegular {
                return .gitPath((p as NSString).appendingPathComponent(".git"))
            }
        } catch let error as CleanupPathError {
            return error
        } catch {
            return nil
        }
        return nil
    }

    private static func protectedPolicy(path: String, home: String, homeIdentity: CleanupIdentity,
                                        refuseShallow: Bool = true) throws {
        // Retain the released app's exclusion for caches and containers
        // managed by macOS, including the Data-volume spelling.
        let lower = path.lowercased()
        if lower.contains("/library/containers/com.apple.")
            || lower.contains("/library/caches/com.apple.")
            || lower.contains("/library/group containers/group.com.apple.") {
            throw CleanupPathError.protectedPath(path)
        }
        try globalPackagePolicy(path)
        try cacheTokenPolicy(path)
        if let homePath = homeAlias(path, home: home, homeIdentity: homeIdentity),
           let relative = relativePath(homePath, under: home) {
            try homePolicy(relative: relative, path: path) { codexChat(homePath, home: home) != nil }
            try claudeProjectPolicy(relative: relative, path: path)
        } else if let relative = otherHomeRelative(path) {
            // A scan root wider than the home (the whole Data volume, an
            // external disk) reaches other users' homes: the same policy
            // applies there, without the Codex chat exception.
            try homePolicy(relative: relative, path: path) { false }
        } else if refuseShallow, isShallowOutsideHome(path) {
            throw CleanupPathError.tooBroad(path)
        }
    }

    /// Top-level dot entries a home may offer for cleaning by themselves. Any
    /// other one (`.aws`, `.zshrc`, `.claude`, `.gradle`...) holds
    /// credentials or settings and is refused; what lies inside the folders in
    /// `dotFolderChildren` is allowed only where the engine names a cache.
    private static let topLevelDotCaches: Set<String> = [".npm", ".venv", ".tox", ".nox", ".stack-work"]

    /// Folders that mix settings or credentials with caches: only these
    /// children, the ones the engine's rules emit, may be cleaned.
    private static let dotFolderChildren: [String: Set<String>] = [
        ".claude": ["projects", "file-history", "debug"],
        ".codex": ["sessions", "archived_sessions", "worktrees"],
        ".gradle": ["caches", "wrapper", "daemon", "jdks", "workers", "kotlin-profile", "build-scan-data"],
        ".cargo": ["registry", "git"],
        ".m2": ["repository"],
        ".ollama": ["models"],
        ".rustup": ["toolchains", "downloads", "tmp"],
    ]

    /// Where package managers keep globally installed tools. A `lib/node_modules`
    /// under one of these is the CLIs the user runs, not a project's packages.
    static let systemPackageRoots = ["/opt/homebrew", "/usr/local"]

    /// Whether `path` is, or is inside, a global `lib/node_modules` below one
    /// of `roots`, in either volume spelling and any letter case.
    static func isGlobalPackageFolder(_ path: String, roots: [String] = systemPackageRoots) -> Bool {
        let components = componentsBelowDataRoot(path)
        return roots.contains { root in
            let prefix = Array((root as NSString).pathComponents.dropFirst())
            guard components.count > prefix.count,
                  zip(components, prefix).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame }) else { return false }
            return containsLibNodeModules(components.dropFirst(prefix.count))
        }
    }

    private static func containsLibNodeModules(_ components: ArraySlice<String>) -> Bool {
        zip(components, components.dropFirst()).contains {
            $0.caseInsensitiveCompare("lib") == .orderedSame && $1.caseInsensitiveCompare("node_modules") == .orderedSame
        }
    }

    private static func globalPackagePolicy(_ path: String) throws {
        if isGlobalPackageFolder(path) { throw CleanupPathError.protectedPath(path) }
    }

    /// Tool logins live in files named `token` or `stored_tokens` (Hugging Face
    /// keeps them beside its cache). Under any `.cache`, a path that is one, is
    /// inside one, or is a folder holding one directly is refused, whatever
    /// the engine's rules said about it.
    private static let tokenNames = ["token", "stored_tokens"]

    private static func cacheTokenPolicy(_ path: String) throws {
        let components = (path as NSString).pathComponents.dropFirst()
        guard let cache = components.firstIndex(where: { $0.caseInsensitiveCompare(".cache") == .orderedSame }) else { return }
        if components.dropFirst(cache - components.startIndex + 1).contains(where: { name in
            tokenNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }) { throw CleanupPathError.protectedPath(path) }
        for name in tokenNames {
            var info = stat()
            if lstat((path as NSString).appendingPathComponent(name), &info) == 0 {
                throw CleanupPathError.protectedPath(path)
            }
        }
    }

    /// The most entries of a Claude Code project folder the policy will look at.
    private static let projectEntryLimit = 100_000

    /// `~/.claude/projects/<project>` holds session transcripts, and Claude Code
    /// keeps its persistent memory (`memory/`) in the same folder. The engine
    /// offers the folder only while every entry in it is a transcript
    /// (`only_transcripts` in src/cleanup.rs: `*.jsonl` files, `.DS_Store`, and
    /// session-id folders), but it decided that at scan time. Anything added
    /// since (a `memory/`, a notes file) makes the folder a refusal at capture
    /// and at every revalidation, whatever its dates say. One directory
    /// listing: the session folders' contents are not opened, and a folder with
    /// more entries than the limit, or one that cannot be listed, is refused.
    private static func claudeProjectPolicy(relative: String, path: String) throws {
        let parts = relative.split(separator: "/")
        guard parts.count == 3, parts[0].caseInsensitiveCompare(".claude") == .orderedSame,
              parts[1].caseInsensitiveCompare("projects") == .orderedSame else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path),
              names.count <= projectEntryLimit else { throw CleanupPathError.protectedPath(path) }
        for name in names {
            var info = stat()
            guard lstat((path as NSString).appendingPathComponent(name), &info) == 0 else {
                throw CleanupPathError.protectedPath(path)
            }
            let isDirectory = UInt16(truncatingIfNeeded: info.st_mode) & modeMask == modeDirectory
            let transcript = isDirectory ? UUID(uuidString: name) != nil
                                         : name == ".DS_Store" || name.hasSuffix(".jsonl")
            if !transcript { throw CleanupPathError.protectedPath(path) }
        }
    }

    /// Whether `path` is in a folder whose contents the engine sorts one by
    /// one instead of offering whole: any `.cache`, and the home's `.claude`,
    /// `.codex`, `.gradle`, `.cargo`, `.m2`, `.ollama` and `.rustup`. A plan
    /// naming such a path is honoured only inside a folder the scan recognised.
    static func isInsideEngineContainer(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let components = Array((path as NSString).pathComponents.dropFirst())
        if components.contains(where: { $0.caseInsensitiveCompare(".cache") == .orderedSame }) { return true }
        guard let h = try? normalize(home), let homeIdentity = try? identity(of: h),
              let p = try? normalize(path),
              let homePath = homeAlias(p, home: h, homeIdentity: homeIdentity),
              let relative = relativePath(homePath, under: h),
              let first = relative.split(separator: "/").first else { return false }
        return dotFolderChildren.keys.contains { $0.caseInsensitiveCompare(String(first)) == .orderedSame }
    }

    /// The components of an absolute path, minus the `/System/Volumes/Data` prefix.
    private static func componentsBelowDataRoot(_ path: String) -> [String] {
        var components = Array((path as NSString).pathComponents.dropFirst())
        let data = Array((dataRoot as NSString).pathComponents.dropFirst())
        if components.count > data.count,
           zip(components, data).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame }) {
            components.removeFirst(data.count)
        }
        return components
    }

    /// `rest` of `/Users/<name>/rest` or `/Volumes/<disk>/Users/<name>/rest`
    /// (either on the Data volume spelling): a home other than the user's.
    /// "" for the home folder itself.
    static func otherHomeRelative(_ path: String) -> String? {
        var components = componentsBelowDataRoot(path)
        if components.count >= 3, components[0].caseInsensitiveCompare("Volumes") == .orderedSame {
            components.removeFirst(2)
        }
        guard components.count >= 2, components[0].caseInsensitiveCompare("Users") == .orderedSame else { return nil }
        return components.dropFirst(2).joined(separator: "/")
    }

    /// A path at the top of a volume (`/Users/Shared`, `/Applications/Foo.app`,
    /// `/Volumes/Disk/Photos`, `/opt/homebrew`): nothing a cleanup offers lives
    /// there, outside the user's own home. On an external disk the volume's
    /// own name is no depth: a project's `node_modules` at
    /// `/Volumes/Disk/proj/node_modules` is as deep as `/Users/me/proj` is
    /// below its home, and the engine offers it. Only a folder directly on the
    /// disk (`/Volumes/Disk/Photos`) and another user's home folder on it
    /// (`/Volumes/Disk/Users/other`) are the top.
    static func isShallowOutsideHome(_ path: String) -> Bool {
        let components = componentsBelowDataRoot(path)
        guard components.count >= 3, components[0].caseInsensitiveCompare("Volumes") == .orderedSame else {
            return components.count <= 2
        }
        let onDisk = Array(components.dropFirst(2))
        return onDisk.count <= 1
            || (onDisk.count == 2 && onDisk[0].caseInsensitiveCompare("Users") == .orderedSame)
    }

    /// The policy for a path inside a home, as the part below that home.
    static func homePolicy(relative: String, path: String, isCodexChat: () -> Bool) throws {
        let parts = relative.split(separator: "/").map(String.init)
        if relative.isEmpty || (parts.count < 2 && !relative.hasPrefix(".")) {
            throw CleanupPathError.tooBroad(path)
        }
        if broadRelative.contains(where: { $0.caseInsensitiveCompare(relative) == .orderedSame }) {
            throw CleanupPathError.tooBroad(path)
        }
        let lowerRelative = relative.lowercased()
        if neverCleanRelative.contains(where: {
            lowerRelative == $0.lowercased() || lowerRelative.hasPrefix($0.lowercased() + "/")
        }) {
            throw CleanupPathError.tooBroad(path)
        }
        for protected in protectedRelative {
            let protectedMatch = relative.caseInsensitiveCompare(protected) == .orderedSame
                || relative.lowercased().hasPrefix(protected.lowercased() + "/")
            guard protectedMatch else { continue }
            let suffix = relative.caseInsensitiveCompare(protected) == .orderedSame
                ? [] : relative.dropFirst(protected.count + 1).split(separator: "/")
            if protected == "Documents", isCodexChat() { continue }
            if protected.caseInsensitiveCompare("Documents") == .orderedSame
                || protected.caseInsensitiveCompare("Desktop") == .orderedSame {
                guard suffix.count >= 2,
                      rebuildable.contains(where: { $0.caseInsensitiveCompare(String(suffix.last!)) == .orderedSame }) else {
                    throw CleanupPathError.protectedPath(path)
                }
            } else {
                throw CleanupPathError.protectedPath(path)
            }
        }
        if let first = parts.first {
            if parts.count >= 2,
               let children = dotFolderChildren.first(where: { $0.key.caseInsensitiveCompare(first) == .orderedSame })?.value,
               !children.contains(where: { $0.caseInsensitiveCompare(parts[1]) == .orderedSame }) {
                throw CleanupPathError.protectedPath(path)
            }
            // Claude Code keeps its saved memory beside the transcripts.
            if first.caseInsensitiveCompare(".claude") == .orderedSame,
               parts.dropFirst().contains(where: { $0.caseInsensitiveCompare("memory") == .orderedSame }) {
                throw CleanupPathError.protectedPath(path)
            }
            if first.caseInsensitiveCompare(".nvm") == .orderedSame, containsLibNodeModules(parts.dropFirst()) {
                throw CleanupPathError.protectedPath(path)
            }
            if parts.count == 1, first.hasPrefix("."),
               !topLevelDotCaches.contains(where: { $0.caseInsensitiveCompare(first) == .orderedSame }) {
                throw CleanupPathError.tooBroad(path)
            }
        }
    }

    private static func homeAlias(
        _ path: String, home: String, homeIdentity: CleanupIdentity
    ) -> String? {
        if let match = matchingPrefix(path, under: home, insensitive: true),
           (try? self.identity(of: match.prefix)) == homeIdentity {
            return appendPath(home, match.suffix)
        }
        let aliasHome = home.hasPrefix(dataRoot + "/")
            ? String(home.dropFirst(dataRoot.count))
            : dataRoot + home
        if let match = matchingPrefix(path, under: aliasHome, insensitive: true),
           (try? self.identity(of: match.prefix)) == homeIdentity {
            return appendPath(home, match.suffix)
        }
        return nil
    }

    /// Any `.git` component or marker blocks, except a target whose own `.git`
    /// is a regular file and which `GitWorktree.verify` accepts as a clean,
    /// unused linked worktree. That verification runs at capture and again at
    /// every validation, so a worktree changed after planning is refused.
    private static func rejectGitPaths(_ path: String, evidence: WorktreeEvidence?) throws -> WorktreeInfo? {
        try rejectGitComponents(path)
        let marker = (path as NSString).appendingPathComponent(".git")
        return try rejectGitMarker(marker, worktree: path, evidence: evidence)
    }

    private static func rejectGitComponents(_ path: String) throws {
        var current = "/"
        for component in (path as NSString).pathComponents.dropFirst() {
            current = (current as NSString).appendingPathComponent(component)
            if component.caseInsensitiveCompare(".git") == .orderedSame {
                throw CleanupPathError.gitPath(current)
            }
        }
    }

    private static func rejectGitMarker(_ marker: String, worktree: String,
                                        evidence: WorktreeEvidence?) throws -> WorktreeInfo? {
        let info: stat
        do {
            info = try readStat(marker)
        } catch let error as CleanupPathError {
            if case .missing = error { return nil }
            throw error
        }
        guard UInt16(truncatingIfNeeded: info.st_mode) & modeMask == modeRegular else {
            throw CleanupPathError.gitPath(marker)
        }
        do {
            return try GitWorktree.verify(worktree, evidence: evidence)
        } catch GitWorktreeError.notWorktree {
            throw CleanupPathError.gitPath(marker)
        } catch let error as GitWorktreeError {
            throw CleanupPathError.gitWorktree(error)
        }
    }

    private static func isPath(_ path: String, under root: String) -> Bool {
        path == root || (root == "/" ? path.hasPrefix("/") : path.hasPrefix(root + "/"))
    }

    private static func matchingPrefix(
        _ path: String, under root: String, insensitive: Bool
    ) -> (prefix: String, suffix: [String])? {
        let pathComponents = (path as NSString).pathComponents
        let rootComponents = (root as NSString).pathComponents
        guard pathComponents.count >= rootComponents.count else { return nil }
        for (lhs, rhs) in zip(pathComponents.prefix(rootComponents.count), rootComponents) {
            if insensitive {
                guard lhs.caseInsensitiveCompare(rhs) == .orderedSame else { return nil }
            } else {
                guard lhs == rhs else { return nil }
            }
        }
        let prefix = appendComponents(Array(pathComponents.prefix(rootComponents.count)))
        return (prefix, Array(pathComponents.dropFirst(rootComponents.count)))
    }

    private static func appendComponents(_ components: [String]) -> String {
        guard let first = components.first else { return "/" }
        var path = first
        for component in components.dropFirst() {
            path = (path as NSString).appendingPathComponent(component)
        }
        return path
    }

    private static func appendPath(_ root: String, _ suffix: [String]) -> String {
        var path = root
        for component in suffix {
            path = (path as NSString).appendingPathComponent(component)
        }
        return path
    }

    private static func relativePath(_ path: String, under root: String) -> String? {
        guard isPath(path, under: root) else { return nil }
        if path == root { return "" }
        return String(path.dropFirst(root.count + (root == "/" ? 0 : 1)))
    }
}
