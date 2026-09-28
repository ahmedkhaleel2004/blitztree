import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @State private var model = ScanModel()
    @State private var showTable = true
    @AppStorage("bz.showCleanup") private var showCleanup = false
    @AppStorage("bz.listWidth") private var listWidth = 390.0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: NSColor(calibratedWhite: 0.10, alpha: 1))
                // Build the empty canvases while the first scan is running,
                // so AppKit setup does not delay the finished tree. Once built,
                // the list and treemap stay alive (hidden) through
                // a rescan: tearing them down and rebuilding them made AppKit
                // redo its first-time setup and froze the window as the new
                // scan landed. A new tree only reloads into the same views.
                if model.scanning || model.tree != nil || model.hasShownTree {
                    // Not HSplitView: next to the Clean Up inspector it put AppKit
                    // in an endless constraint-update loop and crashed the app
                    // seconds after every scan with the panel open.
                    HStack(spacing: 0) {
                        if showTable {
                            OutlinePanel(model: model)
                                .frame(width: listWidth)
                            ListDivider(width: $listWidth)
                        }
                        Group {
                            switch model.mapStyle {
                            case .treemap:
                                TreemapView(model: model, freeBytes: model.showFreeSpace ? model.freeBytes : 0)
                            case .rings:
                                SunburstView(model: model, freeBytes: model.showFreeSpace && model.viewRoot == 0 ? model.freeBytes : 0)
                            }
                        }
                        .frame(minWidth: 400, maxWidth: .infinity)
                    }
                    // Hidden by an opaque cover below, not by opacity or hit
                    // testing: SwiftUI re-inserts AppKit views when those change.
                }
                if model.tree == nil {
                    Group {
                        if model.scanning {
                            ScanProgress(model: model)
                        } else if needsFDA {
                            fdaOverlay
                        } else {
                            idleOverlay
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: NSColor(calibratedWhite: 0.10, alpha: 1)))
                    .contentShape(Rectangle())
                }
            }
            Divider()
            ScanStatusBar(model: model)
        }
        .frame(minWidth: 760, minHeight: 500)
        .inspector(isPresented: $showCleanup) {
            CleanupPanel(model: model)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
        .toolbar { toolbar }
        .task {
            model.agentEnv = await AgentLocator.find()
            model.openPanelAfterLaunchScan()
        }
        // An agent run or the setup offer always shows in the panel.
        .onChange(of: model.agentRun == nil) { if model.agentRun != nil { showCleanup = true } }
        .onChange(of: model.panelRequests) { showCleanup = true }
        .hidingWindowTitle()
        .onAppear {
            // Never start a whole-disk scan without FDA: every protected
            // app container would fire a permission prompt.
            if FDA.isActive() {
                model.startScan()
            } else {
                needsFDA = true
            }
        }
    }

    @State private var needsFDA = false

    private var fdaOverlay: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("BlitzTree needs Full Disk Access")
                .font(.title2.weight(.semibold))
            Text("System Settings → Privacy & Security → Full Disk Access.\nRemove any old BlitzTree rows, then add /Applications/BlitzTree.app.\nmacOS only applies the permission to a freshly launched app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
            HStack(spacing: 12) {
                Button("Open System Settings") { openFDASettings() }
                Button("I granted it — Relaunch") { FDA.relaunch() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Scan without it") {
                needsFDA = false
                model.startScan()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: toolbar

    @ViewBuilder
    private var titleCrumbs: some View {
        if let tree = model.tree {
            breadcrumbs(tree: tree)
        } else {
            Text(displayRootName())
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // macOS 26+: crumbs sit bare in the Liquid Glass toolbar, pushed apart
        // from the controls by a flexible spacer. Older systems lay out the
        // classic toolbar themselves.
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { titleCrumbs }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .navigation) { titleCrumbs }
        }

        ToolbarItemGroup(placement: .automatic) {
            Menu {
                Button("Macintosh HD") { model.startScan(path: "/System/Volumes/Data") }
                Button("Home") { model.startScan(path: FileManager.default.homeDirectoryForCurrentUser.path) }
                Divider()
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                Label("Scan", systemImage: "folder")
            }
            .disabled(model.scanning || model.cleanupTrash.running)
            .help("Choose what to scan")

            Button {
                model.startScan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.scanning || model.cleanupTrash.running)
            .help("Rescan")
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .automatic)
        }

        ToolbarItem(placement: .automatic) {
            Picker("View", selection: $model.mapStyle) {
                Label("Treemap", systemImage: "square.grid.2x2").tag(MapStyle.treemap)
                Label("Rings", systemImage: "circle.circle").tag(MapStyle.rings)
            }
            .pickerStyle(.segmented)
            .help("Treemap (WizTree-style) or rings (DaisyDisk-style)")
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .automatic)
        }

        ToolbarItemGroup(placement: .automatic) {
            Toggle(isOn: $model.showFreeSpace) {
                Label("Free Space", systemImage: "square.dashed")
            }
            .help("Show free space in the map")

            Toggle(isOn: $showTable) {
                Label("Directory List", systemImage: "sidebar.leading")
            }
            .help("Show directory list")

            Toggle(isOn: $showCleanup) {
                Label("Clean Up", systemImage: "sparkles")
            }
            .help("Show folders that are safe to clean up")
        }
    }

    private func breadcrumbs(tree: Tree) -> some View {
        HStack(spacing: 4) {
            let chain = tree.ancestry(model.viewRoot)
            ForEach(Array(chain.enumerated()), id: \.offset) { i, node in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    model.viewRoot = node
                } label: {
                    Text(node == 0 ? displayRootName() : tree.name(node))
                        .font(.system(.body, design: .rounded).weight(i == chain.count - 1 ? .semibold : .regular))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(i == chain.count - 1 ? .primary : .secondary)
            }
        }
    }

    private func displayRootName() -> String {
        let p = model.scanRoot
        if p == "/System/Volumes/Data" { return "Macintosh HD" }
        return (p as NSString).lastPathComponent.isEmpty ? p : (p as NSString).lastPathComponent
    }

    // MARK: overlays

    private var idleOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Pick a target and scan")
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.startScan(path: url.path)
        }
    }

    private func openFDASettings() { openFullDiskAccessSettings() }
}

/// Observe 60 Hz counters here so progress updates do not rebuild the toolbar.
private struct ScanProgress: View {
    let model: ScanModel
    var body: some View {
        VStack(spacing: 14) {
            Text(Fmt.size(model.bytes))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text("\(Fmt.num(model.files)) files · \(Fmt.num(model.dirs)) folders · \(String(format: "%.2f", model.elapsed))s")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        // No spinner: the counters are the progress, and a ProgressView is an
        // AppKit view whose insertion recomputed the window's key-view loop
        // (laying out the hidden list) just as each scan started.
        // No numeric-text transition: its blur is rasterized on the CPU and
        // stalled the main thread for most of a short scan. Plain digits
        // updated at the 60 Hz poll count up smoothly on their own.
    }
}

/// Pointer movement changes only the status text, not the window's view graph.
private struct ScanStatusBar: View {
    let model: ScanModel
    var body: some View {
        HStack(spacing: 8) {
            if let tree = model.tree {
                if let sel = model.hovered ?? model.selection {
                    Text(tree.displayPath(sel))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    let a = tree.alloc[sel]
                    let rootA = max(tree.alloc[model.viewRoot], 1)
                    Text("\(Fmt.size(a)) · \(String(format: "%.1f%%", 100 * Double(a) / Double(rootA)))")
                        .monospacedDigit()
                } else {
                    Text("\(Fmt.num(UInt64(tree.nFiles[model.viewRoot]))) files · \(Fmt.size(tree.alloc[model.viewRoot]))")
                    Spacer()
                    if tree.errors > 0 {
                        if FDA.isActive() {
                            // Root-owned system dirs: unreadable by design,
                            // not a permissions problem the user can fix.
                            let gap = model.unscannedBytes > 1_000_000_000
                                ? " · ~\(Fmt.size(model.unscannedBytes)) root-only" : ""
                            Text("\(tree.errors) system folders unreadable\(gap)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            Button {
                                openFullDiskAccessSettings()
                            } label: {
                                Label("\(tree.errors) folders skipped — grant Full Disk Access", systemImage: "lock.shield")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Text("scanned in \(String(format: "%.1fs", model.elapsed))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("BlitzTree").foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private func openFullDiskAccessSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
        NSWorkspace.shared.open(url)
    }
}

/// Left panel: a real NSOutlineView — the same control as Finder's list
/// view. Native disclosure triangles, real file icons, alternating rows,
/// keyboard navigation.
/// The draggable line between the list and the treemap (210–400 pt).
private struct ListDivider: View {
    @Binding var width: Double
    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? width
                                dragStart = start
                                width = min(400, max(210, start + drag.translation.width))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}

/// List cells laid out by frame, not Auto Layout: AppKit re-lays out every
/// row as it reloads, and solving constraints per row made reloads stall.
final class NameCell: NSTableCellView {
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let lineHeight = ceil(font.ascender - font.descender + font.leading)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let iv = NSImageView()
        let tf = NSTextField(labelWithString: "")
        tf.font = Self.font
        tf.lineBreakMode = .byTruncatingMiddle
        addSubview(iv)
        addSubview(tf)
        imageView = iv
        textField = tf
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let h = bounds.height
        imageView?.frame = NSRect(x: 2, y: ((h - 16) / 2).rounded(), width: 16, height: 16)
        textField?.frame = NSRect(x: 23, y: ((h - Self.lineHeight) / 2).rounded(),
                                  width: max(0, bounds.width - 25), height: Self.lineHeight)
    }
}

/// A right-aligned figure (size or percentage) in the list.
final class ValueCell: NSTableCellView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let lineHeight = ceil(font.ascender - font.descender + font.leading)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let tf = NSTextField(labelWithString: "")
        tf.font = Self.font
        tf.textColor = .secondaryLabelColor
        tf.alignment = .right
        addSubview(tf)
        textField = tf
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        textField?.frame = NSRect(x: 0, y: ((bounds.height - Self.lineHeight) / 2).rounded(),
                                  width: max(0, bounds.width - 2), height: Self.lineHeight)
    }
}

struct OutlinePanel: NSViewRepresentable {
    let model: ScanModel

    /// An NSObject so the outline hashes and compares items by pointer: as a
    /// plain Swift class every lookup went through the Swift runtime's
    /// conformance checks, a third of expanding a 100k-item folder.
    final class Item: NSObject {
        private(set) var id: Int
        private(set) var tree: Tree
        private var kids: [Item]?
        init(id: Int, tree: Tree) {
            self.id = id
            self.tree = tree
        }
        var children: [Item] {
            if kids == nil { kids = tree.children(id).map { Item(id: Int($0), tree: tree) } }
            return kids!
        }

        /// Only an untouched, collapsed item can be rebound without leaving
        /// stale child identities in AppKit's outline cache.
        func canRebind(to id: Int, in tree: Tree) -> Bool {
            kids == nil && self.tree.isDir(self.id) == tree.isDir(id)
                && self.tree.children(self.id).count == tree.children(id).count
                && self.tree.name(self.id) == tree.name(id)
        }

        func rebind(to id: Int, in tree: Tree) {
            precondition(kids == nil)
            self.id = id
            self.tree = tree
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var model: ScanModel?
        var tree: Tree?
        var viewRoot = -1
        var roots: [Item] = []
        weak var outline: NSOutlineView?
        private var iconCache: [String: NSImage] = [:]

        func rebuildIfNeeded() {
            guard let model, let t = model.tree else { return }
            if t !== tree || model.viewRoot != viewRoot {
                let childIDs = t.children(model.viewRoot)
                // Bound name comparisons for extremely wide directories.
                let reuseRows = t !== tree && model.viewRoot == viewRoot
                    && roots.count <= 4_096
                    && outline?.numberOfRows == roots.count && childIDs.count == roots.count
                    && zip(roots, childIDs).allSatisfy { item, id in
                        item.canRebind(to: Int(id), in: t) && outline?.isItemExpanded(item) == false
                    }
                tree = t
                viewRoot = model.viewRoot
                let started = Date()
                if reuseRows, let outline {
                    // A rescan often has the same top-level shape. Keep row
                    // views/disclosure buttons and refresh only their cells.
                    for (item, id) in zip(roots, childIDs) { item.rebind(to: Int(id), in: t) }
                    outline.deselectAll(nil)
                    outline.enumerateAvailableRowViews { rowView, row in
                        guard self.roots.indices.contains(row) else { return }
                        for (column, definition) in outline.tableColumns.enumerated() {
                            if let cell = rowView.view(atColumn: column) as? NSTableCellView {
                                self.configure(cell, column: definition.identifier.rawValue, item: self.roots[row])
                            }
                        }
                    }
                } else {
                    roots = childIDs.map { Item(id: Int($0), tree: t) }
                    outline?.reloadData()
                }
                if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
                    NSLog("BZ list reload: %.1f ms", -started.timeIntervalSinceNow * 1000)
                }
            }
        }

        func icon(for name: String, isDir: Bool) -> NSImage {
            let key: String
            if isDir {
                key = "/folder"
            } else if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                key = String(name[name.index(after: dot)...]).lowercased()
            } else {
                key = "/plain"
            }
            if let hit = iconCache[key] { return hit }
            let img: NSImage
            if key == "/folder" {
                img = NSWorkspace.shared.icon(for: .folder)
            } else if key == "/plain" {
                img = NSWorkspace.shared.icon(for: .data)
            } else {
                img = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
            }
            // Pre-render to a small bitmap: workspace icons are lazy, and every
            // row asking IconServices for one again made list reloads slow.
            let scale = outline?.window?.backingScaleFactor ?? 2
            let px = Int(16 * scale)
            let flat: NSImage
            if let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) {
                rep.size = NSSize(width: 16, height: 16)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                NSGraphicsContext.restoreGraphicsState()
                flat = NSImage(size: NSSize(width: 16, height: 16))
                flat.addRepresentation(rep)
            } else {
                flat = img
            }
            iconCache[key] = flat
            return flat
        }

        // MARK: data source
        func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item = item as? Item else { return roots.count }
            // AppKit asks counts without expanding a row. The flat tree
            // already knows this; do not allocate wrappers for its children.
            return item.tree.children(item.id).count
        }
        func outlineView(_ v: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            item == nil ? roots[index] : (item as! Item).children[index]
        }
        func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool {
            let it = item as! Item
            return it.tree.isDir(it.id) && !it.tree.children(it.id).isEmpty
        }

        // MARK: cells
        func outlineView(_ v: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            let it = item as! Item
            let colID = col?.identifier.rawValue ?? "name"
            let reuse = NSUserInterfaceItemIdentifier("cell-\(colID)")

            if colID == "name" {
                let cell = (v.makeView(withIdentifier: reuse, owner: nil) as? NameCell) ?? {
                    let c = NameCell()
                    c.identifier = reuse
                    return c
                }()
                configure(cell, column: colID, item: it)
                return cell
            }

            let cell = (v.makeView(withIdentifier: reuse, owner: nil) as? ValueCell) ?? {
                let c = ValueCell()
                c.identifier = reuse
                return c
            }()
            configure(cell, column: colID, item: it)
            return cell
        }

        private func configure(_ cell: NSTableCellView, column: String, item it: Item) {
            let tree = it.tree
            if column == "name" {
                let name = tree.name(it.id)
                cell.textField?.stringValue = name
                cell.imageView?.image = icon(for: name, isDir: tree.isDir(it.id))
            } else if column == "size" {
                cell.textField?.stringValue = Fmt.size(tree.alloc[it.id])
            } else {
                let parent = Int(tree.parents[it.id])
                let pAlloc = parent == Int(UInt32.max) ? tree.alloc[0] : tree.alloc[parent]
                let pct = pAlloc > 0 ? 100 * Double(tree.alloc[it.id]) / Double(pAlloc) : 0
                cell.textField?.stringValue = pct < 0.5 ? "–" : String(format: "%.0f%%", pct)
                cell.textField?.textColor = .tertiaryLabelColor
            }
        }

        func outlineViewSelectionDidChange(_ n: Notification) {
            // While a rescan runs the list still shows the old tree, hidden.
            guard let outline, let model, model.tree != nil, model.tree === tree else { return }
            if let it = outline.item(atRow: outline.selectedRow) as? Item {
                model.selection = it.id
            }
        }

        /// Treemap click → expand ancestors, select and reveal the row here.
        func syncSelection() {
            guard let outline, let tree, let sel = model?.selection else { return }
            if let cur = outline.item(atRow: outline.selectedRow) as? Item, cur.id == sel { return }

            var chain: [Int] = []
            var cur = sel
            while cur != viewRoot {
                if cur == Int(UInt32.max) { return } // outside current view root
                chain.append(cur)
                cur = Int(tree.parents[cur])
            }
            chain.reverse()

            var level = roots
            var target: Item?
            for id in chain {
                guard let it = level.first(where: { $0.id == id }) else { return }
                target = it
                if id != chain.last {
                    outline.expandItem(it)
                    level = it.children
                }
            }
            if let target {
                let row = outline.row(forItem: target)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            }
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard let it = sender.item(atRow: sender.clickedRow) as? Item else { return }
            if it.tree.isDir(it.id) {
                model?.viewRoot = it.id
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: it.tree.path(it.id))])
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.style = .plain
        outline.rowSizeStyle = .default
        outline.usesAlternatingRowBackgroundColors = true
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 13
        outline.autoresizesOutlineColumn = false

        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Name"
        name.minWidth = 120
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "Size"
        size.width = 92; size.minWidth = 84; size.maxWidth = 116
        let pct = NSTableColumn(identifier: .init("pct"))
        pct.title = "%"
        pct.width = 34; pct.minWidth = 30; pct.maxWidth = 44

        outline.addTableColumn(name)
        outline.addTableColumn(size)
        outline.addTableColumn(pct)
        outline.outlineTableColumn = name
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let coord = context.coordinator
        coord.model = model
        coord.outline = outline
        outline.dataSource = coord
        outline.delegate = coord
        outline.target = coord
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        coord.rebuildIfNeeded()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.rebuildIfNeeded()
        context.coordinator.syncSelection()
    }
}

private extension View {
    /// The breadcrumbs are the title; drop the duplicate window title.
    @ViewBuilder
    func hidingWindowTitle() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
        } else {
            navigationTitle("")
        }
    }
}
