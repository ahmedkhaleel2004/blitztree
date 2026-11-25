import Darwin
import Foundation

/// GitWorktree verification, CleanupVerify, and the worktree Trash → delete →
/// admin-entry flow, all against real git in disposable fixtures.
@main
enum WorktreeChecks {
    private static let fm = FileManager.default

    static func main() async throws {
        let raw = fm.temporaryDirectory.appendingPathComponent("blitztree-worktree-\(UUID().uuidString)")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        let base = GitFixture.canonical(raw)
        defer { try? fm.removeItem(at: base) }
        let fixture = GitFixture(base: base)
        let repo = fixture.repository(base.appendingPathComponent("repo").path)
        var serial = 0
        func worktree(_ name: String) -> String {
            serial += 1
            return fixture.worktree(of: repo, at: base.appendingPathComponent("wts/\(serial)-\(name)").path)
        }

        try verification(fixture: fixture, repo: repo, worktree: worktree)
        try ignoredFiles(fixture: fixture, worktree: worktree)
        try rebuildableFolders(fixture: fixture, worktree: worktree)
        try recency(fixture: fixture, worktree: worktree)
        try sessionLogs(fixture: fixture, worktree: worktree)
        try processes(worktree: worktree)
        try cleanupVerify(base: base, worktree: worktree)
        try boundary(base: base, fixture: fixture, worktree: worktree)
        try await flow(fixture: fixture, base: base, repo: repo, worktree: worktree)
        try processFailures(base: base, worktree: worktree)
        try boundedProcess(base: base)
        try gitBudget(base: base, worktree: worktree)
        try unreachableRepository(fixture: fixture, worktree: worktree)
        try sharedEvidence(base: base, worktree: worktree)
        try await staleRefresh(fixture: fixture, base: base, worktree: worktree)
        try await settlement(fixture: fixture, base: base, repo: repo, worktree: worktree)
        try adminEntryMessages(base: base)
        print("PASS WorktreeChecks")
    }

    // MARK: Ignored files

    /// `git status` leaves ignored files out, but a `.env` or a local database
    /// kept under an ignored path is not recreated by a build: it blocks. An
    /// ignored folder a build recreates (`node_modules`) still passes, at any depth.
    private static func ignoredFiles(fixture: GitFixture, worktree: (String) -> String) throws {
        let env = worktree("ignored-env")
        fixture.write(env + "/.gitignore", "node_modules/\n.env\ndata/\n")
        fixture.run(["add", ".gitignore"], in: env)
        fixture.run(["commit", "-q", "-m", "ignore more"], in: env)
        fixture.write(env + "/.env", "SECRET=1\n")
        precondition(fixture.run(["status", "--porcelain"], in: env).isEmpty, "git status cannot see the ignored file")
        expectBlocked("ignored .env", env, .ignoredFiles(env))
        try fm.removeItem(atPath: env + "/.env")
        _ = expectVerified("the ignored file removed", env)

        try fm.createDirectory(atPath: env + "/data/db", withIntermediateDirectories: true)
        fixture.write(env + "/data/db/local.sqlite", "rows\n")
        expectBlocked("ignored data folder", env, .ignoredFiles(env))
        try fm.removeItem(atPath: env + "/data")

        // The nested one is build output only beside its own package.json.
        try fm.createDirectory(atPath: env + "/web", withIntermediateDirectories: true)
        fixture.write(env + "/web/package.json", "{}\n")
        fixture.run(["add", "web/package.json"], in: env)
        fixture.run(["commit", "-q", "-m", "web package"], in: env)
        for path in ["/node_modules/pkg", "/web/node_modules/pkg"] {
            try fm.createDirectory(atPath: env + path, withIntermediateDirectories: true)
            fixture.write(env + path + "/index.js", "x\n")
        }
        _ = expectVerified("ignored node_modules at the top and nested, each beside its package.json", env)
        try fm.createDirectory(atPath: env + "/docs", withIntermediateDirectories: true)
        fixture.write(env + "/docs/.env", "SECRET=2\n")
        expectBlocked("ignored .env next to rebuildable folders", env, .ignoredFiles(env))
        try fm.removeItem(atPath: env + "/docs")
        fixture.write(env + "/.gitignore", "node_modules/\n.env\ndata/\n.DS_Store\n")
        fixture.run(["add", ".gitignore"], in: env)
        fixture.run(["commit", "-q", "-m", "ignore Finder files"], in: env)
        fixture.write(env + "/.DS_Store", "finder\n")
        try fm.createDirectory(atPath: env + "/docs", withIntermediateDirectories: true)
        fixture.write(env + "/docs/.DS_Store", "finder\n")
        _ = expectVerified("Finder's .DS_Store is not a file worth keeping", env)
        try fm.removeItem(atPath: env + "/docs")
        fixture.write(env + "/node_modules/.env", "INSIDE=1\n")
        _ = expectVerified("an ignored file inside node_modules is part of it", env)
        fixture.write(env + "/stray.txt", "untracked\n")
        expectBlocked("an untracked file is still a change", env, .changes(env))

        // A rebuildable name above an ignored FILE exempts nothing: only a
        // folder ignored as a whole and named for build output may stay.
        for (label, file) in [("a database under a folder named target", "data/target/prod.db"),
                              (".env under a folder named target", "src/target/.env"),
                              ("a database under node_modules that is not ignored as a whole", "x/node_modules/secret.db")] {
            let nested = worktree("ignored-nested")
            fixture.write(nested + "/.gitignore", "*.db\n.env\n")
            fixture.run(["add", ".gitignore"], in: nested)
            fixture.run(["commit", "-q", "-m", "ignore files"], in: nested)
            _ = expectVerified("\(label): nothing there yet", nested)
            try fm.createDirectory(atPath: (nested + "/" + file as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            fixture.write(nested + "/" + file, "keep me\n")
            expectBlocked(label, nested, .ignoredFiles(nested))
        }
    }

    // MARK: Rebuildable ignored folders

    /// An ignored folder passes only where the engine's own rule would call it
    /// build output: its marker beside it (Cargo.toml, package.json, Podfile) or
    /// inside it (pyvenv.cfg). The name alone never does, and `.gradle` never.
    private static func rebuildableFolders(fixture: GitFixture, worktree: (String) -> String) throws {
        /// A worktree whose `.gitignore` holds `ignore` and which commits `tracked`
        /// (a nil text removes the file), with `ignored` files made afterwards.
        func scenario(_ label: String, ignore: String, tracked: [String: String?] = [:],
                      ignored: [String: String]) throws -> String {
            let path = worktree("rebuildable")
            fixture.write(path + "/.gitignore", ignore)
            for (file, text) in tracked {
                try fm.createDirectory(atPath: (path + "/" + file as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                if let text { fixture.write(path + "/" + file, text) } else { try fm.removeItem(atPath: path + "/" + file) }
            }
            fixture.run(["add", "-A"], in: path)
            fixture.run(["commit", "-q", "--allow-empty", "-m", label], in: path)
            for (file, text) in ignored {
                try fm.createDirectory(atPath: (path + "/" + file as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                fixture.write(path + "/" + file, text)
            }
            return path
        }
        let noManifest: [String: String?] = ["package.json": nil]

        // target/: only beside a Cargo.toml.
        var path = try scenario("target beside Cargo.toml", ignore: "target/\n", tracked: ["Cargo.toml": "[package]\n"],
                                ignored: ["target/debug/x": "o\n"])
        _ = expectVerified("target/ beside its Cargo.toml", path)
        path = try scenario("target without Cargo.toml", ignore: "target/\n", ignored: ["target/debug/x": "o\n"])
        expectBlocked("/target with no Cargo.toml beside it", path, .ignoredFiles(path))
        path = try scenario("nested target", ignore: "target/\n", tracked: ["Cargo.toml": "[package]\n"],
                            ignored: ["data/target/prod.db": "rows\n"])
        expectBlocked("data/target/prod.db: Cargo.toml is not beside that target", path, .ignoredFiles(path))

        // node_modules: only beside a package.json.
        path = try scenario("node_modules without package.json", ignore: "node_modules/\n", tracked: noManifest,
                            ignored: ["node_modules/.env": "SECRET=1\n"])
        expectBlocked("node_modules/.env with no package.json beside it", path, .ignoredFiles(path))
        path = try scenario("node_modules with package.json", ignore: "node_modules/\n",
                            ignored: ["node_modules/.env": "INSIDE=1\n"])
        _ = expectVerified("node_modules beside its package.json", path)

        // .venv: only with a pyvenv.cfg inside.
        path = try scenario("venv without pyvenv.cfg", ignore: ".venv/\n", ignored: [".venv/notes.txt": "mine\n"])
        expectBlocked(".venv/notes.txt with no pyvenv.cfg", path, .ignoredFiles(path))
        path = try scenario("venv with pyvenv.cfg", ignore: ".venv/\n",
                            ignored: [".venv/pyvenv.cfg": "home = /usr/bin\n", ".venv/lib/x": "o\n"])
        _ = expectVerified("an environment with its pyvenv.cfg", path)

        // Pods: only beside a Podfile.
        path = try scenario("Pods without Podfile", ignore: "Pods/\n", ignored: ["Pods/keys.plist": "<plist/>\n"])
        expectBlocked("Pods/keys.plist with no Podfile", path, .ignoredFiles(path))
        path = try scenario("Pods with Podfile", ignore: "Pods/\n", tracked: ["Podfile": "platform :ios\n"],
                            ignored: ["Pods/keys.plist": "<plist/>\n"])
        _ = expectVerified("Pods beside its Podfile", path)

        // .gradle: never, whatever sits beside it.
        path = try scenario("gradle properties", ignore: ".gradle/\n", tracked: ["build.gradle": "plugins {}\n"],
                            ignored: [".gradle/gradle.properties": "token=secret\n"])
        expectBlocked(".gradle/gradle.properties beside a build.gradle", path, .ignoredFiles(path))

        // A marker that is not a regular file is no marker.
        path = try scenario("symlinked manifest", ignore: "target/\n", ignored: ["target/x": "o\n"])
        try fm.createSymbolicLink(atPath: path + "/Cargo.toml", withDestinationPath: path + "/a.txt")
        fixture.run(["add", "Cargo.toml"], in: path)
        fixture.run(["commit", "-q", "-m", "link"], in: path)
        expectBlocked("target/ beside a Cargo.toml that is a symlink", path, .ignoredFiles(path))
    }

    // MARK: Verification

    private static func verification(fixture: GitFixture, repo: String,
                                     worktree: (String) -> String) throws {
        let clean = worktree("clean")
        let info = expectVerified("clean worktree on a branch", clean)
        precondition(info.branch == (clean as NSString).lastPathComponent, "branch name")
        precondition(info.head.count == 40 && info.path == clean, "head and path")
        precondition(info.commonDir == GitFixture.canonical(URL(fileURLWithPath: repo + "/.git")).path)
        precondition((info.adminDir as NSString).deletingLastPathComponent == info.commonDir + "/worktrees")

        let modified = worktree("modified")
        fixture.write(modified + "/a.txt", "changed\n")
        expectBlocked("modified tracked file", modified, .changes(modified))

        let staged = worktree("staged")
        fixture.write(staged + "/staged.txt", "staged\n")
        fixture.run(["add", "staged.txt"], in: staged)
        expectBlocked("staged new file", staged, .changes(staged))

        let untracked = worktree("untracked")
        fixture.write(untracked + "/new.txt", "new\n")
        expectBlocked("untracked file", untracked, .changes(untracked))

        let ignored = worktree("ignored")
        try fm.createDirectory(atPath: ignored + "/node_modules/pkg", withIntermediateDirectories: true)
        fixture.write(ignored + "/node_modules/pkg/index.js", "x\n")
        _ = expectVerified("ignored files only", ignored)

        let hidden = worktree("assume-unchanged")
        fixture.run(["update-index", "--assume-unchanged", "a.txt"], in: hidden)
        fixture.write(hidden + "/a.txt", "hidden change\n")
        precondition(fixture.run(["status", "--porcelain"], in: hidden).isEmpty, "status cannot see it")
        expectBlocked("assume-unchanged file", hidden, .hiddenChanges(hidden))

        let locked = worktree("locked")
        fixture.run(["worktree", "lock", "--reason", "fixture", locked], in: repo)
        expectBlocked("locked worktree", locked, .locked(locked))

        let orphan = worktree("detached-orphan")
        fixture.run(["checkout", "-q", "--detach"], in: orphan)
        fixture.run(["commit", "-q", "--allow-empty", "-m", "on no ref"], in: orphan)
        expectBlocked("detached HEAD with a commit on no ref", orphan, .unreachableHead(orphan))

        let detached = worktree("detached-contained")
        fixture.run(["checkout", "-q", "--detach"], in: detached)
        let detachedInfo = expectVerified("detached HEAD at a branch commit", detached)
        precondition(detachedInfo.branch == nil)

        let modules = worktree("gitmodules")
        fixture.write(modules + "/.gitmodules", "")
        expectBlocked(".gitmodules present", modules, .submodules(modules))

        // A commit that only refs/worktree/* keeps: HEAD itself is on a branch, so
        // nothing else notices, but removing the admin entry would drop the commit.
        let ownRef = worktree("own-ref")
        let ownAdmin = fixture.admin(of: ownRef)
        fixture.run(["checkout", "-q", "--detach"], in: ownRef)
        fixture.run(["commit", "-q", "--allow-empty", "-m", "only a worktree ref keeps this"], in: ownRef)
        let kept = fixture.run(["rev-parse", "HEAD"], in: ownRef).trimmingCharacters(in: .whitespacesAndNewlines)
        fixture.run(["update-ref", "refs/worktree/keep", kept], in: ownRef)
        fixture.run(["checkout", "-q", "--detach", "HEAD~1"], in: ownRef)
        precondition(fm.fileExists(atPath: ownAdmin + "/refs/worktree/keep"), "the ref is in the admin entry")
        precondition(fixture.run(["for-each-ref", "--contains", kept, "refs/heads", "refs/remotes", "refs/tags"], in: ownRef).isEmpty,
                     "no shared ref holds that commit")
        expectBlocked("a commit kept only by refs/worktree/keep", ownRef, .ownRefs(ownRef))
        let bisect = worktree("own-bisect-ref")
        let bisectAdmin = fixture.admin(of: bisect)
        try fm.createDirectory(atPath: bisectAdmin + "/refs/bisect", withIntermediateDirectories: true)
        _ = expectVerified("empty ref folders hold nothing", bisect)
        fixture.write(bisectAdmin + "/refs/bisect/bad", "0000000000000000000000000000000000000000\n")
        expectBlocked("a ref under refs/bisect", bisect, .ownRefs(bisect))
        try fm.removeItem(atPath: bisectAdmin + "/refs/bisect/bad")
        try fm.createSymbolicLink(atPath: bisectAdmin + "/refs/bisect/link", withDestinationPath: "/nonexistent")
        expectBlocked("a symlink under refs/ is an entry", bisect, .ownRefs(bisect))
        try fm.removeItem(atPath: bisectAdmin + "/refs/bisect/link")
        fixture.run(["update-ref", "-d", "refs/worktree/keep"], in: ownRef)
        _ = expectVerified("the ref deleted: verified again", ownRef)
        let ownMessage = GitWorktreeError.ownRefs(ownRef).englishDescription
        precondition(ownMessage.contains("refs of its own") && ownMessage.hasSuffix(ownRef), ownMessage)

        // Structural: anything but a `.git` file that round-trips to its own
        // admin entry is not a worktree.
        let linked = fixture.base.appendingPathComponent("git-symlink").path
        try fm.createDirectory(atPath: linked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linked + "/.git", withDestinationPath: clean + "/.git")
        expectBlocked(".git symlink", linked, .notWorktree(linked))
        expectBlocked(".git directory (plain repository)", repo, .notWorktree(repo))
        let outside = fixture.base.appendingPathComponent("git-file-outside").path
        let elsewhere = fixture.base.appendingPathComponent("plain-dir").path
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        fixture.write(outside + "/.git", "gitdir: \(elsewhere)\n")
        expectBlocked(".git file pointing outside a repository", outside, .notWorktree(outside))
        fixture.write(outside + "/.git", "gitdir: \(repo)/.git/worktrees/no-such-entry\n")
        expectBlocked(".git file naming a missing admin dir", outside, .notWorktree(outside))
        fixture.write(outside + "/.git", "gitdir: \(info.adminDir)\nextra\n")
        expectBlocked(".git file with more than one line", outside, .notWorktree(outside))
        let copy = fixture.base.appendingPathComponent("git-file-copy").path
        try fm.createDirectory(atPath: copy, withIntermediateDirectories: true)
        try fm.copyItem(atPath: clean + "/.git", toPath: copy + "/.git")
        expectBlocked("admin gitdir names another worktree", copy, .notWorktree(copy))
        let repointed = worktree("repointed")
        fixture.write(fixture.admin(of: repointed) + "/gitdir", clean + "/.git\n")
        expectBlocked("admin gitdir pointing elsewhere", repointed, .notWorktree(repointed))
        // The repository moved inside its own worktree, metadata still
        // consistent: trashing the worktree would take the repository along.
        let nestRepo = fixture.repository(fixture.base.appendingPathComponent("nest-repo").path)
        let nested = fixture.worktree(of: nestRepo, at: fixture.base.appendingPathComponent("wts/nested").path)
        let nestedID = (fixture.admin(of: nested) as NSString).lastPathComponent
        try fm.moveItem(atPath: nestRepo, toPath: nested + "/repo")
        let movedAdmin = nested + "/repo/.git/worktrees/" + nestedID
        let dataRoot = "/System/Volumes/Data"
        for spelling in [movedAdmin, dataRoot + movedAdmin] where fm.fileExists(atPath: spelling) {
            fixture.write(nested + "/.git", "gitdir: \(spelling)\n")
            precondition((try? GitWorktree.layout(of: nested)) == nil, "repository inside its worktree via \(spelling)")
            expectBlocked("repository inside its worktree via \(spelling)", nested, .notWorktree(nested))
        }
        // The Data-volume spelling of an ordinary worktree still verifies.
        if fm.fileExists(atPath: dataRoot + clean) {
            precondition(expectVerified("Data-volume spelling", dataRoot + clean).path == dataRoot + clean)
        }

        // Git lookup: never the /usr/bin shim; nothing usable means blocked.
        precondition(GitWorktree.locateGit(GitLookup(searchPath: "/usr/bin:relative/bin", useDeveloperDir: false)) == nil,
                     "the /usr/bin/git shim and relative PATH entries are never used")
        expectBlocked("git missing", clean, .gitMissing(clean),
                      lookup: GitLookup(searchPath: "", useDeveloperDir: false))

        // A repository fsmonitor hook must not run during verification.
        let monitored = worktree("fsmonitor")
        let sentinel = fixture.base.appendingPathComponent("fsmonitor-ran").path
        let hook = fixture.base.appendingPathComponent("fsmonitor-hook.sh").path
        fixture.write(hook, "#!/bin/sh\n/usr/bin/touch '\(sentinel)'\nexit 1\n")
        precondition(chmod(hook, 0o755) == 0)
        fixture.run(["config", "core.fsmonitor", hook], in: repo)
        _ = expectVerified("clean worktree with an fsmonitor hook configured", monitored)
        precondition(!fm.fileExists(atPath: sentinel), "verification ran the repository's fsmonitor hook")
        fixture.run(["status", "--porcelain"], in: monitored)
        precondition(fm.fileExists(atPath: sentinel), "fixture hook is real: plain git status runs it")
        fixture.run(["config", "--unset", "core.fsmonitor"], in: repo)
    }

    // MARK: Recent use

    private static func recency(fixture: GitFixture, worktree: (String) -> String) throws {
        let fresh = worktree("fresh")
        expectBlocked("freshly created worktree", fresh, .recentlyUsed(fresh), within: GitWorktree.recentWindow)
        fixture.backdate(fresh)
        // Twice with the real window: verification must not refresh what it reads.
        for round in 1...2 {
            _ = expectVerified("backdated worktree, round \(round)", fresh, within: GitWorktree.recentWindow)
        }

        // A Claude Code session that worked inside it counts as use.
        let worked = worktree("claude-session")
        fixture.backdate(worked)
        _ = expectVerified("backdated, no sessions", worked, within: GitWorktree.recentWindow)
        let key = String(String.UnicodeScalarView(worked.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? $0 : "-"
        }))
        let folder = AgentSessions.claude.appendingPathComponent(key)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("\(UUID().uuidString).jsonl")
        try Data("{\"type\":\"user\",\"cwd\":\"\(worked)/src\"}\n".utf8).write(to: log)
        expectBlocked("Claude Code session inside", worked, .recentlyUsed(worked), within: GitWorktree.recentWindow)
        try fm.removeItem(at: folder)

        // And so does a Codex session.
        let day = AgentSessions.codex.appendingPathComponent("2026/10/06")
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout.jsonl")
        try Data("{\"payload\":{\"cwd\":\"\(worked)\"}}\n".utf8).write(to: rollout)
        expectBlocked("Codex session inside", worked, .recentlyUsed(worked), within: GitWorktree.recentWindow)
        try fm.removeItem(at: rollout)
        _ = expectVerified("sessions gone", worked, within: GitWorktree.recentWindow)
    }

    // MARK: Trash boundary

    /// The rule's check runs wherever a target is captured or revalidated,
    /// and `CleanupOperations.trash` is where nothing can skip it: a tag
    /// forged after planning, a folder used since, a target never given its
    /// rule, a check that belongs to another folder.
    private static func boundary(base: URL, fixture: GitFixture, worktree: (String) -> String) throws {
        let home = base.appendingPathComponent("boundary-home")
        let bin = base.appendingPathComponent("boundary-trash")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        func folder(_ relative: String) throws -> String {
            let path = home.appendingPathComponent(relative).path
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        func capture(_ path: String, _ check: CleanupCheck) throws -> CleanupTarget {
            try CleanupPathSafety.capture(path: path, root: home.path, home: home.path, check: check)
        }
        func move(_ source: URL) throws -> URL {
            let destination = bin.appendingPathComponent(UUID().uuidString)
            try fm.moveItem(at: source, to: destination)
            return destination
        }
        func refused(_ label: String, _ target: CleanupTarget, _ matches: (Error) -> Bool) {
            var moved = false
            do {
                _ = try CleanupOperations.trash(target) { url in moved = true; return url }
                fatalError("\(label): reached the Trash")
            } catch {
                precondition(!moved && matches(error), "\(label): refused for the wrong reason: \(error)")
                precondition(fm.fileExists(atPath: target.path), "\(label): the folder must stay")
            }
        }
        func failedCheck(_ error: Error) -> Bool {
            if case CleanupPathError.checkFailed = error { return true }
            return false
        }
        func old(_ paths: [String]) throws {
            let date = Date().addingTimeInterval(-5 * 86400)
            for path in paths { try fm.setAttributes([.modificationDate: date], ofItemAtPath: path) }
        }

        // A CACHEDIR.TAG without the signature, or forged after planning.
        let tagged = try folder("caches/tagged")
        let tag = URL(fileURLWithPath: tagged + "/CACHEDIR.TAG")
        let tagCheck = CleanupCheck(verify: "cachedir_tag", folder: tagged)
        try Data((CleanupVerify.cacheSignature + "\n").utf8).write(to: tag)
        let planned = try capture(tagged, tagCheck)
        _ = try CleanupOperations.trash(try capture(tagged, tagCheck)) { url in url }
        try Data("Signature: forged\n".utf8).write(to: tag)
        refused("tag forged after planning", planned, failedCheck)
        do {
            _ = try capture(tagged, tagCheck)
            fatalError("a tag without the signature must not be captured")
        } catch { precondition(failedCheck(error), "captured for the wrong reason: \(error)") }
        try fm.removeItem(at: tag)
        refused("tag removed after planning", planned, failedCheck)
        try Data((CleanupVerify.cacheSignature + "\n").utf8).write(to: tag)
        let inside = try folder("caches/tagged/sub")
        let insideTarget = try capture(inside, tagCheck)
        try fm.removeItem(at: tag)
        refused("a folder inside a tagged cache answers to the cache's tag", insideTarget, failedCheck)

        // Checks that cannot be satisfied block at capture.
        let unchecked = try folder("caches/unchecked")
        let elsewhere = try folder("caches/elsewhere")
        for (label, check) in [("the engine gave no answer", CleanupCheck(verify: CleanupVerify.unavailable, folder: unchecked)),
                               ("a verifier nobody knows", CleanupCheck(verify: "made_up", folder: unchecked)),
                               ("a check that belongs to another folder", CleanupCheck(verify: "cachedir_tag", folder: elsewhere))] {
            do {
                _ = try capture(unchecked, check)
                fatalError("\(label): captured")
            } catch { precondition(failedCheck(error), "\(label): \(error)") }
        }
        let moved = try CleanupOperations.trash(try capture(unchecked, CleanupCheck.policyOnly), move: move)
        precondition(!fm.fileExists(atPath: unchecked) && fm.fileExists(atPath: moved.url.path), "no rule, only the path policy")

        // recent_activity (what ~/.claude/projects/<x> carries), through the capture.
        let project = try folder(".claude/projects/-Users-me-work")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-5 * 86400)], ofItemAtPath: project)
        let activityCheck = CleanupCheck(verify: "recent_activity", folder: project)
        let quiet = try capture(project, activityCheck)
        fixture.write(project + "/today.jsonl", "{}\n")
        refused("a project folder touched today", quiet, failedCheck)
        let memory = try folder(".claude/projects/-Users-me-work/memory")
        fixture.write(memory + "/MEMORY.md", "kept\n")
        do {
            _ = try capture(memory, activityCheck)
            fatalError("memory/ must not be captured, used lately or not")
        } catch { precondition((error as? CleanupPathError) == .protectedPath(memory), "memory/ is protected: \(error)") }
        try old([project + "/today.jsonl", memory + "/MEMORY.md", memory, project])
        // The project folder with a memory/ in it is not transcripts only, however old.
        do {
            _ = try capture(project, activityCheck)
            fatalError("a project folder holding memory/ must not be captured")
        } catch { precondition((error as? CleanupPathError) == .protectedPath(project), "project with memory/: \(error)") }
        try fm.removeItem(atPath: memory)
        try old([project + "/today.jsonl", project])
        _ = try capture(project, activityCheck)

        // Planned while it held transcripts only; a memory/ appears afterwards and the dates are put
        // back: the Trash boundary refuses, with the folder in place.
        let session = "0b0e6f0e-2f6a-4b61-9a53-0d6a3c1a9a11"
        try fm.createDirectory(atPath: project + "/" + session + "/subagents", withIntermediateDirectories: true)
        fixture.write(project + "/" + session + ".jsonl", "{}\n")
        fixture.write(project + "/.DS_Store", "finder\n")
        try old([project + "/" + session + "/subagents", project + "/" + session, project + "/" + session + ".jsonl",
                 project + "/.DS_Store", project])
        let transcripts = try capture(project, activityCheck)
        let lateMemory = try folder(".claude/projects/-Users-me-work/memory")
        fixture.write(lateMemory + "/MEMORY.md", "added after the scan\n")
        try old([lateMemory + "/MEMORY.md", lateMemory, project])
        refused("memory/ added after planning and backdated", transcripts) { ($0 as? CleanupPathError) == .protectedPath(project) }
        try fm.removeItem(atPath: lateMemory)
        for stray in ["notes.md", "CLAUDE.md", "settings.json"] {
            fixture.write(project + "/" + stray, "mine\n")
            try old([project + "/" + stray, project])
            refused("\(stray) added after planning", transcripts) { ($0 as? CleanupPathError) == .protectedPath(project) }
            try fm.removeItem(atPath: project + "/" + stray)
        }
        try fm.createDirectory(atPath: project + "/not-a-session-id", withIntermediateDirectories: true)
        try old([project + "/not-a-session-id", project])
        refused("a folder that is not a session id", transcripts) { ($0 as? CleanupPathError) == .protectedPath(project) }
        try fm.removeItem(atPath: project + "/not-a-session-id")
        try old([project])
        _ = try capture(project, activityCheck)

        // A subfolder of a worktree answers to the worktree's check.
        let wt = worktree("boundary")
        fixture.backdate(wt)
        let wtCheck = CleanupCheck(verify: "git_worktree", folder: wt)
        let source = wt + "/src"
        try fm.createDirectory(atPath: source, withIntermediateDirectories: true)
        let plannedSource = try CleanupPathSafety.capture(path: source, root: base.path, home: base.path, check: wtCheck)
        fixture.write(wt + "/dirty.txt", "uncommitted\n")
        refused("a subfolder of a worktree that was dirtied", plannedSource, failedCheck)
        try mounts(base: base)
    }

    /// A volume mounted inside a recent_activity folder is never walked
    /// (FTS_XDEV), so the folder cannot be shown unchanged: it blocks.
    private static func mounts(base: URL) throws {
        let folder = base.appendingPathComponent("mount-host")
        let mountpoint = folder.appendingPathComponent("volume")
        try fm.createDirectory(at: mountpoint, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("file"))
        let old = Date().addingTimeInterval(-5 * 86400)
        for path in [folder.appendingPathComponent("file").path, mountpoint.path, folder.path] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        precondition(CleanupVerify.blockReason(verify: "recent_activity", path: folder.path) == nil, "no mount, old files")
        let image = base.appendingPathComponent("mount.sparseimage").path
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
        guard hdiutil(["create", "-quiet", "-size", "8m", "-type", "SPARSE", "-fs", "HFS+", "-volname", "BZMount", image]),
              hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mountpoint.path, image]) else {
            print("SKIP mount inside a recent_activity folder (hdiutil could not attach an image here)")
            return
        }
        defer { _ = hdiutil(["detach", mountpoint.path, "-force", "-quiet"]) }
        // The mounted volume's root is as old as an external disk's would be:
        // only the mount itself can block.
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: mountpoint.path)
        let reason = CleanupVerify.blockReason(verify: "recent_activity", path: folder.path)
        precondition(reason?.english.hasPrefix("Another volume is mounted inside") == true,
                     "a mount inside blocks: \(String(describing: reason))")
    }

    // MARK: Session logs

    /// The folder a session worked in is found line by line within a byte
    /// budget (a first line over 8 KB is common), and logs that cannot be read
    /// are not read as "no sessions".
    private static func sessionLogs(fixture: GitFixture, worktree: (String) -> String) throws {
        let worked = worktree("big-first-line")
        fixture.backdate(worked)
        let key = String(String.UnicodeScalarView(worked.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? $0 : "-"
        }))
        let folder = AgentSessions.claude.appendingPathComponent(key)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let padding = String(repeating: "x", count: 20_000)
        let big = "{\"type\":\"queue-operation\",\"content\":\"\(padding)\"}\n"
        let log = folder.appendingPathComponent("\(UUID().uuidString).jsonl")
        try Data((big + "{\"type\":\"user\",\"cwd\":\"\(worked)/src\"}\n").utf8).write(to: log)
        precondition(big.utf8.count > 8192, "the fixture's first line is over 8 KB")
        expectBlocked("cwd on the second line, after a 20 KB queue-operation line", worked, .recentlyUsed(worked),
                      within: GitWorktree.recentWindow)

        // The reader itself: where it finds the folder and where it gives up.
        func read(_ text: String, limit: Int = AgentSessions.cwdBudget) -> AgentSessions.CwdResult {
            let file = folder.appendingPathComponent("probe-\(UUID().uuidString).txt")
            guard (try? Data(text.utf8).write(to: file)) != nil, let handle = try? FileHandle(forReadingFrom: file) else {
                fatalError("cannot write the probe log")
            }
            defer { try? handle.close(); try? fm.removeItem(at: file) }
            return AgentSessions.cwd(in: handle, limit: limit)
        }
        guard case .found(let escaped, _) = read("{\"a\":1}\n{\"cwd\":\"/tmp/a \\\"q\\\" \\\\ \\/b\"}\n") else {
            fatalError("an escaped cwd is found")
        }
        precondition(escaped == "/tmp/a \"q\" \\ /b", "JSON escapes are decoded: \(escaped)")
        guard case .found(let unterminated, _) = read("{\"cwd\":\"/tmp/last\"}") else { fatalError("no final newline") }
        precondition(unterminated == "/tmp/last")
        precondition(read("{\"a\":1}\n{\"b\":2}\n") == .absent(bytesRead: 16), "a log that names no folder")
        precondition(read("") == .absent(bytesRead: 0), "an empty log")
        precondition(read(big + "{\"cwd\":\"/x\"}\n", limit: 4096) == .exhausted(bytesRead: 4096),
                     "a folder past the budget is not found, and says so")
        precondition(read("{\"cwd\":\"/xyz", limit: 10) == .exhausted(bytesRead: 10), "an unfinished value is not a folder")
        let exact = "{\"a\":1}\n"
        precondition(read(exact, limit: exact.utf8.count) == .absent(bytesRead: exact.utf8.count),
                     "a log that ends exactly at the budget was read in full")
        guard case .found(let accents, _) = read("not json \"cwd\":\"\\u00e9\\ud83d\\ude00\"\n") else {
            fatalError("unicode escapes are found")
        }
        precondition(accents == "é😀", "unicode escapes: \(accents)")

        // Past the per-log budget, the log cannot be attributed: unknown, not unused.
        let huge = folder.appendingPathComponent("huge.jsonl")
        try Data((big + "{\"cwd\":\"\(worked)\"}\n").utf8).write(to: huge)
        try fm.removeItem(at: log)
        let small = AgentSessions.scan(in: AgentSessions.claude, cwdBudget: 4096)
        precondition(!small.complete && small.folders.isEmpty, "a log whose folder is out of reach makes the scan incomplete")
        let capped = AgentSessions.scan(in: AgentSessions.claude, scanBudget: 4096)
        precondition(!capped.complete, "the scan's total budget is bounded too")
        precondition(AgentSessions.scan(in: AgentSessions.claude).folders[worked] != nil, "within the budgets it is found")
        try fm.removeItem(at: huge)

        // An unreadable sessions folder blocks; a missing one is no sessions.
        let clean = worktree("unreadable-sessions")
        fixture.backdate(clean)
        _ = expectVerified("no logs", clean, within: GitWorktree.recentWindow)
        let projects = AgentSessions.claude
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projects.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projects.path) }
        expectBlocked("unreadable Claude Code projects folder", clean, .sessionsUnreadable(clean),
                      within: GitWorktree.recentWindow)
        precondition(AgentSessions.claudeUsage(in: clean, since: Date().addingTimeInterval(-86400)) == .unknown)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projects.path)
        // An unreadable log.
        let cleanKey = String(String.UnicodeScalarView(clean.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? $0 : "-"
        }))
        let related = projects.appendingPathComponent(cleanKey + "-sub")
        try fm.createDirectory(at: related, withIntermediateDirectories: true)
        let sealed = related.appendingPathComponent("sealed.jsonl")
        try Data("{\"cwd\":\"/elsewhere\"}\n".utf8).write(to: sealed)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealed.path)
        expectBlocked("unreadable session log", clean, .sessionsUnreadable(clean), within: GitWorktree.recentWindow)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sealed.path)
        _ = expectVerified("the log readable again", clean, within: GitWorktree.recentWindow)
        try fm.removeItem(at: related)
        try fm.removeItem(at: projects)
        _ = expectVerified("no sessions folder at all is no sessions", clean, within: GitWorktree.recentWindow)

        // A sessions root that is itself a symlink (a dotfiles checkout) is
        // resolved once; it reads as sessions, not as unknown.
        let real = projects.deletingLastPathComponent().appendingPathComponent("projects-real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: projects, withDestinationURL: real)
        _ = expectVerified("symlinked sessions root, no sessions", clean, within: GitWorktree.recentWindow)
        let linkedFolder = real.appendingPathComponent(cleanKey)
        try fm.createDirectory(at: linkedFolder, withIntermediateDirectories: true)
        try Data("{\"type\":\"user\",\"cwd\":\"\(clean)\"}\n".utf8)
            .write(to: linkedFolder.appendingPathComponent("\(UUID().uuidString).jsonl"))
        expectBlocked("a session found through a symlinked root", clean, .recentlyUsed(clean), within: GitWorktree.recentWindow)
        try fm.removeItem(at: linkedFolder)
        // A symlink below the root is not followed, and that is not "no sessions".
        let target = real.deletingLastPathComponent().appendingPathComponent("linked-logs")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: real.appendingPathComponent(cleanKey), withDestinationURL: target)
        expectBlocked("a symlinked project folder below the root", clean, .sessionsUnreadable(clean), within: GitWorktree.recentWindow)
        try fm.removeItem(at: real.appendingPathComponent(cleanKey))
        try fm.removeItem(at: target)
        try fm.removeItem(at: projects)
        try fm.removeItem(at: real)
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        // And the same for Codex's root, which is enumerated whole.
        let codexRoot = AgentSessions.codex
        let codexReal = codexRoot.deletingLastPathComponent().appendingPathComponent("sessions-real")
        try fm.moveItem(at: codexRoot, to: codexReal)
        try fm.createSymbolicLink(at: codexRoot, withDestinationURL: codexReal)
        try fm.createDirectory(at: codexReal.appendingPathComponent("2026/10/08"), withIntermediateDirectories: true)
        try Data("{\"payload\":{\"cwd\":\"\(clean)\"}}\n".utf8)
            .write(to: codexReal.appendingPathComponent("2026/10/08/rollout.jsonl"))
        expectBlocked("a Codex session found through a symlinked root", clean, .recentlyUsed(clean), within: GitWorktree.recentWindow)
        try fm.removeItem(at: codexRoot)
        try fm.moveItem(at: codexReal, to: codexRoot)
        try fm.removeItem(at: codexRoot.appendingPathComponent("2026"))

        // Codex: a rollout whose first line (session_meta with its instructions) is large.
        let codexDay = AgentSessions.codex.appendingPathComponent("2026/10/07")
        try fm.createDirectory(at: codexDay, withIntermediateDirectories: true)
        let rollout = codexDay.appendingPathComponent("rollout.jsonl")
        try Data(("{\"type\":\"session_meta\",\"payload\":{\"instructions\":\"\(padding)\",\"cwd\":\"\(clean)\"}}\n").utf8)
            .write(to: rollout)
        expectBlocked("Codex session_meta line over 8 KB", clean, .recentlyUsed(clean), within: GitWorktree.recentWindow)
        try fm.removeItem(at: rollout)
    }

    // MARK: Processes

    private static func processes(worktree: (String) -> String) throws {
        let busy = worktree("process-cwd")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try fm.createDirectory(atPath: busy + "/node_modules/deep", withIntermediateDirectories: true)
        sleeper.currentDirectoryURL = URL(fileURLWithPath: busy + "/node_modules/deep")
        try sleeper.run()
        usleep(200_000)
        expectBlocked("a process working inside", busy, .inUse(busy))
        sleeper.terminate()
        sleeper.waitUntilExit()
        _ = expectVerified("process gone", busy)
    }

    // MARK: CleanupVerify

    private static func cleanupVerify(base: URL, worktree: (String) -> String) throws {
        precondition(CleanupVerify.blockReason(verify: "", path: "/nonexistent") == nil, "no verifier")
        let unknown = CleanupVerify.blockReason(verify: "made_up", path: base.path)
        precondition(unknown?.english.hasPrefix("Unknown check made_up") == true, "unknown verifier fails closed")

        func cache(_ name: String) throws -> String {
            let path = base.appendingPathComponent("caches/\(name)").path
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        let good = try cache("good")
        try Data((CleanupVerify.cacheSignature + "\n# This file is a cache directory tag.\n").utf8)
            .write(to: URL(fileURLWithPath: good + "/CACHEDIR.TAG"))
        precondition(CleanupVerify.blockReason(verify: "cachedir_tag", path: good) == nil, "valid tag")
        let bad = try cache("bad")
        try Data("Signature: 0000000000000000000000000000000\n".utf8).write(to: URL(fileURLWithPath: bad + "/CACHEDIR.TAG"))
        let short = try cache("short")
        try Data("Signature: 8a477f597d28d172789f06".utf8).write(to: URL(fileURLWithPath: short + "/CACHEDIR.TAG"))
        let missing = try cache("missing")
        let directory = try cache("directory")
        try fm.createDirectory(atPath: directory + "/CACHEDIR.TAG", withIntermediateDirectories: true)
        let linked = try cache("linked")
        try fm.createSymbolicLink(atPath: linked + "/CACHEDIR.TAG", withDestinationPath: good + "/CACHEDIR.TAG")
        for (label, path) in [("bad signature", bad), ("truncated signature", short), ("missing tag", missing),
                              ("directory named CACHEDIR.TAG", directory), ("symlinked tag", linked)] {
            precondition(CleanupVerify.blockReason(verify: "cachedir_tag", path: path) != nil, label)
        }

        let activity = try cache("activity")
        for index in 0..<5 {
            try Data([UInt8(index)]).write(to: URL(fileURLWithPath: activity + "/f\(index)"))
        }
        try fm.createDirectory(atPath: activity + "/sub", withIntermediateDirectories: true)
        try Data([9]).write(to: URL(fileURLWithPath: activity + "/sub/inner"))
        func age(_ paths: [String]) throws {
            let old = Date().addingTimeInterval(-5 * 86400)
            for path in paths { try fm.setAttributes([.modificationDate: old], ofItemAtPath: path) }
        }
        let all = (0..<5).map { activity + "/f\($0)" } + [activity + "/sub/inner", activity + "/sub", activity]
        try age(all)
        precondition(CleanupVerify.blockReason(verify: "recent_activity", path: activity) == nil, "old folder")
        precondition(CleanupVerify.blockReason(verify: "recent_activity", path: activity, entryCap: 3)?
            .english.hasPrefix("Too many files to check") == true, "entry cap blocks")
        try Data([1]).write(to: URL(fileURLWithPath: activity + "/sub/inner"))
        try age([activity + "/sub", activity])
        precondition(CleanupVerify.blockReason(verify: "recent_activity", path: activity)?
            .english.hasPrefix("Changed in the last 2 days") == true, "a new file deep inside blocks")
        try age(all)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: activity + "/sub")
        precondition(CleanupVerify.blockReason(verify: "recent_activity", path: activity)?
            .english.hasPrefix("Could not check every file") == true, "unreadable folder blocks")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: activity + "/sub")
        precondition(CleanupVerify.blockReason(verify: "recent_activity", path: base.path + "/no-such") != nil,
                     "missing folder blocks")

        let tree = worktree("verify-kind")
        precondition(CleanupVerify.blockReason(verify: "git_worktree", path: tree, within: 0) == nil)
        precondition(CleanupVerify.blockReason(verify: "git_worktree", path: tree)?
            .english == GitWorktreeError.recentlyUsed(tree).englishDescription)
    }

    // MARK: Trash → delete → admin entry

    private static func flow(fixture: GitFixture, base: URL, repo: String,
                             worktree: (String) -> String) async throws {
        let trash = base.appendingPathComponent("fake-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        func toTrash(_ target: CleanupTarget) throws -> CleanupReceipt {
            try CleanupOperations.trash(target) { source in
                let destination = trash.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: source, to: destination)
                return destination
            }
        }
        func listed(_ path: String) -> Bool {
            fixture.run(["worktree", "list", "--porcelain"], in: repo)
                .split(separator: "\n").contains { $0 == "worktree \(path)" }
        }
        func ready(_ name: String) throws -> (path: String, admin: String, target: CleanupTarget) {
            let path = worktree(name)
            fixture.backdate(path)
            let target = try CleanupPathSafety.capture(path: path, root: base.path, home: base.path,
                                                       check: CleanupCheck(verify: "git_worktree", folder: path))
            return (path, fixture.admin(of: path), target)
        }

        // Full flow: Trash, delete for good, then only this admin entry goes.
        let neighbour = worktree("neighbour")
        let done = try ready("full-flow")
        precondition(listed(done.path))
        let receipt = try toTrash(done.target)
        precondition(receipt.worktree?.adminDir == done.admin, "receipt records the admin entry")
        precondition(fm.fileExists(atPath: done.admin), "step 1 leaves the admin entry")
        let removed = await CleanupOperations.remove([receipt])
        precondition(removed.errors.isEmpty && removed.remaining.isEmpty && removed.notices.isEmpty,
                     "removal: \(removed.errors) \(removed.notices)")
        precondition(!fm.fileExists(atPath: receipt.url.path), "worktree deleted")
        precondition(!fm.fileExists(atPath: done.admin), "admin entry removed")
        precondition(!listed(done.path), "git no longer lists the worktree")
        precondition(listed(neighbour) && fm.fileExists(atPath: fixture.admin(of: neighbour)),
                     "other worktrees untouched")
        let branch = (done.path as NSString).lastPathComponent
        precondition(!fixture.run(["rev-parse", "--verify", "refs/heads/\(branch)"], in: repo).isEmpty,
                     "the branch survives")

        // Restored from the Trash before step 2: the receipt no longer
        // validates, nothing is deleted and the admin entry stays.
        let restored = try ready("restored")
        let restoredReceipt = try toTrash(restored.target)
        try fm.moveItem(atPath: restoredReceipt.url.path, toPath: restored.path)
        let refused = await CleanupOperations.remove([restoredReceipt]) { _ in
            fatalError("a restored worktree must not reach the eraser")
        }
        precondition(refused.remaining.count == 1 && !refused.errors.isEmpty)
        precondition(fm.fileExists(atPath: restored.admin) && listed(restored.path), "admin entry intact")

        // Admin entry changed while the worktree sat in the Trash: the
        // worktree is freed, the entry is left and reported.
        let changed = try ready("admin-changed")
        let changedReceipt = try toTrash(changed.target)
        fixture.write(changed.admin + "/gitdir", neighbour + "/.git\n")
        let partial = await CleanupOperations.remove([changedReceipt])
        precondition(partial.errors.isEmpty && partial.remaining.isEmpty, "the worktree itself was freed")
        precondition(partial.notices.count == 1 && fm.fileExists(atPath: changed.admin), "entry left and reported")

        // A worktree dirtied after planning is refused at the Trash boundary.
        let late = try ready("dirtied-late")
        fixture.write(late.path + "/late.txt", "late\n")
        do {
            _ = try toTrash(late.target)
            fatalError("a dirtied worktree must not move")
        } catch CleanupPathError.gitWorktree(.changes) {
            precondition(fm.fileExists(atPath: late.path))
        }
    }

    // MARK: Fake programs

    /// An executable shell script, to stand in for lsof or git.
    private static func program(_ path: String, _ body: String) throws {
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: URL(fileURLWithPath: path))
        precondition(chmod(path, 0o755) == 0)
    }

    private static func seconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    // MARK: lsof failing

    /// A process check that cannot answer blocks, whatever the reason: no
    /// lsof, a failing lsof, one that says nothing, one that hangs, one that
    /// floods. None of them may read as "nothing is using the worktree".
    private static func processFailures(base: URL, worktree: (String) -> String) throws {
        let clean = worktree("lsof-failures")
        let bin = base.appendingPathComponent("fake-lsof")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let missing = bin.appendingPathComponent("no-such-lsof").path
        let failing = bin.appendingPathComponent("failing").path
        let silent = bin.appendingPathComponent("silent").path
        let hanging = bin.appendingPathComponent("hanging").path
        let flooding = bin.appendingPathComponent("flooding").path
        let answering = bin.appendingPathComponent("answering").path
        try program(failing, "echo 'lsof: WARNING' >&2; exit 1")
        try program(silent, "exit 0")
        try program(hanging, "exec /bin/sleep 30")
        try program(flooding, "exec /usr/bin/yes n/somewhere")
        try program(answering, "echo p1; echo n/elsewhere")

        func blocked(_ label: String, _ limits: GitWorktree.Limits) {
            let elapsed = seconds {
                do {
                    let info = try GitWorktree.verify(clean, recentWithin: 0, limits: limits)
                    fatalError("\(label): verified \(info)")
                } catch let error as GitWorktreeError {
                    precondition(error == .processCheckFailed(clean), "\(label): blocked for the wrong reason: \(error)")
                } catch { fatalError("\(label): \(error)") }
            }
            precondition(elapsed < 15, "\(label): the check must stay bounded, took \(elapsed) s")
        }
        blocked("lsof is not there", GitWorktree.Limits(lsof: missing))
        blocked("lsof exits non-zero", GitWorktree.Limits(lsof: failing))
        blocked("lsof answers nothing", GitWorktree.Limits(lsof: silent))
        blocked("lsof hangs past its limit", GitWorktree.Limits(lsof: hanging, lsofTimeout: 1))
        blocked("lsof output past its cap", GitWorktree.Limits(lsof: flooding, lsofCap: 64))
        // And the same lsof, answering, lets it through.
        _ = try GitWorktree.verify(clean, recentWithin: 0, limits: GitWorktree.Limits(lsof: answering))
        // A failed reading is cached by the refresh sharing it: one 10 s lsof
        // is not paid once per worktree.
        BoundedProcess.spawns.reset()
        let shared = WorktreeEvidence(limits: GitWorktree.Limits(lsof: failing))
        let others = [clean, worktree("lsof-failures-2"), worktree("lsof-failures-3")]
        for path in others {
            do {
                _ = try GitWorktree.verify(path, recentWithin: 0, evidence: shared)
                fatalError("verified with a failed lsof")
            } catch let error as GitWorktreeError {
                precondition(error == .processCheckFailed(path), "shared failure: \(error)")
            }
        }
        precondition(BoundedProcess.spawns.count("failing") == 1, "a failed lsof reading is shared, not retried per worktree")
    }

    // MARK: BoundedProcess

    /// The time limit, the output cap and the kill of a program that ignores
    /// the first signal.
    private static func boundedProcess(base: URL) throws {
        let sleeping = BoundedProcess.run("/bin/sleep", ["30"], environment: ["PATH": "/usr/bin:/bin"], timeout: 0.5, cap: 1024)
        precondition(sleeping?.timedOut == true, "a program past its limit is reported as timed out")
        let flooded = BoundedProcess.run("/usr/bin/yes", [], environment: ["PATH": "/usr/bin:/bin"], timeout: 3, cap: 1000)
        precondition(flooded?.overflow == true && flooded?.stdout.count == 1000, "output past the cap is cut and says so")
        precondition(BoundedProcess.run(base.appendingPathComponent("nothing-here").path, [], environment: [:],
                                        timeout: 1, cap: 1) == nil, "a program that cannot start is nil, not a result")
        // Ignores TERM, so only the kill ends it, and only within a bound.
        let stubborn = base.appendingPathComponent("stubborn.sh").path
        try program(stubborn, "trap '' TERM\nwhile :; do /bin/sleep 1; done")
        var outcome: BoundedProcess.Outcome?
        let elapsed = seconds {
            outcome = BoundedProcess.run(stubborn, [], environment: ["PATH": "/usr/bin:/bin"], timeout: 0.5, cap: 1024)
        }
        precondition(outcome?.timedOut == true && elapsed < 10, "a program that ignores TERM is killed within a bound: \(elapsed) s")
    }

    // MARK: git budget

    /// All of one worktree's git commands share one budget: a git that hangs,
    /// or many that are each slow, block with "took too long".
    private static func gitBudget(base: URL, worktree: (String) -> String) throws {
        let clean = worktree("git-budget")
        guard let realGit = GitWorktree.locateGit(.standard) else { fatalError("no git") }
        let hang = base.appendingPathComponent("hanging-git")
        let slow = base.appendingPathComponent("slow-git")
        for folder in [hang, slow] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try program(hang.appendingPathComponent("git").path, "exec /bin/sleep 30")
        try program(slow.appendingPathComponent("git").path, "/bin/sleep 0.7\nexec '\(realGit)' \"$@\"")

        func timedOut(_ label: String, _ folder: URL, budget: TimeInterval) {
            let elapsed = seconds {
                do {
                    let info = try GitWorktree.verify(clean, recentWithin: 0,
                                                      lookup: GitLookup(searchPath: folder.path, useDeveloperDir: false),
                                                      limits: GitWorktree.Limits(gitBudget: budget))
                    fatalError("\(label): verified \(info)")
                } catch let error as GitWorktreeError {
                    precondition(error == .timedOut(clean), "\(label): blocked for the wrong reason: \(error)")
                } catch { fatalError("\(label): \(error)") }
            }
            precondition(elapsed < 12, "\(label): bounded, took \(elapsed) s")
        }
        timedOut("a git that never answers", hang, budget: 1)
        timedOut("commands that are each fast enough but together spend the budget", slow, budget: 1.5)
        // Within the budget the same slow git passes.
        _ = try GitWorktree.verify(clean, recentWithin: 0, lookup: GitLookup(searchPath: slow.path, useDeveloperDir: false),
                                   limits: GitWorktree.Limits(gitBudget: 60))
    }

    // MARK: Unreachable repository

    /// A worktree whose repository is off-line (an unmounted drive) says so;
    /// a pruned entry in a repository that is there stays "not a worktree".
    private static func unreachableRepository(fixture: GitFixture, worktree: (String) -> String) throws {
        let offline = fixture.base.appendingPathComponent("wts/offline-worktree").path
        try fm.createDirectory(atPath: offline, withIntermediateDirectories: true)
        fixture.write(offline + "/.git", "gitdir: /Volumes/BlitzTreeNoSuchDisk/repo/.git/worktrees/offline\n")
        expectBlocked("the repository's drive is not mounted", offline, .repositoryUnavailable(offline))
        let message = GitWorktreeError.repositoryUnavailable(offline).englishDescription
        precondition(message.contains("can't be reached") && !message.contains("protected"), message)

        // Reached through CleanupPathSafety it is the same message, not "Git metadata path is protected".
        do {
            _ = try CleanupPathSafety.capture(path: offline, root: fixture.base.path, home: fixture.base.path,
                                              check: .policyOnly)
            fatalError("captured a worktree whose repository is off-line")
        } catch CleanupPathError.gitWorktree(.repositoryUnavailable) {}

        let moved = worktree("commondir-offline")
        let commondir = fixture.admin(of: moved) + "/commondir"
        let original = try String(contentsOfFile: commondir, encoding: .utf8)
        fixture.write(commondir, "/Volumes/BlitzTreeNoSuchDisk/repo/.git\n")
        expectBlocked("the common dir named by commondir is off-line", moved, .repositoryUnavailable(moved))
        fixture.write(commondir, original)

        let pruned = fixture.base.appendingPathComponent("pruned-worktree").path
        try fm.createDirectory(atPath: pruned, withIntermediateDirectories: true)
        let reachableRepo = fixture.base.appendingPathComponent("repo").path
        fixture.write(pruned + "/.git", "gitdir: \(reachableRepo)/.git/worktrees/pruned\n")
        expectBlocked("the entry was pruned from a repository that is there", pruned, .notWorktree(pruned))
    }

    // MARK: One reading per refresh

    /// A refresh shares one lsof between its worktrees, verifies each once,
    /// and a verification without a shared reading runs its own.
    private static func sharedEvidence(base: URL, worktree: (String) -> String) throws {
        let paths = (0..<4).map { worktree("shared-\($0)") }
        BoundedProcess.spawns.reset()
        _ = try GitWorktree.verify(paths[0], recentWithin: 0)
        let gitPerVerification = BoundedProcess.spawns.count("git")
        precondition(gitPerVerification >= 4, "a verification runs git: \(gitPerVerification)")
        precondition(BoundedProcess.spawns.count("lsof") == 1, "a lone verification reads the processes itself")

        BoundedProcess.spawns.reset()
        let evidence = WorktreeEvidence()
        for path in paths { _ = try GitWorktree.verify(path, recentWithin: 0, evidence: evidence) }
        precondition(BoundedProcess.spawns.count("lsof") == 1,
                     "four verifications of one refresh share one lsof, ran \(BoundedProcess.spawns.count("lsof"))")
        precondition(BoundedProcess.spawns.count("git") == gitPerVerification * paths.count,
                     "and verify each worktree once, no more")

        BoundedProcess.spawns.reset()
        for path in paths { _ = try GitWorktree.verify(path, recentWithin: 0) }
        precondition(BoundedProcess.spawns.count("lsof") == paths.count, "without a shared reading each runs its own")
    }

    // MARK: A refresh is advisory

    /// What the refresh read is only what the panel offers. A worktree that
    /// becomes busy or dirty afterwards is blocked at the Trash, which reads
    /// lsof and git status again, fresh: one lsof and the git commands per move.
    private static func staleRefresh(fixture: GitFixture, base: URL, worktree: (String) -> String) async throws {
        let trash = base.appendingPathComponent("stale-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        func capture(_ path: String, _ evidence: WorktreeEvidence) throws -> CleanupTarget {
            try CleanupPathSafety.capture(path: path, root: base.path, home: base.path,
                                          check: CleanupCheck(verify: "git_worktree", folder: path), evidence: evidence)
        }
        func toTrash(_ target: CleanupTarget) throws -> CleanupReceipt {
            try CleanupOperations.trash(target) { source in
                let destination = trash.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: source, to: destination)
                return destination
            }
        }
        let evidence = WorktreeEvidence()
        let busy = worktree("busy-after-refresh"), dirty = worktree("dirty-after-refresh"), quiet = worktree("quiet-after-refresh")
        for path in [busy, dirty, quiet] { fixture.backdate(path) }
        let busyTarget = try capture(busy, evidence), dirtyTarget = try capture(dirty, evidence)
        let quietTarget = try capture(quiet, evidence)
        precondition(BoundedProcess.spawns.count("lsof") >= 1)

        // The refresh saw nothing running; a process starts in `busy` afterwards.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        sleeper.currentDirectoryURL = URL(fileURLWithPath: busy)
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        usleep(200_000)
        precondition((try? capture(busy, evidence)) != nil,
                     "the refresh's own reading still says it is free: that is why the Trash must look again")
        do {
            _ = try toTrash(busyTarget)
            fatalError("a worktree that became busy after the refresh reached the Trash")
        } catch CleanupPathError.gitWorktree(.inUse) {
            precondition(fm.fileExists(atPath: busy))
        }
        sleeper.terminate()
        sleeper.waitUntilExit()

        // Dirty after the refresh.
        try Data("late\n".utf8).write(to: URL(fileURLWithPath: dirty + "/late.txt"))
        do {
            _ = try toTrash(dirtyTarget)
            fatalError("a worktree dirtied after the refresh reached the Trash")
        } catch CleanupPathError.gitWorktree(.changes) {
            precondition(fm.fileExists(atPath: dirty))
        }

        // A quiet one moves, and the Trash did its own reading: one lsof, the git commands.
        BoundedProcess.spawns.reset()
        _ = try toTrash(quietTarget)
        precondition(BoundedProcess.spawns.count("lsof") == 1 && BoundedProcess.spawns.count("git") >= 4,
                     "the Trash reads lsof and git again: lsof \(BoundedProcess.spawns.count("lsof")), git \(BoundedProcess.spawns.count("git"))")
    }

    // MARK: Emptying the Trash frees the branch

    /// The panel only moves a worktree to the Trash. Its admin entry goes once
    /// the Trash copy is gone, never while it can still be put back.
    /// A missing admin entry is already gone. An unreadable one says so.
    /// Only a real identity mismatch says the entry changed. Nothing is deleted.
    private static func adminEntryMessages(base: URL) throws {
        let root = base.appendingPathComponent("admin-messages")
        let worktrees = root.appendingPathComponent("worktrees")
        try fm.createDirectory(at: worktrees, withIntermediateDirectories: true)
        let placeholder = CleanupIdentity(device: 1, inode: 2, type: UInt16(S_IFDIR))
        func entry(_ admin: String, identity: CleanupIdentity) -> WorktreeAdminEntry {
            WorktreeAdminEntry(adminDir: admin, adminIdentity: identity, worktreesIdentity: identity,
                               commonIdentity: identity, gitdirIdentity: identity,
                               gitdirContent: Data("gitdir: /tmp/x/.git\n".utf8), gitFile: "/tmp/x/.git")
        }
        var erased: [String] = []
        let missing = worktrees.appendingPathComponent("gone").path
        let gone = GitWorktree.removeAdminEntry(entry(missing, identity: placeholder)) { path in
            erased.append(path); return nil
        }
        precondition(gone == nil && erased.isEmpty, "a missing admin entry is already gone: \(gone ?? "nil")")

        let real = worktrees.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let changed = GitWorktree.removeAdminEntry(entry(real.path, identity: placeholder)) { path in
            erased.append(path); return nil
        }
        precondition(changed?.contains("changed") == true && changed?.contains("could not be read") != true,
                     "a different identity says changed: \(changed ?? "nil")")
        precondition(erased.isEmpty && fm.fileExists(atPath: real.path), "a mismatch deletes nothing")

        if geteuid() != 0 {
            chmod(worktrees.path, 0)
            defer { chmod(worktrees.path, 0o755) }
            let blocked = worktrees.appendingPathComponent("hidden").path
            let unread = GitWorktree.removeAdminEntry(entry(blocked, identity: placeholder)) { path in
                erased.append(path); return nil
            }
            precondition(unread?.contains("could not be read") == true && unread?.contains("changed") != true,
                         "an unreadable admin entry is not reported as changed: \(unread ?? "nil")")
            precondition(erased.isEmpty, "an unreadable entry deletes nothing")
        }
    }

    private static func settlement(fixture: GitFixture, base: URL, repo: String,
                                   worktree: (String) -> String) async throws {
        let trash = base.appendingPathComponent("settle-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        func listed(_ path: String) -> Bool {
            fixture.run(["worktree", "list", "--porcelain"], in: repo)
                .split(separator: "\n").contains { $0 == "worktree \(path)" }
        }
        func moved(_ name: String) throws -> (path: String, admin: String, receipt: CleanupReceipt) {
            let path = worktree(name)
            fixture.backdate(path)
            let target = try CleanupPathSafety.capture(path: path, root: base.path, home: base.path,
                                                       check: CleanupCheck(verify: "git_worktree", folder: path))
            let admin = fixture.admin(of: path)
            let receipt = try CleanupOperations.trash(target) { source in
                let destination = trash.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: source, to: destination)
                return destination
            }
            return (path, admin, receipt)
        }

        // In the Trash: waits. Emptied: the entry goes, only that entry.
        let neighbour = worktree("settle-neighbour")
        let one = try moved("settle-one")
        var settled = CleanupOperations.settleWorktrees([one.receipt])
        precondition(settled.waiting.count == 1 && settled.notices.isEmpty && fm.fileExists(atPath: one.admin),
                     "still in the Trash: the entry stays so a put-back worktree works")
        try fm.removeItem(atPath: one.receipt.url.path)
        settled = CleanupOperations.settleWorktrees(settled.waiting)
        precondition(settled.waiting.isEmpty && settled.notices.isEmpty, "settled: \(settled.notices)")
        precondition(!fm.fileExists(atPath: one.admin) && !listed(one.path), "emptied: the admin entry is gone")
        precondition(listed(neighbour) && fm.fileExists(atPath: fixture.admin(of: neighbour)), "other worktrees untouched")
        precondition(!fixture.run(["rev-parse", "--verify", "refs/heads/\((one.path as NSString).lastPathComponent)"], in: repo).isEmpty,
                     "the branch survives")

        // Renamed inside the Trash: still there.
        let renamed = try moved("settle-renamed")
        let newName = trash.appendingPathComponent("renamed by the person")
        try fm.moveItem(at: renamed.receipt.url, to: newName)
        precondition(CleanupOperations.settleWorktrees([renamed.receipt]).waiting.count == 1 && fm.fileExists(atPath: renamed.admin),
                     "a rename in the Trash does not make it look emptied")
        try fm.removeItem(at: newName)
        precondition(CleanupOperations.settleWorktrees([renamed.receipt]).waiting.isEmpty && !fm.fileExists(atPath: renamed.admin))

        // Put back where it was: the worktree exists again, the entry stays and says why.
        let back = try moved("settle-put-back")
        try fm.moveItem(atPath: back.receipt.url.path, toPath: back.path)
        let notice = CleanupOperations.settleWorktrees([back.receipt])
        precondition(notice.notices.count == 1 && fm.fileExists(atPath: back.admin) && listed(back.path), "put back: \(notice.notices)")

        // A Trash that was replaced, or cannot be read, is "unknown", never "emptied".
        let swapped = try moved("settle-swapped")
        try fm.removeItem(atPath: swapped.receipt.url.path)
        let aside = base.appendingPathComponent("settle-trash-aside")
        try fm.moveItem(at: trash, to: aside)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        precondition(swapped.receipt.trashState() == .unknown, "a different Trash folder proves nothing")
        precondition(CleanupOperations.settleWorktrees([swapped.receipt]).waiting.count == 1 && fm.fileExists(atPath: swapped.admin))
        try fm.removeItem(at: trash)
        try fm.moveItem(at: aside, to: trash)
        precondition(swapped.receipt.trashState() == .gone)

        // Moved into a folder inside the Trash: still there, still restorable, so the
        // entry stays. Only when no folder at any depth holds it is it gone.
        let nested = try moved("settle-nested")
        let deeper = trash.appendingPathComponent("kept folder/deeper")
        try fm.createDirectory(at: deeper, withIntermediateDirectories: true)
        let nestedHome = deeper.appendingPathComponent("the worktree")
        try fm.moveItem(at: nested.receipt.url, to: nestedHome)
        precondition(nested.receipt.trashState() == .present, "a worktree in a Trash subfolder is not gone")
        let nestedWait = CleanupOperations.settleWorktrees([nested.receipt])
        precondition(nestedWait.waiting.count == 1 && nestedWait.notices.isEmpty && fm.fileExists(atPath: nested.admin)
                     && listed(nested.path), "its admin entry stays while the worktree can be put back")
        try fm.removeItem(at: nestedHome)
        precondition(nested.receipt.trashState() == .gone, "the folders hold nothing of it now")
        try fm.removeItem(at: trash.appendingPathComponent("kept folder"))

        // The bound counts every entry at every depth: exactly at the limit reads, one over is unknown.
        let bulk = trash.appendingPathComponent("bulk")
        try fm.createDirectory(at: bulk, withIntermediateDirectories: true)
        for index in 0..<5 { precondition(fm.createFile(atPath: bulk.appendingPathComponent("f\(index)").path, contents: Data())) }
        let everything = (fm.enumerator(atPath: trash.path)?.allObjects.count) ?? -1
        precondition(everything >= 6, "entries in the Trash at any depth: \(everything)")
        precondition(swapped.receipt.trashState(entryLimit: everything) == .gone)
        precondition(swapped.receipt.trashState(entryLimit: everything - 1) == .unknown,
                     "entries in subfolders count toward the bound")
        try fm.removeItem(at: bulk)

        // A symlink is looked at, never followed: a link to a folder that holds the item proves nothing.
        let linked = try moved("settle-linked")
        let elsewhere = base.appendingPathComponent("settle-elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.moveItem(at: linked.receipt.url, to: elsewhere.appendingPathComponent("the worktree"))
        let link = trash.appendingPathComponent("link to a folder")
        try fm.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        precondition(linked.receipt.trashState() == .gone, "the walk does not follow a symlink out of the Trash")
        try fm.removeItem(at: link)

        // An entry that cannot be examined, or a folder that cannot be read, is unknown (not skipped as gone).
        let closed = trash.appendingPathComponent("closed folder")
        try fm.createDirectory(at: closed, withIntermediateDirectories: true)
        precondition(fm.createFile(atPath: closed.appendingPathComponent("inside").path, contents: Data()))
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path) }
        // A listed entry whose lstat fails: only ENOENT (it was removed since it was listed) is skipped.
        func failing(_ code: Int32) -> (String, UnsafeMutablePointer<stat>) -> Int32 {
            { path, info in
                if path.hasSuffix("/inside") { errno = code; return -1 }
                return lstat(path, info)
            }
        }
        precondition(swapped.receipt.trashState(examine: failing(EACCES)) == .unknown, "EACCES on a listed entry is unknown")
        precondition(swapped.receipt.trashState(examine: failing(EIO)) == .unknown, "EIO on a listed entry is unknown")
        precondition(swapped.receipt.trashState(examine: failing(ENOENT)) == .gone, "an entry that just vanished is skipped")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        if (try? fm.contentsOfDirectory(atPath: closed.path)) == nil {
            precondition(swapped.receipt.trashState() == .unknown, "a Trash subfolder that cannot be read is unknown")
        } else {
            print("SKIP unreadable Trash subfolder (this user can read a folder with no permissions)")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path)
        precondition(swapped.receipt.trashState() == .gone)
        try fm.removeItem(at: closed)

        let crowded = try moved("settle-crowded")
        try fm.removeItem(atPath: crowded.receipt.url.path)
        precondition(fm.createFile(atPath: trash.appendingPathComponent("decoy").path, contents: Data()))
        precondition(crowded.receipt.trashState(entryLimit: 0) == .unknown, "more entries than the limit is unknown")
        precondition(crowded.receipt.trashState() == .gone)
        // A worktree locked after the move keeps its entry.
        fixture.run(["worktree", "lock", "--reason", "fixture", crowded.path], in: repo)
        precondition(CleanupOperations.settleWorktrees([crowded.receipt]).notices.count == 1 && fm.fileExists(atPath: crowded.admin),
                     "a locked entry is left in place and reported")
    }

    // MARK: Helpers

    @discardableResult
    private static func expectVerified(_ label: String, _ path: String, within: TimeInterval = 0) -> WorktreeInfo {
        do {
            return try GitWorktree.verify(path, recentWithin: within)
        } catch {
            fatalError("\(label): unexpectedly blocked: \(error)")
        }
    }

    private static func expectBlocked(_ label: String, _ path: String, _ expected: GitWorktreeError,
                                      within: TimeInterval = 0, lookup: GitLookup? = nil) {
        do {
            let info = try GitWorktree.verify(path, recentWithin: within, lookup: lookup)
            fatalError("\(label): unexpectedly verified: \(info)")
        } catch let error as GitWorktreeError {
            precondition(error == expected, "\(label): blocked for the wrong reason: \(error)")
            precondition(!error.englishDescription.isEmpty && error.errorDescription != nil)
        } catch {
            fatalError("\(label): unexpected error \(error)")
        }
    }
}
