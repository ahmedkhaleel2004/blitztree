import Foundation

@main
struct LaunchSettingsChecks {
    @MainActor
    static func main() {
        let defaults = UserDefaults.standard
        let savedTarget = defaults.object(forKey: ScanModel.launchTargetKey)
        let savedAuto = defaults.object(forKey: ScanModel.autoAnalyzeKey)
        defer {
            if let savedTarget { defaults.set(savedTarget, forKey: ScanModel.launchTargetKey) }
            else { defaults.removeObject(forKey: ScanModel.launchTargetKey) }
            if let savedAuto { defaults.set(savedAuto, forKey: ScanModel.autoAnalyzeKey) }
            else { defaults.removeObject(forKey: ScanModel.autoAnalyzeKey) }
        }

        defaults.removeObject(forKey: ScanModel.launchTargetKey)
        defaults.removeObject(forKey: ScanModel.autoAnalyzeKey)

        let model = ScanModel()
        precondition(model.launchTarget == .macintoshHD, "default launch target must be Macintosh HD")
        precondition(!model.autoAnalyze, "auto-analyse must default to off")
        precondition(model.scanRoot == "/System/Volumes/Data", "default scanRoot is Data volume")

        model.launchTarget = .home
        precondition(defaults.string(forKey: ScanModel.launchTargetKey) == LaunchTarget.home.rawValue)
        let homeModel = ScanModel()
        precondition(homeModel.launchTarget == .home)
        precondition(homeModel.scanRoot == FileManager.default.homeDirectoryForCurrentUser.path)

        model.launchTarget = .prompt
        precondition(ScanModel().launchTarget == .prompt)

        model.autoAnalyze = true
        precondition(ScanModel().autoAnalyze)

        print("LaunchSettingsChecks passed")
    }
}
