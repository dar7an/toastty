import Sparkle
import Cocoa

/// Toastty's update entry point. The inherited driver remains available for
/// a future signed update channel, but is never started in preview builds.
class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're installing an update triggered manually.
    var shouldTerminateWithoutWarning: Bool {
        viewModel.state.shouldTerminateWithoutWarning
    }

    /// Initialize a new update controller.
    init() {
        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(
            viewModel: .init(),
            hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: userDriver
        )
    }

    /// Automatic updates remain disabled until Toastty owns a signed appcast.
    func startUpdater() {
        // Toastty has no signed appcast yet. Never start Ghostty's updater.
    }

    func checkForUpdates() {
        if let url = URL(string: "https://github.com/dar7an/toastty/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}
