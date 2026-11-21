import Photos
import Foundation

/// When the timeline asks for Photos access by itself.
///
/// A fresh install used to show the server's photos alone: nothing asked for
/// access until the first backup, and only then did the device's photos join the
/// timeline. The timeline now asks on its first appearance, so the device half
/// is there as soon as the user signs in. Only an access never answered
/// (`.notDetermined`) is asked for, and only with "Show Photos from This Device"
/// on; after a refusal the banner leading to Settings is the only way back.
///
/// Debug builds skip the prompt against a local server. The UI scenarios run
/// against a stub on the loopback and `Scripts/ci.sh` resets the permissions
/// before every row (`simctl privacy reset all`): the system alert would sit
/// over the grid and the simulator's own photos would mix into the timeline,
/// breaking the ~50 scenarios that sign in through the UI without handling it.
/// The scenarios that need the prompt still trigger it through the backup.
/// Release builds ask whatever the host.
enum DeviceAccessPrompt {
    static func shouldAsk(status: PHAuthorizationStatus, showsDeviceAssets: Bool, serverURL: URL?) -> Bool {
        guard showsDeviceAssets, status == .notDetermined else { return false }
        #if DEBUG
        if let host = serverURL?.host?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host) {
            return false
        }
        #endif
        return true
    }
}
