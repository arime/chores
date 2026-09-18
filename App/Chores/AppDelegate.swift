import UIKit

/// Exists for one callback: the APNs device token, which UIKit hands only to
/// the application delegate. Everything else about push lives in
/// `PushRegistrar`, and this forwards to it without knowing anything about it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by `ChoresApp` before any token can arrive.
    var onDeviceToken: ((String) -> Void)?

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        onDeviceToken?(hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No token means no reminder on this phone. Nothing else in the app
        // depends on it, so there is nothing to show anyone.
    }
}
