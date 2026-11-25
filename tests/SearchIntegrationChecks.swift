import Foundation

@main
struct SearchIntegrationChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.path
        guard let physical = realpath(temporary, nil) else { fatalError("cannot resolve temporary directory") }
        let temporaryURL = URL(fileURLWithPath: String(cString: physical))
        free(physical)
        let fixture = temporaryURL
            .appendingPathComponent("blitztree-search-\(UUID().uuidString)")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }

        let root = fixture.appendingPathComponent("scan_root").path
        func file(_ relative: String, bytes: Int) throws -> String {
            let path = root + "/" + relative
            let dir = (path as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: bytes).write(to: URL(fileURLWithPath: path))
            return path
        }

        let _ = try file("sub/alpha.txt", bytes: 10_000)
        let _ = try file("sub/beta.log", bytes: 50_000)
        let _ = try file("sub/gamma_big.dat", bytes: 500_000)
        let _ = try file("sub/DELTA_UPPER.bin", bytes: 20_000)
        let _ = try file("sub/café_accent.txt", bytes: 15_000)
        let _ = try file("sub/nested/file_pattern123.dat", bytes: 30_000)
        let _ = try file("sub/nested/file_pattern456.dat", bytes: 40_000)

        guard let handle = bz_scan_start(root) else { fatalError("fixture scan failed") }
        var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0, done: Int32 = 0
        while done == 0 {
            bz_progress(handle, &files, &dirs, &bytes, &done)
            if done == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard let tree = Tree(handle: handle) else {
            bz_free(handle)
            fatalError("fixture tree failed")
        }

        let (totalBeta, nodesBeta) = tree.search(query: "BETA", limit: 100)
        precondition(totalBeta == 1 && nodesBeta.count == 1, "query BETA should match 1 node")
        precondition(tree.name(nodesBeta[0]) == "beta.log", "matched name should be beta.log")

        let (totalAlpha, nodesAlpha) = tree.search(query: "alph", limit: 100)
        precondition(totalAlpha == 1 && nodesAlpha.count == 1)
        precondition(tree.name(nodesAlpha[0]) == "alpha.txt")

        let (totalDat, nodesDat) = tree.search(query: "*.dat", limit: 100)
        precondition(totalDat == 3 && nodesDat.count == 3, "expected 3 .dat files, got \(totalDat)")
        precondition(tree.name(nodesDat[0]) == "gamma_big.dat")
        precondition(tree.name(nodesDat[1]) == "file_pattern456.dat")
        precondition(tree.name(nodesDat[2]) == "file_pattern123.dat")
        precondition(tree.alloc[nodesDat[0]] >= tree.alloc[nodesDat[1]])
        precondition(tree.alloc[nodesDat[1]] >= tree.alloc[nodesDat[2]])

        let (totalQ, nodesQ) = tree.search(query: "?lpha.txt", limit: 100)
        precondition(totalQ == 1 && nodesQ.count == 1)
        precondition(tree.name(nodesQ[0]) == "alpha.txt")

        let (totalMulti, nodesMulti) = tree.search(query: "file_*456.*", limit: 100)
        precondition(totalMulti == 1 && nodesMulti.count == 1)
        precondition(tree.name(nodesMulti[0]) == "file_pattern456.dat")

        let (totalCafe, nodesCafe) = tree.search(query: "CAFÉ", limit: 100)
        precondition(totalCafe == 1 && nodesCafe.count == 1, "expected 1 match for CAFÉ")
        precondition(tree.name(nodesCafe[0]) == "café_accent.txt")

        let (totalCapped, nodesCapped) = tree.search(query: "*.dat", limit: 2)
        precondition(totalCapped == 3, "total count must carry true match count")
        precondition(nodesCapped.count == 2)
        precondition(nodesCapped[0] == nodesDat[0])
        precondition(nodesCapped[1] == nodesDat[1])

        let model = ScanModel()
        model.tree = tree
        model.searchQuery = "nested"
        for _ in 0..<50 {
            if !model.isSearching && !model.searchResults.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(model.searchTotalMatches >= 1)
        precondition(!model.searchResults.isEmpty)

        let targetNode = nodesDat[0]
        model.reveal(targetNode)
        precondition(model.selection == targetNode)
        precondition(model.viewRoot == 0)

        print("PASS: SearchIntegrationChecks (matcher, ranking, wildcards, unicode, model reveal)")
    }
}
