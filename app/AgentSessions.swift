import Foundation

/// When a coding agent last worked in each folder, from its session logs:
/// every log is a .jsonl file that names the working folder ("cwd") near its
/// start and is appended to as the session goes on.
nonisolated enum AgentSessions {
    /// Codex rollouts: $CODEX_HOME/sessions/<date>/*.jsonl.
    static var codex: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        return URL(fileURLWithPath: home + "/sessions")
    }

    /// Claude Code transcripts: $CLAUDE_CONFIG_DIR/projects/<folder>/*.jsonl.
    static var claude: URL {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        return URL(fileURLWithPath: home + "/projects")
    }

    /// The most one log is read for its "cwd". A line that opens a session can
    /// be large (Claude Code's `queue-operation`, Codex's `session_meta` with
    /// its instructions), so the folder is looked for line by line, not in a
    /// fixed head.
    static let cwdBudget = 4 << 20
    /// The most one scan reads from all its logs together.
    static let scanBudget = 256 << 20
    private static let chunk = 64 << 10

    /// What a scan of the session logs found.
    struct Activity {
        /// When a session last worked in each folder.
        var folders: [String: Date] = [:]
        /// False when something could not be read or attributed, so `folders`
        /// may be missing sessions: a directory that exists but cannot be
        /// listed, a log whose date or content cannot be read, or one whose
        /// folder was not found within `cwdBudget` or the scan's `scanBudget`.
        /// A directory that does not exist is complete: no agent, no sessions.
        var complete = true
    }

    /// Whether sessions worked in a folder. `unknown`: the logs could not all
    /// be read, and none of those read said yes.
    enum Usage: Equatable { case used, unused, unknown }

    /// `folders`, when given, picks which top-level folders of `root` to read;
    /// every folder is read otherwise.
    static func scan(in requested: URL, since: Date? = nil, folders: ((String) -> Bool)? = nil,
                     cwdBudget: Int = cwdBudget, scanBudget: Int = scanBudget) -> Activity {
        var activity = Activity()
        var remaining = scanBudget
        // The sessions root itself may be a symlink (a dotfiles checkout): it
        // is resolved once, here. A symlink below it is still not followed
        // and still makes the answer unknown.
        let root: URL
        switch resolve(requested.path) {
        case .resolved(let path): root = URL(fileURLWithPath: path)
        case .missing: return activity
        case .failed: activity.complete = false; return activity
        }
        let roots: [URL]
        if let keep = folders {
            switch listing(root.path) {
            case .missing: return activity
            case .failed: activity.complete = false; return activity
            case .names(let names): roots = names.filter(keep).map { root.appendingPathComponent($0) }
            }
        } else {
            roots = [root]
        }
        for folder in roots {
            if case .missing = status(of: folder.path) { continue }
            var unreadable = false
            guard let files = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                errorHandler: { _, error in
                    if !isMissing(error) { unreadable = true }
                    return true
                }) else {
                activity.complete = false
                continue
            }
            for case let url as URL in files where url.pathExtension == "jsonl" {
                if !note(url, since: since, in: &activity.folders, remaining: &remaining, cwdBudget: cwdBudget) {
                    activity.complete = false
                }
            }
            if unreadable { activity.complete = false }
        }
        return activity
    }

    /// `folders`, when given, picks which top-level folders of `root` to read;
    /// every folder is read otherwise. What could not be read is left out:
    /// callers that gate a cleanup use `usage` or `worked` instead.
    static func lastActive(in root: URL, since: Date? = nil, folders: ((String) -> Bool)? = nil) -> [String: Date] {
        scan(in: root, since: since, folders: folders).folders
    }

    /// False when the log could not be read or attributed (see `Activity`).
    private static func note(_ url: URL, since: Date?, in active: inout [String: Date],
                             remaining: inout Int, cwdBudget: Int) -> Bool {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return status(of: url.path) == .missing
        }
        guard since.map({ date > $0 }) ?? true else { return true }
        let file: FileHandle
        do { file = try FileHandle(forReadingFrom: url) } catch { return isMissing(error) }
        defer { try? file.close() }
        let limit = min(cwdBudget, remaining)
        switch cwd(in: file, limit: limit) {
        case .found(let cwd, let read):
            remaining -= read
            active[cwd] = max(active[cwd] ?? date, date)
            return true
        case .absent(let read):
            // A whole log that never names a folder cannot be attributed to
            // any, by this or any later read.
            remaining -= read
            return true
        case .exhausted(let read):
            remaining -= read
            return false
        case .failed:
            return false
        }
    }

    enum CwdResult: Equatable {
        case found(String, bytesRead: Int)
        /// The whole log was read and names no folder.
        case absent(bytesRead: Int)
        /// `limit` bytes were read without finding a folder or the end of the log.
        case exhausted(bytesRead: Int)
        case failed
    }

    private static let needle = Data("\"cwd\":\"".utf8)

    /// The first `"cwd"` of a log, read line by line from the start, at most
    /// `limit` bytes in all.
    static func cwd(in file: FileHandle, limit: Int) -> CwdResult {
        var pending = Data()
        var read = 0
        while read < limit {
            guard let part = readChunk(file, min(chunk, limit - read)) else { return .failed }
            if part.isEmpty {
                if let found = cwd(inLine: pending) { return .found(found, bytesRead: read) }
                return .absent(bytesRead: read)
            }
            read += part.count
            pending.append(part)
            while let newline = pending.firstIndex(of: 0x0A) {
                if let found = cwd(inLine: pending[pending.startIndex..<newline]) { return .found(found, bytesRead: read) }
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if let found = cwd(inLine: pending) { return .found(found, bytesRead: read) }
        // A log that ends exactly at the limit has been read in full.
        guard let probe = readChunk(file, 1) else { return .failed }
        return probe.isEmpty ? .absent(bytesRead: read) : .exhausted(bytesRead: read)
    }

    /// The next `count` bytes: empty at the end of the log (`read(upToCount:)`
    /// answers nil there), nil when the read fails.
    private static func readChunk(_ file: FileHandle, _ count: Int) -> Data? {
        do { return try file.read(upToCount: count) ?? Data() } catch { return nil }
    }

    /// The value of the first complete `"cwd":"…"` in one line, JSON escapes decoded.
    private static func cwd(inLine line: Data) -> String? {
        guard let start = line.range(of: needle) else { return nil }
        var escaped = false
        var end: Data.Index?
        for index in line[start.upperBound...].indices {
            let byte = line[index]
            if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { end = index; break }
        }
        guard let end else { return nil }
        let literal = Data([0x22]) + line[start.upperBound..<end] + Data([0x22])
        return (try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed)) as? String
    }

    private enum Resolution { case resolved(String), missing, failed }

    /// `realpath`, which is bounded by PATH_MAX and by the system's own symlink limit.
    private static func resolve(_ path: String) -> Resolution {
        guard let resolved = realpath(path, nil) else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .failed
        }
        defer { free(resolved) }
        return .resolved(String(cString: resolved))
    }

    private enum Listing { case names([String]), missing, failed }

    private static func listing(_ path: String) -> Listing {
        do { return .names(try FileManager.default.contentsOfDirectory(atPath: path)) }
        catch { return isMissing(error) ? .missing : .failed }
    }

    private enum PathStatus { case present, missing }

    private static func status(of path: String) -> PathStatus {
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT ? .missing : .present
    }

    private static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
    }

    /// Whether a session in `root` worked at or inside `folder` since `since`.
    static func usage(in folder: String, root: URL, since: Date, folders: ((String) -> Bool)? = nil) -> Usage {
        usage(of: folder, in: scan(in: root, since: since, folders: folders))
    }

    /// The same answer from a scan already made, for callers asking about
    /// several folders of one root.
    static func usage(of folder: String, in activity: Activity) -> Usage {
        if activity.folders.keys.contains(where: { $0 == folder || $0.hasPrefix(folder + "/") }) { return .used }
        return activity.complete ? .unused : .unknown
    }

    /// Whether Claude Code worked at or inside `folder` since `since`. Claude
    /// Code files each session under a folder named after the working folder
    /// it started in, with separators turned into "-"; subagent and worktree
    /// sessions go under their parent's folder. So only folders naming
    /// `folder`, one inside it, or one around it are read (thousands of logs
    /// otherwise, on every card). Both sides are folded the same way, so this
    /// only narrows what is read; the "cwd" inside each log still decides.
    static func claudeUsage(in folder: String, since: Date) -> Usage {
        let key = claudeFolderKey(folder)
        return usage(in: folder, root: claude, since: since) {
            let name = claudeFolderKey($0)
            return name.hasPrefix(key) || key.hasPrefix(name)
        }
    }

    enum SessionState: Equatable { case running, ended, unknown }

    /// Claude Code's registry of running sessions: one `<pid>.json` per
    /// process in $CLAUDE_CONFIG_DIR/sessions, naming its `sessionId`.
    static var claudeRegistry: URL {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        return URL(fileURLWithPath: home + "/sessions")
    }

    /// How recently a session's temp folder may have been written to and
    /// still count as ended: a headless or crashed-but-alive run that never
    /// registered itself is still writing.
    static let quietPeriod: TimeInterval = 15 * 60

    /// Whether the Claude Code session owning `temp` still runs: a registry
    /// entry for its id whose process is alive, or a write inside its session
    /// or scratchpad folder within `quietPeriod`. Fails closed: a registry
    /// that cannot be listed, or an entry that cannot be read, is `.unknown`.
    static func claudeSessionState(_ temp: ClaudeTemp, registry: URL = claudeRegistry,
                                   now: Date = Date()) -> SessionState {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: registry.path) else { return .unknown }
        for name in entries where name.hasSuffix(".json") {
            guard let data = fm.contents(atPath: registry.appendingPathComponent(name).path),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unknown
            }
            guard (entry["sessionId"] as? String)?.lowercased() == temp.sessionID else { continue }
            let pid = (entry["pid"] as? Int).flatMap { pid_t(exactly: $0) }
                ?? pid_t(name.split(separator: ".").first ?? "")
            guard let pid, pid > 0 else { return .unknown }
            // EPERM: the process exists but belongs to someone else.
            if kill(pid, 0) == 0 || errno == EPERM { return .running }
        }
        let cutoff = now.addingTimeInterval(-quietPeriod)
        let scratch = (temp.sessionFolder as NSString).appendingPathComponent("scratchpad")
        // The entries only, never the two folders holding them: cleaning one
        // folder out of a scratchpad changes the scratchpad's own date, and
        // the next folder of that ended session must not read as in use. A
        // new file still shows by its own date; a running session that
        // registered is caught above.
        var stamps: [String] = []
        for folder in [temp.sessionFolder, scratch] {
            stamps += ((try? fm.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { !(folder == temp.sessionFolder && $0 == "scratchpad") }
                .map { (folder as NSString).appendingPathComponent($0) }
        }
        let recent = stamps.contains { path in
            ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date).map { $0 > cutoff } ?? false
        }
        return recent ? .running : .ended
    }

    private static func claudeFolderKey(_ path: String) -> String {
        String(String.UnicodeScalarView(path.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? $0 : "-"
        }))
    }
}
