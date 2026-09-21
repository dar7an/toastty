import Sparkle

extension UpdateController: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // Use the feed sealed into this app, never an inherited preference.
        Bundle.main.infoDictionary?["SUFeedURL"] as? String
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        AppDelegate.logger.info("Nightly \(item.versionString) is ready to install on quit")
        // Sparkle installs on normal quit and can offer its standard UI later.
        // Never invoke the immediate restart handler in the background.
        return false
    }
}
