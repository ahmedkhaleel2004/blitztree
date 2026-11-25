import Darwin
import Foundation

/// A receipt is created from the actual destination returned by the move,
/// never from an agent-supplied Trash path. Identity checks also pin its parent.
nonisolated struct CleanupReceipt: Sendable {
    let url: URL
    let sourcePath: String
    let identity: CleanupIdentity
    let parentIdentity: CleanupIdentity
    /// Set when the moved item was a verified linked git worktree: its admin
    /// entry, removed only after the item itself is deleted for good.
    let worktree: WorktreeAdminEntry?

    init(url: URL, sourcePath: String, original: CleanupIdentity,
         worktree: WorktreeAdminEntry? = nil) throws {
        let identity = try CleanupIdentity.capture(path: url.path)
        guard identity == original else {
            throw CleanupOperations.failure("The moved item changed identity; leave it in the Trash and review it")
        }
        self.url = url
        self.sourcePath = sourcePath
        self.identity = identity
        self.parentIdentity = try CleanupIdentity.capture(path: url.deletingLastPathComponent().path)
        self.worktree = worktree
    }

    func validate() throws {
        guard try CleanupIdentity.capture(path: url.path) == identity,
              try CleanupIdentity.capture(path: url.deletingLastPathComponent().path) == parentIdentity else {
            throw CleanupOperations.failure("The item in the Trash or its parent changed; review it before deleting")
        }
    }

    enum TrashState: Equatable, Sendable {
        /// Still in the Trash (under its name or another), so it can be put back.
        case present
        /// The Trash folder is the one the move went to and nothing in it is the item.
        case gone
        /// The Trash could not be read, was replaced, or holds too many entries to look through.
        case unknown
    }

    /// Whether the moved item is still in the Trash. "Gone" requires the whole
    /// Trash folder, subfolders included (the person can drag the item into
    /// one, and it can still be put back from there), to have been read, and
    /// none of its entries to be the item (matched by device and inode, so a
    /// rename or a move inside the Trash does not hide it). Symlinks are
    /// looked at, never followed. Anything less is `unknown`, which is not
    /// "gone": more than `entryLimit` entries in all, a folder that cannot be
    /// read, or an entry that cannot be examined for a reason other than
    /// having just disappeared.
    func trashState(entryLimit: Int = 50_000,
                    examine: (String, UnsafeMutablePointer<stat>) -> Int32 = { lstat($0, $1) }) -> TrashState {
        var info = stat()
        if lstat(url.path, &info) == 0 { return .present }
        guard errno == ENOENT else { return .unknown }
        let folder = url.deletingLastPathComponent().path
        guard let current = try? CleanupIdentity.capture(path: folder), current == parentIdentity else { return .unknown }
        var pending = [folder]
        var seen = 0
        while let directory = pending.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return .unknown }
            seen += names.count
            guard seen <= entryLimit else { return .unknown }
            for name in names {
                let path = directory + "/" + name
                var entry = stat()
                guard examine(path, &entry) == 0 else {
                    // Removed since it was listed: nothing there to be the item.
                    if errno == ENOENT { continue }
                    return .unknown
                }
                if UInt64(truncatingIfNeeded: entry.st_dev) == identity.device,
                   UInt64(truncatingIfNeeded: entry.st_ino) == identity.inode { return .present }
                if (entry.st_mode & S_IFMT) == S_IFDIR { pending.append(path) }
            }
        }
        return .gone
    }
}

nonisolated enum CleanupOperations {
    static func failure(_ message: String) -> NSError {
        NSError(domain: "BlitzTree.Cleanup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Both manual and agent cleanup use this boundary, immediately before I/O.
    /// Revalidating the target runs the path policy and the check recorded in
    /// `target.check` (cache tag, recent activity, worktree...) as they are now,
    /// so a caller cannot skip either once the target exists.
    ///
    /// The contract, exactly: the boundary runs the check the target carries,
    /// not the check the engine's rule would name for the path. It cannot look
    /// the rule up itself, because the rule belongs to the scan (the `Tree`),
    /// which this layer neither has nor should. Whoever captures the target
    /// supplies the `CleanupCheck` (`Tree.cleanupCheck(for:path:indexByNode:)`,
    /// or the candidate's own verifier in `CleanupItem`), and `.policyOnly`
    /// is a statement that no rule recognised the path. What the boundary does
    /// guarantee: a check that names a verifier nobody knows, one the engine
    /// gave no answer for (`CleanupVerify.unavailable`), or one that belongs to
    /// another folder, blocks rather than passes; the check cannot be dropped
    /// from a target (`CleanupTarget.check` is not optional); and the folder
    /// is re-verified here, fresh, not trusted from the capture.
    static func trash(_ target: CleanupTarget,
                      move: (URL) throws -> URL = systemTrash) throws -> CleanupReceipt {
        // A linked worktree is re-verified here (clean, unused, nothing
        // running inside) and its admin entry recorded before it moves.
        let worktree = try CleanupPathSafety.validatedWorktree(target)
        let entry = try worktree.map { try GitWorktree.adminEntry(for: $0) }
        let destination = try move(URL(fileURLWithPath: target.path))
        return try CleanupReceipt(url: destination, sourcePath: target.path, original: target.identity,
                                  worktree: entry)
    }

    /// Finder's own move to the Trash, the default of every caller. Checks
    /// and callers inject another so a refusal that fails to happen cannot
    /// put a fixture in the real Trash.
    static func systemTrash(_ source: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
        guard let destination else {
            throw failure("The item was moved but its Trash location was not returned; review the Trash manually")
        }
        return destination as URL
    }

    // Preserve the existing global limit of four filesystem delete operations.
    private static let slots = DispatchSemaphore(value: 4)
    private static let queue = DispatchQueue(label: "blitztree.delete", qos: .userInitiated,
                                             attributes: .concurrent)

    struct RemovalResult: Sendable {
        let remaining: [CleanupReceipt]
        let errors: [String]
        /// Worktree admin entries left in place after their worktree was
        /// deleted (the item itself was freed; these are not failures).
        var notices: [String] = []
    }

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [Int: [String]] = [:]
        func record(_ index: Int, _ message: String) {
            lock.lock(); defer { lock.unlock() }
            messages[index, default: []].append(message)
        }
        func has(_ index: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return messages[index] != nil
        }
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return messages.keys.sorted().flatMap { messages[$0]! }
        }
    }

    /// Return failed receipts for review/retry; never report them as freed.
    static func remove(_ receipts: [CleanupReceipt],
                       erase: @escaping @Sendable (String) -> String? = erasePath) async -> RemovalResult {
        await withCheckedContinuation { continuation in
            queue.async {
                let failures = Failures()
                let group = DispatchGroup()
                for (index, receipt) in receipts.enumerated() {
                    do {
                        try receipt.validate()
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: receipt.url.path, isDirectory: &isDirectory) else {
                            throw failure("The item in the Trash is missing")
                        }
                        if isDirectory.boolValue {
                            let children = try FileManager.default.contentsOfDirectory(atPath: receipt.url.path)
                            for child in children {
                                slots.wait()
                                group.enter()
                                queue.async {
                                    defer { slots.signal(); group.leave() }
                                    do {
                                        try receipt.validate()
                                        if let error = erase(receipt.url.appendingPathComponent(child).path) {
                                            failures.record(index, error)
                                        }
                                    } catch { failures.record(index, error.localizedDescription) }
                                }
                            }
                        }
                    } catch { failures.record(index, error.localizedDescription) }
                }
                group.wait()
                var notices: [String] = []
                for (index, receipt) in receipts.enumerated() where !failures.has(index) {
                    do {
                        try receipt.validate()
                        slots.wait()
                        let error = erase(receipt.url.path)
                        slots.signal()
                        if let error { failures.record(index, error) }
                    } catch { failures.record(index, error.localizedDescription) }
                    // Only after this worktree is gone for good, and only its
                    // own admin entry; never `git worktree prune`.
                    if let entry = receipt.worktree, !failures.has(index) {
                        slots.wait()
                        let notice = GitWorktree.removeAdminEntry(entry, erase: erase)
                        slots.signal()
                        if let notice { notices.append(notice) }
                    }
                }
                let remaining = receipts.enumerated().filter { failures.has($0.offset) }.map(\.element)
                continuation.resume(returning: RemovalResult(remaining: remaining, errors: failures.all,
                                                             notices: notices))
            }
        }
    }

    struct Settlement: Sendable {
        /// Receipts whose worktree is still in the Trash (or whose Trash could
        /// not be read): asked again later.
        let waiting: [CleanupReceipt]
        /// Admin entries that were left in place, with why.
        let notices: [String]
    }

    /// The manual panel only moves a worktree to the Trash; the person empties
    /// it, later and in Finder. This takes the admin entry of each worktree
    /// whose Trash copy is gone, the same way and under the same checks as
    /// the agent's delete-for-good step (`GitWorktree.removeAdminEntry`:
    /// the entry must be unchanged, name the vanished `.git` file, and the
    /// worktree must not exist again). While the copy can still be put back
    /// the entry stays, since a put-back worktree needs it. Never
    /// `git worktree prune`. Synchronous and bounded by the Trash's size:
    /// call it off the main thread.
    static func settleWorktrees(_ receipts: [CleanupReceipt],
                                erase: (String) -> String? = erasePath) -> Settlement {
        var waiting: [CleanupReceipt] = []
        var notices: [String] = []
        for receipt in receipts {
            guard let entry = receipt.worktree else { continue }
            guard receipt.trashState() == .gone else {
                waiting.append(receipt)
                continue
            }
            if let notice = GitWorktree.removeAdminEntry(entry, erase: erase) { notices.append(notice) }
        }
        return Settlement(waiting: waiting, notices: notices)
    }

    private static func erasePath(_ path: String) -> String? {
        guard removefile(path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 else {
            let message = String(cString: strerror(errno))
            return "\(path): \(message)"
        }
        return nil
    }
}
