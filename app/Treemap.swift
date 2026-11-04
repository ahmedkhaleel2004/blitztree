import AppKit
import os

/// One laid-out rectangle in the treemap.
nonisolated struct TMRect {
    var rect: CGRect
    var node: Int
    var isDir: Bool
}

/// A directory title strip: `strip` is the bar (text + hit target), `region`
/// the whole directory (hover boundary), both in view points.
nonisolated struct TMLabel {
    var strip: CGRect
    var region: CGRect
    var node: Int
    var depth: Int
    var name: String
}

/// Disjoint leaves occupy only a few nearby cells. Keep their original draw
/// order within each cell so the last matching leaf still wins at boundaries.
nonisolated struct TMLeafIndex {
    private static let cellSize: CGFloat = 32
    private var columns = 0
    private var rows = 0
    private var cells: [[Int]] = []

    init() {}

    init(leaves: [TMRect], size: CGSize) {
        guard !leaves.isEmpty, size.width > 0, size.height > 0 else { return }
        columns = max(1, Int(ceil(size.width / Self.cellSize)))
        rows = max(1, Int(ceil(size.height / Self.cellSize)))
        cells = Array(repeating: [], count: columns * rows)
        for (i, leaf) in leaves.enumerated() {
            let x0 = column(leaf.rect.minX), x1 = column(leaf.rect.maxX)
            let y0 = row(leaf.rect.minY), y1 = row(leaf.rect.maxY)
            for y in y0...y1 {
                for x in x0...x1 { cells[y * columns + x].append(i) }
            }
        }
    }

    private func column(_ x: CGFloat) -> Int {
        Int(min(CGFloat(columns - 1), max(0, floor(x / Self.cellSize))))
    }

    private func row(_ y: CGFloat) -> Int {
        Int(min(CGFloat(rows - 1), max(0, floor(y / Self.cellSize))))
    }

    func hit(_ point: CGPoint, leaves: [TMRect]) -> TMRect? {
        guard !cells.isEmpty, point.x.isFinite, point.y.isFinite else { return nil }
        for i in cells[row(point.y) * columns + column(point.x)].reversed() {
            if leaves[i].rect.contains(point) { return leaves[i] }
        }
        return nil
    }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk) over the flat tree.
nonisolated enum Squarify {
    typealias Item = (node: Int, size: Double)
    typealias Placed = (node: Int, rect: CGRect)

    /// The direct children of `dir` worth laying out, into a reused buffer.
    static func items(tree: Tree, dir: Int, into items: inout [Item]) {
        items.removeAll(keepingCapacity: true)
        for k in tree.children(dir) {
            let s = Double(tree.size[Int(k)])
            if s > 0 { items.append((Int(k), s)) }
        }
    }

    /// Core squarify over explicit (node, size) items, already sorted
    /// descending, appended to `out`. One level, no recursion. Synthetic
    /// nodes (negative ids) welcome. Children below ~half a pixel are
    /// dropped. Returns whether every rounded pixel in `rect` is painted by
    /// a tile that survives the renderer's half-pixel cutoff: only then may
    /// opaque children replace their parent's cushion without changing its
    /// pixels.
    @discardableResult
    static func layoutItems(_ items: [Item], rect: CGRect, into out: inout [Placed]) -> Bool {
        guard !items.isEmpty else { return false }
        let total = items.reduce(0.0) { $0 + $1.size }
        guard total > 0 else { return false }
        let scale = Double(rect.rawWidth * rect.rawHeight) / total

        var x = rect.rawMinX, y = rect.rawMinY
        var w = rect.rawWidth, h = rect.rawHeight
        var i = 0
        var covered = true

        while i < items.count {
            let side = Double(min(w, h))
            guard side >= 1 else { break }
            // Children are sorted descending: once areas drop below a quarter
            // pixel every remaining child is invisible too.
            if items[i].size * scale < 0.25 { break }

            // Grow a row until the worst aspect ratio would degrade.
            var rowMin = items[i].size * scale
            var rowMax = rowMin
            var rowSum = rowMin
            var rowEnd = i + 1
            var worst = worstRatio(sum: rowSum, minA: rowMin, maxA: rowMax, side: side)
            while rowEnd < items.count {
                let a = items[rowEnd].size * scale
                let newWorst = worstRatio(sum: rowSum + a, minA: min(rowMin, a), maxA: max(rowMax, a), side: side)
                if newWorst > worst { break }
                worst = newWorst
                rowSum += a
                rowMin = min(rowMin, a)
                rowMax = max(rowMax, a)
                rowEnd += 1
            }

            let thickness = CGFloat(rowSum) / min(w, h)
            var offset: CGFloat = 0
            var pixelEnd = (w < h ? x : y).rounded()
            for j in i..<rowEnd {
                let len = CGFloat(items[j].size * scale) / thickness
                let r: CGRect
                if w < h {
                    r = CGRect(x: x + offset, y: y, width: len, height: thickness)
                } else {
                    r = CGRect(x: x, y: y + offset, width: thickness, height: len)
                }
                // Check the actual rounded edges, rather than relying on
                // floating-point area sums to establish pixel coverage.
                let pixelStart = (w < h ? r.rawMinX : r.rawMinY).rounded()
                covered = covered && pixelStart == pixelEnd && r.rawWidth >= 0.5 && r.rawHeight >= 0.5
                pixelEnd = (w < h ? r.rawMaxX : r.rawMaxY).rounded()
                offset += len
                out.append((items[j].node, r))
            }
            covered = covered && pixelEnd == (w < h ? rect.rawMaxX : rect.rawMaxY).rounded()
            if w < h {
                y += thickness; h -= thickness
            } else {
                x += thickness; w -= thickness
            }
            i = rowEnd
            if w < 0.5 || h < 0.5 { break }
        }
        return covered && (x.rounded() >= rect.rawMaxX.rounded() || y.rounded() >= rect.rawMaxY.rounded())
    }

    private static func worstRatio(sum: Double, minA: Double, maxA: Double, side: Double) -> Double {
        let s2 = sum * sum
        let side2 = side * side
        return max(side2 * maxA / s2, s2 / (side2 * minA))
    }
}

/// Raw edges of a rect with positive size. CGRect's minX/width/… are
/// out-of-line CoreGraphics calls that standardize first, which showed up
/// in layout profiles; for positive sizes the arithmetic is the same.
nonisolated extension CGRect {
    fileprivate var rawMinX: CGFloat { origin.x }
    fileprivate var rawMinY: CGFloat { origin.y }
    fileprivate var rawMaxX: CGFloat { origin.x + size.width }
    fileprivate var rawMaxY: CGFloat { origin.y + size.height }
    fileprivate var rawWidth: CGFloat { size.width }
    fileprivate var rawHeight: CGFloat { size.height }
}

/// Per-extension colors as linear RGB triples for the cushion shader.
/// Vivid, WizTree-class saturation — the cushion shading supplies the depth.
nonisolated enum TypeColor {
    typealias RGB = (r: Double, g: Double, b: Double)

    private static func hsb(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> RGB {
        let c = NSColor(calibratedHue: h, saturation: s, brightness: v, alpha: 1)
            .usingColorSpace(.deviceRGB)!
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    static let fixed: [String: RGB] = {
        var m: [String: RGB] = [:]
        let groups: [([String], RGB)] = [
            (["mp4", "mov", "mkv", "avi", "webm", "m4v"], hsb(0.055, 0.78, 0.98)), // video: orange
            (["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "raw", "svg", "icns"], hsb(0.80, 0.55, 0.96)), // images: purple
            (["mp3", "m4a", "aac", "wav", "flac", "aiff"], hsb(0.34, 0.65, 0.88)), // audio: green
            (["zip", "tar", "gz", "xz", "7z", "rar", "dmg", "pkg", "ipa", "xip"], hsb(0.125, 0.72, 0.97)), // archives: amber
            (["dylib", "so", "framework", "bin", "exe", "o", "a", "metallib"], hsb(0.60, 0.62, 0.96)), // binaries: blue
            (["swift", "rs", "c", "h", "cpp", "m", "py", "js", "ts", "tsx", "jsx", "go", "java", "rb", "sh", "json", "yaml", "toml"], hsb(0.47, 0.60, 0.86)), // code: teal
            (["pdf", "doc", "docx", "txt", "md", "pages", "key", "ppt", "pptx", "xls", "xlsx", "csv"], hsb(0.57, 0.40, 0.92)), // docs: slate blue
            (["sst", "db", "sqlite", "sqlite3", "wal", "ldb", "mdb", "realm"], hsb(0.02, 0.55, 0.92)), // databases: coral
            (["plist", "log", "cache", "dat", "tmp"], hsb(0.10, 0.25, 0.80)), // system litter: tan
        ]
        for (exts, color) in groups { for e in exts { m[e] = color } }
        return m
    }()

    /// Extensionless files: warm neutral, clearly "a file", never void-grey.
    static let plain: RGB = hsb(0.09, 0.14, 0.82)
    /// Directory base (shows through where children are sub-pixel).
    /// Light neutral so dense regions read as texture, not holes.
    static let dir: RGB = hsb(0.58, 0.06, 0.66)
    /// Free-space block: flat near-background so it reads as absence.
    static let free: RGB = (0.155, 0.155, 0.175)
    /// Frame + title strip of a labeled directory (WizTree-style box).
    /// Flat-shaded, so pick the pre-lighting value for a ~#26262B result.
    static let strip: RGB = (0.165, 0.165, 0.195)

    /// Per-render colour lookup that reads extensions straight from the
    /// tree's name bytes: no String per file, one real lookup per extension.
    /// Starts from the extensions earlier renders met; `save()` adds this
    /// render's back.
    struct Cache {
        /// Up to 16 extension bytes, ASCII-lowercased, 8 per word. Names
        /// hold no zero bytes, so distinct extensions never share a key.
        struct Key: Hashable { var a: UInt64, b: UInt64 }

        private var byExt: [Key: RGB]
        /// Direct-mapped front for the dictionary: files next to each
        /// other mostly share a few extensions. The all-zero key is never one.
        private var recentKey = [Key](repeating: Key(a: 0, b: 0), count: 256)
        private var recentColor = [RGB](repeating: (0, 0, 0), count: 256)
        private static let known = OSAllocatedUnfairLock(initialState: [Key: RGB]())

        init() { byExt = Self.known.withLock { $0 } }

        func save() {
            Self.known.withLock { if $0.count < byExt.count { $0 = byExt } }
        }

        mutating func color(_ tree: Tree, _ node: Int) -> RGB {
            let start = Int(tree.nameOff[node]), end = Int(tree.nameOff[node + 1])
            var dot = end - 1
            while dot > start, tree.nameBlob[dot] != UInt8(ascii: ".") { dot -= 1 }
            // No extension, or a dotfile with nothing before the dot.
            guard dot > start else { return TypeColor.plain }
            let len = end - dot - 1
            guard len > 0, len <= 16 else { return TypeColor.forName(tree.name(node)) }
            var key = Key(a: 0, b: 0)
            for i in (dot + 1)..<end {
                var b = tree.nameBlob[i]
                if b >= 65, b <= 90 { b += 32 } // ASCII lowercase
                if i - dot <= 8 { key.a = key.a << 8 | UInt64(b) } else { key.b = key.b << 8 | UInt64(b) }
            }
            let slot = Int(truncatingIfNeeded: ((key.a ^ key.b &* 31) &* 0x9E37_79B9_7F4A_7C15) >> 56)
            if recentKey[slot] == key { return recentColor[slot] }
            let c: RGB
            if let known = byExt[key] {
                c = known
            } else {
                c = TypeColor.forName(tree.name(node))
                byExt[key] = c
            }
            recentKey[slot] = key
            recentColor[slot] = c
            return c
        }
    }

    /// The hash-fallback colours, built once (NSColor conversion is slow).
    private static let hashHues: [RGB] = (0..<360).map { hsb(CGFloat($0) / 360.0, 0.52, 0.90) }

    static func forName(_ name: String) -> RGB {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return plain }
        let ext = name[name.index(after: dot)...].lowercased()
        if ext.count > 10 { return plain }
        if let c = fixed[ext] { return c }
        // fallback: stable hash -> vivid hue
        var h: UInt32 = 2166136261
        for b in ext.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return hashHues[Int(h % 360)]
    }
}

// ---- WinDirStat-style cushion renderer ----
//
// Every node adds a parabolic ridge to an accumulated quadratic surface
//   z = ax2·x² + ax1·x + ay2·y² + ay1·y
// and leaves are shaded per pixel from the surface normal and a fixed
// light. Parents paint before children, so every pixel is always covered
// — no voids, and nesting reads through the compounded cushions exactly
// like WizTree/WinDirStat.
nonisolated enum TreemapRenderer {
    private struct Surface {
        var ax2 = 0.0, ax1 = 0.0, ay2 = 0.0, ay1 = 0.0

        mutating func addRidge(_ r: CGRect, height: Double) {
            let wx = Double(r.rawWidth), wy = Double(r.rawHeight)
            if wx > 0 {
                let h4 = 4 * height / (wx * wx)
                ax2 -= h4
                ax1 += h4 * Double(r.rawMinX + r.rawMaxX)
            }
            if wy > 0 {
                let h4 = 4 * height / (wy * wy)
                ay2 -= h4
                ay1 += h4 * Double(r.rawMinY + r.rawMaxY)
            }
        }
    }

    private enum Cushion {
        static let baseHeight = 0.55   // ridge height at the top level
        static let falloff = 0.72      // height multiplier per depth
        static let ambient = 0.38
        // Light from the top-left, mostly overhead.
        static let lx = -0.408, ly = -0.408, lz = 0.816

        /// Ridge height proportional to rect size so big tiles still curve.
        static func height(_ r: CGRect, _ h: Double) -> Double {
            h * Double(min(r.rawWidth, r.rawHeight))
        }
    }

    struct Result {
        var image: CGImage
        var rects: [TMRect]
        var leaves: [TMRect]
        var labels: [TMLabel]
        var steps: Int, bands: Int
        var layoutMs: Double, paintMs: Double
    }

    static func render(tree: Tree, pw: Int, ph: Int, scale: CGFloat, root rootIndex: Int,
                       showFree: Bool, freeBytes: UInt64) -> Result {
        // Lay it out once, then paint horizontal bands on every core; each
        // band runs the same steps in the same order over its own rows only,
        // so the result is pixel-identical to a single pass.
        let started = Date()
        var layout = Layout(tree: tree, pw: pw, ph: ph, scale: scale, showFree: showFree, freeBytes: freeBytes)
        layout.draw(rootIndex, CGRect(x: 0, y: 0, width: pw, height: ph), Cushion.baseHeight, Surface(), 0)
        layout.colors.save()
        let ops = layout.ops, shades = layout.shades
        let laidOut = Date()
        // Every band writes each of its pixels once, so no clearing first;
        // the image takes the buffer over without a copy.
        let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: pw * ph)
        let bands = max(1, min(ProcessInfo.processInfo.activeProcessorCount * 3, ph / 32))
        ops.withUnsafeBufferPointer { ops in
            shades.withUnsafeBufferPointer { shades in
                nonisolated(unsafe) let ops = ops, shades = shades, base = pixels
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    Self.paint(ops, shades, base: base, pw: pw,
                               rows: (ph * band / bands)..<(ph * (band + 1) / bands))
                }
            }
        }
        let provider = CGDataProvider(dataInfo: nil, data: pixels, size: pw * ph * 4) { _, data, _ in
            data.deallocate()
        }!
        let image = CGImage(
            width: pw, height: ph,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return Result(image: image, rects: layout.rects, leaves: layout.leaves, labels: layout.labels,
                      steps: ops.count, bands: bands,
                      layoutMs: laidOut.timeIntervalSince(started) * 1000,
                      paintMs: -laidOut.timeIntervalSinceNow * 1000)
    }

    /// One step of the cushion painter, in paint order, with its pixel
    /// bounds rounded and clipped once at layout time.
    private struct PaintOp {
        var x0: Int32, y0: Int32, x1: Int32, y1: Int32
        /// 0: shade with `shades[arg]`. Otherwise darken a frame band this
        /// many pixels thick around the bounds by `frameFactors[arg]`.
        var thickness: Int32, arg: Int32
    }

    private struct Shade {
        var rgb: TypeColor.RGB
        var s: Surface
    }

    private static let frameFactors = [0.30, 0.42, 0.55, 0.62]

    /// Lays the treemap out once, in paint order: parents before children,
    /// frames after their contents, plus the geometry used for hit-testing
    /// and labels. A struct recursing through mutating methods: as a nested
    /// function, every captured var paid a dynamic exclusivity check.
    private struct Layout {
        let tree: Tree
        let pw: Int, ph: Int, scale: CGFloat
        let showFree: Bool, freeBytes: UInt64
        var ops: [PaintOp] = []
        var shades: [Shade] = []
        var rects: [TMRect] = []
        var leaves: [TMRect] = []
        var labels: [TMLabel] = []
        var colors = TypeColor.Cache()
        // Reused per directory instead of two fresh arrays each: `placed`
        // is a stack, each level's children above its parent's.
        var items: [Squarify.Item] = []
        var placed: [Squarify.Placed] = []

        init(tree: Tree, pw: Int, ph: Int, scale: CGFloat, showFree: Bool, freeBytes: UInt64) {
            self.tree = tree
            self.pw = pw; self.ph = ph; self.scale = scale
            self.showFree = showFree; self.freeBytes = freeBytes
            // Room for a typical dense map up front: regrowing these while
            // appending was ~8% of layout.
            let expected = min(tree.count, 1 << 18)
            ops.reserveCapacity(expected)
            shades.reserveCapacity(expected)
            leaves.reserveCapacity(expected)
            rects.reserveCapacity(expected / 4)
        }

        private func bounds(_ r: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
            (max(0, Int(r.rawMinX.rounded())), max(0, Int(r.rawMinY.rounded())),
             min(pw, Int(r.rawMaxX.rounded())), min(ph, Int(r.rawMaxY.rounded())))
        }

        private mutating func shade(_ r: CGRect, _ rgb: TypeColor.RGB, _ s: Surface) {
            let b = bounds(r)
            guard b.x1 > b.x0, b.y1 > b.y0 else { return }
            ops.append(PaintOp(x0: Int32(b.x0), y0: Int32(b.y0), x1: Int32(b.x1), y1: Int32(b.y1),
                               thickness: 0, arg: Int32(shades.count)))
            shades.append(Shade(rgb: rgb, s: s))
        }

        private mutating func frame(_ r: CGRect, _ thickness: Int, _ factor: Int) {
            let b = bounds(r)
            guard thickness > 0, b.x1 - b.x0 > thickness * 2 + 2, b.y1 - b.y0 > thickness * 2 + 2 else { return }
            ops.append(PaintOp(x0: Int32(b.x0), y0: Int32(b.y0), x1: Int32(b.x1), y1: Int32(b.y1),
                               thickness: Int32(thickness), arg: Int32(factor)))
        }

        private func points(_ r: CGRect) -> CGRect {
            CGRect(x: r.rawMinX / scale, y: r.rawMinY / scale,
                   width: r.rawWidth / scale, height: r.rawHeight / scale)
        }

        mutating func draw(_ node: Int, _ rect: CGRect, _ h: Double, _ surface: Surface, _ depth: Int) {
            guard rect.rawWidth >= 0.5, rect.rawHeight >= 0.5 else { return }
            var s = surface
            // The view root adds no ridge: a window-wide parabola would
            // just vignette the whole map.
            if depth > 0 {
                s.addRidge(rect, height: Cushion.height(rect, h))
            }
            let ptRect = points(rect)
            guard tree.isDir(node) else {
                leaves.append(TMRect(rect: ptRect, node: node, isDir: false))
                shade(rect, colors.color(tree, node), s)
                return
            }
            rects.append(TMRect(rect: ptRect, node: node, isDir: true))

            // WizTree-style framed box: big directories get a title
            // strip on their top border and children render inside
            // the frame — at every depth, no zooming required.
            let headerH = (15 * scale).rounded()
            let headed = depth >= 1
                && rect.rawWidth >= 88 * scale
                && rect.rawHeight >= max(58 * scale, headerH * 2.8)
            var content = rect
            var layoutNode = node
            if headed {
                // Collapse pass-through chains (a dir whose one child
                // holds ~everything) into a single "A ▸ B" strip.
                var stripName = tree.name(node)
                while let first = tree.children(layoutNode).first {
                    let fi = Int(first)
                    guard tree.isDir(fi),
                          Double(tree.size[fi]) >= 0.99 * Double(max(tree.size[layoutNode], 1))
                    else { break }
                    stripName += "  ▸  " + tree.name(fi)
                    layoutNode = fi
                }
                shade(rect, TypeColor.strip, Surface())
                let strip = CGRect(x: rect.rawMinX, y: rect.rawMinY,
                                   width: rect.rawWidth, height: headerH)
                labels.append(TMLabel(strip: points(strip), region: ptRect,
                                      node: layoutNode, depth: depth, name: stripName))
                content = CGRect(x: rect.rawMinX + 2, y: rect.rawMinY + headerH,
                                 width: rect.rawWidth - 4, height: rect.rawHeight - headerH - 2)
            }

            // Parent cushion first wherever child tiles leave rounded pixels
            // uncovered (sub-pixel children, pixel-snap slivers), so the map
            // has no holes. Fully covered parents need no shading.
            if content.rawWidth >= 3, content.rawHeight >= 3 {
                Squarify.items(tree: tree, dir: layoutNode, into: &items)
                if depth == 0, showFree, freeBytes > 0 {
                    // Free disk space competes for area like a file.
                    items.append((-1, Double(freeBytes)))
                    items.sort { $0.size > $1.size }
                }
                let from = placed.count
                if !Squarify.layoutItems(items, rect: content, into: &placed) {
                    shade(content, TypeColor.dir, s)
                }
                let to = placed.count
                for i in from..<to {
                    let (kid, r) = placed[i]
                    if kid == -1 {
                        // Flat, quiet void — clearly "nothing here".
                        shade(r, TypeColor.free, Surface())
                        let pr = points(r)
                        if pr.width >= 90, pr.height >= 30 {
                            labels.append(TMLabel(strip: pr, region: pr, node: -1, depth: 1, name: "Free space"))
                        }
                    } else {
                        draw(kid, r, depth == 0 ? h : h * Cushion.falloff, s, depth + 1)
                    }
                }
                placed.removeLast(to - from)
            } else {
                shade(content, TypeColor.dir, s)
            }
            // Separation frames for unheaded dirs (headed ones have
            // their own frame already).
            if !headed {
                switch depth {
                case 0: break // window edge needs no frame
                case 1: frame(rect, Int(2 * scale), 0) // frameFactors[0] = 0.30
                case 2: frame(rect, Int(scale), 1)
                case 3: frame(rect, max(1, Int(scale / 2)), 2)
                default:
                    if rect.rawWidth > 28, rect.rawHeight > 28 {
                        frame(rect, 1, 3)
                    }
                }
            }
        }
    }

    /// Runs the paint steps for pixel rows in `rows` only. Steps are applied
    /// in order, so any split into bands gives the same pixels as one pass.
    ///
    /// A step repaints everything under it, so only the last shade step
    /// over a pixel shows: find that owner per pixel first (cheap integer
    /// fills), then run the cushion shader once per pixel instead of once
    /// per nesting level, then darken frame pixels no later shade covered.
    private static func paint(
        _ ops: UnsafeBufferPointer<PaintOp>, _ shades: UnsafeBufferPointer<Shade>,
        base: UnsafeMutablePointer<UInt32>, pw: Int, rows: Range<Int>
    ) {
        let by0 = rows.lowerBound, by1 = rows.upperBound
        let owner = UnsafeMutablePointer<Int32>.allocate(capacity: (by1 - by0) * pw)
        defer { owner.deallocate() }
        owner.initialize(repeating: -1, count: (by1 - by0) * pw)
        var frames: [Int] = []
        for i in 0..<ops.count {
            let op = ops[i]
            guard Int(op.y1) > by0, Int(op.y0) < by1 else { continue }
            guard op.thickness == 0 else { frames.append(i); continue }
            let x0 = Int(op.x0), n = Int(op.x1) - x0
            for py in max(by0, Int(op.y0))..<min(by1, Int(op.y1)) {
                (owner + (py - by0) * pw + x0).update(repeating: Int32(i), count: n)
            }
        }

        for py in by0..<by1 {
            let own = owner + (py - by0) * pw, row = base + py * pw
            var px = 0
            while px < pw {
                let k = own[px]
                var end = px + 1
                while end < pw, own[end] == k { end += 1 }
                if k < 0 {
                    (row + px).update(repeating: 0xFF16_1616, count: end - px)
                } else {
                    shadeRun(row, px..<end, py, shades[Int(ops[Int(k)].arg)])
                }
                px = end
            }
        }

        /// Separation "grout" between directories. Multiplies what's
        /// underneath so hues survive.
        for i in frames {
            let op = ops[i], thickness = Int(op.thickness), f = Int32(i)
            let factor = frameFactors[Int(op.arg)]
            let x0 = Int(op.x0), x1 = Int(op.x1), y0 = Int(op.y0), y1 = Int(op.y1)
            func darken(_ px: Int, _ py: Int) {
                guard own(px, py) < f else { return } // a later step painted over it
                let p = base + py * pw + px
                let v = p.pointee
                let r8 = UInt32(Double(v & 0xFF) * factor)
                let g8 = UInt32(Double((v >> 8) & 0xFF) * factor)
                let b8 = UInt32(Double((v >> 16) & 0xFF) * factor)
                p.pointee = 0xFF00_0000 | (b8 << 16) | (g8 << 8) | r8
            }
            func own(_ px: Int, _ py: Int) -> Int32 { owner[(py - by0) * pw + px] }
            for t in 0..<thickness {
                if (by0..<by1).contains(y0 + t) { for px in x0..<x1 { darken(px, y0 + t) } }
                if (by0..<by1).contains(y1 - 1 - t) { for px in x0..<x1 { darken(px, y1 - 1 - t) } }
                let v0 = max(y0 + thickness, by0), v1 = min(y1 - thickness, by1)
                if v1 > v0 {
                    for py in v0..<v1 {
                        darken(x0 + t, py)
                        darken(x1 - 1 - t, py)
                    }
                }
            }
        }
    }

    /// `UInt32(x)` for 0 ≤ x ≤ 255, four at a time: floor, then read the
    /// integer out of the mantissa (x + 2⁵² is exact). Swift's generic
    /// SIMD float-to-int conversion compiled to a slow scalar loop.
    @inline(__always)
    private static func byte(_ x: SIMD4<Double>) -> SIMD4<UInt32> {
        let biased = x.rounded(.down) + SIMD4(repeating: 4_503_599_627_370_496.0)
        return SIMD4<UInt32>(truncatingIfNeeded: unsafeBitCast(biased, to: SIMD4<UInt64>.self))
    }

    /// The cushion shader over one run of pixels in row `py`.
    @inline(__always)
    private static func shadeRun(_ row: UnsafeMutablePointer<UInt32>, _ xs: Range<Int>, _ py: Int,
                                 _ shade: Shade, flat: Bool = true) {
        let s = shade.s, rgb = shade.rgb
        // Root backgrounds, title strips and free space have a constant
        // normal: shade the run's first pixel, then fill.
        if flat, s.ax2 == 0, s.ay2 == 0 {
            shadeRun(row, xs.lowerBound..<(xs.lowerBound + 1), py, shade, flat: false)
            (row + xs.lowerBound + 1).update(repeating: row[xs.lowerBound], count: xs.count - 1)
            return
        }
        let fy = Double(py) + 0.5
        let ny = -(2 * s.ay2 * fy + s.ay1)
        // Four pixels at a time, same operations in the same order as the
        // scalar tail below (sqrt and divide round exactly), so the same bits.
        typealias V = SIMD4<Double>
        let ax2x2 = V(repeating: 2 * s.ax2), ax1 = V(repeating: s.ax1)
        let nyly = V(repeating: ny * Cushion.ly), ny2 = V(repeating: ny * ny)
        let lx = V(repeating: Cushion.lx), lz = V(repeating: Cushion.lz), one = V(repeating: 1)
        let ambient = V(repeating: Cushion.ambient), diffuse = V(repeating: 1 - Cushion.ambient)
        let r = V(repeating: rgb.r), g = V(repeating: rgb.g), b = V(repeating: rgb.b)
        let v255 = V(repeating: 255), zero = V(repeating: 0)
        var px = xs.lowerBound
        while px + 4 <= xs.upperBound {
            let fx = V(Double(px), Double(px + 1), Double(px + 2), Double(px + 3)) + 0.5
            let nx = -(ax2x2 * fx + ax1)
            let cos = (nx * lx + nyly + lz) / (nx * nx + ny2 + one).squareRoot()
            let lum = ambient + pointwiseMax(zero, cos) * diffuse
            let r8 = byte(pointwiseMin(v255, r * lum * v255))
            let g8 = byte(pointwiseMin(v255, g * lum * v255))
            let b8 = byte(pointwiseMin(v255, b * lum * v255))
            let out = 0xFF00_0000 | (b8 &<< 16) | (g8 &<< 8) | r8
            UnsafeMutableRawPointer(row + px).storeBytes(of: out, as: SIMD4<UInt32>.self)
            px += 4
        }
        for px in px..<xs.upperBound {
            let fx = Double(px) + 0.5
            let nx = -(2 * s.ax2 * fx + s.ax1)
            let cos = (nx * Cushion.lx + ny * Cushion.ly + Cushion.lz)
                / (nx * nx + ny * ny + 1).squareRoot()
            let lum = Cushion.ambient + max(0, cos) * (1 - Cushion.ambient)
            let r8 = UInt32(min(255, rgb.r * lum * 255))
            let g8 = UInt32(min(255, rgb.g * lum * 255))
            let b8 = UInt32(min(255, rgb.b * lum * 255))
            (row + px).pointee = 0xFF00_0000 | (b8 << 16) | (g8 << 8) | r8
        }
    }
}
