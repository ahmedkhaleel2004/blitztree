import Foundation

/// The Scan menu's volume list and the free space shown after scanning a volume.
/// Attaches two small disk images under a disposable folder (never /Volumes)
/// and detaches them on exit.
@main
struct VolumeChecks {
    static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "hdiutil \(arguments.joined(separator: " ")) failed")
    }

    @MainActor
    static func main() async throws {
        // Rules on plain values: hidden and network mounts are left out, `/`
        // scans the Data volume, and a zero important-usage figure is not free space.
        precondition(ScanVolume(.init(path: "/System/Volumes/VM", name: "VM", isBrowsable: false)) == nil,
                     "hidden volumes must not be listed")
        precondition(ScanVolume(.init(path: "/Volumes/share", name: "share", isLocal: false)) == nil,
                     "network volumes must not be listed")
        let root = ScanVolume(.init(path: "/", name: "Renamed Disk", isRootFileSystem: true,
                                    total: 1_000, available: 300, availableForImportantUsage: 400))
        precondition(root?.path == "/System/Volumes/Data" && root?.isInternal == true,
                     "the boot volume must scan its Data volume")
        precondition(root?.free == 400 && root?.used == 600, "APFS free space includes purgeable space")
        let exfat = ScanVolume(.init(path: "/Volumes/Card", name: "Card", total: 1_000, available: 700,
                                     availableForImportantUsage: 0))
        precondition(exfat?.free == 700 && exfat?.used == 300 && exfat?.isInternal == false,
                     "a zero important-usage figure must fall back to the plain free count")
        precondition(VolumeSpace.free(important: 0, available: 700) == 700)
        precondition(VolumeSpace.free(important: nil, available: nil) == nil)
        precondition(VolumeSpace.free(important: 5, available: nil) == 5)

        // Real mounts.
        let fm = FileManager.default
        guard let physical = realpath(fm.temporaryDirectory.path, nil) else { fatalError("cannot resolve temporary directory") }
        let fixture = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("blitztree-volumes-\(UUID().uuidString)")
        free(physical)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        // exFAT labels hold at most 11 characters.
        let tag = String(UUID().uuidString.prefix(6))
        let shown = "BZS\(tag)", hidden = "BZH\(tag)"
        var mounted: [String] = []
        defer {
            for point in mounted { try? hdiutil(["detach", point, "-force", "-quiet"]) }
            try? fm.removeItem(at: fixture)
        }
        let shownImage = fixture.appendingPathComponent("shown.dmg").path
        let hiddenImage = fixture.appendingPathComponent("hidden.dmg").path
        try hdiutil(["create", "-quiet", "-size", "40m", "-fs", "ExFAT", "-volname", shown, shownImage])
        try hdiutil(["create", "-quiet", "-size", "40m", "-fs", "ExFAT", "-volname", hidden, hiddenImage])
        try hdiutil(["attach", "-quiet", "-mountroot", fixture.path, shownImage])
        mounted.append(fixture.appendingPathComponent(shown).path)
        try hdiutil(["attach", "-quiet", "-nobrowse", "-mountroot", fixture.path, hiddenImage])
        mounted.append(fixture.appendingPathComponent(hidden).path)

        let volumes = ScanVolume.mounted()
        precondition(volumes.first?.path == "/System/Volumes/Data", "Macintosh HD must lead the list")
        precondition(volumes.allSatisfy { !$0.path.hasPrefix("/System/Volumes/") || $0.path == "/System/Volumes/Data" },
                     "system volumes must not be listed: \(volumes.map(\.path))")
        precondition(!volumes.contains { $0.path == "/" }, "the sealed system volume must not be listed")
        precondition(!volumes.contains { $0.name == hidden }, "a nobrowse mount must not be listed")
        guard let card = volumes.first(where: { $0.name == shown }) else {
            fatalError("mounted exFAT volume missing from \(volumes.map(\.name))")
        }
        precondition(card.path == mounted[0], "the volume must scan its own root, got \(card.path)")
        precondition(card.total > 30_000_000 && card.free > 30_000_000 && card.used < card.total,
                     "exFAT capacity: total \(card.total), free \(card.free)")

        // What the status bar and the free-space tile read after scanning it.
        let space = VolumeSpace.read(card.path)
        precondition((space.free ?? 0) > 30_000_000, "exFAT free space after scanning: \(String(describing: space.free))")

        print("PASS: VolumeChecks (\(volumes.count) volumes listed, exFAT free \(Fmt.size(card.free)))")
    }
}
