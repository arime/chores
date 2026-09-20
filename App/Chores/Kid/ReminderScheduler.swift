import Foundation
import UserNotifications
import ChoresCore

/// The child's reminders, entirely on-device: no APNs, no certificates, no push
/// tokens on this side of the app. The parent's evening reminder is the push,
/// and lives on the server.
///
/// Renders plans; decides nothing. What to schedule is `ReminderSchedule`'s
/// call, in ChoresCore, where it is tested.
@MainActor
enum ReminderScheduler {

    /// Every request this app owns starts with this, so a reschedule can clear
    /// exactly its own and nothing else.
    private static let identifierPrefix = "chores."

    /// Replaces all previously scheduled reminders with the given plans. The
    /// "replace everything" shape is what makes this idempotent: ticking the
    /// last chore removes today's two, unticking puts back whichever is still
    /// ahead, and neither path has to know what was there before.
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
            // One key with plural variations in the catalog, rather than a
            // ternary here: Finnish takes the partitive singular after a number
            // greater than one, which is a rule the catalog already knows.
            switch plan.slot {
            case .afternoon:
                content.title = String(localized: "Chores today")
                content.body = String(localized: "You have \(plan.remaining) chores today.")
            case .evening:
                content.title = String(localized: "Chores tonight")
                content.body = String(localized: "\(plan.remaining) chores still unticked. Done them? Tick them off.")
            }
            content.sound = .default

            var components = DateComponents()
            components.year = plan.day.year
            components.month = plan.day.month
            components.day = plan.day.day
            components.hour = plan.time.hour
            components.minute = plan.time.minute
            components.timeZone = timeZone

            let request = UNNotificationRequest(
                identifier: "\(identifierPrefix)reminder.\(plan.slot.rawValue).\(ChoresJSON.encodedDay(plan.day))",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))

            try? await center.add(request)
        }
    }
}
