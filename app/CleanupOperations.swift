import Foundation

/// A receipt is created from the actual destination returned by the move,
/// never from an agent-supplied Trash path. Identity checks also pin its parent.
nonisolated struct CleanupReceipt: Sendable {
    let url: URL
    let sourcePath: String
    let identity: CleanupIdentity
    let parentIdentity: CleanupIdentity

    init(url: URL, sourcePath: String, original: CleanupIdentity) throws {
        let identity = try CleanupIdentity.capture(path: url.path)
        guard identity == original else {
            throw CleanupOperations.failure("The moved item changed identity; leave it in the Trash and review it")
        }
        self.url = url
        self.sourcePath = sourcePath
        self.identity = identity
        self.parentIdentity = try CleanupIdentity.capture(path: url.deletingLastPathComponent().path)
    }

    func validate() throws {
        guard try CleanupIdentity.capture(path: url.path) == identity,
              try CleanupIdentity.capture(path: url.deletingLastPathComponent().path) == parentIdentity else {
            throw CleanupOperations.failure("The item in the Trash or its parent changed; review it before deleting")
        }
    }
}

nonisolated enum CleanupOperations {
    static func failure(_ message: String) -> NSError {
        NSError(domain: "BlitzTree.Cleanup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Both manual and agent cleanup use this boundary, immediately before I/O.
    static func trash(_ target: CleanupTarget,
                      move: (URL) throws -> URL = systemTrash) throws -> CleanupReceipt {
        try target.validate()
        let destination = try move(URL(fileURLWithPath: target.path))
        return try CleanupReceipt(url: destination, sourcePath: target.path, original: target.identity)
    }

    private static func systemTrash(_ source: URL) throws -> URL {
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
                for (index, receipt) in receipts.enumerated() where !failures.has(index) {
                    do {
                        try receipt.validate()
                        slots.wait()
                        let error = erase(receipt.url.path)
                        slots.signal()
                        if let error { failures.record(index, error) }
                    } catch { failures.record(index, error.localizedDescription) }
                }
                let remaining = receipts.enumerated().filter { failures.has($0.offset) }.map(\.element)
                continuation.resume(returning: RemovalResult(remaining: remaining, errors: failures.all))
            }
        }
    }

    private static func erasePath(_ path: String) -> String? {
        guard removefile(path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 else {
            let message = String(cString: strerror(errno))
            return "\(path): \(message)"
        }
        return nil
    }
}
