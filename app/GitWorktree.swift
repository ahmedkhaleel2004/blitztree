import Darwin
import Foundation

/// A linked git worktree that passed every check in `GitWorktree.verify`.
nonisolated struct WorktreeInfo: Sendable, Equatable {
    /// The worktree folder, as it was asked about (normalized).
    let path: String
    /// `<common>/worktrees/<id>`, resolved.
    let adminDir: String
    /// The repository's shared git directory, resolved.
    let commonDir: String
    /// Short branch name, or nil when HEAD is detached (then it is contained in a ref).
    let branch: String?
    let head: String
    /// Latest of the admin entry's index, HEAD and logs/HEAD modification dates.
    let lastUsed: Date
}

/// The admin entry of a worktree moved to the Trash, as it was just before the
/// move. `GitWorktree.removeAdminEntry` deletes it only if it is still exactly this.
nonisolated struct WorktreeAdminEntry: Sendable, Equatable {
    let adminDir: String
    let adminIdentity: CleanupIdentity
    /// `<common>/worktrees`, which must still hold the admin dir.
    let worktreesIdentity: CleanupIdentity
    let commonIdentity: CleanupIdentity
    let gitdirIdentity: CleanupIdentity
    /// Raw bytes of `<admin>/gitdir`.
    let gitdirContent: Data
    /// The `.git` file that content names (relative names joined to the admin dir).
    let gitFile: String
}

nonisolated enum GitWorktreeError: Error, LocalizedError, Equatable, Sendable {
    /// Not a linked worktree whose metadata points back to itself. The cleanup
    /// guard reports this exactly as it reports any other `.git` marker.
    case notWorktree(String)
    /// Its `.git` file names a repository this Mac cannot reach right now: the
    /// repository's folder is missing, typically on a drive that is not mounted.
    case repositoryUnavailable(String)
    case locked(String)
    case submodules(String)
    case gitMissing(String)
    case gitFailed(String, String)
    case timedOut(String)
    case changes(String)
    case hiddenChanges(String)
    case unreachableHead(String)
    case recentlyUsed(String)
    case inUse(String)
    case processCheckFailed(String)
    /// Ignored files git status leaves out that a build would not recreate.
    case ignoredFiles(String)
    /// The agents' session logs could not all be read, so use cannot be ruled out.
    case sessionsUnreadable(String)
    /// The admin entry holds refs of its own (refs/worktree/*, refs/bisect/*...).
    /// Removing the entry would drop them, and the commits only they keep.
    case ownRefs(String)

    var errorDescription: String? {
        switch self {
        case .notWorktree(let path): return "Not a linked git worktree: \(path)"
        case .repositoryUnavailable(let path): return "The repository of this git worktree can't be reached (is its drive connected?): \(path)"
        case .locked(let path): return "Git worktree is locked: \(path)"
        case .submodules(let path): return "Git worktree has submodules: \(path)"
        case .gitMissing(let path): return "Git is not available to check this worktree: \(path)"
        case .gitFailed(let path, let detail): return "Git could not check \(path): \(detail)"
        case .timedOut(let path): return "Checking this git worktree took too long: \(path)"
        case .changes(let path): return "Git worktree has uncommitted or untracked changes: \(path)"
        case .hiddenChanges(let path): return "Git worktree has files hidden from git status: \(path)"
        case .unreachableHead(let path): return "Git worktree has commits on no branch or tag: \(path)"
        case .recentlyUsed(let path): return "Git worktree used in the last 2 days: \(path)"
        case .inUse(let path): return "A running process is working in this git worktree: \(path)"
        case .processCheckFailed(let path): return "Could not check for processes using this git worktree: \(path)"
        case .ignoredFiles(let path): return "Git worktree has ignored files that a build would not recreate (such as .env): \(path)"
        case .sessionsUnreadable(let path): return "Could not read the coding agents' session logs to check whether this git worktree is in use: \(path)"
        case .ownRefs(let path): return "Git worktree has refs of its own that could keep commits nothing else keeps: \(path)"
        }
    }

    var englishDescription: String {
        switch self {
        case .notWorktree(let path): return "Not a linked git worktree: \(path)"
        case .repositoryUnavailable(let path): return "The repository of this git worktree can't be reached (is its drive connected?): \(path)"
        case .locked(let path): return "Git worktree is locked: \(path)"
        case .submodules(let path): return "Git worktree has submodules: \(path)"
        case .gitMissing(let path): return "Git is not available to check this worktree: \(path)"
        case .gitFailed(let path, let detail): return "Git could not check \(path): \(detail)"
        case .timedOut(let path): return "Checking this git worktree took too long: \(path)"
        case .changes(let path): return "Git worktree has uncommitted or untracked changes: \(path)"
        case .hiddenChanges(let path): return "Git worktree has files hidden from git status: \(path)"
        case .unreachableHead(let path): return "Git worktree has commits on no branch or tag: \(path)"
        case .recentlyUsed(let path): return "Git worktree used in the last 2 days: \(path)"
        case .inUse(let path): return "A running process is working in this git worktree: \(path)"
        case .processCheckFailed(let path): return "Could not check for processes using this git worktree: \(path)"
        case .ignoredFiles(let path): return "Git worktree has ignored files that a build would not recreate (such as .env): \(path)"
        case .sessionsUnreadable(let path): return "Could not read the coding agents' session logs to check whether this git worktree is in use: \(path)"
        case .ownRefs(let path): return "Git worktree has refs of its own that could keep commits nothing else keeps: \(path)"
        }
    }
}

/// Where verification may find git. /usr/bin/git and /usr/bin/xcrun are
/// shims that can raise the Command Line Tools install prompt, so they are
/// never run; a git is taken from `searchPath`, else from the selected
/// developer directory when `xcode-select -p` names one that has git.
nonisolated struct GitLookup: Sendable, Equatable {
    var searchPath: String
    var useDeveloperDir: Bool

    /// The app's PATH plus the usual package-manager locations, then the
    /// selected developer directory. The app does not widen this to the login
    /// shell's PATH (decision): the shell PATH reaches user-writable folders
    /// (`~/.local/bin`, version managers), and the program found here decides
    /// whether a folder may be deleted. A git installed only there blocks every
    /// worktree with "Git is not available", which fails closed and says why.
    static var standard: GitLookup {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return GitLookup(searchPath: inherited + ":/opt/homebrew/bin:/usr/local/bin", useDeveloperDir: true)
    }
}

/// Verifies linked git worktrees with read-only, hardened git: no fsmonitor
/// hooks, no optional index writes, no prompts, no stdin, bounded time and
/// output. Anything that cannot be checked blocks.
nonisolated enum GitWorktree {
    static let recentWindow: TimeInterval = 2 * 86400

    private static let settings = Settings(GitLookup.standard)

    /// The lookup the cleanup guard uses. Tests inject an empty one to prove
    /// that a missing git blocks.
    static var lookup: GitLookup {
        get { settings.value }
        set { settings.value = newValue }
    }

    /// The bounds one verification runs under. Tests narrow them to prove that
    /// a hung or chatty program blocks.
    struct Limits: Sendable, Equatable {
        /// Wall time for all of one worktree's git commands together.
        var gitBudget: TimeInterval = 20
        var lsof = "/usr/sbin/lsof"
        var lsofTimeout: TimeInterval = 10
        var lsofCap = 32 << 20

        static let standard = Limits()
    }

    private static let markerLimit = 4096
    private static let statusCap = 1 << 20
    private static let listCap = 64 << 20
    private static let dataRoot = "/System/Volumes/Data"

    // MARK: Verification

    /// `evidence` is what one refresh shares between its worktrees (one lsof,
    /// one Codex log scan). Without it every call reads its own, fresh: the
    /// trash boundary always verifies that way, so a worktree that became busy
    /// or dirty after the refresh is still caught.
    static func verify(
        _ rawPath: String,
        recentWithin: TimeInterval = recentWindow,
        lookup: GitLookup? = nil,
        now: Date = Date(),
        limits: Limits = .standard,
        evidence: WorktreeEvidence? = nil
    ) throws -> WorktreeInfo {
        let evidence = evidence ?? WorktreeEvidence(limits: limits)
        let layout = try self.layout(of: rawPath)
        let path = layout.path
        if try exists(layout.admin + "/locked", path: path) { throw GitWorktreeError.locked(path) }
        if try exists(path + "/.gitmodules", path: path) { throw GitWorktreeError.submodules(path) }
        // Refs under `<admin>/refs` (refs/worktree/*, refs/bisect/*) belong to this
        // worktree alone and go with its admin entry. Whether the commits they
        // name are also on a shared ref is not worked out: any such ref blocks.
        if try holdsRefs(layout.admin + "/refs", path: path) { throw GitWorktreeError.ownRefs(path) }

        // Read the recency evidence before git runs, so the check can never
        // be satisfied (or defeated) by its own activity.
        let stamps = [layout.admin + "/index", layout.admin + "/HEAD", layout.admin + "/logs/HEAD"]
        let dates = stamps.compactMap(modificationDate)
        guard let lastUsed = dates.max() else { throw GitWorktreeError.notWorktree(path) }
        let cutoff = now.addingTimeInterval(-recentWithin)
        if lastUsed > cutoff { throw GitWorktreeError.recentlyUsed(path) }
        // A session found anywhere is use; logs that could not be read leave the
        // question open, which blocks with its own reason, not as "unused".
        var unreadable = false
        let codex = evidence.codexActivity(since: cutoff)
        for spelling in spellings(of: path, real: layout.realPath) {
            for usage in [AgentSessions.claudeUsage(in: spelling, since: cutoff),
                          AgentSessions.usage(of: spelling, in: codex)] {
                switch usage {
                case .used: throw GitWorktreeError.recentlyUsed(path)
                case .unknown: unreadable = true
                case .unused: break
                }
            }
        }
        if unreadable { throw GitWorktreeError.sessionsUnreadable(path) }

        guard let git = locateGit(lookup ?? self.lookup) else { throw GitWorktreeError.gitMissing(path) }
        let runner = GitRunner(git: git, layout: layout, deadline: Date().addingTimeInterval(limits.gitBudget))

        // Ignored files count too: git status leaves them out, yet `.env` files,
        // local databases and data kept under an ignored path are not recreated
        // by a build. Only what a build recreates (an ignored `node_modules`...)
        // may be there.
        let status = try runner.run(["status", "--porcelain=v1", "-z", "--untracked-files=all",
                                     "--ignore-submodules=none", "--no-renames", "--ignored=matching"], cap: statusCap)
        if status.overflow { throw GitWorktreeError.changes(path) }
        for entry in status.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            guard entry.count > 3, entry.starts(with: Array("!! ".utf8)) else { throw GitWorktreeError.changes(path) }
            let text = String(decoding: entry.dropFirst(3), as: UTF8.self)
            let parts = text.split(separator: "/").map(String.init)
            // Finder writes .DS_Store into every folder it opens, and most
            // global gitignores list it: it holds nothing worth keeping.
            if parts.last == ".DS_Store" { continue }
            // `matching` reports a folder that is ignored as a whole with a
            // trailing slash. Only such a folder that the engine would itself
            // recognise as build output may stay (`rebuildableFolders`): the
            // name alone is not enough, since `data/target/prod.db` or a
            // `node_modules/.env` with no package.json beside it is data.
            if text.hasSuffix("/"), isRebuildableFolder(parts, in: layout.realPath) { continue }
            throw GitWorktreeError.ignoredFiles(path)
        }

        // Assume-unchanged (lowercase tag) and skip-worktree ("S") entries are
        // invisible to status, so only plain tracked entries ("H") pass.
        let listed = try runner.run(["ls-files", "-v", "-z"], cap: listCap)
        if listed.overflow { throw GitWorktreeError.gitFailed(path, "too many files to check") }
        for entry in listed.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            guard entry.count >= 2, entry[entry.startIndex] == UInt8(ascii: "H"),
                  entry[entry.startIndex + 1] == UInt8(ascii: " ") else {
                throw GitWorktreeError.hiddenChanges(path)
            }
        }

        let symbolic = try runner.run(["symbolic-ref", "-q", "HEAD"], cap: 4096, allowed: [0, 1])
        let headRef = symbolic.status == 0 ? symbolic.text : nil
        let resolved = try runner.run(["rev-parse", "--verify", "-q", "HEAD^{commit}"], cap: 4096)
        let head = resolved.text
        guard head.count == 40 || head.count == 64,
              head.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            throw GitWorktreeError.gitFailed(path, "unexpected HEAD")
        }
        var branch: String?
        if let headRef, headRef.hasPrefix("refs/heads/"), headRef.count > "refs/heads/".count {
            branch = String(headRef.dropFirst("refs/heads/".count))
        } else {
            let containing = try runner.run(["for-each-ref", "--contains", head, "--count=1",
                                             "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"],
                                            cap: 4096)
            if containing.text.isEmpty { throw GitWorktreeError.unreachableHead(path) }
            branch = nil
        }

        try rejectProcesses(inside: path, real: layout.realPath, evidence: evidence)
        return WorktreeInfo(path: path, adminDir: layout.admin, commonDir: layout.common,
                            branch: branch, head: head, lastUsed: lastUsed)
    }

    /// Records the admin entry immediately before the worktree is moved.
    static func adminEntry(for info: WorktreeInfo) throws -> WorktreeAdminEntry {
        let admin = info.adminDir
        let parent = (admin as NSString).deletingLastPathComponent
        let gitdir = try readMarker(admin + "/gitdir", path: info.path)
        let line = try singleLine(gitdir.data, path: info.path)
        return WorktreeAdminEntry(
            adminDir: admin,
            adminIdentity: try identity(admin, path: info.path),
            worktreesIdentity: try identity(parent, path: info.path),
            commonIdentity: try identity(info.commonDir, path: info.path),
            gitdirIdentity: gitdir.identity,
            gitdirContent: gitdir.data,
            gitFile: join(line, to: admin)
        )
    }

    /// After the worktree itself was deleted for good: removes its admin entry
    /// only while that entry is unchanged and still names the vanished `.git`
    /// file. Returns nil on success, otherwise why it was left in place.
    static func removeAdminEntry(_ entry: WorktreeAdminEntry, erase: (String) -> String?) -> String? {
        let admin = entry.adminDir
        switch inspect(admin) {
        case .missing:
            return nil
        case .unreadable(let code):
            return "Left git worktree metadata in place because it could not be read: \(admin) (errno \(Int(code)))"
        case .present:
            break
        }
        let parent = (admin as NSString).deletingLastPathComponent
        let common = (parent as NSString).deletingLastPathComponent
        guard (parent as NSString).lastPathComponent == "worktrees",
              (try? identity(admin, path: admin)) == entry.adminIdentity,
              entry.adminIdentity.type == directoryMode,
              (try? identity(parent, path: admin)) == entry.worktreesIdentity,
              (try? identity(common, path: admin)) == entry.commonIdentity,
              let gitdir = try? readMarker(admin + "/gitdir", path: admin),
              gitdir.identity == entry.gitdirIdentity, gitdir.data == entry.gitdirContent else {
            return "Left git worktree metadata in place because it changed: \(admin)"
        }
        let worktree = (entry.gitFile as NSString).deletingLastPathComponent
        guard isMissing(entry.gitFile), isMissing(worktree) else {
            return "Left git worktree metadata in place because the worktree exists again: \(admin)"
        }
        guard isMissing(admin + "/locked") else {
            return "Left git worktree metadata in place because it is locked: \(admin)"
        }
        if let error = erase(admin) {
            return "Could not remove git worktree metadata: \(error)"
        }
        return nil
    }

    // MARK: Layout

    struct Layout: Sendable {
        let path: String
        let realPath: String
        let admin: String
        let common: String
    }

    /// Structural checks only, no git: `<path>/.git` is a small regular file of
    /// exactly one `gitdir: ` line naming `<common>/worktrees/<id>`, whose
    /// `gitdir` names this same `.git` file back, and whose common dir lies
    /// outside the worktree.
    static func layout(of rawPath: String) throws -> Layout {
        guard let path = try? CleanupPathSafety.normalize(rawPath) else {
            throw GitWorktreeError.notWorktree(rawPath)
        }
        let fail = GitWorktreeError.notWorktree(path)
        guard let folder = try? lstatInfo(path), folder.st_mode & S_IFMT == S_IFDIR,
              let realPath = realPath(path) else { throw fail }

        let gitFile = path + "/.git"
        let marker = try readMarker(gitFile, path: path)
        let markerLine = try singleLine(marker.data, path: path)
        guard markerLine.hasPrefix("gitdir: ") else { throw fail }
        let reference = String(markerLine.dropFirst("gitdir: ".count))
        guard !reference.isEmpty else { throw fail }
        guard let admin = self.realPath(join(reference, to: path)) else {
            // `<repository>/.git/worktrees/<id>` is gone. With the repository
            // folder reachable the entry was pruned: not a worktree. Without
            // it the repository is off-line, and "protected Git metadata"
            // would be the wrong thing to tell the person.
            let entry = join(reference, to: path) as NSString
            let worktrees = entry.deletingLastPathComponent as NSString
            if worktrees.lastPathComponent == "worktrees", !isReachable(worktrees.deletingLastPathComponent) {
                throw GitWorktreeError.repositoryUnavailable(path)
            }
            throw fail
        }
        guard let adminInfo = try? lstatInfo(admin), adminInfo.st_mode & S_IFMT == S_IFDIR else { throw fail }

        let commonLine = try singleLine(try readMarker(admin + "/commondir", path: path).data, path: path)
        guard !commonLine.isEmpty else { throw fail }
        guard let common = self.realPath(join(commonLine, to: admin)) else {
            throw isReachable(join(commonLine, to: admin)) ? fail : GitWorktreeError.repositoryUnavailable(path)
        }
        guard let commonInfo = try? lstatInfo(common), commonInfo.st_mode & S_IFMT == S_IFDIR else { throw fail }
        // The admin entry must be one of the common dir's own worktree entries.
        let parent = (admin as NSString).deletingLastPathComponent
        guard (parent as NSString).lastPathComponent == "worktrees",
              let parentID = try? identity(parent, path: path),
              let worktreesID = try? identity(common + "/worktrees", path: path),
              parentID == worktreesID else { throw fail }

        let backLine = try singleLine(try readMarker(admin + "/gitdir", path: path).data, path: path)
        guard !backLine.isEmpty, let back = try? lstatInfo(join(backLine, to: admin)),
              back.st_dev == marker.info.st_dev, back.st_ino == marker.info.st_ino else { throw fail }

        // By identity, so the Data-volume and firmlinked spellings of one
        // folder cannot hide a repository nested inside the worktree.
        for (inner, outer) in [(common, realPath), (admin, realPath), (realPath, common)]
        where isWithin(inner, outer) {
            throw fail
        }
        return Layout(path: path, realPath: realPath, admin: admin, common: common)
    }

    /// Whether something answers at `path` (symlinks followed): false for a
    /// folder that is not there, such as one on a drive that is not mounted.
    private static func isReachable(_ path: String) -> Bool {
        access(path, F_OK) == 0
    }

    /// Whether `inner` is `outer` or inside it, comparing each ancestor of
    /// `inner` with `outer` by device and inode. Unreadable means yes.
    private static func isWithin(_ inner: String, _ outer: String) -> Bool {
        guard let target = try? lstatInfo(outer) else { return true }
        var current = inner
        while true {
            guard let info = try? lstatInfo(current) else { return true }
            if info.st_dev == target.st_dev && info.st_ino == target.st_ino { return true }
            if current == "/" { return false }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    // MARK: Git

    static func locateGit(_ lookup: GitLookup) -> String? {
        let shim = try? statInfo("/usr/bin/git")
        func usable(_ candidate: String) -> Bool {
            guard candidate != "/usr/bin/git", let info = try? statInfo(candidate),
                  info.st_mode & S_IFMT == S_IFREG, access(candidate, X_OK) == 0 else { return false }
            if let shim, shim.st_dev == info.st_dev, shim.st_ino == info.st_ino { return false }
            return true
        }
        for directory in lookup.searchPath.split(separator: ":").map(String.init)
        where directory.hasPrefix("/") {
            let candidate = (directory as NSString).appendingPathComponent("git")
            if usable(candidate) { return candidate }
        }
        guard lookup.useDeveloperDir,
              let selected = BoundedProcess.run("/usr/bin/xcode-select", ["-p"],
                                                environment: minimalEnvironment, timeout: 5, cap: 4096),
              selected.status == 0, !selected.timedOut, !selected.overflow else { return nil }
        let developer = selected.text
        guard developer.hasPrefix("/") else { return nil }
        let candidate = (developer as NSString).appendingPathComponent("usr/bin/git")
        return usable(candidate) ? candidate : nil
    }

    private static var minimalEnvironment: [String: String] {
        ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    }

    private struct GitRunner {
        let git: String
        let layout: Layout
        let deadline: Date

        /// Runs one read-only git command against exactly the verified admin
        /// dir and worktree; no repository discovery, no inherited GIT_* state.
        func run(_ arguments: [String], cap: Int, allowed: Set<Int32> = [0]) throws -> BoundedProcess.Outcome {
            let path = layout.path
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw GitWorktreeError.timedOut(path) }
            var environment = GitWorktree.minimalEnvironment
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_PAGER"] = "cat"
            environment["PAGER"] = "cat"
            let full = ["--no-optional-locks", "--git-dir=" + layout.admin, "--work-tree=" + layout.path,
                        "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"] + arguments
            guard let outcome = BoundedProcess.run(git, full, environment: environment,
                                                   timeout: remaining, cap: cap) else {
                throw GitWorktreeError.gitMissing(path)
            }
            if outcome.timedOut { throw GitWorktreeError.timedOut(path) }
            guard allowed.contains(outcome.status) else {
                let detail = String(decoding: outcome.stderr.prefix(300), as: UTF8.self)
                    .split(separator: "\n").first.map(String.init) ?? "exit \(outcome.status)"
                throw GitWorktreeError.gitFailed(path, detail)
            }
            return outcome
        }
    }

    // MARK: Processes

    /// Blocks when any process this user can see has its working directory at
    /// or inside the worktree. lsof failing to run or answer blocks too.
    ///
    /// Decision (open files): only working directories are looked at, not
    /// files a process holds open inside the worktree (`lsof +D`, or every
    /// descriptor system-wide). Measured on this Mac, listing every open file
    /// takes 11 s and 12.4 MB against 0.43 s and 51 KB for working
    /// directories: past the 10 s limit and the 32 MB cap, so it would block
    /// every worktree, and `+D` walks the whole tree (a `node_modules` has
    /// 100k files) once per worktree where the working-directory reading is
    /// shared by a whole refresh. A program with files open in the worktree
    /// but its working directory elsewhere (an editor) is covered instead by
    /// the evidence that does not depend on lsof: nothing uncommitted or
    /// untracked or ignored-and-irreplaceable may be there, the admin entry
    /// untouched for two days, and no agent session worked in it. What is
    /// moved goes to the Trash first and can be put back.
    private static func rejectProcesses(inside path: String, real: String, evidence: WorktreeEvidence) throws {
        guard let names = evidence.workingDirectories(), !names.isEmpty else {
            throw GitWorktreeError.processCheckFailed(path)
        }
        for spelling in spellings(of: path, real: real).map({ $0.lowercased() }) {
            if names.contains(where: { $0 == spelling || $0.hasPrefix(spelling + "/") }) {
                throw GitWorktreeError.inUse(path)
            }
        }
    }

    /// What must sit next to an ignored folder, or inside it, for the engine
    /// (src/cleanup.rs `rule`) to call it rebuildable build output.
    private enum FolderMarker {
        case none
        case beside([String])
        case inside([String])
    }

    /// The ignored folders a worktree may still hold, with the marker the
    /// engine's own rule for that name requires. `.venv` is held to the same
    /// `pyvenv.cfg` as `venv`. `.gradle` is never here: it can hold
    /// `gradle.properties` with credentials. A name the engine has no rule for
    /// (`DerivedData` outside Xcode's folder) is not here either, except the
    /// Python tool caches, which hold nothing but what the tool recreates.
    private static let rebuildableFolders: [String: FolderMarker] = [
        "node_modules": .beside(["package.json"]),
        ".venv": .inside(["pyvenv.cfg"]),
        "venv": .inside(["pyvenv.cfg"]),
        "target": .beside(["Cargo.toml"]),
        ".next": .beside(["package.json"]),
        ".turbo": .beside(["package.json"]),
        ".nuxt": .beside(["package.json"]),
        ".svelte-kit": .beside(["package.json"]),
        ".parcel-cache": .beside(["package.json"]),
        ".expo": .beside(["package.json"]),
        "Pods": .beside(["Podfile"]),
        "__pycache__": .none,
        ".pytest_cache": .none,
        ".mypy_cache": .none,
        ".ruff_cache": .none,
    ]

    /// Whether `parts` (the components of an ignored folder, relative to the
    /// worktree) name a rebuildable folder whose marker is a regular file where
    /// the engine's rule looks for it.
    private static func isRebuildableFolder(_ parts: [String], in worktree: String) -> Bool {
        guard let name = parts.last, let marker = rebuildableFolders[name] else { return false }
        func hasFile(in folder: String, _ names: [String]) -> Bool {
            names.contains { file in
                var info = stat()
                return lstat(folder + "/" + file, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            }
        }
        let folder = ([worktree] + parts).joined(separator: "/")
        switch marker {
        case .none: return true
        case .inside(let files): return hasFile(in: folder, files)
        case .beside(let files): return hasFile(in: ([worktree] + parts.dropLast()).joined(separator: "/"), files)
        }
    }

    /// Lowercased working directories of every process lsof can see, nil when
    /// lsof did not run, timed out, overflowed its cap or failed.
    fileprivate static func readWorkingDirectories(_ limits: Limits) -> [String]? {
        guard let outcome = BoundedProcess.run(limits.lsof, ["-a", "-d", "cwd", "-Fn", "-w"],
                                               environment: minimalEnvironment, timeout: limits.lsofTimeout,
                                               cap: limits.lsofCap),
              !outcome.timedOut, !outcome.overflow, outcome.status == 0 else { return nil }
        return String(decoding: outcome.stdout, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("n") }.map { $0.dropFirst().lowercased() }
    }

    /// The given, resolved and Data-volume spellings of a folder.
    private static func spellings(of path: String, real: String) -> [String] {
        var result: [String] = []
        for spelling in [path, real] {
            let other = spelling.hasPrefix(dataRoot + "/") ? String(spelling.dropFirst(dataRoot.count))
                                                           : dataRoot + spelling
            for candidate in [spelling, other] where !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }

    // MARK: Files

    private static let directoryMode = UInt16(S_IFDIR)

    private struct Marker {
        let data: Data
        let info: stat
        var identity: CleanupIdentity {
            CleanupIdentity(device: UInt64(truncatingIfNeeded: info.st_dev),
                            inode: UInt64(truncatingIfNeeded: info.st_ino),
                            type: UInt16(truncatingIfNeeded: info.st_mode) & UInt16(S_IFMT))
        }
    }

    /// A small regular file, read without following a final symlink and only
    /// when the opened file is the one lstat saw.
    private static func readMarker(_ file: String, path: String) throws -> Marker {
        let fail = GitWorktreeError.notWorktree(path)
        guard let seen = try? lstatInfo(file), seen.st_mode & S_IFMT == S_IFREG,
              seen.st_size > 0, seen.st_size <= markerLimit else { throw fail }
        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw fail }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == seen.st_dev, opened.st_ino == seen.st_ino else { throw fail }
        var buffer = [UInt8](repeating: 0, count: markerLimit + 1)
        var count = 0
        while count < buffer.count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + count, $0.count - count) }
            if n < 0 { throw fail }
            if n == 0 { break }
            count += n
        }
        guard count > 0, count <= markerLimit else { throw fail }
        return Marker(data: Data(buffer.prefix(count)), info: opened)
    }

    /// Exactly one line: optional single trailing newline, no other control bytes.
    private static func singleLine(_ data: Data, path: String) throws -> String {
        var bytes = Array(data)
        if bytes.last == 0x0a { bytes.removeLast() }
        guard !bytes.contains(where: { $0 < 0x20 || $0 == 0x7f }),
              let text = String(bytes: bytes, encoding: .utf8) else { throw GitWorktreeError.notWorktree(path) }
        return text
    }

    private static func join(_ reference: String, to base: String) -> String {
        reference.hasPrefix("/") ? reference : (base as NSString).appendingPathComponent(reference)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func lstatInfo(_ path: String) throws -> stat {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else { throw CleanupPathError.unavailable(path, errno) }
        return info
    }

    /// Metadata of what `path` finally names, symlinks resolved.
    private static func statInfo(_ path: String) throws -> stat {
        guard let resolved = realPath(path) else { throw CleanupPathError.missing(path) }
        return try lstatInfo(resolved)
    }

    private static func identity(_ file: String, path: String) throws -> CleanupIdentity {
        guard let info = try? lstatInfo(file) else { throw GitWorktreeError.notWorktree(path) }
        return CleanupIdentity(device: UInt64(truncatingIfNeeded: info.st_dev),
                               inode: UInt64(truncatingIfNeeded: info.st_ino),
                               type: UInt16(truncatingIfNeeded: info.st_mode) & UInt16(S_IFMT))
    }

    /// True when present, false only when lstat says it does not exist.
    private static func exists(_ file: String, path: String) throws -> Bool {
        var info = stat()
        if Darwin.lstat(file, &info) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw GitWorktreeError.gitFailed(path, "cannot inspect \(file) (errno \(code))")
    }

    /// True when `folder` holds anything but empty folders, looked at without
    /// following symlinks (a symlink is an entry). Absent is false. A folder
    /// that cannot be inspected throws (blocks), and more than `refLimit`
    /// entries counts as holding refs.
    private static let refLimit = 10_000
    private static func holdsRefs(_ folder: String, path: String) throws -> Bool {
        var pending = [folder]
        var seen = 0
        while let directory = pending.popLast() {
            var info = stat()
            if Darwin.lstat(directory, &info) != 0 {
                if errno == ENOENT && directory == folder { return false }
                throw GitWorktreeError.gitFailed(path, "cannot inspect \(directory) (errno \(errno))")
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { return true }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                throw GitWorktreeError.gitFailed(path, "cannot read \(directory)")
            }
            seen += names.count
            if seen > refLimit { return true }
            for name in names {
                var entry = stat()
                guard Darwin.lstat(directory + "/" + name, &entry) == 0 else {
                    throw GitWorktreeError.gitFailed(path, "cannot inspect \(directory)/\(name) (errno \(errno))")
                }
                if entry.st_mode & S_IFMT == S_IFDIR { pending.append(directory + "/" + name) } else { return true }
            }
        }
        return false
    }

    private enum Inspection {
        case present, missing, unreadable(Int32)
    }

    /// lstat of the admin entry itself. A missing entry is already gone.
    /// Any other failure is unread, not "changed".
    private static func inspect(_ file: String) -> Inspection {
        var info = stat()
        if Darwin.lstat(file, &info) == 0 { return .present }
        return errno == ENOENT ? .missing : .unreadable(errno)
    }

    private static func isMissing(_ file: String) -> Bool {
        var info = stat()
        return Darwin.lstat(file, &info) != 0 && errno == ENOENT
    }

    private static func modificationDate(_ file: String) -> Date? {
        guard let info = try? lstatInfo(file) else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }

    private final class Settings: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: GitLookup
        init(_ initial: GitLookup) { stored = initial }
        var value: GitLookup {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}

/// What verifying a worktree needs that does not depend on which worktree it
/// is: the working directory of every process (one lsof) and the Codex session
/// logs (one scan). A refresh that verifies many worktrees reads each once and
/// hands this to every verification; a caller that passes none gets fresh
/// readings per verification. Single-flight: concurrent callers share the one
/// reading. A reading that failed stays failed for the lifetime of this value,
/// so a refresh blocks its worktrees with that reason rather than re-running a
/// 10 s lsof for each.
///
/// Only the refresh uses it, and a refresh only decides what the panel offers:
/// `CleanupOperations.trash` verifies again with evidence of its own, so
/// nothing here stands in for the check at the moment of the move.
nonisolated final class WorktreeEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: GitWorktree.Limits
    private var directories: [String]??
    private var codex: (since: Date, activity: AgentSessions.Activity)?

    init(limits: GitWorktree.Limits = .standard) { self.limits = limits }

    /// Lowercased working directories of the processes lsof can see; nil when
    /// lsof could not answer.
    func workingDirectories() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        if let directories { return directories }
        let read = GitWorktree.readWorkingDirectories(limits)
        directories = .some(read)
        return read
    }

    /// The Codex session logs written since `cutoff`. A scan made for an
    /// earlier cutoff serves a later one: it only holds more.
    func codexActivity(since cutoff: Date) -> AgentSessions.Activity {
        lock.lock(); defer { lock.unlock() }
        if let codex, codex.since <= cutoff { return codex.activity }
        let activity = AgentSessions.scan(in: AgentSessions.codex, since: cutoff)
        codex = (cutoff, activity)
        return activity
    }
}

/// Runs a program with an argument array (no shell), stdin closed, a fixed
/// environment, a time limit and an output cap. Both pipes are drained while
/// it runs, so a chatty child cannot stall on a full pipe.
nonisolated enum BoundedProcess {
    /// Every program `run` was asked to start, counted by executable name
    /// (`git`, `lsof`...). Checks and benchmarks read it to prove how many
    /// processes a refresh spawns; nothing in the app depends on it.
    static let spawns = SpawnLog()

    final class SpawnLog: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        fileprivate func record(_ executable: String) {
            let name = (executable as NSString).lastPathComponent
            lock.lock(); defer { lock.unlock() }
            counts[name, default: 0] += 1
        }

        func count(_ name: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[name] ?? 0
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            counts = [:]
        }
    }

    struct Outcome: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
        /// Stdout went past the cap; what was kept is only a prefix.
        let overflow: Bool

        var text: String {
            String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Nil when the program could not be started. The synchronous face of
    /// `Subprocess`: callers here are themselves synchronous (the guard's
    /// git checks), so the thread waits, bounded by `timeout`, and the helper
    /// does the spawning, draining and killing.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval, cap: Int) -> Outcome? {
        spawns.record(executable)
        let spec = Subprocess.Spec(executable, arguments, environment: environment, directory: "/")
        let outcome = Subprocess.runBlocking(spec, stdout: .capture(cap: cap), stderr: .capture(cap: 64 * 1024),
                                             timeout: timeout)
        guard outcome.started else { return nil }
        // A descendant left running can hold the pipes open (`leaked`): the
        // output may be cut short, which callers treat like a timeout.
        return Outcome(status: outcome.status, stdout: outcome.stdout, stderr: outcome.stderr,
                       timedOut: outcome.timedOut || outcome.leaked, overflow: outcome.overflow)
    }
}
