import AppKit
import Sparkle

/// Owned only by the menu process; manager/settings instances never start an updater.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    var prepareToInstall: ((@escaping () -> Void) -> Void)?
    var installationAborted: (() -> Void)?
    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.startUpdater()
        synchronize()
    }
    func synchronize() {
        controller.updater.automaticallyChecksForUpdates = GlassPreferences.automaticUpdates
        controller.updater.automaticallyDownloadsUpdates = false
    }
    func check() { if controller.updater.canCheckForUpdates { controller.checkForUpdates(nil) } }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let prepareToInstall else { return false }
        prepareToInstall(installHandler)
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { installationAborted?() }
}
