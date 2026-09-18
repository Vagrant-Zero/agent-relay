import AppKit
import Sparkle
final class Probe: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        print("available:\(item.versionString)"); fflush(stdout)
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error = error as NSError?, error.code != SUError.noUpdateError.rawValue {
            fputs("\(error)\n", stderr); exit(1)
        }
        print("finished"); exit(0)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let host = Bundle(path: CommandLine.arguments[1])!
let delegate = Probe()
let driver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: delegate)
try updater.start()
updater.automaticallyChecksForUpdates = false
updater.checkForUpdateInformation()
DispatchQueue.main.asyncAfter(deadline: .now()+20) { fputs("Update probe timed out\n",stderr); exit(2) }
application.run()
