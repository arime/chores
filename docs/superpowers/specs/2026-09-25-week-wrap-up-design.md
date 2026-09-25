# Week Wrap-up Card — Design

**Date:** 2026-09-25
**Status:** Approved in conversation; implementation plan to follow.
**Source:** the two design handoffs of 2026-09-24, `design_handoff_kid_mode_refresh/README.md`
(section "Week wrap-up card (kid)") and `design_handoff_parent_mode/README.md`
(section "Week wrap-up card (Family)"). Those hold the visual detail — sizes, colours,
copy tables — and this document does not repeat it. This document records what the
handoffs leave open and how the card fits the code.

## 1. Purpose

From Sunday evening through Monday, both modes show a dismissable card summarising the
week: the kid sees their own count, seven dots and a line of encouragement; the parent
sees one row per child with a percentage. The parent card's line is honest — "Every chore
for this week is ticked" only when it is true — and the kid's Sunday line only promises
"still time" because earlier days of the current week remain tickable.

Monday's card reports the *previous* ISO week, which the app does not fetch today. Making
that data available is the only structural change.

## 2. Decisions

| Question | Decision |
|---|---|
| How does last week reach the device? | **Always fetch two ISO weeks**: previous Monday through this Sunday. One code path, no Monday branch, no second query. Roughly double the completion rows, still a handful. |
| Stale data on Monday morning? | **Show the card regardless.** The strip and lists are equally stale, and the stale banner already sits above the card. The card re-reads the store and corrects itself when the refresh lands. |
| Dismissal | **One dismissal per reported week.** Sunday's card and Monday's card are about the same week and share one key, so dismissing the Sunday nudge also hides Monday's result. The key is the reported ISO week, e.g. `2026-W39`. |
| Window | Sunday **from 18:00** local (the family's time zone) **through Monday 23:59:59**. Sunday reports the week containing today; Monday reports the previous week. |
| Nothing scheduled all week | **No card.** A wrap-up of zero chores says nothing. A single child with nothing scheduled still gets their "Nothing scheduled" row on the parent card. |
| Re-evaluation while open | On every store change (ticks, refresh, foreground). **No timer.** A screen left open across 18:00 on Sunday flips at the next change. |
| Where the rules live | **In `ChoresCore`**, as a pure `WeekWrapUp` type, so window boundaries, week choice, key format and copy thresholds are unit-tested. Views only render. |
| Migration | **None.** The fetch window is client-side. The shipped build keeps working. |
| Week review screen | **Out of scope**, as the handoff says. The parent prototype still carries one, plus a kicker link on Family that opens it; both are ignored. No link from the card. |
| Seeing it on a device | A **`-frozenNow`** launch argument, honoured only on the in-memory fixture paths, pins the clock the store and the seed use. Without it there is no way to photograph the card, since the simulator's clock cannot be moved. |

## 3. Data

### 3.1 Fetch window

`ChoresBackend.fetchSnapshot(familyID:weekOf:)` keeps its signature. Both backends now
compute the range as the Monday of the week *before* the one containing `day` through the
Sunday of the week containing it:

- **Supabase**: `completions` filtered `due_on >= firstDay` (previous Monday) `and <= lastDay`
  (this Sunday). The `schedule_entries_all` filter already takes a range and gets the earlier
  Monday: `valid_from <= lastDay and (valid_until is null or valid_until > firstDay)`.
- **In-memory**: the same two bounds; the `weekDays` set becomes a fourteen-day range.

`FamilySnapshot`, `SnapshotCache` and the outbox are unchanged. A cached snapshot written by
the shipped build simply has one week in it; the next refresh brings two.

`ScheduleResolver.eligibility` is unchanged: a previous-week day stays
`.outsideCurrentWeek`, read-only. The card is informational, not a way back into last week.

### 3.2 `WeekWrapUp` (ChoresCore)

```swift
public struct WeekWrapUp: Equatable, Sendable {
    public enum Moment: Sendable { case sundayEvening, monday }

    public let moment: Moment
    /// The seven days reported on, Monday first.
    public let week: [CalendarDay]
    /// "2026-W39" — the reported ISO week, used as the dismissal key.
    public let key: String

    /// nil outside Sunday 18:00 … Monday 23:59:59 in `timeZone`.
    public static func current(now: Date, timeZone: TimeZone) -> WeekWrapUp?

    /// Percentage, rounded to the nearest integer; 0 when total is 0.
    public static func percent(done: Int, total: Int) -> Int

    /// The kid card's Monday line.
    public enum KidVerdict: Sendable { case complete, great, good, freshStart }
    /// complete at 100 %, great at ≥ 80 %, good at ≥ 50 %, otherwise freshStart.
    public static func kidVerdict(done: Int, total: Int) -> KidVerdict

    /// The parent card's per-child percentage colour.
    public enum Tone: Sendable { case complete, warn, neutral }
    /// complete at 100 %, warn under 60 %, otherwise neutral.
    public static func tone(done: Int, total: Int) -> Tone
}
```

`key` uses the ISO week-numbering year and week of the reported week's Monday
(`Calendar(identifier: .iso8601)`), so the week spanning New Year keys correctly.

### 3.3 `FamilyStore`

Two additions, nothing removed:

```swift
/// The injected clock, so views never read `Date()` themselves.
public var now: Date { clock() }

/// `progress(for:on:)` summed over `days`.
public func weekProgress(for profileID: UUID, in days: [CalendarDay]) -> (done: Int, total: Int)
```

### 3.4 Frozen clock for fixtures

`AppEnvironment` gains `let clock: @Sendable () -> Date`, defaulting to `Date.init`.
`KidRootView` and `ParentRootView` pass it to `FamilyStore`. On the screenshot and UI-test
fixture paths, `-frozenNow 2026-09-27T18:30:00+03:00` (ISO 8601 with offset) pins the clock
and feeds the same instant to the seed's `today`. The live path ignores the argument.

The demo seed (`seedDemoFamily`) also fills the **previous** week so Monday's card has
something to say: the first child ticked everything, the second everything but two, the
third about half. The current week's shape is unchanged.

## 4. Views

### 4.1 Shared (DesignSystem)

- `wrapUpCard()` view modifier: surface fill, `Theme.cornerRadius`, 1pt inset `neutral800`
  edge, 14pt padding.
- `CardDismissButton`: 32pt square, 14pt `xmark` in `neutral600`, trailing top corner.
- `FadingRule` already takes a `ramp`; the parent rows use 24.

### 4.2 `KidWrapUpCard` (App/Chores/Kid)

Inputs: `store`, `profile`, `hue`, `wrapUp: WeekWrapUp`, `onDismiss`. Layout per the kid
README: title 17pt medium, line 13pt `neutral300`; count "{done} of {total}" 28pt medium
monospaced in the accent (child colour, or `Theme.done` when complete); the week's seven
`DayDot`s at 9pt, 5pt apart; a 2pt progress capsule filled in the accent. On Monday every
dot is a past day (`isFuture` false, `isToday` false).

Copy, from `wrapUp.moment` and `WeekWrapUp.kidVerdict`:

| Moment | Condition | Title | Line |
|---|---|---|---|
| Sunday | all ticked | Week complete! | You ticked every single chore. Nice one. |
| Sunday | some left | Nearly the end of the week | %lld left to tick — there's still time before bed. |
| Monday | complete | Last week | Every chore, every day. Legend. |
| Monday | great | Last week | Great week! Keep it rolling. |
| Monday | good | Last week | Good going. New week, fresh start. |
| Monday | freshStart | Last week | New week, fresh start! |

Placement in `KidDayView`: after the header (and the stale card, when shown), before the
strip. Hidden when `total == 0`.

### 4.3 `FamilyWrapUpCard` (App/Chores/Parent)

Inputs: `store`, `children`, `wrapUp`, `onDismiss`. Layout per the parent README: title
15pt medium, line 12pt `neutral500`; then one 36pt row per child with a fading rule on top
(24pt ramps): 8pt colour dot, name 14pt, "{done} of {total}" 14pt `neutral300` monospaced,
percentage 14pt medium right-aligned in 40pt, coloured by `WeekWrapUp.tone`. A child with
`total == 0` shows "Nothing scheduled" and no percentage. Bottom padding 8pt rather than 14,
as the prototype has it.

Copy, from the family-wide totals:

| Moment | Condition | Title | Line |
|---|---|---|---|
| Sunday | all ticked | This week, wrapped up | Every chore for this week is ticked. |
| Sunday | some left | This week so far | %@ of this week's chores ticked so far. |
| Monday | — | Last week | %@ of chores were ticked, %@. |

The first `%@` is the percentage, formatted with `FormatStyle.percent` ("40%" in English,
"40 %" in Finnish). The Monday's second `%@` is the week range in the format `FamilyView`
already draws for its kicker.

Placement in `FamilyView`: after the header and stale card, before the strip. Hidden when the
family-wide `total == 0`.

### 4.4 Dismissal

`@AppStorage` holding the dismissed key as a string.

- Parent: key `wrapUpDismissedWeek`, declared on `FamilyView`.
- Kid: key `wrapUpDismissedWeek.<profile.id>`, assigned in `KidDayView.init` via
  `AppStorage(wrappedValue:_:)`, since the key is dynamic.

The card shows when `wrapUp.key != dismissedKey`. Dismissing sets the key inside
`withAnimation(.snappy)` so the card collapses the way done rows sink.

## 5. Localisation

New catalogue entries, English source with Finnish, in the existing `Localizable.xcstrings`
style (Xcode's separators, keys unsorted by hand). Finnish drafts below; the playful lines
are the author's call and are flagged for review in the plan.

Percentages are formatted with `FormatStyle.percent` and interpolated as strings, so the
keys carry `%@`, not `%lld%%`: SwiftUI runs an interpolated key through `String(format:)`,
where a bare `%` followed by a space and a letter is read as a directive.

| Key | Finnish draft |
|---|---|
| Week complete! | Viikko valmis! |
| Nearly the end of the week | Viikko on melkein paketissa |
| Last week | Viime viikko |
| You ticked every single chore. Nice one. | Teit ihan joka ikisen tehtävän. Hienoa! |
| %lld left to tick — there's still time before bed. | Vielä %lld tekemättä — ehdit hyvin ennen nukkumaanmenoa. |
| Every chore, every day. Legend. | Joka tehtävä, joka päivä. Legenda. |
| Great week! Keep it rolling. | Mahtava viikko! Samaan malliin. |
| Good going. New week, fresh start. | Hyvin menee. Uusi viikko, uusi alku. |
| New week, fresh start! | Uusi viikko, uusi alku! |
| This week, wrapped up | Viikko paketissa |
| This week so far | Viikko tähän mennessä |
| Every chore for this week is ticked. | Kaikki tämän viikon tehtävät on tehty. |
| %@ of this week's chores ticked so far. | %@ tämän viikon tehtävistä on tehty. |
| %@ of chores were ticked, %@. | Viikolla %2$@ tehtiin %1$@ tehtävistä. (The Finnish short date ends in a full stop, so the range cannot end the sentence.) |
| %lld of %lld | %1$lld/%2$lld |
| Dismiss | Sulje |

"Nothing scheduled" is reused.

## 6. Testing

| Layer | Proves |
|---|---|
| `WeekWrapUpTests` (new) | In Europe/Helsinki: Sunday 17:59 → nil; Sunday 18:00 → `.sundayEvening` reporting the week containing that Sunday; Monday 00:00 and 23:59 → `.monday` reporting the previous week; Tuesday → nil. The same instant is Sunday evening in Helsinki and Sunday afternoon in UTC, so the zone matters. `key` for a week spanning New Year (Mon 2026-12-28 → `2026-W53`). `percent` rounds and handles zero. `kidVerdict` and `tone` at each boundary, including `total == 0`. |
| `InMemoryBackendTests` | A snapshot fetched for a day carries last week's completions and a template row that closed last Wednesday, and still excludes a completion from two weeks ago. |
| `FamilyStoreTests` | `weekProgress` sums a previous-week day with the current week; `now` returns the injected clock. |
| `ModelDecodingTests` | Unchanged; no model changes. |
| UI tests / screenshots | No new assertions. `tools/screenshots.sh` may add a Sunday-evening and a Monday capture with `-frozenNow`; whether to ship those in the listing is a separate decision. |

Manual check: launch the screenshot fixture with `-frozenNow` at each moment in both modes,
dismiss, relaunch, confirm it stays dismissed for that week and returns the week after.

## 7. What this does not do

- No week review screen and no link to one.
- No timer to flip the card at 18:00 while the screen is idle.
- No history beyond one previous week; the fetch window is exactly two.
- No per-moment dismissal.
- No Finnish copy review inside this design; the plan flags it.
