import Foundation
import UserNotifications
import ChoresCore

/// Entirely on-device: no APNs, no certificates, no push tokens.
@MainActor
enum ReminderScheduler {

    private static let identifierPrefix = "chores.daily."
    /// Fixed in v1. Not configurable.
    private static let hour = 16

    static func requestAuthorization() async {
        // A refusal is fine — the app simply never notifies.
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// Replaces all previously scheduled reminders with the given plans.
    static func reschedule(plans: [ReminderPlan], timeZone: TimeZone) async {
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return }

        let existing = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: existing.map(\.identifier)
                .filter { $0.hasPrefix(identifierPrefix) })

        for plan in plans {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Chores today")
            // One key with plural variations in the catalog, rather than a
            // ternary here: Finnish takes the partitive singular after a number
            // greater than one, which is a rule the catalog already knows.
            content.body = String(localized: "You have \(plan.choreCount) chores today.")
            content.sound = .default

            var components = DateComponents()
            // UNCalendarNotificationTrigger uses 1 = Sunday, so ISO Monday (1) becomes 2.
            components.weekday = plan.isoWeekday == 7 ? 1 : plan.isoWeekday + 1
            components.hour = hour
            components.minute = 0
            components.timeZone = timeZone

            let request = UNNotificationRequest(
                identifier: "\(identifierPrefix)\(plan.isoWeekday)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))

            try? await center.add(request)
        }
    }
}
