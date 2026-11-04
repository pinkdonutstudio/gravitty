import AppKit
import Sparkle

// Auto-update with Sparkle. The update check is the only network call Gravitty makes. It runs only inside a built .app
// that carries a feed URL and a public key (scripts/bundle.sh adds both); a plain `swift build` binary has neither and skips it.
// Sparkle asks the user once before it starts checking on its own, and keeps the answer in the app's preferences.
@MainActor final class Updater {
    private let controller: SPUStandardUpdaterController?

    init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        controller = configured ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }

    var available: Bool { controller != nil }

    /// "Check for Updates…". The app has no Dock icon, so bring its windows forward first.
    @objc func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
