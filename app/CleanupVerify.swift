import Darwin
import Foundation

/// Per-kind checks a recognised cleanup candidate must pass before it is
/// actionable (the Rust rule names the verifier). Every check fails closed:
/// a check that cannot run blocks with a reason, never passes.
nonisolated enum CleanupVerify {
    typealias Reason = (localized: String, english: String)

    /// What stands for a verifier the engine gave no answer for: unknown, so it blocks.
    static let unavailable = "unavailable"
    static let cacheSignature = "Signature: 8a477f597d28d172789f06886806bc55"
    static let recentWindow: TimeInterval = 2 * 86400
    static let entryCap = 200_000

    /// Nil when `path` passes the verifier named `verify` ("" means none).
    static func blockReason(
        verify: String,
        path: String,
        now: Date = Date(),
        within: TimeInterval = recentWindow,
        entryCap: Int = entryCap,
        evidence: WorktreeEvidence? = nil
    ) -> Reason? {
        switch verify {
        case "":
            return nil
        case "cachedir_tag":
            return cacheTagReason(path)
        case "recent_activity":
            return recentActivityReason(path, cutoff: now.addingTimeInterval(-within), cap: entryCap)
        case "agent_session":
            // The path policy refuses a running session's folder at every
            // capture; this repeats it so the verifier answers on its own.
            if let reason = cacheTagReason(path) { return reason }
            guard let temp = CleanupPathSafety.claudeTemp(path), temp.inScratchpad else {
                return ("Not in a Claude Code scratchpad: \(path)",
                        "Not in a Claude Code scratchpad: \(path)")
            }
            switch AgentSessions.claudeSessionState(temp) {
            case .ended: return nil
            case .running:
                let error = CleanupPathError.sessionRunning(path)
                return (error.errorDescription ?? error.englishDescription, error.englishDescription)
            case .unknown:
                let error = CleanupPathError.sessionUnverified(path)
                return (error.errorDescription ?? error.englishDescription, error.englishDescription)
            }
        case "git_worktree":
            do {
                _ = try GitWorktree.verify(path, recentWithin: within, now: now, evidence: evidence)
                return nil
            } catch let error as GitWorktreeError {
                return (error.errorDescription ?? error.englishDescription, error.englishDescription)
            } catch {
                return (error.localizedDescription, "Could not verify git worktree: \(path)")
            }
        default:
            return ("Unknown check \(verify) for \(path)", "Unknown check \(verify) for \(path)")
        }
    }

    /// A regular `CACHEDIR.TAG` file (not a symlink) that begins with the
    /// signature from the Cache Directory Tagging Specification.
    private static func cacheTagReason(_ path: String) -> Reason? {
        let tag = (path as NSString).appendingPathComponent("CACHEDIR.TAG")
        let failure: Reason = ("No valid cache directory tag in \(path)",
                               "No valid cache directory tag in \(path)")
        var seen = stat()
        guard lstat(tag, &seen) == 0, seen.st_mode & S_IFMT == S_IFREG else { return failure }
        let fd = open(tag, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return failure }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == seen.st_dev, opened.st_ino == seen.st_ino else {
            return failure
        }
        let expected = Array(cacheSignature.utf8)
        var buffer = [UInt8](repeating: 0, count: expected.count)
        var count = 0
        while count < buffer.count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + count, $0.count - count) }
            if n <= 0 { break }
            count += n
        }
        return count == expected.count && buffer == expected ? nil : failure
    }

    /// Blocks when anything in the folder (the folder included) was modified
    /// after `cutoff`, when the walk hits an entry it cannot read, when it
    /// has more than `cap` entries, or when another volume is mounted inside.
    /// Symlinks are not followed, and neither is a mount (FTS_XDEV): what lies
    /// on it is never looked at, so it cannot be shown unchanged and the
    /// folder is kept. A mount inside a folder this check guards is rare, so
    /// refusing costs little; moving the folder to the Trash would carry the
    /// mounted volume's view along with it.
    private static func recentActivityReason(_ path: String, cutoff: Date, cap: Int) -> Reason? {
        let unreadable: Reason = ("Could not check every file in \(path)",
                                  "Could not check every file in \(path)")
        guard let root = strdup(path) else { return unreadable }
        defer { free(root) }
        var roots: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let stream = roots.withUnsafeMutableBufferPointer({
            fts_open($0.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { return unreadable }
        defer { fts_close(stream) }
        let limit = cutoff.timeIntervalSince1970
        var entries = 0
        var volume: dev_t?
        errno = 0
        while let entry = fts_read(stream) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_DP:
                continue
            case FTS_DNR, FTS_ERR, FTS_NS, FTS_NSOK:
                return unreadable
            default:
                break
            }
            entries += 1
            if entries > cap {
                return ("Too many files to check in \(path)", "Too many files to check in \(path)")
            }
            guard let info = entry.pointee.fts_statp else { return unreadable }
            if let volume, info.pointee.st_dev != volume {
                return ("Another volume is mounted inside \(path)",
                        "Another volume is mounted inside \(path)")
            }
            volume = info.pointee.st_dev
            let time = info.pointee.st_mtimespec
            if TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9 > limit {
                return ("Changed in the last 2 days: \(path)", "Changed in the last 2 days: \(path)")
            }
            errno = 0
        }
        return errno == 0 ? nil : unreadable
    }
}
