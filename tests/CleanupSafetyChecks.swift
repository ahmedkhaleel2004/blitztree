import Darwin
import Foundation

@main
enum CleanupSafetyChecks {
    private static let fm = FileManager.default

    static func main() throws {
        let rawBase = fm.temporaryDirectory
            .appendingPathComponent("blitztree-cleanup-safety-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: rawBase, withIntermediateDirectories: true)
        let base = canonical(rawBase)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let project = home.appendingPathComponent("work/repo", isDirectory: true)
        let projectArtifact = project.appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: projectArtifact, withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data([1]).write(to: project.appendingPathComponent(".git/config"))
        expectAllowed("artifact inside git project") {
            _ = try CleanupPathSafety.capture(path: projectArtifact.path, root: home.path, home: home.path, check: .policyOnly)
        }
        expectRejected("git repository root") {
            _ = try CleanupPathSafety.capture(path: project.path, root: home.path, home: home.path, check: .policyOnly)
        }
        expectRejected("inside .git metadata") {
            _ = try CleanupPathSafety.capture(
                path: project.appendingPathComponent(".git/config").path,
                root: home.path,
                home: home.path, check: .policyOnly)
        }

        let credentialsArtifact = home.appendingPathComponent(".ssh/node_modules", isDirectory: true)
        try fm.createDirectory(at: credentialsArtifact, withIntermediateDirectories: true)
        expectRejected("credential root exception") {
            _ = try CleanupPathSafety.capture(path: credentialsArtifact.path, root: home.path, home: home.path, check: .policyOnly)
        }
        let caseCredentials = home.appendingPathComponent(".SSH/node_modules").path
        if fm.fileExists(atPath: caseCredentials) {
            expectRejected("case variant of credential path") {
                _ = try CleanupPathSafety.capture(path: caseCredentials, root: home.path, home: home.path, check: .policyOnly)
            }
        }
        let appleCache = home.appendingPathComponent("Library/Caches/com.apple.fixture")
        try fm.createDirectory(at: appleCache, withIntermediateDirectories: true)
        expectRejected("macOS managed cache") {
            _ = try CleanupPathSafety.capture(path: appleCache.path, root: home.path, home: home.path, check: .policyOnly)
        }
        let dataAlias = "/System/Volumes/Data" + projectArtifact.path
        if fm.fileExists(atPath: dataAlias) {
            expectAllowed("verified Data volume alias") {
                _ = try CleanupPathSafety.capture(path: dataAlias, root: home.path, home: home.path, check: .policyOnly)
            }
            expectRejected("protected path via Data volume alias") {
                _ = try CleanupPathSafety.capture(path: "/System/Volumes/Data" + credentialsArtifact.path,
                                                  root: home.path, home: home.path, check: .policyOnly)
            }
        }

        // Persistence folders block recursively: no named subfolder is a cache.
        for relative in ["Library/LaunchAgents", "Library/LaunchAgents/com.example.agent",
                         "Library/Fonts/node_modules", "Library/Application Scripts/com.example"] {
            let persistence = home.appendingPathComponent(relative, isDirectory: true)
            try fm.createDirectory(at: persistence, withIntermediateDirectories: true)
            expectRejected("persistence folder \(relative)") {
                _ = try CleanupPathSafety.capture(path: persistence.path, root: home.path, home: home.path, check: .policyOnly)
            }
        }
        let namedCache = home.appendingPathComponent("Library/Caches/com.example.tool", isDirectory: true)
        try fm.createDirectory(at: namedCache, withIntermediateDirectories: true)
        expectAllowed("named cache subfolder") {
            _ = try CleanupPathSafety.capture(path: namedCache.path, root: home.path, home: home.path, check: .policyOnly)
        }

        let mediaArtifact = home.appendingPathComponent("Pictures/project/node_modules", isDirectory: true)
        try fm.createDirectory(at: mediaArtifact, withIntermediateDirectories: true)
        expectRejected("media protected root") {
            _ = try CleanupPathSafety.capture(path: mediaArtifact.path, root: home.path, home: home.path, check: .policyOnly)
        }

        let sibling = base.appendingPathComponent("home-evil/project/node_modules", isDirectory: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        expectRejected("sibling prefix escape") {
            _ = try CleanupPathSafety.capture(path: sibling.path, root: home.path, home: home.path, check: .policyOnly)
        }

        let outsideArtifact = outside.appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: outsideArtifact, withIntermediateDirectories: true)
        let ancestorLink = home.appendingPathComponent("linked-project", isDirectory: true)
        try fm.createSymbolicLink(atPath: ancestorLink.path, withDestinationPath: outside.path)
        expectRejected("symlink ancestor") {
            _ = try CleanupPathSafety.capture(
                path: ancestorLink.appendingPathComponent("node_modules").path,
                root: home.path,
                home: home.path, check: .policyOnly)
        }
        expectRejected("symlink ancestor hidden by parent traversal") {
            _ = try CleanupPathSafety.capture(
                path: ancestorLink.appendingPathComponent("../work/node_modules").path,
                root: home.path,
                home: home.path, check: .policyOnly)
        }
        let finalLink = home.appendingPathComponent("work/final-link", isDirectory: true)
        try fm.createSymbolicLink(atPath: finalLink.path, withDestinationPath: outsideArtifact.path)
        expectRejected("symlink final component") {
            _ = try CleanupPathSafety.capture(path: finalLink.path, root: home.path, home: home.path, check: .policyOnly)
        }

        let replacePath = home.appendingPathComponent("work/replaced", isDirectory: true)
        try fm.createDirectory(at: replacePath, withIntermediateDirectories: true)
        let captured = try CleanupPathSafety.capture(path: replacePath.path, root: home.path, home: home.path, check: .policyOnly)
        try fm.removeItem(at: replacePath)
        try fm.createDirectory(at: replacePath, withIntermediateDirectories: true)
        expectRejected("replaced target inode") { try captured.validate() }

        let replaceRoot = home.appendingPathComponent("scan-scope", isDirectory: true)
        let replaceRootTarget = replaceRoot.appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: replaceRootTarget, withIntermediateDirectories: true)
        let rootCaptured = try CleanupPathSafety.capture(
            path: replaceRootTarget.path, root: replaceRoot.path, home: home.path, check: .policyOnly)
        try fm.removeItem(at: replaceRoot)
        try fm.createDirectory(at: replaceRootTarget, withIntermediateDirectories: true)
        expectRejected("replaced authorized root") { try rootCaptured.validate() }

        let rootAlias = home.appendingPathComponent(".").path
        expectRejected("authorized root itself") {
            _ = try CleanupPathSafety.capture(path: rootAlias, root: home.path, home: home.path, check: .policyOnly)
        }

        let caseProject = home.appendingPathComponent("Documents/CaseProject", isDirectory: true)
        let caseArtifact = caseProject.appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: caseArtifact, withIntermediateDirectories: true)
        let caseVariant = home.appendingPathComponent("documents/caseproject/NODE_MODULES").path
        if fm.fileExists(atPath: caseVariant) {
            expectAllowed("case-insensitive policy") {
                _ = try CleanupPathSafety.capture(path: caseVariant, root: home.path, home: home.path, check: .policyOnly)
            }
        }

        let chat = home.appendingPathComponent("Documents/Codex/2026-09-01/example")
        let outputs = chat.appendingPathComponent("outputs")
        try fm.createDirectory(at: outputs, withIntermediateDirectories: true)
        for path in [chat.path, outputs.path] {
            expectAllowed("Codex chat exception") {
                _ = try CleanupPathSafety.capture(path: path, root: home.path, home: home.path, check: .policyOnly)
            }
            precondition(CleanupPathSafety.codexChat(path, home: home.path) == chat.path)
        }
        for relative in ["Documents", "Documents/Codex", "Documents/Codex/2026-09-01",
                         "Documents/Codex/not-a-date/example", "Documents/Other/2026-09-01/example"] {
            let path = home.appendingPathComponent(relative).path
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            expectRejected("Codex exception must not include its parents or neighboring folders") {
                _ = try CleanupPathSafety.capture(path: path, root: home.path, home: home.path, check: .policyOnly)
            }
            precondition(CleanupPathSafety.codexChat(path, home: home.path) == nil)
        }
        let chatAlias = "/System/Volumes/Data" + outputs.path
        if fm.fileExists(atPath: chatAlias) {
            expectAllowed("Codex chat via verified Data alias") {
                _ = try CleanupPathSafety.capture(path: chatAlias, root: home.path, home: home.path, check: .policyOnly)
            }
            precondition(CleanupPathSafety.codexChat(chatAlias, home: home.path) == chat.path)
        }
        try fm.createDirectory(at: chat.appendingPathComponent(".git"), withIntermediateDirectories: true)
        expectRejected("Codex exception must not override git protection") {
            _ = try CleanupPathSafety.capture(path: chat.path, root: home.path, home: home.path, check: .policyOnly)
        }
        let chatLink = chat.appendingPathComponent("linked-output")
        try fm.createSymbolicLink(at: chatLink, withDestinationURL: outside)
        expectRejected("Codex exception must not override symlink protection") {
            _ = try CleanupPathSafety.capture(path: chatLink.path, root: home.path, home: home.path, check: .policyOnly)
        }

        let cloudArtifact = home.appendingPathComponent("cloud/project/node_modules", isDirectory: true)
        try fm.createDirectory(at: cloudArtifact, withIntermediateDirectories: true)
        let cloudFlag = UInt32(0x4000_0000)
        let markedCloud = cloudArtifact.path.withCString { path in
            guard chflags(path, cloudFlag) == 0 else { return false }
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            return UInt64(truncatingIfNeeded: info.st_flags) & UInt64(cloudFlag) != 0
        }
        if markedCloud {
            expectRejected("cloud-only artifact") {
                _ = try CleanupPathSafety.capture(path: cloudArtifact.path, root: home.path, home: home.path, check: .policyOnly)
            }
            _ = cloudArtifact.path.withCString { chflags($0, 0) }
        } else {
            print("SKIP cloud-only flag (filesystem denied chflags)")
        }

        try dotEntryPolicy(home: home)
        try worktreeGuard(home: home, outside: outside)

        print("PASS CleanupSafetyChecks")
    }

    /// Top-level dot entries of a home are not blanket-allowed: credentials and
    /// settings folders are refused, the folders that mix them with caches
    /// (`.claude`, `.codex`, `.gradle`...) give up only the children the engine
    /// names, and global Node installs are refused wherever they live.
    private static func dotEntryPolicy(home: URL) throws {
        func make(_ relative: String, file: Bool = false) throws -> String {
            let url = home.appendingPathComponent(relative)
            if file {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1]).write(to: url)
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url.path
        }
        func capture(_ path: String) throws {
            _ = try CleanupPathSafety.capture(path: path, root: home.path, home: home.path, check: .policyOnly)
        }
        for relative in [".aws", ".kube", ".docker", ".netrc", ".zshrc"] {
            let path = try make(relative, file: relative.hasPrefix(".n") || relative.hasPrefix(".z"))
            expectGitRejection("~/\(relative)", .protectedPath(path)) { try capture(path) }
        }
        for relative in [".aws/credentials", ".kube/config", ".docker/config.json"] {
            let path = try make(relative, file: true)
            expectGitRejection("~/\(relative)", .protectedPath(path)) { try capture(path) }
        }
        for relative in [".claude", ".codex", ".gradle"] {
            let path = try make(relative)
            expectGitRejection("~/\(relative) is not a cleanup target", .tooBroad(path)) { try capture(path) }
        }
        expectGitRejection("~/.zprofile is not on the allowlist", .tooBroad(try make(".zprofile", file: true))) {
            try capture(home.path + "/.zprofile")
        }
        for relative in [".claude/settings.json", ".codex/auth.json", ".gradle/gradle.properties",
                         ".cargo/credentials.toml", ".m2/settings.xml", ".ollama/id_ed25519"] {
            let path = try make(relative, file: true)
            expectGitRejection("~/\(relative) holds settings or credentials", .protectedPath(path)) { try capture(path) }
        }
        let nvm = try make(".nvm/versions/node/v20.0.0/lib/node_modules")
        for path in [nvm, nvm + "/npm"] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            expectGitRejection("global Node install under .nvm", .protectedPath(path)) { try capture(path) }
        }
        for relative in [".config/op", ".config/gh", ".terraform.d", ".local/share/keyrings", ".gnupg", ".ssh",
                         ".config/gcloud", ".oci", ".azure", ".password-store"] {
            let path = try make(relative)
            expectGitRejection("~/\(relative) is a credentials folder", .protectedPath(path)) { try capture(path) }
            let inner = try make(relative + "/secret", file: true)
            expectGitRejection("~/\(relative)/secret", .protectedPath(inner)) { try capture(inner) }
        }
        // Claude's saved memory, and Hugging Face tokens beside a cache.
        for relative in [".claude/projects/-Users-me-work/memory", ".claude/projects/-Users-me-work/memory/MEMORY.md"] {
            let path = try make(relative, file: relative.hasSuffix(".md"))
            expectGitRejection("~/\(relative)", .protectedPath(path)) { try capture(path) }
        }
        // A project folder is a target only while it holds transcripts and nothing else.
        let mixed = try make(".claude/projects/-Users-me-mixed")
        _ = try make(".claude/projects/-Users-me-mixed/0b0e6f0e-2f6a-4b61-9a53-0d6a3c1a9a11")
        _ = try make(".claude/projects/-Users-me-mixed/0b0e6f0e-2f6a-4b61-9a53-0d6a3c1a9a11.jsonl", file: true)
        expectAllowed("a project folder of transcripts") { try capture(mixed) }
        for stray in ["memory", "notes.md", "not-a-session-id"] {
            let entry = try make(".claude/projects/-Users-me-mixed/" + stray, file: stray.hasSuffix(".md"))
            expectGitRejection("a project folder with \(stray) in it", .protectedPath(mixed)) { try capture(mixed) }
            try fm.removeItem(atPath: entry)
        }
        expectAllowed("the project folder again, once the strays are gone") { try capture(mixed) }
        for relative in [".cache/huggingface/token", ".cache/huggingface/stored_tokens"] {
            let path = try make(relative, file: true)
            expectGitRejection("~/\(relative)", .protectedPath(path)) { try capture(path) }
        }
        let hf = try make(".cache/huggingface")
        expectGitRejection("a cache folder holding a token directly", .protectedPath(hf)) { try capture(hf) }
        expectAllowed("a cache folder without one") { try capture(try make(".cache/uv")) }
        precondition(CleanupPathSafety.isInsideEngineContainer(home.path + "/.claude/projects", home: home.path))
        precondition(CleanupPathSafety.isInsideEngineContainer(home.path + "/.codex/worktrees/abc", home: home.path))
        precondition(CleanupPathSafety.isInsideEngineContainer(home.path + "/work/app/.cache/x", home: home.path))
        precondition(CleanupPathSafety.isInsideEngineContainer(home.path + "/.gradle/caches", home: home.path))
        precondition(!CleanupPathSafety.isInsideEngineContainer(home.path + "/work/app/node_modules", home: home.path))
        precondition(!CleanupPathSafety.isInsideEngineContainer(home.path + "/.npm", home: home.path))
        // What the engine's rules emit under these folders stays allowed.
        for relative in [".npm", ".claude/projects/-Users-me-quiet", ".claude/file-history", ".codex/sessions/2026",
                         ".codex/worktrees/abcd", ".gradle/caches", ".cargo/registry", ".m2/repository",
                         ".ollama/models", ".rustup/toolchains/stable", ".cache/pip"] {
            let path = try make(relative)
            expectAllowed("~/\(relative)") { try capture(path) }
        }

        // Global package installs, and other users' homes (a whole-disk scan
        // reaches both), on values: /opt/homebrew cannot be built in a fixture.
        for path in ["/opt/homebrew/lib/node_modules", "/opt/homebrew/lib/node_modules/npm/bin",
                     "/usr/local/lib/node_modules", "/System/Volumes/Data/opt/homebrew/lib/node_modules",
                     "/OPT/Homebrew/Lib/Node_Modules", "/opt/homebrew/Cellar/node/22.1.0/lib/node_modules"] {
            precondition(CleanupPathSafety.isGlobalPackageFolder(path), "\(path) is a global install")
        }
        for path in ["/opt/homebrew/bin", "/opt/homebrew/lib", "/usr/local/lib/python3", "/Users/me/work/node_modules",
                     "/opt/homebrew", "/opt/homebrewed/lib/node_modules", "/usr/local/src/app/node_modules"] {
            precondition(!CleanupPathSafety.isGlobalPackageFolder(path), "\(path) is not a global install")
        }
        precondition(CleanupPathSafety.isGlobalPackageFolder(fm.temporaryDirectory.path + "/p/lib/node_modules",
                                                             roots: [fm.temporaryDirectory.path + "/p"]),
                     "the roots are a parameter")
        if fm.fileExists(atPath: "/opt/homebrew/lib/node_modules") {
            expectGitRejection("the machine's global Node install", .protectedPath("/opt/homebrew/lib/node_modules")) {
                _ = try CleanupPathSafety.capture(path: "/opt/homebrew/lib/node_modules",
                                                  root: "/System/Volumes/Data", home: home.path, check: .policyOnly)
            }
        } else {
            print("SKIP /opt/homebrew/lib/node_modules capture (not installed here)")
        }
        for (path, relative) in [("/Users/other/.aws", ".aws"), ("/System/Volumes/Data/Users/other/Documents/a", "Documents/a"),
                                 ("/Volumes/Disk/Users/other/.ssh/id", ".ssh/id")] {
            precondition(CleanupPathSafety.otherHomeRelative(path) == relative, "\(path) is in another home")
        }
        precondition(CleanupPathSafety.otherHomeRelative("/Users/other") == "", "another home itself")
        precondition(CleanupPathSafety.otherHomeRelative("/Volumes/Disk/Users/other") == "", "another home on a disk")
        for path in ["/Users", "/Applications/Foo.app", "/private/tmp/x/y", "/Volumes/Disk/data/y"] {
            precondition(CleanupPathSafety.otherHomeRelative(path) == nil, "\(path) is not inside a home")
        }
        // At the top of a volume nothing is offered: a planted tag or a
        // dot entry must not make /Users/<name> or an app bundle a target.
        for path in ["/Users", "/Users/Shared", "/System/Volumes/Data/Users/other", "/Applications/Foo.app",
                     "/Volumes/Disk", "/Volumes/Disk/Photos", "/opt/homebrew", "/Volumes/Disk/Users/other"] {
            precondition(CleanupPathSafety.isShallowOutsideHome(path), "\(path) is at the top of a volume")
        }
        for path in ["/Users/Shared/x", "/Applications/Foo.app/Contents", "/Volumes/Disk/Photos/2024/a",
                     "/private/tmp/claude-501/p/s", "/System/Volumes/Data/Users/other/work/app",
                     "/Volumes/Disk/proj/node_modules", "/Volumes/Disk/work/repo/target",
                     "/System/Volumes/Data/Volumes/Disk/proj/node_modules", "/Volumes/Disk/Users/other/work"] {
            precondition(!CleanupPathSafety.isShallowOutsideHome(path), "\(path) is deeper")
        }
        precondition(CleanupPathSafety.isShallowOutsideHome("/Volumes/Disk/proj"), "a folder directly on a disk is its top")
        try externalDisk()
        expectGitRejection("/Users/Shared under a whole-disk scan root", .tooBroad("/Users/Shared")) {
            _ = try CleanupPathSafety.capture(path: "/Users/Shared", root: "/System/Volumes/Data", home: home.path, check: .policyOnly)
        }
        for relative in [".aws", ".aws/credentials", ".zshrc", ".claude", ".gradle", ".claude/settings.json",
                         "Documents/a", "Desktop", ".ssh/id", "Library/LaunchAgents/x", ".nvm/v/lib/node_modules"] {
            let path = "/Users/other/" + relative
            do {
                try CleanupPathSafety.homePolicy(relative: relative, path: path) { false }
                fatalError("another user's ~/\(relative) unexpectedly accepted")
            } catch is CleanupPathError {}
        }
        for relative in [".npm", ".claude/projects/x", ".cache/pip", "work/app/node_modules"] {
            try CleanupPathSafety.homePolicy(relative: relative, path: "/Users/other/" + relative) { false }
        }
    }

    /// A linked worktree is allowed only while it verifies as clean and
    /// unused, at capture and again at validate; every other `.git` stays blocked.
    private static func worktreeGuard(home: URL, outside: URL) throws {
        let fixture = GitFixture(base: home.deletingLastPathComponent())
        let repo = fixture.repository(home.appendingPathComponent("work/gitrepo").path)
        func capture(_ path: String) throws -> CleanupTarget {
            try CleanupPathSafety.capture(path: path, root: home.path, home: home.path, check: .policyOnly)
        }

        let clean = fixture.worktree(of: repo, at: home.appendingPathComponent("work/wt-clean").path)
        fixture.backdate(clean)
        expectAllowed("clean, unused linked worktree") { _ = try capture(clean) }

        let dirtied = fixture.worktree(of: repo, at: home.appendingPathComponent("work/wt-dirtied").path)
        fixture.backdate(dirtied)
        let planned = try capture(dirtied)
        fixture.write(dirtied + "/new-file.txt", "not committed\n")
        expectGitRejection("worktree dirtied between planning and action", .gitWorktree(.changes(dirtied))) { try planned.validate() }

        let fresh = fixture.worktree(of: repo, at: home.appendingPathComponent("work/wt-fresh").path)
        expectGitRejection("worktree used in the last 2 days", .gitWorktree(.recentlyUsed(fresh))) { _ = try capture(fresh) }

        let saved = GitWorktree.lookup
        GitWorktree.lookup = GitLookup(searchPath: "", useDeveloperDir: false)
        expectGitRejection("git missing blocks a worktree", .gitWorktree(.gitMissing(clean))) { _ = try capture(clean) }
        GitWorktree.lookup = saved

        // A `.git` directory, a `.git` symlink, an unverifiable `.git` file,
        // and a path through a `.git` component all stay blocked.
        expectGitRejection("main repository with a .git directory", .gitPath(repo + "/.git")) { _ = try capture(repo) }
        let linked = home.appendingPathComponent("work/git-symlink").path
        try fm.createDirectory(atPath: linked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linked + "/.git", withDestinationPath: clean + "/.git")
        expectGitRejection(".git symlink", .gitPath(linked + "/.git")) { _ = try capture(linked) }
        let copied = home.appendingPathComponent("work/git-file-copy").path
        try fm.createDirectory(atPath: copied, withIntermediateDirectories: true)
        try fm.copyItem(atPath: clean + "/.git", toPath: copied + "/.git")
        expectGitRejection(".git file whose admin entry names another worktree", .gitPath(copied + "/.git")) { _ = try capture(copied) }
        let stray = home.appendingPathComponent("work/git-file-stray").path
        try fm.createDirectory(atPath: stray, withIntermediateDirectories: true)
        fixture.write(stray + "/.git", "gitdir: \(outside.path)\n")
        expectGitRejection(".git file pointing outside any repository", .gitPath(stray + "/.git")) { _ = try capture(stray) }
        let admin = fixture.admin(of: clean)
        try fm.createDirectory(atPath: admin + "/sub", withIntermediateDirectories: true)
        expectRejected("inside a worktree admin entry") { _ = try capture(admin + "/sub") }

        // Each case above fails for its own reason, not because git is unusable.
        expectAllowed("clean worktree still allowed after the blocked cases") { _ = try capture(clean) }
    }

    private static func expectAllowed(_ label: String, _ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            fatalError("\(label): unexpectedly rejected: \(error)")
        }
    }

    private static func expectRejected(_ label: String, _ operation: () throws -> Void) {
        do {
            try operation()
            fatalError("\(label): unexpectedly accepted")
        } catch {
            // Every rejection is useful here; the production caller presents
            // the localized reason and the policy tests focus on the boundary.
        }
    }

    /// A real disk image mounted under /Volumes: a project's build folder on
    /// it is offered (as in 0.7.0), what sits directly on the disk is not.
    private static func externalDisk() throws {
        func hdiutil(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        let folder = fm.temporaryDirectory.appendingPathComponent("blitztree-disk-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let name = "BZV" + UUID().uuidString.prefix(6)
        let mount = "/Volumes/" + name
        let image = folder.appendingPathComponent("disk.dmg").path
        guard hdiutil(["create", "-quiet", "-size", "10m", "-fs", "HFS+", "-volname", name, image]),
              hdiutil(["attach", "-quiet", "-nobrowse", image]) else {
            print("SKIP external disk under /Volumes (hdiutil could not attach an image here)")
            return
        }
        defer { _ = hdiutil(["detach", mount, "-force", "-quiet"]) }
        for relative in ["proj/node_modules/pkg", "Photos/2024"] {
            try fm.createDirectory(atPath: mount + "/" + relative, withIntermediateDirectories: true)
        }
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: mount + "/proj/package.json"))
        let home = canonical(folder).appendingPathComponent("home").path
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        expectAllowed("a project's node_modules on an external disk") {
            _ = try CleanupPathSafety.capture(path: mount + "/proj/node_modules", root: mount, home: home, check: .policyOnly)
        }
        expectGitRejection("a folder directly on the disk", .tooBroad(mount + "/Photos")) {
            _ = try CleanupPathSafety.capture(path: mount + "/Photos", root: mount, home: home, check: .policyOnly)
        }
        expectGitRejection("a project folder directly on the disk", .tooBroad(mount + "/proj")) {
            _ = try CleanupPathSafety.capture(path: mount + "/proj", root: mount, home: home, check: .policyOnly)
        }
    }

    private static func expectGitRejection(_ label: String, _ expected: CleanupPathError,
                                           _ operation: () throws -> Void) {
        do {
            try operation()
            fatalError("\(label): unexpectedly accepted")
        } catch let error as CleanupPathError {
            precondition(error == expected, "\(label): rejected for the wrong reason: \(error)")
        } catch {
            fatalError("\(label): unexpected error \(error)")
        }
    }

    private static func canonical(_ url: URL) -> URL {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let found = url.path.withCString { path in
            resolved.withUnsafeMutableBufferPointer { buffer in
                realpath(path, buffer.baseAddress)
            }
        }
        return found == nil ? url : URL(fileURLWithPath:
            String(decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
}
