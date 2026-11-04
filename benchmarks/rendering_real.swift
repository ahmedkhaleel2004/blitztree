import AppKit
import Foundation

// Treemap before/after on real scans: rendering.py --real FOLDER compiles the
// baseline's Treemap*.swift (renamed Legacy*) next to the whole current app,
// scans each folder once with the Rust engine, then for each case checks the
// two bitmaps and all hit-test geometry are identical and times both in
// alternating pairs. Per mouse move, it also replays hover and selection
// changes: the baseline redraws the whole view each time, the candidate only
// the rects it invalidates, into a persistent context that must stay equal.

let renderingScale: CGFloat = 2

@main struct RealRenderingBench {
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    static func stat(_ v: [Double]) -> String {
        let s = v.sorted()
        return String(format: "%8.2f [%6.2f-%7.2f]", s[s.count / 2], s[0], s[s.count - 1])
    }

    static func pixels(_ image: CGImage?) -> Data {
        guard let data = image?.dataProvider?.data else { fatalError("missing bitmap") }
        return data as Data
    }

    static func fnv(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { raw in
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in raw { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            return h
        }
    }

    /// The baseline's render as its view runs it, split into layout and paint.
    static func legacyRender(_ tree: Tree, pw: Int, ph: Int, root: Int, free: Bool,
                             freeBytes: UInt64) -> (layout: Double, paint: Double) {
        // BASELINE-RENDER-BEGIN
        let t0 = now()
        let out = LegacyTreemapNSView.RenderOutput()
        let ops = LegacyTreemapNSView.layoutOps(tree: tree, pw: pw, ph: ph, scale: 2, root: root,
                                                showFree: free, freeBytes: freeBytes, out: out)
        let t1 = now()
        var pixels = [UInt32](repeating: 0xFF16_1616, count: pw * ph)
        let bands = max(1, min(ProcessInfo.processInfo.activeProcessorCount * 3, ph / 32))
        ops.withUnsafeBufferPointer { ops in
            pixels.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let operations = ops
                nonisolated(unsafe) let base = buffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    LegacyTreemapNSView.paint(operations, base: base, pw: pw, ph: ph,
                                              rows: (ph * band / bands)..<(ph * (band + 1) / bands))
                }
            }
        }
        return (t1 - t0, now() - t1)
        // BASELINE-RENDER-END
    }

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        let checkOnly = args.contains("--check-only")
        args.removeAll { $0 == "--check-only" }
        var iterations = 11
        if let i = args.firstIndex(of: "--iterations") {
            iterations = Int(args[i + 1])!
            args.removeSubrange(i...(i + 1))
        }
        var allSame = true
        for path in args {
            let t0 = now()
            let handle = bz_scan_start(path)!
            var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0, done: Int32 = 0
            repeat { usleep(5000); bz_progress(handle, &f, &d, &b, &done) } while done == 0
            let tree = Tree(handle: handle)!
            print(String(format: "scan %@: %d nodes in %.2f s", path, tree.count, (now() - t0) / 1000))
            allSame = compare(tree, iterations: checkOnly ? 0 : iterations) && allSame
            allSame = interaction(tree, timed: !checkOnly) && allSame
        }
        print(allSame ? "PASS: real-scan treemaps identical to the baseline" : "FAIL: output differs")
        exit(allSame ? 0 : 1)
    }

    /// Bitmaps and geometry at each size, then alternating timing pairs.
    static func compare(_ tree: Tree, iterations: Int) -> Bool {
        // Largest child directory: the zoomed-in case.
        let zoom = tree.children(0).map(Int.init).filter { tree.isDir($0) }
            .max { tree.size[$0] < tree.size[$1] } ?? 0
        let freeBytes = tree.size[0] / 3
        let cases: [(String, CGSize, Int, Bool)] = [
            ("3200x2000", CGSize(width: 1600, height: 1000), 0, false),
            ("1600x1600", CGSize(width: 800, height: 800), 0, false),
            ("3200x2000 zoomed", CGSize(width: 1600, height: 1000), zoom, false),
            ("3200x2000 free space", CGSize(width: 1600, height: 1000), 0, true),
        ]
        var same = true
        for (name, size, root, free) in cases {
            let oldModel = ScanModel(), newModel = ScanModel()
            for m in [oldModel, newModel] {
                m.tree = tree; m.viewRoot = root; m.freeBytes = freeBytes; m.showFreeSpace = free
            }
            let frame = CGRect(origin: .zero, size: size)
            let old = LegacyTreemapNSView(frame: frame), new = TreemapNSView(frame: frame)
            old.model = oldModel; new.model = newModel
            let a = pixels(old.bitmap), b = pixels(new.bitmap)
            var geometry = old.leaves.count == new.leaves.count && old.rects.count == new.rects.count
                && old.labels.count == new.labels.count
            for (x, y) in zip(old.leaves, new.leaves) where x.rect != y.rect || x.node != y.node { geometry = false }
            for (x, y) in zip(old.rects, new.rects) where x.rect != y.rect || x.node != y.node { geometry = false }
            for (x, y) in zip(old.labels, new.labels)
                where x.strip != y.strip || x.region != y.region || x.node != y.node || x.name != y.name { geometry = false }
            let ok = a == b && geometry
            same = same && ok
            print(String(format: "%@: bitmap %016llx vs %016llx, geometry %@ -> %@ [%d files, %d labels]",
                         name, fnv(a), fnv(b), geometry ? "same" : "DIFFERS", ok ? "IDENTICAL" : "DIFFERENT",
                         new.leaves.count, new.labels.count))
            guard iterations > 0 else { continue }
            let pw = Int(size.width * 2), ph = Int(size.height * 2)
            var ol: [Double] = [], op: [Double] = [], ot: [Double] = []
            var nl: [Double] = [], np: [Double] = [], nt: [Double] = []
            func runOld() {
                let r = legacyRender(tree, pw: pw, ph: ph, root: root, free: free, freeBytes: freeBytes)
                ol.append(r.layout); op.append(r.paint)
                let s = now(); old.relayout(); _ = old.hit(.zero); ot.append(now() - s)
            }
            func runNew() {
                let r = TreemapRenderer.render(tree: tree, pw: pw, ph: ph, scale: 2, root: root,
                                               showFree: free, freeBytes: freeBytes)
                nl.append(r.layoutMs); np.append(r.paintMs)
                let s = now(); new.relayout(); _ = new.hit(.zero); nt.append(now() - s)
            }
            for i in 0..<iterations {
                if i % 2 == 0 { runOld(); runNew() } else { runNew(); runOld() }
            }
            print("            layout                paint                 total (view relayout + leaf index)")
            print("  baseline " + stat(ol) + stat(op) + stat(ot))
            print("  candidate" + stat(nl) + stat(np) + stat(nt))
        }
        return same
    }

    /// Mouse moves, selection and agent highlights at 1600x1000 pt @2x.
    static func interaction(_ tree: Tree, timed: Bool) -> Bool {
        let size = CGSize(width: 1600, height: 1000)
        let oldModel = ScanModel(), newModel = ScanModel()
        oldModel.tree = tree; newModel.tree = tree
        let old = LegacyTreemapNSView(frame: CGRect(origin: .zero, size: size))
        let new = TreemapNSView(frame: CGRect(origin: .zero, size: size))
        old.model = oldModel; new.model = newModel

        func context() -> (CGContext, NSGraphicsContext) {
            let ctx = CGContext(data: nil, width: 3200, height: 2000, bitsPerComponent: 8, bytesPerRow: 3200 * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            ctx.translateBy(x: 0, y: 2000)
            ctx.scaleBy(x: 2, y: -2)
            return (ctx, NSGraphicsContext(cgContext: ctx, flipped: true))
        }
        let (octx, ons) = context(), (nctx, nns) = context()
        func equal() -> Bool { memcmp(octx.data!, nctx.data!, 3200 * 2000 * 4) == 0 }
        func fullDraw(_ v: NSView, _ ns: NSGraphicsContext) {
            NSGraphicsContext.current = ns
            v.draw(v.bounds)
        }
        /// Like AppKit: one pass clipped to the damaged region in whole
        /// device pixels, handed the union as the dirty rect.
        func partialDraw(_ rects: [CGRect]) {
            guard !rects.isEmpty else { return }
            NSGraphicsContext.current = nns
            let snapped = rects.map { r in
                let x0 = (r.minX * 2).rounded(.down), y0 = (r.minY * 2).rounded(.down)
                return CGRect(x: x0 / 2, y: y0 / 2, width: ((r.maxX * 2).rounded(.up) - x0) / 2,
                              height: ((r.maxY * 2).rounded(.up) - y0) / 2)
            }
            nctx.saveGState()
            nctx.clip(to: snapped)
            new.draw(snapped.dropFirst().reduce(snapped[0]) { $0.union($1) })
            nctx.restoreGState()
        }
        /// The baseline has no point-based hover entry: send it a real event.
        func oldMove(_ p: CGPoint) {
            let loc = old.convert(p, to: nil)
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: loc, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            old.mouseMoved(with: event)
        }
        precondition(old.convert(old.convert(CGPoint(x: 10, y: 20), to: nil), from: nil) == CGPoint(x: 10, y: 20))

        fullDraw(old, ons); fullDraw(new, nns)
        var ok = equal()
        var rng: UInt64 = 42
        func next() -> CGFloat {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(rng >> 11) / CGFloat(1 << 53)
        }
        let dirs = tree.children(0).map(Int.init).filter { tree.isDir($0) }
            .flatMap { d in [d] + tree.children(d).map(Int.init).filter { tree.isDir($0) } }
        var oh: [Double] = [], nh: [Double] = [], od: [Double] = [], nd: [Double] = []
        var mismatches = 0, differ = 0, area = 0.0
        var p = CGPoint(x: size.width / 2, y: size.height / 2)
        let moves = 300
        for i in 0..<moves {
            // Sweep like a mouse (small steps) with occasional jumps.
            p = i % 25 == 0 ? CGPoint(x: next() * size.width, y: next() * size.height)
                : CGPoint(x: min(size.width - 1, max(0, p.x + (next() - 0.5) * 40)),
                          y: min(size.height - 1, max(0, p.y + (next() - 0.5) * 40)))
            if i % 30 == 29, !dirs.isEmpty {
                let s = dirs[Int(next() * CGFloat(dirs.count))]
                oldModel.selection = s; newModel.selection = s
            }
            var s = now(); oldMove(p); oh.append(now() - s)
            s = now(); fullDraw(old, ons); od.append(now() - s)
            s = now(); var dirty = new.hover(at: p); nh.append(now() - s)
            dirty += new.syncOverlay() // the selection change, as updateNSView does
            area += dirty.reduce(0) { $0 + $1.width * $1.height }
            s = now(); partialDraw(dirty); nd.append(now() - s)
            if oldModel.hovered != newModel.hovered { mismatches += 1 }
            if !equal() { differ += 1 }
        }
        print(String(format: "interaction 1600x1000 pt @2x: %d moves, %d hover mismatches, %d frames differ, dirty area %.2f%% per move",
                     moves, mismatches, differ, 100 * area / Double(moves) / (size.width * size.height)))
        if timed {
            print("            hit test per move     redraw per move")
            print("  baseline " + stat(oh) + stat(od))
            print("  candidate" + stat(nh) + stat(nd))
        }
        ok = ok && mismatches == 0 && differ == 0

        // Agent highlights: a full redraw when they change, then hovering.
        let lit = Array(dirs.prefix(3))
        old.highlights = lit; new.highlights = lit
        fullDraw(old, ons); fullDraw(new, nns)
        var litDiffer = equal() ? 0 : 1
        for _ in 0..<50 {
            let q = CGPoint(x: next() * size.width, y: next() * size.height)
            oldMove(q); fullDraw(old, ons)
            partialDraw(new.hover(at: q))
            if !equal() { litDiffer += 1 }
        }
        print("with highlights: \(litDiffer)/51 frames differ")
        NSGraphicsContext.current = nil
        return ok && litDiffer == 0
    }
}
