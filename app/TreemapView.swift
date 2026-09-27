import AppKit
import SwiftUI

/// The treemap canvas: cushion-shaded rects rendered once into a bitmap per
/// layout change; hover/selection drawn as a light overlay per frame, and a
/// mouse move redraws only the few rects whose overlay changed.
final class TreemapNSView: NSView {
    var model: ScanModel? {
        // SwiftUI hands the same model back on every update; only a new one
        // needs a render (the rest goes through relayoutIfNeeded).
        didSet { if model !== oldValue { relayout() } }
    }

    /// Folders an agent plan would remove: lit while the rest dims.
    var highlights: [Int] = [] { didSet { if highlights != oldValue { litRects = nil } } }
    /// Their rects in the current layout, found once per change, not per frame.
    private var litRects: [CGRect]?
    private var rects: [TMRect] = []
    private var leaves: [TMRect] = [] // files only, for hit-testing
    /// `strip` is the title bar (text + hit target); `region` is the whole
    /// directory rect (hover boundary). Both in view points.
    private var labels: [TMLabel] = []
    /// Label text laid out once per render, not on every frame.
    private var labelText: [LabelText] = []
    private var labelHits: [(rect: CGRect, node: Int)] = []
    private var bitmap: CGImage?
    private var lastSize: CGSize = .zero
    private var lastRoot: Int = -1
    private var lastTreeID: ObjectIdentifier?
    private var lastShowFree = false

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        relayoutIfNeeded()
    }

    func relayoutIfNeeded() {
        guard let model, let tree = model.tree else { return }
        let treeID = ObjectIdentifier(tree)
        if bounds.size != lastSize || model.viewRoot != lastRoot || treeID != lastTreeID
            || model.showFreeSpace != lastShowFree {
            relayout()
        }
    }

    func relayout() {
        guard let model, let tree = model.tree, bounds.width > 4, bounds.height > 4 else {
            rects = []; leaves = []; labels = []; labelText = []; labelHits = []
            hoveredLabel = nil; litRects = nil; bitmap = nil
            lastSize = .zero
            resetLookups()
            needsDisplay = true
            return
        }
        lastSize = bounds.size
        lastRoot = model.viewRoot
        lastTreeID = ObjectIdentifier(tree)
        lastShowFree = model.showFreeSpace

        rects.removeAll(keepingCapacity: true)
        leaves.removeAll(keepingCapacity: true)
        labels.removeAll(keepingCapacity: true)
        renderBitmap(tree: tree)
        // Everything redraws, so the overlay simply starts from the model
        // (a zoom clears the selection, a rescan the hover).
        hoveredNode = model.hovered
        shown = Overlay(hovered: hoveredNode, label: hoveredLabel, selection: model.selection)
        needsDisplay = true
    }

    private func renderBitmap(tree: Tree) {
        let scale = window?.backingScaleFactor ?? 2
        let pw = max(1, Int((bounds.width * scale).rounded()))
        let ph = max(1, Int((bounds.height * scale).rounded()))
        let r = TreemapRenderer.render(
            tree: tree, pw: pw, ph: ph, scale: scale, root: model?.viewRoot ?? 0,
            showFree: model?.showFreeSpace ?? false, freeBytes: model?.freeBytes ?? 0
        )
        if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
            NSLog("BZ render %dx%d: %d steps, layout %.1f ms, paint %.1f ms (%d bands)",
                  pw, ph, r.steps, r.layoutMs, r.paintMs, r.bands)
        }
        rects = r.rects
        leaves = r.leaves
        litRects = nil
        labels = r.labels
        bitmap = r.image
        resetLookups()
        labelText = labels.map { LabelText($0, tree: tree, freeBytes: model?.freeBytes ?? 0) }
        labelHits = Scan.hits(labels)
    }

    /// A label's strings and their sizes in the resting (unhovered) look.
    private struct LabelText {
        var name: NSAttributedString, nameHeight: CGFloat, nameWidth: CGFloat = 0
        var size: NSAttributedString?, sizeSize: CGSize = .zero
        /// Where a free-space tag's text may paint (it floats unclipped).
        var bounds: CGRect

        init(_ label: TMLabel, tree: Tree, freeBytes: UInt64) {
            if label.node < 0 {
                // Free-space keeps a small floating tag (it has no frame).
                let text = label.region.width > 130
                    ? String(localized: "Free space  ·  \(Fmt.size(freeBytes))") : String(localized: "Free space")
                name = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                ])
                let s = name.size()
                nameHeight = s.height
                bounds = CGRect(x: label.region.minX + 8, y: label.region.minY + 6,
                                width: s.width, height: s.height).insetBy(dx: -2, dy: -2)
                return
            }
            name = Self.name(label, hovered: false)
            let ns = name.size()
            (nameWidth, nameHeight) = (ns.width, ns.height)
            if label.strip.width > 175 {
                let s = Self.size(label, tree: tree, hovered: false)
                size = s
                sizeSize = s.size()
            }
            bounds = label.strip.insetBy(dx: -2, dy: -2)
        }

        static func name(_ label: TMLabel, hovered: Bool) -> NSAttributedString {
            NSAttributedString(string: label.name, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(hovered ? 1.0 : 0.92),
            ])
        }

        static func size(_ label: TMLabel, tree: Tree, hovered: Bool) -> NSAttributedString {
            NSAttributedString(string: Fmt.size(tree.alloc[label.node]), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(hovered ? 0.95 : 0.60),
            ])
        }
    }

    // ---- Overlay state ----

    /// What the overlay shows. It changes only through `syncOverlay()`,
    /// which invalidates exactly the areas that look different, so a
    /// partial redraw never mixes two states.
    private struct Overlay: Equatable {
        var hovered: Int?, label: Int?, selection: Int?
    }
    private var shown = Overlay()
    private var hoveredLabel: Int? = nil
    /// `model.hovered` as this view last set it. Read instead of the model
    /// so `updateNSView` doesn't subscribe SwiftUI to every hover change.
    private var hoveredNode: Int? = nil

    /// Catch the overlay up with the model (hover, hovered label, selection)
    /// and queue redraws of just what changed (returned for the bench).
    @discardableResult
    func syncOverlay() -> [CGRect] {
        let now = Overlay(hovered: hoveredNode, label: hoveredLabel, selection: model?.selection)
        guard now != shown else { return [] }
        let dirty = dirtyRects(from: shown, to: now)
        for r in dirty { setNeedsDisplay(r) }
        shown = now
        return dirty
    }

    /// Everything that looks different between two overlay states.
    private func dirtyRects(from a: Overlay, to b: Overlay) -> [CGRect] {
        var out: [CGRect] = []
        if a.hovered != b.hovered {
            for h in [a.hovered, b.hovered] {
                guard let h, let r = hoverRects(h) else { continue }
                out += ring(r.leaf, outside: 1, inside: 2)
                if let p = r.parent { out += ring(p, outside: 1, inside: 2) }
            }
        }
        if a.label != b.label {
            for l in [a.label, b.label] {
                guard let l, let i = Scan.label(labels, l) else { continue }
                // The halo straddles region.insetBy(2): 3.5 pt either side.
                out += ring(labels[i].region, outside: 2.5, inside: 6.5)
                out.append(labels[i].strip.insetBy(dx: -1, dy: -1))
            }
        }
        if a.selection != b.selection {
            for s in [a.selection, b.selection] {
                guard let s, let r = dirRect(s) else { continue }
                out += ring(r, outside: 1, inside: 3)
            }
        }
        return out
    }

    /// The four edge bands of `r`, `outside` beyond it to `inside` within.
    private func ring(_ r: CGRect, outside o: CGFloat, inside i: CGFloat) -> [CGRect] {
        let outer = r.insetBy(dx: -o, dy: -o)
        guard r.width > 2 * i, r.height > 2 * i else { return [outer] }
        return [
            CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: o + i),
            CGRect(x: outer.minX, y: r.maxY - i, width: outer.width, height: o + i),
            CGRect(x: outer.minX, y: outer.minY, width: o + i, height: outer.height),
            CGRect(x: r.maxX - i, y: outer.minY, width: o + i, height: outer.height),
        ]
    }

    // ---- Lookups (one scan per change, not per frame or mouse move) ----

    private var leafMemo: (node: Int, rects: (leaf: CGRect, parent: CGRect?)?)?
    private var dirMemo: [Int: CGRect?] = [:]
    /// Built on the first hit test after a render, not on every resize.
    private var leafIndex: TMLeafIndex?

    private func resetLookups() {
        leafMemo = nil
        dirMemo = [:]
        leafIndex = nil
    }

    /// The hovered file's rect and its parent directory's, if on screen.
    private func hoverRects(_ node: Int) -> (leaf: CGRect, parent: CGRect?)? {
        if let m = leafMemo, m.node == node { return m.rects }
        // Only files are in `leaves`.
        guard let tree = model?.tree, !tree.isDir(node) else { return nil }
        return remember(Scan.leaf(leaves, node), tree: tree, node: node)
    }

    @discardableResult
    private func remember(_ leaf: TMRect?, tree: Tree, node: Int) -> (leaf: CGRect, parent: CGRect?)? {
        let found = leaf.map { ($0.rect, dirRect(Int(tree.parents[node]))) }
        leafMemo = (node, found)
        return found
    }

    private func dirRect(_ node: Int) -> CGRect? {
        if let r = dirMemo[node] { return r }
        let r = Scan.dir(rects, node)
        if dirMemo.count > 64 { dirMemo = [:] }
        dirMemo[node] = r
        return r
    }

    // ---- Drawing ----

    override func draw(_ dirtyRect: NSRect) {
        // Redraw only what was invalidated: a mouse move damages a few thin
        // strips, and blitting the whole bitmap (25 MB on a big Retina
        // window) plus every label was most of each hover frame.
        var damaged: UnsafePointer<NSRect>?
        var n = 0
        getRectsBeingDrawn(&damaged, count: &n)
        let dirty = n > 0 && damaged != nil ? Array(UnsafeBufferPointer(start: damaged, count: n)) : [dirtyRect]
        func needs(_ r: CGRect) -> Bool { Scan.intersects(dirty, r) }

        if let bitmap {
            let full = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
            let sx = CGFloat(bitmap.width) / bounds.width, sy = CGFloat(bitmap.height) / bounds.height
            for r in dirty {
                let px = CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
                    .integral.intersection(full)
                guard !px.isEmpty, let part = px == full ? bitmap : bitmap.cropping(to: px) else { continue }
                let dst = CGRect(x: px.minX / sx, y: px.minY / sy, width: px.width / sx, height: px.height / sy)
                NSImage(cgImage: part, size: dst.size).draw(
                    in: dst, from: .zero, operation: .copy, fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.none.rawValue]
                )
            }
        }

        guard let model, let tree = model.tree else { return }

        // Label hover boundary FIRST, so strip text always renders above it.
        if let hl = shown.label, let i = Scan.label(labels, hl), case let lab = labels[i],
           needs(lab.region.insetBy(dx: -3, dy: -3)) {
            let rr = lab.region.insetBy(dx: 2, dy: 2)
            let halo = NSBezierPath(rect: rr)
            halo.lineWidth = 7
            NSColor.black.withAlphaComponent(0.55).setStroke()
            halo.stroke()
            let line = NSBezierPath(rect: rr)
            line.lineWidth = 2.5
            NSColor.white.setStroke()
            line.stroke()
        }

        // Title-strip labels: text lives on the directory's frame, never on
        // top of its contents.
        for (label, text) in zip(labels, labelText) where needs(text.bounds) {
            if label.node < 0 {
                text.name.draw(at: CGPoint(x: label.region.minX + 8, y: label.region.minY + 6))
                continue
            }

            let strip = label.strip
            let hovered = label.node == shown.label
            if hovered {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(rect: strip).fill()
            }
            let nameStr = hovered ? LabelText.name(label, hovered: true) : text.name
            var avail = strip.width - 12
            if strip.width > 175 {
                // right-aligned size on roomy strips
                let sizeStr = hovered ? LabelText.size(label, tree: tree, hovered: true) : text.size!
                let sw = hovered ? sizeStr.size() : text.sizeSize
                sizeStr.draw(at: CGPoint(x: strip.maxX - sw.width - 6,
                                         y: strip.midY - sw.height / 2))
                avail -= sw.width + 10
            }
            let nh = text.nameHeight
            if text.nameWidth <= avail {
                // Fits: skip the truncating typesetter (same glyphs, far cheaper).
                nameStr.draw(at: CGPoint(x: strip.minX + 6, y: strip.midY - nh / 2))
            } else {
                nameStr.draw(
                    with: CGRect(x: strip.minX + 6, y: strip.midY - nh / 2,
                                 width: max(0, avail), height: nh),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
            }
        }

        // Hover: outline the file and its parent directory.
        if let h = shown.hovered, let r = hoverRects(h) {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let p = NSBezierPath(rect: r.leaf.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
            if let pr = r.parent {
                NSColor.white.withAlphaComponent(0.35).setStroke()
                let pp = NSBezierPath(rect: pr.insetBy(dx: 0.5, dy: 0.5))
                pp.lineWidth = 1
                pp.stroke()
            }
        }
        if !highlights.isEmpty {
            if litRects == nil { litRects = Scan.lit(rects, highlights) }
            let lit = litRects ?? []
            if !lit.isEmpty {
                let dim = NSBezierPath(rect: bounds)
                for r in lit { dim.append(NSBezierPath(rect: r)) }
                dim.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.55).setFill()
                dim.fill()
                NSColor.controlAccentColor.setStroke()
                for r in lit {
                    let p = NSBezierPath(rect: r)
                    p.lineWidth = 1.5
                    p.stroke()
                }
            }
        }
        if let sel = shown.selection, let r = dirRect(sel) {
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
        }
    }

    // ---- Interaction ----

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let esc = event.keyCode == 53
        let cmdUp = event.modifierFlags.contains(.command) && event.keyCode == 126
        if esc || cmdUp, let model, let tree = model.tree, model.viewRoot != 0 {
            let p = Int(tree.parents[model.viewRoot])
            model.viewRoot = p == Int(UInt32.max) ? 0 : p
            relayout()
        } else {
            super.keyDown(with: event)
        }
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func hit(_ point: CGPoint) -> TMRect? {
        // Files are disjoint; smallest matching leaf wins.
        if leafIndex == nil { leafIndex = TMLeafIndex(leaves: leaves, size: lastSize) }
        return leafIndex!.hit(point, leaves: leaves)
    }

    override func mouseMoved(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    @discardableResult
    func hover(at p: CGPoint) -> [CGRect] {
        let lab = Scan.hit(labelHits, p)
        hoveredLabel = lab
        let leaf = lab == nil ? hit(p) : nil
        let node = lab ?? leaf?.node
        if let leaf, let tree = model?.tree, leafMemo?.node != leaf.node {
            remember(leaf, tree: tree, node: leaf.node) // saves the lookup when drawing
        }
        if node != hoveredNode {
            hoveredNode = node
            model?.hovered = node
            if let node, let tree = model?.tree {
                toolTip = "\(tree.displayPath(node))\n\(Fmt.size(tree.alloc[node]))"
            } else {
                toolTip = nil
            }
        }
        return syncOverlay()
    }

    override func mouseExited(with event: NSEvent) {
        model?.hovered = nil
        hoveredNode = nil
        hoveredLabel = nil
        syncOverlay()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let model, let tree = model.tree else { return }
        if event.clickCount == 2 {
            // Directory labels are zoom targets first.
            if let lab = Scan.hit(labelHits, p, slop: 2) {
                model.viewRoot = lab
                relayout()
                return
            }
            if let leaf = hit(p) {
                // zoom into the file's parent directory
                let parent = Int(tree.parents[leaf.node])
                if parent != Int(UInt32.max) && tree.isDir(parent) && parent != model.viewRoot {
                    model.viewRoot = parent
                    relayout()
                }
            }
        } else {
            if let lab = Scan.hit(labelHits, p) {
                model.selection = lab
            } else {
                model.selection = hit(p)?.node
            }
            syncOverlay()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let model, let tree = model.tree, let leaf = hit(p) else { return }
        model.selection = leaf.node
        syncOverlay()
        NodeMenu.popUp(path: tree.path(leaf.node), with: event, for: self)
    }
}

/// Scans over the layout arrays, nonisolated on purpose: a closure written
/// in the MainActor view checks its executor on every call, which made one
/// pass over 40k directory rects cost milliseconds per mouse move.
nonisolated private enum Scan {
    static func leaf(_ leaves: [TMRect], _ node: Int) -> TMRect? {
        leaves.first { $0.node == node }
    }

    static func dir(_ rects: [TMRect], _ node: Int) -> CGRect? {
        rects.first { $0.node == node && $0.isDir }?.rect
    }

    static func lit(_ rects: [TMRect], _ nodes: [Int]) -> [CGRect] {
        let wanted = Set(nodes)
        return rects.filter { wanted.contains($0.node) }.map { $0.rect.insetBy(dx: 0.5, dy: 0.5) }
    }

    static func label(_ labels: [TMLabel], _ node: Int) -> Int? {
        labels.firstIndex { $0.node == node }
    }

    static func hits(_ labels: [TMLabel]) -> [(rect: CGRect, node: Int)] {
        labels.filter { $0.node >= 0 }.map { ($0.strip, $0.node) }
    }

    static func hit(_ hits: [(rect: CGRect, node: Int)], _ p: CGPoint, slop: CGFloat = 0) -> Int? {
        slop == 0 ? hits.first { $0.rect.contains(p) }?.node
            : hits.first { $0.rect.insetBy(dx: -slop, dy: -slop).contains(p) }?.node
    }

    static func intersects(_ rects: [CGRect], _ r: CGRect) -> Bool {
        rects.contains { $0.intersects(r) }
    }
}

/// Right-click menu for a file or folder, shared by the treemap and rings.
final class NodeMenu: NSObject {
    private static let shared = NodeMenu()

    static func popUp(path: String, with event: NSEvent, for view: NSView) {
        let menu = NSMenu()
        for (title, action) in [(String(localized: "Reveal in Finder"), #selector(revealInFinder(_:))),
                                (String(localized: "Copy Path"), #selector(copyPath(_:))),
                                (String(localized: "Move to Trash"), #selector(moveToTrash(_:)))] {
            if action == #selector(moveToTrash(_:)) { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = shared
            item.representedObject = path
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func moveToTrash(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        let alert = NSAlert()
        alert.messageText = String(localized: "Move \u{201C}\(url.lastPathComponent)\u{201D} to Trash?")
        alert.informativeText = path
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            // Note: sizes refresh on next rescan; v1 keeps it simple.
        }
    }
}

struct TreemapView: NSViewRepresentable {
    let model: ScanModel

    func makeNSView(context: Context) -> TreemapNSView {
        let v = TreemapNSView()
        v.model = model
        return v
    }

    func updateNSView(_ view: TreemapNSView, context: Context) {
        view.model = model
        view.relayoutIfNeeded()
        view.syncOverlay() // e.g. a selection made in the list
        let lit = model.agentRun?.highlights(in: model.tree) ?? []
        if lit != view.highlights {
            view.highlights = lit
            view.needsDisplay = true
        }
    }
}
