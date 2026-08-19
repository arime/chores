# Finnish Localization — Design

**Date:** 2026-08-19
**Status:** Designed, not implemented.

## 1. Purpose

The app is written in English and hardcodes it. Every user-facing string is an English
literal sitting in a SwiftUI view, there is no `.xcstrings` anywhere, and
`developmentRegion` is `en` with `knownRegions = (en, Base)`.

Its users are a Finnish household. This design adds Finnish without removing English:
English stays the source language and the fallback, Finnish arrives as a translation, and
the device's language setting picks between them.

## 2. Decisions

| Question | Decision |
|---|---|
| Finnish-only or bilingual? | **Bilingual.** English stays the source language; Finnish is a translation. Nothing is lost, and a third language later costs one more column. |
| Where do the keys come from? | **The English text itself.** SwiftUI literals are already `LocalizedStringKey`, so most call sites need no edit at all. |
| Who populates the catalog? | **Hand-authored JSON.** `xcodebuild` does not write extracted strings back into a catalog — only the Xcode IDE does — so the file is written directly from the literals in source. |
| Register | **Informal throughout** (sinuttelu). One voice for children and parents both; the English copy is warm and the Finnish should match. |
| "chore" | **tehtävä.** Short, neutral, and a child reads it without effort. Rejected: *kotityö* (heavy in buttons), *askare* (a word many children don't know). |
| App display name | **Stays "Chores"** in every language. No `InfoPlist.xcstrings`, and the name stays stable in App Store Connect. |
| UI tests | **Pinned to English.** The suite asserts English labels in a dozen places; pinning keeps every one of them passing untouched. |
| Localize `ChoresCore`? | **No.** It has no user-facing strings — see §4. |

## 3. Mechanism

One file: `App/Chores/Localizable.xcstrings`, `sourceLanguage` `en`, with an `fi`
localization per key.

The app target is a `PBXFileSystemSynchronizedRootGroup`, so a file dropped into
`App/Chores/` is compiled in with no pbxproj group entry. Two project edits are still
needed:

- `fi` added to `knownRegions`.
- `SWIFT_EMIT_LOC_STRINGS = YES` on the Chores target, so that anyone who later opens the
  project in Xcode gets extraction into the catalog rather than a catalog that silently
  stops tracking new strings.

At build time `XCStringsTool` compiles the catalog into `en.lproj/` and `fi.lproj/`
inside the `.app`. A key present in code but absent from the catalog does not fail the
build — it falls back to English silently. That failure mode is the reason §8 exists.

## 4. Why `ChoresCore` is untouched

Worth stating because the opposite is the usual arrangement. `ChoresBackendError` is a
plain enum of cases — `notAuthenticated`, `alreadyClaimed`, `claimCodeExpired` — carrying
no message. Every string a person reads is composed in a view in the app target. The
package therefore needs no bundle, no `Bundle.module` lookups, and no
`defaultLocalization` in `Package.swift`.

This is a property worth keeping: the moment a `String` describing a failure appears in
`ChoresCore`, the package acquires a resource bundle and the localization story splits in
two.

## 5. What changes at the call sites

Three categories, in ascending order of care required.

**Free — roughly 120 sites.** `Text("Nothing today")`, `Button("Add")`,
`.navigationTitle("Manage")`, `ContentUnavailableView("…")`, `.alert("…")`. These
arguments are already `LocalizedStringKey`. Adding the catalog makes them resolve through
it; the code does not move.

**Needs `String(localized:)` — roughly a dozen sites.** `Text(errorMessage)` binds the
`StringProtocol` overload, which does *not* localize. Every `errorMessage = "Couldn't add
\(name)…"` assignment in `PeopleView`, `ChoresView`, `ScheduleEditorView`,
`ClaimCodeSheet`, `EditChildSheet`, `ParentRootView`, `ClaimCodeView`, `CreateFamilyView`
and `ParentSignInView` becomes `String(localized:)`. So do
`ReminderScheduler`'s `content.title` and `content.body`, which are `String` properties on
`UNMutableNotificationContent`.

**Needs the overload pinned explicitly — five sites.** A ternary of two string literals
inside `Text(...)` or `.accessibilityLabel(...)` leaves the compiler to choose between the
`LocalizedStringKey` and `String` overloads, and which one it picks is not obvious from
reading it:

- `AssignChoreSheet.swift:27`
- `EditChildSheet.swift:55`
- `ParentRootView.swift:149`, `:160`
- `ParentWeekView.swift:135`

Each is hoisted into a computed property with an explicit `LocalizedStringKey` annotation,
which settles the overload by declaration instead of by inference:

```swift
private var emptyMessage: LocalizedStringKey {
    chores.isEmpty
        ? "Every chore is already assigned."
        : "\(child.displayName) already has every chore on this day."
}
```

Guessing wrong here produces exactly the silent English fallback that a build cannot
catch.

**Explicitly not touched:** `.accessibilityIdentifier("people.addChild")` and its
siblings. Those are identifiers the UI tests query by, they are not read by anyone, and
localizing one would break a test in a way that looks like a UI bug.

## 6. The Finnish constraint that shapes the copy

Finnish inflects. English composes its sentences by concatenation, and several strings in
this app interpolate a name or a weekday into the middle of one:

```swift
Text("Enter this on \(profile.displayName)'s device")     // ClaimCodeSheet.swift:18
.navigationTitle("Assign to \(child.displayName)")        // AssignChoreSheet.swift:33
Button("Copy \(WeekdayNames.full(selectedWeekday)) to…")  // ScheduleEditorView.swift:81
errorMessage = "Couldn't add \(name)…"                    // PeopleView.swift:161
```

A faithful Finnish translation of each would need the interpolated word in the genitive
(*Liisan laitteella*), the allative (*Liisalle*), or the genitive of a weekday
(*maanantain*). None of those can be produced from a `%@` at runtime: the substitution is
a name the parent typed, or a `DateFormatter` symbol in the nominative.

**The rule for the Finnish copy is therefore: reword so every substituted word stays in
the nominative.** Finnish has the constructions for it, and they read naturally:

| English | Finnish |
|---|---|
| `Enter this on %@'s device` | `Syötä tämä koodi laitteella, jota %@ käyttää` |
| `Assign to %@` | `Lisää tehtävä: %@` |
| `Delete %@?` | `Poistetaanko %@?` |
| `Couldn't add %@. Check your connection and try again.` | `Lisääminen epäonnistui: %@. Tarkista yhteys ja yritä uudelleen.` |

The weekday cases do not yield to rewording as cleanly, because "Copy Monday to…" wants
*maanantain* and no nominative phrasing of it is short. They are resolved by dropping the
substitution instead: the Finnish values for `ScheduleEditorView`'s copy button and its
sheet title read `Kopioi tämä päivä…` and `Kopioi päivä`. A localization is permitted to
leave a format argument unused, and here nothing is lost — the segmented day picker
directly above the button already shows which day is selected, so naming it again in the
button was redundant even in English.

Rejected: a Finnish weekday-genitive table in the app. Weekday names come from
`DateFormatter` precisely so no such table exists, and adding one for a single button
trades a real maintenance burden for a phrasing that rewording already solves.

## 7. Numbers

Two strings vary with a count.

`"\(progress.done) of \(progress.total) done"` has key `%lld of %lld done` and becomes
`%1$lld tehty, %2$lld yhteensä`. Neither *tehty* nor *yhteensä* agrees with a number, so
no inflection arises.

That one key has three call sites: the section header in `KidTodayView.swift:58`, and the
VoiceOver labels in `ProgressRing.swift:27` and `ParentWeekView.swift:135`. Sharing it
means the visible and the spoken form are necessarily identical, which is why the Finnish
is worded rather than punctuated — the obvious `%1$lld / %2$lld tehty` looks right on
screen but VoiceOver reads the slash aloud as *kautta*.

`ReminderScheduler`'s notification body currently branches on a ternary between
`"You have 1 chore today."` and `"You have \(count) chores today."`. That collapses into
one key with plural variations, which is what the catalog is for:

| | English | Finnish |
|---|---|---|
| `one` | You have 1 chore today. | Sinulla on 1 tehtävä tänään. |
| `other` | You have %lld chores today. | Sinulla on %lld tehtävää tänään. |

Finnish takes the partitive singular after a number greater than one — *tehtävää*, not
*tehtäviä* — which the CLDR `other` category expresses correctly.

`ProgressRing.swift:19`'s `Text("\(done)/\(total)")` is digits and a slash. It goes in the
catalog with the Finnish value identical to the English, rather than being excluded, so
that the §8 check can assume every key is present.

## 8. Dates and weekdays come free

`CalendarDay.formattedLong`/`formattedShort` use
`setLocalizedDateFormatFromTemplate`, and `WeekdayNames` reads
`standaloneWeekdaySymbols` off a default-locale `DateFormatter`. Both follow the device
language with no change: `Monday 10 August` becomes `maanantai 10. elokuuta`.

One cosmetic consequence. `WeekdayNames` applies `.capitalized`, and Finnish does not
capitalize weekdays. In the week header and the day picker — where the weekday stands
alone as a label rather than inside a sentence — an initial capital is conventional in
Finnish UI too, so this stays as it is.

## 9. Testing

**UI tests are pinned to English.** They query visible labels in a dozen places —
`app.tabBars.buttons["Manage"]`, `app.buttons["People"]`, `fillAlert(confirm: "Add")`,
`app.staticTexts["0 of 1 done"]`, `app.staticTexts["Nothing today"]` — and pinning the
language keeps all of them true without editing a single assertion.

There are four launch sites: `ParentUITestCase.swift:15`, `OnboardingUITests.swift:16`,
`KidUITests.swift:14`, `LostSessionUITests.swift:14`. Rather than repeat the arguments
four times, an `XCUIApplication` extension in the test target takes the mode flag and
appends `-AppleLanguages (en)` and `-AppleLocale en_US`.

**Unit tests are unaffected.** `swift test` exercises `ChoresCore`, which per §4 holds no
strings.

**The Finnish rendering gets no automated coverage.** This is a deliberate gap, and the
reason §10 exists: a suite that runs in English cannot notice a missing translation, and
a second suite in Finnish would double the UI-test runtime to assert a handful of labels.
The manual pass is cheaper and catches more — including the two things a test never
would, which are whether the Finnish reads naturally and whether it fits the button.

## 10. Verifying the sweep

A missing key is invisible: it compiles, it runs, and it shows English. So the
implementation ends with three checks rather than a green build.

1. **Key coverage.** Diff the set of keys the compiler extracts against the set the
   catalog defines. Neither direction may be non-empty — a key in code and not the catalog
   is an untranslated string, and a key in the catalog and not the code is a stale one that
   will drift.

   The authoritative source is the compiler's own output: with
   `SWIFT_EMIT_LOC_STRINGS = YES`, each compilation emits a `.stringsdata` file into
   `Build/Intermediates.noindex/`, listing every key it extracted. That beats grepping
   source, because it is the same extraction the IDE uses and it cannot disagree with what
   actually shipped. If those files turn out not to be reachable from a command-line
   build, the fallback is a grep over the call-site forms enumerated in §5 — weaker,
   since it can only find the patterns it is told to look for.
2. **The catalog compiled.** `fi.lproj/Localizable.strings` exists in the built `.app` and
   holds the expected number of entries.
3. **A manual pass in Finnish.** Run the simulator with the system language set to
   Finnish and walk both modes: onboarding, the parent's four tabs, the kid's two, one
   error path, and the notification. Check for text that overflows its control — Finnish
   words run longer than English ones, and *Tarkista yhteys ja yritä uudelleen* is a
   good deal wider than *Check your connection*.

The coverage check is run once, at implementation time, and not committed as a script.
Two languages and one maintainer do not need a CI gate; when a third language arrives,
that is the moment to write one.

## 11. Out of scope

- **An in-app language switcher.** iOS 13 and later give every app a per-app language
  setting in Settings, which is where users look for it.
- **Localizing the App Store listing, the app name, or the notification permission
  prompt.** The listing is written by hand at submission time; the name is decided in §2;
  the system prompt takes its wording from iOS.
- **Localizing `ChoresCore`** — see §4.
- **A committed lint or CI check for missing translations** — see §10.
- **Any other language.** The catalog makes adding one a matter of a column, but nothing
  in this design is shaped by an anticipated third language.
