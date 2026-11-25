import Darwin
import Foundation

/// Disposable git repositories and linked worktrees for the cleanup checks.
/// Fixture git ignores the user's global and system config, so a global
/// `commit.gpgsign` or hook setting cannot leak in; repository config set by a
/// check (the fsmonitor hook) still applies, as it would for a real repo.
nonisolated struct GitFixture {
    let git: String
    let base: URL
    let environment: [String: String]

    init(base: URL) {
        guard let git = GitWorktree.locateGit(.standard) else {
            fatalError("git fixtures need a real git (not the /usr/bin shim)")
        }
        self.git = git
        self.base = base
        environment = [
            "HOME": base.path, "PATH": "/usr/bin:/bin", "LC_ALL": "C",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ]
        // Session logs are read from these; keep the user's own out of it.
        let claude = base.appendingPathComponent("claude-config").path
        let codex = base.appendingPathComponent("codex-home").path
        try? FileManager.default.createDirectory(atPath: claude + "/projects", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: codex + "/sessions", withIntermediateDirectories: true)
        setenv("CLAUDE_CONFIG_DIR", claude, 1)
        setenv("CODEX_HOME", codex, 1)
    }

    @discardableResult
    func run(_ arguments: [String], in directory: String) -> String {
        let prefix = ["-C", directory, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                      "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"]
        guard let outcome = BoundedProcess.run(git, prefix + arguments, environment: environment,
                                               timeout: 60, cap: 4 << 20) else {
            fatalError("could not run git \(arguments)")
        }
        guard outcome.status == 0, !outcome.timedOut else {
            fatalError("git \(arguments) failed: \(String(decoding: outcome.stderr, as: UTF8.self))")
        }
        return outcome.text
    }

    /// A repository with one commit; node_modules/ is ignored.
    func repository(_ path: String) -> String {
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        run(["init", "-q"], in: path)
        write(path + "/a.txt", "tracked\n")
        // The engine only calls a node_modules build output beside a package.json.
        write(path + "/package.json", "{}\n")
        write(path + "/.gitignore", "node_modules/\n")
        run(["add", "-A"], in: path)
        run(["commit", "-q", "-m", "init"], in: path)
        return path
    }

    /// A linked worktree on a new branch named after its folder.
    func worktree(of repository: String, at path: String) -> String {
        let branch = (path as NSString).lastPathComponent
        run(["worktree", "add", "-q", "-b", branch, path], in: repository)
        return path
    }

    /// `count` linked worktrees of one fresh repository below `home`, each
    /// backdated past the recent-use window and holding an ignored
    /// `node_modules` file over the engine's 50 MB floor, so a scan of `home`
    /// offers every worktree and verification passes for all of them.
    /// Returns the worktree paths.
    func scannableWorktrees(in home: String, count: Int) -> [String] {
        let repo = repository(home + "/repo")
        let blob = Data(repeating: 7, count: 51_000_000)
        return (0..<count).map { index in
            let path = worktree(of: repo, at: home + "/wts/wt\(index)")
            try! FileManager.default.createDirectory(atPath: path + "/node_modules", withIntermediateDirectories: true)
            try! blob.write(to: URL(fileURLWithPath: path + "/node_modules/blob"))
            backdate(path)
            return path
        }
    }

    func admin(of worktree: String) -> String {
        try! GitWorktree.layout(of: worktree).admin
    }

    /// Moves the recency evidence (admin index, HEAD, logs/HEAD) into the past.
    func backdate(_ worktree: String, days: Double = 5) {
        let old = Date().addingTimeInterval(-days * 86400)
        let admin = admin(of: worktree)
        for file in ["index", "HEAD", "logs/HEAD"] {
            try! FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: admin + "/" + file)
        }
    }

    func write(_ path: String, _ text: String) {
        try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}
