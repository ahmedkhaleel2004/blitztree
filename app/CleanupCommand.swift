import Foundation

/// A cleanup command after it has passed BlitzTree's small, exact allowlist.
///
/// This type deliberately contains no process or filesystem code. Callers can
/// use `arguments` with Process directly, while the prompt can be generated
/// from the same catalogue that validates a plan.
nonisolated struct CleanupCommand: Sendable, Equatable {
    let executable: String
    let arguments: [String]

    var argv: [String] { [executable] + arguments }

    /// A known folder cache that can be measured and moved to the Trash.
    /// The caller must still canonicalize this relative path and verify that
    /// it is present in the current scan before using it.
    var cacheRelativePath: String? {
        switch (executable, arguments) {
        case ("uv", ["cache", "clean"]):
            return ".cache/uv"
        case ("npm", ["cache", "clean"]), ("npm", ["cache", "clean", "--force"]):
            return ".npm/_cacache"
        case ("bun", ["pm", "cache", "rm"]):
            return ".bun/install/cache"
        case ("pip", ["cache", "purge"]), ("pip3", ["cache", "purge"]):
            return "Library/Caches/pip"
        case ("yarn", ["cache", "clean"]):
            return "Library/Caches/Yarn"
        default:
            return nil
        }
    }

    /// Commands accepted by the cleanup prompt. The first entries are the
    /// documented forms; the final exact forms preserve harmless cache
    /// commands accepted by older app builds without accepting new flags.
    static var promptExamples: String {
        fixedEntries.map { "`\($0.words.joined(separator: " "))`" }
            .joined(separator: ", ") + ", `ollama rm <model>`, `xcrun simctl runtime delete <id>`, `xcrun simctl erase <udid>`"
    }

    /// Parses only a single known argv shape. Spaces and tabs separate argv
    /// words; shell quoting, non-ASCII text, controls, and metacharacters are
    /// rejected before any caller can execute the result.
    static func parse(_ command: String) -> Self? {
        let bytes = Array(command.utf8)
        guard !bytes.isEmpty else { return nil }
        for byte in bytes {
            guard byte < 0x80 else { return nil }
            if byte < 0x20 && byte != 0x09 { return nil }
            if byte == 0x7f || forbiddenShellBytes.contains(byte) { return nil }
        }

        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !words.isEmpty else { return nil }

        if let fixed = fixedEntries.first(where: { $0.words == words }) {
            return Self(executable: fixed.words[0], arguments: Array(fixed.words.dropFirst()))
        }

        // Target one simulator by its UUID, never aliases such as "all" or
        // "booted", multiple IDs, or optional flags.
        if (words.count == 4 && Array(words.prefix(3)) == ["xcrun", "simctl", "erase"])
            || (words.count == 5 && Array(words.prefix(4)) == ["xcrun", "simctl", "runtime", "delete"]) {
            guard let id = words.last, id.utf8.count == 36, UUID(uuidString: id) != nil else { return nil }
            return Self(executable: "xcrun", arguments: Array(words.dropFirst()))
        }

        guard words.count == 3, words[0] == "ollama", words[1] == "rm",
              validModel(words[2]) else { return nil }
        return Self(executable: "ollama", arguments: ["rm", words[2]])
    }

    private struct Fixed: Sendable {
        let words: [String]
    }

    private static let fixedEntries: [Fixed] = [
        // Prompt forms.
        Fixed(words: ["uv", "cache", "clean"]),
        Fixed(words: ["bun", "pm", "cache", "rm"]),
        Fixed(words: ["npm", "cache", "clean", "--force"]),
        Fixed(words: ["pnpm", "store", "prune"]),
        Fixed(words: ["yarn", "cache", "clean"]),
        Fixed(words: ["brew", "cleanup", "--prune=all"]),
        Fixed(words: ["docker", "system", "prune", "-f"]),
        Fixed(words: ["docker", "builder", "prune", "-f"]),
        Fixed(words: ["xcrun", "simctl", "delete", "unavailable"]),
        Fixed(words: ["pip", "cache", "purge"]),
        Fixed(words: ["go", "clean", "-modcache"]),
        Fixed(words: ["gem", "cleanup"]),
        Fixed(words: ["pod", "cache", "clean", "--all"]),
        Fixed(words: ["conda", "clean", "-a", "-y"]),

        // Exact cache-only compatibility forms from the released guard.
        Fixed(words: ["uv", "cache", "prune"]),
        Fixed(words: ["npm", "cache", "clean"]),
        Fixed(words: ["pip3", "cache", "purge"]),
        Fixed(words: ["go", "clean", "-cache"]),
    ]

    private static let forbiddenShellBytes: Set<UInt8> = [
        0x22, // double quote
        0x27, // single quote
        0x24, // $
        0x60, // backtick
        0x3b, // ;
        0x7c, // |
        0x26, // &
        0x3e, // >
        0x3c, // <
        0x5c, // backslash
        0x2a, // glob
        0x3f, // glob
        0x21, // !
        0x23, // comment
        0x28, 0x29, 0x5b, 0x5d, 0x7b, 0x7d,
    ]

    private static func validModel(_ model: String) -> Bool {
        guard !model.isEmpty, !model.hasPrefix("-") else { return false }
        return model.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) ||
            (byte >= 0x41 && byte <= 0x5a) ||
            (byte >= 0x61 && byte <= 0x7a) ||
            byte == 0x2e || byte == 0x2f || byte == 0x3a ||
            byte == 0x40 || byte == 0x5f || byte == 0x2d
        }
    }
}
