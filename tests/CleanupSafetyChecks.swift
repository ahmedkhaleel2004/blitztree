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
            _ = try CleanupPathSafety.capture(path: projectArtifact.path, root: home.path, home: home.path)
        }
        expectRejected("git repository root") {
            _ = try CleanupPathSafety.capture(path: project.path, root: home.path, home: home.path)
        }
        expectRejected("inside .git metadata") {
            _ = try CleanupPathSafety.capture(
                path: project.appendingPathComponent(".git/config").path,
                root: home.path,
                home: home.path
            )
        }

        let credentialsArtifact = home.appendingPathComponent(".ssh/node_modules", isDirectory: true)
        try fm.createDirectory(at: credentialsArtifact, withIntermediateDirectories: true)
        expectRejected("credential root exception") {
            _ = try CleanupPathSafety.capture(path: credentialsArtifact.path, root: home.path, home: home.path)
        }
        let caseCredentials = home.appendingPathComponent(".SSH/node_modules").path
        if fm.fileExists(atPath: caseCredentials) {
            expectRejected("case variant of credential path") {
                _ = try CleanupPathSafety.capture(path: caseCredentials, root: home.path, home: home.path)
            }
        }
        let appleCache = home.appendingPathComponent("Library/Caches/com.apple.fixture")
        try fm.createDirectory(at: appleCache, withIntermediateDirectories: true)
        expectRejected("macOS managed cache") {
            _ = try CleanupPathSafety.capture(path: appleCache.path, root: home.path, home: home.path)
        }
        let dataAlias = "/System/Volumes/Data" + projectArtifact.path
        if fm.fileExists(atPath: dataAlias) {
            expectAllowed("verified Data volume alias") {
                _ = try CleanupPathSafety.capture(path: dataAlias, root: home.path, home: home.path)
            }
            expectRejected("protected path via Data volume alias") {
                _ = try CleanupPathSafety.capture(path: "/System/Volumes/Data" + credentialsArtifact.path,
                                                  root: home.path, home: home.path)
            }
        }

        let mediaArtifact = home.appendingPathComponent("Pictures/project/node_modules", isDirectory: true)
        try fm.createDirectory(at: mediaArtifact, withIntermediateDirectories: true)
        expectRejected("media protected root") {
            _ = try CleanupPathSafety.capture(path: mediaArtifact.path, root: home.path, home: home.path)
        }

        let sibling = base.appendingPathComponent("home-evil/project/node_modules", isDirectory: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        expectRejected("sibling prefix escape") {
            _ = try CleanupPathSafety.capture(path: sibling.path, root: home.path, home: home.path)
        }

        let outsideArtifact = outside.appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: outsideArtifact, withIntermediateDirectories: true)
        let ancestorLink = home.appendingPathComponent("linked-project", isDirectory: true)
        try fm.createSymbolicLink(atPath: ancestorLink.path, withDestinationPath: outside.path)
        expectRejected("symlink ancestor") {
            _ = try CleanupPathSafety.capture(
                path: ancestorLink.appendingPathComponent("node_modules").path,
                root: home.path,
                home: home.path
            )
        }
        expectRejected("symlink ancestor hidden by parent traversal") {
            _ = try CleanupPathSafety.capture(
                path: ancestorLink.appendingPathComponent("../work/node_modules").path,
                root: home.path,
                home: home.path
            )
        }
        let finalLink = home.appendingPathComponent("work/final-link", isDirectory: true)
        try fm.createSymbolicLink(atPath: finalLink.path, withDestinationPath: outsideArtifact.path)
        expectRejected("symlink final component") {
            _ = try CleanupPathSafety.capture(path: finalLink.path, root: home.path, home: home.path)
        }

        let replacePath = home.appendingPathComponent("work/replaced", isDirectory: true)
        try fm.createDirectory(at: replacePath, withIntermediateDirectories: true)
        let captured = try CleanupPathSafety.capture(path: replacePath.path, root: home.path, home: home.path)
        try fm.removeItem(at: replacePath)
        try fm.createDirectory(at: replacePath, withIntermediateDirectories: true)
        expectRejected("replaced target inode") { try captured.validate() }

        let replaceRoot = home.appendingPathComponent("scan-scope", isDirectory: true)
        let replaceRootTarget = replaceRoot.appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: replaceRootTarget, withIntermediateDirectories: true)
        let rootCaptured = try CleanupPathSafety.capture(
            path: replaceRootTarget.path, root: replaceRoot.path, home: home.path
        )
        try fm.removeItem(at: replaceRoot)
        try fm.createDirectory(at: replaceRootTarget, withIntermediateDirectories: true)
        expectRejected("replaced authorized root") { try rootCaptured.validate() }

        let rootAlias = home.appendingPathComponent(".").path
        expectRejected("authorized root itself") {
            _ = try CleanupPathSafety.capture(path: rootAlias, root: home.path, home: home.path)
        }

        let caseProject = home.appendingPathComponent("Documents/CaseProject", isDirectory: true)
        let caseArtifact = caseProject.appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: caseArtifact, withIntermediateDirectories: true)
        let caseVariant = home.appendingPathComponent("documents/caseproject/NODE_MODULES").path
        if fm.fileExists(atPath: caseVariant) {
            expectAllowed("case-insensitive policy") {
                _ = try CleanupPathSafety.capture(path: caseVariant, root: home.path, home: home.path)
            }
        }

        let chat = home.appendingPathComponent("Documents/Codex/2026-09-01/example")
        let outputs = chat.appendingPathComponent("outputs")
        try fm.createDirectory(at: outputs, withIntermediateDirectories: true)
        for path in [chat.path, outputs.path] {
            expectAllowed("Codex chat exception") {
                _ = try CleanupPathSafety.capture(path: path, root: home.path, home: home.path)
            }
            precondition(CleanupPathSafety.codexChat(path, home: home.path) == chat.path)
        }
        for relative in ["Documents", "Documents/Codex", "Documents/Codex/2026-09-01",
                         "Documents/Codex/not-a-date/example", "Documents/Other/2026-09-01/example"] {
            let path = home.appendingPathComponent(relative).path
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            expectRejected("Codex exception must not include its parents or neighboring folders") {
                _ = try CleanupPathSafety.capture(path: path, root: home.path, home: home.path)
            }
            precondition(CleanupPathSafety.codexChat(path, home: home.path) == nil)
        }
        let chatAlias = "/System/Volumes/Data" + outputs.path
        if fm.fileExists(atPath: chatAlias) {
            expectAllowed("Codex chat via verified Data alias") {
                _ = try CleanupPathSafety.capture(path: chatAlias, root: home.path, home: home.path)
            }
            precondition(CleanupPathSafety.codexChat(chatAlias, home: home.path) == chat.path)
        }
        try fm.createDirectory(at: chat.appendingPathComponent(".git"), withIntermediateDirectories: true)
        expectRejected("Codex exception must not override git protection") {
            _ = try CleanupPathSafety.capture(path: chat.path, root: home.path, home: home.path)
        }
        let chatLink = chat.appendingPathComponent("linked-output")
        try fm.createSymbolicLink(at: chatLink, withDestinationURL: outside)
        expectRejected("Codex exception must not override symlink protection") {
            _ = try CleanupPathSafety.capture(path: chatLink.path, root: home.path, home: home.path)
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
                _ = try CleanupPathSafety.capture(path: cloudArtifact.path, root: home.path, home: home.path)
            }
            _ = cloudArtifact.path.withCString { chflags($0, 0) }
        } else {
            print("SKIP cloud-only flag (filesystem denied chflags)")
        }

        print("PASS CleanupSafetyChecks")
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
