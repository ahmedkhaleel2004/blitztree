import Sparkle
import SwiftUI

@main
struct BlitzTreeApp: App {
    /// Sparkle checks the latest GitHub release's appcast once a day,
    /// downloads the EdDSA-signed dmg and installs it when the app quits.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @AppStorage(ScanCache.enabledKey) private var saveResults = true

    init() {
        // `BlitzTree /some/path` is a scan target, not a document to open.
        // Left to AppKit, the path becomes an open-file request and SwiftUI
        // then skips creating the main window entirely.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    var body: some Scene {
        WindowGroup("BlitzTree") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
                Divider()
                // Saved results open the last scan at launch; turning them
                // off also frees the space they take.
                Toggle("Save Results for Fast Launch", isOn: $saveResults)
                    .onChange(of: saveResults) { if !saveResults { ScanCache.deleteAll() } }
                Button("Delete Saved Results…") { confirmDeleteSaved() }
            }
        }
    }

    private func confirmDeleteSaved() {
        let bytes = ScanCache.savedBytes()
        let alert = NSAlert()
        if bytes == 0 {
            alert.messageText = "No saved results"
            alert.informativeText = "BlitzTree hasn't saved any scan results."
            alert.runModal()
            return
        }
        alert.messageText = "Delete saved results?"
        alert.informativeText = "This frees \(Fmt.size(bytes)). The next launch scans from the start."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { ScanCache.deleteAll() }
    }
}
