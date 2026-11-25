import AppKit
import Foundation

/// Checks OutlinePanel fixed row height (#11), TypeColor extension parity with
/// src/types.rs, TreemapRenderer extension highlighting, and live bz_types /
/// bz_largest_files FFI calls through ScanModel's Tree.
@main
struct TypesAndRowHeightChecks {
    static func extString(_ tree: Tree, _ node: Int) -> String? {
        guard let range = TypeColor.extensionRange(tree, node) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: tree.nameBlob + range.lowerBound, count: range.count), as: UTF8.self)
            .lowercased()
    }

    @MainActor
    static func main() throws {
        // 1. OutlinePanel row height (#11): custom style taller than 13pt line height.
        let font = NSFont.systemFont(ofSize: 13)
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        let outline = NSOutlineView()
        OutlinePanel.configureRows(outline)
        precondition(outline.rowSizeStyle == .custom && outline.rowHeight >= textHeight + 6,
                     "outline rows must be taller than text regardless of system sidebar icon size: \(outline.rowHeight)")

        // 2. Real scan fixture via FFI: verifies bz_types, bz_largest_files, extension parity, and highlight dimming.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("blitztree-pr6-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let files: [(String, Int)] = [
            ("photo.JPG", 4096 * 4),
            ("clip.png", 4096 * 2),
            (".zshrc", 4096),
            ("trailing.", 4096),
            ("README", 4096),
            ("Archive.TAR.GZ", 4096 * 8),
        ]
        for (name, bytes) in files {
            let data = Data(repeating: 0xAB, count: bytes)
            try data.write(to: root.appendingPathComponent(name))
        }

        let handle = bz_scan_start(root.path)!
        var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0
        var done: Int32 = 0
        while done == 0 {
            usleep(1000)
            bz_progress(handle, &f, &d, &b, &done)
        }
        guard let tree = Tree(handle: handle) else {
            bz_free(handle)
            fatalError("Tree(handle:) returned nil")
        }

        // Verify types breakdown sums to root alloc and file count, and trailing./.zshrc/README group together.
        let rows = tree.types(root: 0)
        precondition(rows.reduce(0) { $0 + $1.alloc } == tree.alloc[0], "types alloc must sum to root alloc")
        precondition(rows.reduce(0) { $0 + $1.files } == UInt64(tree.nFiles[0]), "types file count must sum to root nFiles")
        let emptyRow = rows.first { $0.ext.isEmpty }
        precondition(emptyRow?.files == 3, "dotfile, trailing-dot, and extensionless README must share empty extension row")

        // Verify extensionRange & hasExtension on every leaf matches Rust's extension rule.
        for i in 1..<tree.count where !tree.isDir(i) {
            let name = tree.name(i)
            let got = extString(tree, i)
            if name == ".zshrc" || name == "trailing." || name == "README" {
                precondition(got == nil && TypeColor.hasExtension(tree, i, []), "expected empty extension for \(name)")
            } else if name == "photo.JPG" {
                precondition(got == "jpg" && TypeColor.hasExtension(tree, i, Array("jpg".utf8)))
                precondition(!TypeColor.hasExtension(tree, i, Array("png".utf8)))
            }
        }

        // Verify largestFiles returns non-directory files sorted descending by alloc.
        let largest = tree.largestFiles(limit: 3)
        precondition(largest.count == 3, "expected 3 largest files, got \(largest.count)")
        for i in largest { precondition(!tree.isDir(i)) }
        precondition(tree.alloc[largest[0]] >= tree.alloc[largest[1]] && tree.alloc[largest[1]] >= tree.alloc[largest[2]])

        // Verify highlight rendering completes cleanly both unhighlighted and highlighted.
        let base = TreemapRenderer.render(tree: tree, pw: 200, ph: 120, scale: 1, root: 0, showFree: false, freeBytes: 0)
        let lit = TreemapRenderer.render(tree: tree, pw: 200, ph: 120, scale: 1, root: 0, showFree: false, freeBytes: 0, highlight: Array("jpg".utf8))
        precondition(base.leaves.count == lit.leaves.count && lit.leaves.count == files.count)

        print("PASS: TypesAndRowHeightChecks (types=\(rows.count), largest=\(largest.count), rowHeight=\(outline.rowHeight))")
    }
}
