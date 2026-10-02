import Foundation

/// macOS gives the two-finger swipe in from the trackpad's right edge to Notification Center.
/// The panel can only use that swipe while the system gesture is switched off, which is the
/// same setting as System Settings → Trackpad → More Gestures → Notification Center.
enum NotificationCenterGesture {
    private static let settings: [(arguments: [String], key: String)] = [
        (["write", "com.apple.AppleMultitouchTrackpad"], "TrackpadTwoFingerFromRightEdgeSwipeGesture"),
        (["write", "com.apple.driver.AppleBluetoothMultitouch.trackpad"], "TrackpadTwoFingerFromRightEdgeSwipeGesture"),
        (["-currentHost", "write", "NSGlobalDomain"], "com.apple.trackpad.twoFingerFromRightEdgeSwipeGesture"),
    ]

    /// On unless explicitly switched off; a missing value means the macOS default.
    static var isEnabled: Bool {
        let value = CFPreferencesCopyAppValue("TrackpadTwoFingerFromRightEdgeSwipeGesture" as CFString,
                                              "com.apple.AppleMultitouchTrackpad" as CFString)
        return (value as? Int) != 0
    }

    static func setEnabled(_ enabled: Bool) {
        for setting in settings {
            run("/usr/bin/defaults", setting.arguments + [setting.key, "-int", enabled ? "3" : "0"])
        }
        // Makes the trackpad driver pick the change up without logging out.
        run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
        CFPreferencesAppSynchronize("com.apple.AppleMultitouchTrackpad" as CFString)
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
