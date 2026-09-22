import Sparkle
import Cocoa

/// Only the dedicated nightly app opts into Toastty's signed update channel.
class UpdateController: NSObject {
    // Kept for the debug-only update UI simulator. Real updates use Sparkle's
    // standard dialogs, including the explicit Install and Relaunch choice.
    let viewModel = UpdateViewModel()
    private let userDriver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    private var started = false
    private var startError: Error?

    private(set) lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: userDriver,
        delegate: self
    )

    var isEnabled: Bool {
        Self.isEnabled(bundleIdentifier: Bundle.main.bundleIdentifier, info: Bundle.main.infoDictionary ?? [:])
    }

    static func isEnabled(bundleIdentifier: String?, info: [String: Any]) -> Bool {
        guard let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              let feed = info["SUFeedURL"] as? String else { return false }

        switch bundleIdentifier {
        case "com.dar7an.toastty.nightly":
            return feed == "https://github.com/dar7an/toastty/releases/download/nightly/appcast.xml"
        case "com.dar7an.toastty.nightly.test":
            // A separate, locally packaged app exercises real Sparkle installs
            // without sharing preferences or feeds with an installed nightly.
            guard let url = URL(string: feed) else { return false }
            return url.scheme == "http" && url.host == "127.0.0.1"
        default:
            return false
        }
    }

    func startUpdater() {
        guard isEnabled, !started else { return }
        do {
            try updater.start()
            started = true
            startError = nil
        } catch {
            startError = error
            Ghostty.logger.error("Unable to start Toastty updates: \(error.localizedDescription)")
        }
    }

    func checkForUpdates() {
        guard isEnabled else {
            if let url = URL(string: "https://github.com/dar7an/toastty/releases") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        startUpdater()
        if started {
            updater.checkForUpdates()
        } else if let startError {
            NSAlert(error: startError).runModal()
        }
    }
}
