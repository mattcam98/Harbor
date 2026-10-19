#if targetEnvironment(simulator)
import Foundation

/// What scripts/guest-smoke-test.sh asks of Harbor through launch
/// arguments. Compiled only for the iOS Simulator; device builds have none
/// of it.
extension AppModel {
    func runSimulatorHooks() async {
        let defaults = UserDefaults.standard
        // Run a guest beside Harbor.
        if let folder = defaults.string(forKey: "HarborRunBeside"),
           let guest = guests.first(where: { $0.folderName == folder }) {
            await launch(guest, mode: .beside)
        }
        // Open a link, as a Home Screen icon would. The simulator asks before
        // delivering a real one, which a script cannot answer.
        if let link = defaults.string(forKey: "HarborOpenLink"), let url = URL(string: link) {
            await open(url)
        }
        // Add the IPA named on the command line, which the simulator can
        // read from the Mac.
        if let path = defaults.string(forKey: "HarborAddGuest") {
            await addGuest(ipaAt: URL(fileURLWithPath: path))
        }
    }
}
#endif
