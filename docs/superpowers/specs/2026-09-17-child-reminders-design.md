# Child Reminders — Design

**Date:** 2026-09-17
**Status:** Designed, not implemented. Depends on §3 of
`2026-09-17-parent-evening-push-design.md` (the shared foundation).

## 1. Purpose

A child gets one reminder today: "You have 3 chores today", at 16:00, on every weekday
the template gives them something, whether or not they have already done it. The hour is
a constant (`ReminderScheduler.hour = 16`, "Fixed in v1").

Two things are wrong with it for a real household. Children have different afternoons —
one is home at 14:30, the other at 16:15 — and a reminder that fires after the chores
are done teaches the child to ignore it. And there is no second nudge in the evening
for the child who did the chore and forgot to tick it, or who never got round to it.

This design gives each child two reminders, an afternoon heads-up and an evening nag,
each at a time the parent sets, each firing only when something is still unticked.

## 2. Decisions

| Question | Decision |
|---|---|
| Push or local? | **Local.** The child's condition depends almost entirely on ticks made on the child's own device, which is therefore the source of truth. Push would add device identifiers for children and a dependence on connectivity for nothing the phone does not already know. See §9 for the one gap this leaves. |
| One reminder or two? | **Two**, with different wording: afternoon says what there is to do, evening says what is still unticked and asks whether it was done. |
| Per family or per child? | **Per child.** The reason for configurability is that children's days differ; a family setting would only move the problem. |
| Defaults | **15:00 and 20:00**, filled by the trigger in the shared foundation. `null` = off. |
| Conditional? | **Both.** Neither fires when the child's day is already complete, and neither fires on a day with nothing scheduled. |
| Where set? | **The child's edit sheet**, where the parent already sets name and colour. |
| Replace or add? | **Replace.** The fixed 16:00 weekly trigger goes away. |

## 3. Data

Nothing beyond the shared foundation: `profiles.afternoon_reminder_at` and
`profiles.evening_reminder_at`, `TimeOfDay`, the two fields on `Profile`, and the
`updateProfile` payload that sends explicit `null`. The child's device reads its own
profile out of the `FamilySnapshot` it already holds.

## 4. Semantics

For a child on a given local day, with `remaining` = the number of that child's
template entries for the weekday whose chore is not archived and that have no completion
for that date:

| Slot | Fires when | Body |
|---|---|---|
| Afternoon | `afternoon_reminder_at` is set, the time has not passed, `remaining > 0` | "You have 2 chores today." |
| Evening | `evening_reminder_at` is set, the time has not passed, `remaining > 0` | "2 chores still unticked. Done them? Tick them off." |

Ticking the last chore of the day removes both of today's; unticking one puts back
whichever has not yet passed. A day with no entries produces nothing. Times are in the
family's timezone, as everything is.

## 5. Mechanism

### 5.1 `ReminderSchedule` produces dated plans

Today it maps weekday → chore count. It becomes:

```swift
public struct ReminderPlan: Equatable, Sendable {
    public enum Slot: Sendable { case afternoon, evening }
    public let day: CalendarDay
    public let slot: Slot
    public let time: TimeOfDay
    public let remaining: Int
}

public static func plans(for profileID: UUID, snapshot: FamilySnapshot,
                         now: Date, horizonDays: Int = 14) -> [ReminderPlan]
```

`today` is `CalendarDay(now, in: snapshot.family.timeZone)` — the family's day, never a
UTC day, the same rule `FamilyStore.today` follows. For each of the next `horizonDays`
days starting there: look up the child's entries for that weekday against non-archived
chores; subtract completions for that date; for each slot whose time is set and — on
today only — has not yet passed, emit a plan if `remaining > 0`. Ordered by day, then
slot.

The snapshot carries only the current week's completions (`FamilySnapshot.completions`).
That is enough: a future day cannot have completions — `CompletionEligibility.future`
forbids ticking early — so for days beyond this week `remaining` is simply the entry
count, which is correct.

`now` is a parameter so the "already passed" rule is testable.

### 5.2 `ReminderScheduler` schedules one-shots

Replaces every pending request whose identifier starts with `chores.` — the pattern it
uses today — with one `UNNotificationRequest` per plan:

- identifier `chores.reminder.<afternoon|evening>.<yyyy-mm-dd>`
- `UNCalendarNotificationTrigger` with year, month, day, hour, minute and the family's
  timezone, `repeats: false`
- content per slot: title and plural-aware body from the catalog (§7)

At most 28 pending requests, under iOS's limit of 64. Nothing in `ReminderScheduler`
decides anything; it renders plans.

### 5.3 When it runs

`KidRootView` currently reschedules `.onChange(of: store.snapshot?.template)`. It becomes
`.onChange(of: store.snapshot)` — any change: a tick, an untick, a schedule edit, a
changed time. `FamilySnapshot` is `Equatable` already. The recompute is a few dozen rows
and runs on the main actor; no debounce.

It also runs once after `store.start()` completes, as today, so a device that has been
closed for a while rebuilds its fortnight on the next open. Because the horizon is
fourteen days and the child opens the app to tick things, the schedule does not run dry
in practice.

### 5.4 What goes away

`ReminderScheduler.hour`, the weekday-repeating trigger, and the `chores.daily.<weekday>`
identifiers. The `requestAuthorization()` call moves to the shared `Notifications` enum
introduced by the push design; `KidRootView` keeps calling it.

## 6. UI

Two rows on `EditChildSheet`, each the shared toggle-and-picker control from the push
design's §3.3, bound to `afternoonReminderAt` and `eveningReminderAt`: "Afternoon
reminder" and "Evening reminder". Saved with the sheet's existing save through
`updateProfile`. A footnote under the pair: *Each fires only when this child still has
chores unticked. Off means never.*

The child's own screen shows nothing about this. Children do not configure their
reminders.

## 7. Strings

`Localizable.xcstrings`, English source with Finnish. Both bodies are plural keys, as the
existing "You have %lld chores today." already is.

| Key / en | fi (proposed) |
|---|---|
| Chores today *(exists)* | Tehtävät tänään *(exists)* |
| You have %lld chores today. *(exists, plural variants)* | *(exists)* |
| Chores tonight | Illan tehtävät |
| %lld chores still unticked. Done them? Tick them off. — *one:* 1 chore still unticked. Done it? Tick it off. | %lld tehtävää on vielä kuittaamatta. Tehtyjä? Kuittaa ne. — *one:* 1 tehtävä on vielä kuittaamatta. Tehty? Kuittaa se. |
| Afternoon reminder | Iltapäivän muistutus |
| Evening reminder | Illan muistutus |
| Each fires only when this child still has chores unticked. Off means never. | Kumpikin tulee vain, jos lapsella on vielä kuittaamattomia tehtäviä. Pois tarkoittaa ei koskaan. |

The evening body is one catalog key with `one` and `other` variants, like the existing
afternoon body.

The Finnish is a proposal for review.

## 8. Testing

**XCTest**, `Tests/ChoresCoreTests/ReminderScheduleTests.swift`, extended:

- a slot set to `null` produces no plans for that slot
- today's slot whose time has passed is skipped; tomorrow's is not
- a day whose entries are all completed produces nothing; completing the last one removes
  today's plans, uncompleting restores the one still ahead
- archived chores do not count toward `remaining`
- a weekday with no entries produces nothing
- the horizon is exactly `horizonDays` days starting today
- ISO weekday mapping across a week boundary
- midnight in the family's timezone: `now` just before and just after midnight puts
  "today" on the right calendar day

**pgTAP**, in `02_evening_reminder.sql` from the push design: a child's two columns
accept a time and `null`; a child cannot update their own reminder times (`profiles_update`
requires `is_parent()`).

**Manual**: set a child's afternoon reminder two minutes ahead on a device, tick nothing,
see it arrive; tick everything, see it not.

## 9. Known gap

A parent who ticks on the child's behalf **before** the child's reminder hour, without
the child's app having refreshed since, leaves the child's device believing the chore is
open. The reminder fires; the child opens the app and sees the day complete. It is
self-correcting and, for the afternoon slot, uncommon — parent-on-behalf ticks cluster in
the evening. For the evening slot it is more likely.

If it turns out to bite, the fix is push for children: let child devices register a
token, and group `evening_reminder_work()` by child profile as well as parent. Nothing in
this design has to be undone for that; the times already live on the server and the
"undone for this profile on this date" SQL already exists. That decision is deferred until
it is a known problem.

## 10. Out of scope

- Per-family defaults for new children. New children get 15:00 and 20:00.
- A second afternoon or evening slot.
- Configuring reminders from the child's own screen.
