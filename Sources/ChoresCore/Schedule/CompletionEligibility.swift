/// Whether a chore on a given day may be ticked off.
///
/// Children forget to tap, so earlier days in the current week stay open. A strict
/// today-only rule would make the app a source of arguments rather than a record
/// of what actually happened.
public enum CompletionEligibility: Equatable, Sendable {
    case allowed
    /// The day has not happened yet.
    case future
    /// A real past day, but outside the current ISO week.
    case outsideCurrentWeek
}
