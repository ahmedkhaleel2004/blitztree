import Foundation

@main
struct CleanupCommandChecks {
    static func main() {
        let simulatorID = "12345678-1234-1234-1234-123456789ABC"
        let allowed = [
            "uv cache clean",
            "bun pm cache rm",
            "npm cache clean --force",
            "pnpm store prune",
            "yarn cache clean",
            "brew cleanup --prune=all",
            "docker builder prune -f",
            "xcrun simctl delete unavailable",
            "xcrun simctl runtime delete \(simulatorID)",
            "xcrun simctl erase \(simulatorID)",
            "pip cache purge",
            "ollama rm llama3.2:latest",
            "go clean -modcache",
            "pod cache clean --all",
            "conda clean -a -y",
            "uv cache prune",
            "npm cache clean",
            "pip3 cache purge",
            "go clean -cache",
            "swift package purge-cache",
            "dotnet nuget locals all --clear",
            "composer clear-cache",
            "hf cache prune --yes",
            "rustup toolchain uninstall nightly-2026-10-05-aarch64-apple-darwin",
            "rustup toolchain uninstall 1.97.0-aarch64-apple-darwin",
            "rustup toolchain uninstall stable",
            "rustup toolchain uninstall 1.80",
            "rustup toolchain uninstall beta-2026-01-02",
        ]
        for raw in allowed {
            precondition(CleanupCommand.parse(raw) != nil, "should allow: \(raw)")
        }

        // Not cache-only (verified against each tool's docs/source): these
        // remove stopped containers' data or uninstall gems, so they stay out
        // even though older builds accepted them.
        for raw in ["docker system prune -f", "gem cleanup", "podman system prune -f", "deno clean",
                    "dart pub cache clean --force", "flutter pub cache clean -f"] {
            precondition(CleanupCommand.parse(raw) == nil, "not a cache-only cleanup: \(raw)")
        }
        // Toolchain names: rustup's <channel>[-<date>][-<host>] grammar only.
        for name in ["", "-v", "--help", "all", "stable nightly", "../stable", "stable/x", "~stable",
                     "nightly-2026-13-05", "1.97.0.1", "1..97", "stable-", "Stable", "nightly-2026-10-05-",
                     String(repeating: "a", count: 101), "1.97.0-aarch64-apple-darwin\u{00e9}"] {
            precondition(CleanupCommand.parse("rustup toolchain uninstall \(name)") == nil,
                         "should reject toolchain name: \(name)")
        }

        let padded = CleanupCommand.parse(" \tuv\tcache clean \t")
        precondition(padded?.argv == ["uv", "cache", "clean"], "space/tab tokenization changed")

        let rejected = [
            "docker system prune -f --volumes",
            "docker system prune -af",
            "brew cleanup --prune=all --dry-run",
            "npm cache clean --force /tmp/other-cache",
            "xcrun simctl delete unavailable ABCD",
            "xcrun simctl runtime delete all",
            "xcrun simctl runtime delete \(simulatorID) --dry-run",
            "xcrun simctl runtime delete \(simulatorID) \(simulatorID)",
            "xcrun simctl erase all",
            "xcrun simctl erase booted",
            "xcrun simctl erase invalid-id",
            "xcrun simctl erase \(simulatorID)\t\(simulatorID)",
            "xcrun simctl erase \(simulatorID); true",
            "go clean -modcache /tmp/other-cache",
            "ollama rm --all",
            "ollama rm model-one model-two",
            "ollama rm modèle:latest",
            "uv cache clean; touch /tmp/pwned",
            "npm cache clean --force $(touch /tmp/pwned)",
            "npm cache clean --force\n touch /tmp/pwned",
            "npm cache clean --force\"",
        ]
        for raw in rejected {
            precondition(CleanupCommand.parse(raw) == nil, "should reject: \(raw)")
        }

        precondition(CleanupCommand.parse("uv cache clean")?.cacheRelativePath == ".cache/uv")
        precondition(CleanupCommand.parse("uv cache prune")?.cacheRelativePath == nil)
        precondition(CleanupCommand.parse("npm cache clean --force")?.cacheRelativePath == ".npm/_cacache")
        precondition(CleanupCommand.parse("bun pm cache rm")?.cacheRelativePath == ".bun/install/cache")
        precondition(CleanupCommand.parse("pip3 cache purge")?.cacheRelativePath == "Library/Caches/pip")
        precondition(CleanupCommand.parse("docker builder prune -f")?.cacheRelativePath == nil)
        precondition(CleanupCommand.parse("swift package purge-cache")?.cacheRelativePath
                     == "Library/Caches/org.swift.swiftpm")
        precondition(CleanupCommand.parse("composer clear-cache")?.cacheRelativePath == "Library/Caches/composer")
        precondition(CleanupCommand.parse("pod cache clean --all")?.cacheRelativePath == "Library/Caches/CocoaPods")
        precondition(CleanupCommand.parse("rustup toolchain uninstall stable")?.cacheRelativePath == nil)
        precondition(CleanupCommand.promptExamples.contains("`rustup toolchain uninstall <toolchain>`"))
        precondition(!CleanupCommand.promptExamples.contains("docker system prune"))
        precondition(!CleanupCommand.promptExamples.contains("gem cleanup"))
        precondition(CleanupCommand.promptExamples.contains("`ollama rm <model>`"))
        precondition(CleanupCommand.promptExamples.contains("`xcrun simctl runtime delete <id>`"))
        precondition(CleanupCommand.promptExamples.contains("`xcrun simctl erase <udid>`"))
        precondition(CleanupCommand.parse("xcrun simctl erase \(simulatorID)")?.argv
                     == ["xcrun", "simctl", "erase", simulatorID])
        print("PASS: CleanupCommand exact argv allowlist")
    }
}
