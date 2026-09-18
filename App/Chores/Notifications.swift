import UserNotifications

/// The one permission both sides of the app ask for: a child for its local
/// reminders, a parent for the push.
enum Notifications {
    static func requestAuthorization() async {
        // A refusal is fine — the app simply never notifies.
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }
}
