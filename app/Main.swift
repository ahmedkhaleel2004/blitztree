import SwiftUI

@main
struct BlitzTreeApp: App {
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

        // Cmd+, — language and custom model providers.
        Settings {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gear") }
                ProvidersView()
                    .tabItem { Label("Model Providers", systemImage: "point.3.filled.connected.trianglepath.dotted") }
            }
            .frame(minHeight: 360)
        }
    }
}
