import Sparkle
import SwiftUI

@main
struct BlitzTreeApp: App {
    /// Sparkle checks the latest GitHub release's appcast once a day,
    /// downloads the EdDSA-signed dmg and installs it when the app quits.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

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
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}

private struct SettingsView: View {
    @AppStorage(ScanModel.launchTargetKey) private var launchTarget = LaunchTarget.macintoshHD.rawValue
    @AppStorage(ScanModel.autoAnalyzeKey) private var autoAnalyze = false

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 6) {
                Picker("At launch", selection: $launchTarget) {
                    ForEach(LaunchTarget.allCases) { target in
                        Text(target.label).tag(target.rawValue)
                    }
                }
                .frame(width: 280)
                Text("What to scan when BlitzTree opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Auto-analyse suggestions", isOn: $autoAnalyze)
                Text("Automatically plan cleanup with AI after the launch scan instead of waiting for a click. Off by default so nothing leaves your Mac unprompted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
