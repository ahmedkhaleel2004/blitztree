import AppKit
import SwiftUI

@MainActor enum UIHandoffMetrics {
    static var rootBodies = 0
    static var engineDoneAt: Date?
}

/// Displays the actual production UI and repeats read-only scans. The launcher
/// injects this model into a copy of ContentView and removes agent discovery.
@main
struct UIHandoff {
    @MainActor static func outline(in view: NSView) -> NSOutlineView? {
        if let found = view as? NSOutlineView { return found }
        for child in view.subviews {
            if let found = outline(in: child) { return found }
        }
        return nil
    }

    @MainActor static func verifyCells(_ window: NSWindow, model: ScanModel) {
        guard let outline = outline(in: window.contentView!) else { preconditionFailure("Missing outline") }
        var checked = 0
        outline.enumerateAvailableRowViews { rowView, row in
            guard row >= 0, row < outline.numberOfRows else { return }
            let item = outline.item(atRow: row) as! OutlinePanel.Item
            precondition(item.tree === model.tree, "Displayed item belongs to an older scan")
            for (column, definition) in outline.tableColumns.enumerated() {
                guard let cell = rowView.view(atColumn: column) as? NSTableCellView else { continue }
                if definition.identifier.rawValue == "name" {
                    precondition(cell.textField?.stringValue == item.tree.name(item.id), "Stale displayed name")
                } else if definition.identifier.rawValue == "size" {
                    precondition(cell.textField?.stringValue == Fmt.size(item.tree.alloc[item.id]), "Stale displayed size")
                }
                checked += 1
            }
        }
        NSLog("BZ verified %d visible cells", checked)
    }

    @MainActor static func main() {
        precondition(CommandLine.arguments.count > 1, "Usage: ui-handoff SCAN_PATH [runs]")
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = ScanModel()
        model.mapStyle = .treemap
        model.showFreeSpace = false
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1240, height: 900),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "BlitzTree performance harness"
        window.contentView = NSHostingView(rootView: ContentView(model: model).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        let runs = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 5
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            for trial in 0..<runs {
                let bodies = UIHandoffMetrics.rootBodies
                NSLog("BZ trial %d begin", trial)
                let metadataStarted = Date()
                model.startScan(path: CommandLine.arguments[1])
                var ticks = 0
                while model.scanning {
                    ticks += 1
                    try? await Task.sleep(for: .milliseconds(10))
                }
                precondition(model.tree != nil)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                NSLog("BZ visible handoff: %.3f ms", -UIHandoffMetrics.engineDoneAt!.timeIntervalSinceNow * 1000)
                verifyCells(window, model: model)
                NSLog("BZ trial %d visible nodes=%d", trial, model.tree!.count)
                if let delay = ProcessInfo.processInfo.environment["BZ_VOLUME_DELAY"].flatMap(Double.init) {
                    // Tree-first handoff leaves scanning=false while capacity
                    // is pending. Keep the old reference behavior acceptable
                    // too: its capacity is already nonzero at this point.
                    var metadataTicks = 0
                    if model.freeBytes == 0 {
                        let waitElapsed = max(0, delay - (-metadataStarted.timeIntervalSinceNow))
                        let deadline = Date().addingTimeInterval(waitElapsed + 0.5)
                        while model.freeBytes == 0 && Date() < deadline {
                            metadataTicks += 1
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                        precondition(model.freeBytes > 0, "Capacity metadata was not applied")
                        if waitElapsed > 0.2 {
                            precondition(metadataTicks > Int(waitElapsed * 30), "Volume metadata blocked the main actor")
                        }
                    }
                    NSLog("BZ delayed metadata: %d responsive main-actor ticks; tree was already visible", metadataTicks)
                }
                try? await Task.sleep(for: .milliseconds(750))
                NSLog("BZ trial %d root body evaluations=%d", trial, UIHandoffMetrics.rootBodies - bodies)
            }
            if ProcessInfo.processInfo.environment["BZ_HOVER_PROBE"] != nil {
                let bodies = UIHandoffMetrics.rootBodies
                for update in 0..<120 {
                    model.hovered = 1 + update % min(model.tree!.count - 1, 20)
                    try? await Task.sleep(for: .milliseconds(17))
                }
                NSLog("BZ hover 120 updates: root body evaluations=%d", UIHandoffMetrics.rootBodies - bodies)
            }
            if ProcessInfo.processInfo.environment["BZ_UI_EXERCISE"] != nil {
                let tree = model.tree!
                let folder = tree.children(0).map(Int.init).first { tree.isDir($0) && !tree.children($0).isEmpty }!
                model.hovered = nil
                model.viewRoot = folder
                try? await Task.sleep(for: .milliseconds(150))
                let selected = Int(tree.children(folder)[0])
                model.selection = selected
                try? await Task.sleep(for: .milliseconds(150))
                let list = outline(in: window.contentView!)!
                precondition((list.item(atRow: list.selectedRow) as? OutlinePanel.Item)?.id == selected,
                             "Selection stopped reaching the outline after view isolation")
                for style in [MapStyle.rings, .treemap] {
                    model.mapStyle = style
                    for showFree in [true, false] {
                        model.showFreeSpace = showFree
                        try? await Task.sleep(for: .milliseconds(150))
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }
                }
                model.viewRoot = 0
                try? await Task.sleep(for: .milliseconds(150))
                verifyCells(window, model: model)
                let rootList = outline(in: window.contentView!)!
                for row in [max(0, rootList.numberOfRows - 1), 0] {
                    rootList.scrollRowToVisible(row)
                    try? await Task.sleep(for: .milliseconds(150))
                    window.displayIfNeeded()
                    verifyCells(window, model: model)
                }
                NSLog("BZ PASS: zoom, selection synchronization, rings/treemap, free space, root navigation, recycled cells")
            }
            if let path = ProcessInfo.processInfo.environment["BZ_UI_IMAGE"], let view = window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            }
            app.terminate(nil)
        }
        app.run()
        withExtendedLifetime(window) {}
    }
}
