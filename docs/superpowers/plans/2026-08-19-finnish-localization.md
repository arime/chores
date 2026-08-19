# Finnish Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Finnish to the app as a translation, with English remaining the source language and the fallback, so a Finnish device shows Finnish and every other device is unchanged.

**Architecture:** One String Catalog (`App/Chores/Localizable.xcstrings`) keyed on the existing English text, since SwiftUI's `Text`/`Button`/`navigationTitle` arguments are already `LocalizedStringKey` and resolve through a catalog with no code change. The work is therefore: get the handful of non-localizing call sites to localize, get the eleven strings currently inside `ChoresCore` out of it, then author the catalog.

**Tech Stack:** SwiftUI, Swift 6, Xcode 26, String Catalogs (`.xcstrings`), `XCStringsTool`, swift-testing (`swift test`), XCUITest.

**Spec:** [`docs/superpowers/specs/2026-08-19-finnish-localization-design.md`](../specs/2026-08-19-finnish-localization-design.md)

## Global Constraints

- **English is the source language.** Never edit an English string to make translation easier. The English text *is* the catalog key — changing it orphans the entry.
- **Register: informal Finnish throughout** (sinuttelu). One voice for children and parents alike.
- **"chore" is always `tehtävä`**, never *kotityö* or *askare*. Plural `tehtävät`, partitive `tehtävää`.
- **Cross-references must match the tab and row names they point at.** Three strings say "Manage → People" and one says "Manage → Chores"; in Finnish those are `Hallinta → Ihmiset` and `Hallinta → Tehtävät`, matching the `Label` strings in `ManageView`.
- **Every substituted value stays in the nominative.** Finnish inflects and `%@` cannot. Reword the Finnish rather than inflecting a name or weekday — see spec §6.
- **Never touch a string passed to `.accessibilityIdentifier(...)`.** Those are identifiers the UI tests query by, not text anyone reads.
- **`swift test` must stay at 141 passing tests, and the UI suite at 23**, throughout. No test is deleted by this plan; four change what they assert. Where a step below says "13 UI tests", read 23. (`README.md:29-32` claims 111 and 13 — both counts are stale, and were already stale before this work.)
- **Two strings are deliberately kept out of the catalog** — see Task 3, Step 1. The app name `"Chores"` on the launch screen and the empty `Text("")` spacer both become `Text(verbatim:)`.

---

### Task 1: Move the onboarding error messages out of `ChoresCore`

`OnboardingViewModel.message(for:)` maps `ChoresBackendError` to eleven English sentences, and two guard clauses add their own. `ChoresCore` has no bundle and should not acquire one, so the mapping moves to the app target and the view model exposes a typed failure instead.

**Files:**
- Modify: `Sources/ChoresCore/ViewModels/OnboardingViewModel.swift:15` (the property), `:26-29`, `:40`, `:47-50`, `:67`, `:72-99` (the mapping)
- Create: `App/Chores/Onboarding/OnboardingFailureText.swift`
- Modify: `App/Chores/Onboarding/ClaimCodeView.swift:35-39`
- Modify: `App/Chores/Onboarding/CreateFamilyView.swift:27-31`
- Test: `Tests/ChoresCoreTests/OnboardingViewModelTests.swift:105`, `:121-122`, `:130`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `public enum OnboardingFailure` and `OnboardingViewModel.failure: OnboardingFailure?`, replacing `errorMessage: String?`. The app target gains `OnboardingFailure.text: String`. Task 4 translates the strings that `text` returns.

- [ ] **Step 1: Rewrite the four assertions that check English prose**

In `Tests/ChoresCoreTests/OnboardingViewModelTests.swift`, replace the substring checks with equality against cases. Line 105:

```swift
#expect(model.failure == .unknownClaimCode)
```

Lines 121-122 (two assertions collapse into one):

```swift
#expect(model.failure == .claimCodeAlreadyUsed)
```

Line 130:

```swift
#expect(model.failure == .projectUnavailable)
```

Then update the five assertions that only check for presence or absence — lines 32, 57, 93, 152, 156 — from `model.errorMessage` to `model.failure`, keeping their `== nil` / `!= nil` comparisons exactly as they are.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter OnboardingViewModelTests`
Expected: FAIL to compile — `value of type 'OnboardingViewModel' has no member 'failure'`.

- [ ] **Step 3: Add the enum and swap the property**

In `Sources/ChoresCore/ViewModels/OnboardingViewModel.swift`, add above the class:

```swift
/// Why an onboarding step failed. A case rather than a sentence: the wording
/// belongs to whatever is showing it, and this package has no bundle to
/// translate one from.
public enum OnboardingFailure: Equatable, Sendable {
    case bothNamesRequired
    case codeRequired
    case unknownClaimCode
    case claimCodeAlreadyUsed
    case claimCodeExpired
    case alreadyClaimed
    case projectUnavailable
    case sessionUnavailable
    case mustSignIn
    case notPermitted
    /// A detail string from the server, or an `Error` this enum does not
    /// recognise. Untranslatable by nature — it is shown as it arrives.
    case other(String)
}
```

Replace line 15 with:

```swift
    public private(set) var failure: OnboardingFailure?
```

- [ ] **Step 4: Replace the assignments and the mapping**

Four assignment sites, in order: line 27 becomes `failure = .bothNamesRequired`; line 33 becomes `failure = nil`; line 40 becomes `failure = Self.failure(for: error)`; line 48 becomes `failure = .codeRequired`; line 54 becomes `failure = nil`; line 67 becomes `failure = Self.failure(for: error)`.

Then replace `message(for:)` (lines 72-99) with:

```swift
    private static func failure(for error: Error) -> OnboardingFailure {
        switch error as? ChoresBackendError {
        case .unknownClaimCode:      .unknownClaimCode
        case .claimCodeAlreadyUsed:  .claimCodeAlreadyUsed
        case .claimCodeExpired:      .claimCodeExpired
        case .alreadyClaimed:        .alreadyClaimed
        case .projectUnavailable:    .projectUnavailable
        case .notAuthenticated:      .sessionUnavailable
        case .mustSignIn:            .mustSignIn
        case .notPermitted:          .notPermitted
        case .underlying(let detail): .other(detail)
        case nil:                    .other(error.localizedDescription)
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test`
Expected: PASS, 111 tests. The app target does not build yet — that is Step 6.

- [ ] **Step 6: Add the text mapping in the app target**

Create `App/Chores/Onboarding/OnboardingFailureText.swift`. The English here is moved verbatim from the old `message(for:)` — do not reword it, since it becomes the catalog key in Task 4:

```swift
import Foundation
import ChoresCore

extension OnboardingFailure {
    /// Every message names what to do next. "An error occurred" would leave an
    /// eleven-year-old stuck.
    var text: String {
        switch self {
        case .bothNamesRequired:
            String(localized: "Please fill in both names.")
        case .codeRequired:
            String(localized: "Enter the code from your parent.")
        case .unknownClaimCode:
            String(localized: "We don't recognise that code. Check for typos and try again.")
        case .claimCodeAlreadyUsed:
            String(localized: "That code has already been used. Ask your parent for a new one.")
        case .claimCodeExpired:
            String(localized: "That code has expired. Ask your parent for a new one.")
        case .alreadyClaimed:
            String(localized: "This device is already set up.")
        case .projectUnavailable:
            String(localized: "Can't reach the server. Check your connection and try again.")
        case .sessionUnavailable:
            String(localized: "Couldn't start a session. Try restarting the app.")
        case .mustSignIn:
            String(localized: "Only a parent who has signed in with Apple can start a family. Sign in with Apple, then try again.")
        case .notPermitted:
            String(localized: "You're not able to do that.")
        case .other(let detail):
            detail
        }
    }
}
```

- [ ] **Step 7: Point the two views at it**

In `App/Chores/Onboarding/ClaimCodeView.swift`, replace lines 35-39:

```swift
            if let failure = model.failure {
                Section {
                    Text(failure.text).foregroundStyle(.red)
                }
            }
```

In `App/Chores/Onboarding/CreateFamilyView.swift`, replace lines 27-31:

```swift
            if let failure = model.failure {
                Section {
                    Text(failure.text).foregroundStyle(.red)
                }
            }
```

- [ ] **Step 8: Build the app target and run the UI tests**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd test`
Expected: BUILD SUCCEEDED, 13 UI tests pass. They exercise the onboarding error paths through the in-memory backend and are unchanged by this task.

- [ ] **Step 9: Commit**

```bash
git add Sources/ChoresCore/ViewModels/OnboardingViewModel.swift Tests/ChoresCoreTests/OnboardingViewModelTests.swift App/Chores/Onboarding/
git commit -m 'Let the view model name the failure and the view word it'
```

---

### Task 2: Pin the UI tests to English

The suite asserts visible English labels in a dozen places. Once Finnish exists, running the suite on a Finnish-configured simulator would fail on the labels rather than on anything real. Pinning the app's language settles it before the translations land.

**Files:**
- Create: `App/ChoresUITests/XCUIApplication+Language.swift`
- Modify: `App/ChoresUITests/ParentUITestCase.swift:13-16`
- Modify: `App/ChoresUITests/OnboardingUITests.swift:14-17`
- Modify: `App/ChoresUITests/KidUITests.swift:12-15`
- Modify: `App/ChoresUITests/LostSessionUITests.swift:12-15`

**Interfaces:**
- Consumes: nothing.
- Produces: `XCUIApplication.launchInEnglish(_ arguments: String...)`, used by all four launch sites. No later task depends on it.

- [ ] **Step 1: Write the helper**

Create `App/ChoresUITests/XCUIApplication+Language.swift`:

```swift
import XCTest

extension XCUIApplication {
    /// Launches with the language pinned to English rather than inherited from
    /// the simulator. The suite asserts visible labels — "Manage", "Nothing
    /// today", "0 of 1 done" — and English is the source language those are
    /// written in. A Finnish simulator would otherwise fail every one of them
    /// while the app was working correctly.
    func launchInEnglish(_ arguments: String...) {
        launchArguments = arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        launch()
    }
}
```

- [ ] **Step 2: Use it at all four launch sites**

`ParentUITestCase.swift:14-16` becomes:

```swift
        let app = XCUIApplication()
        app.launchInEnglish("-ui-testing")
```

`OnboardingUITests.swift:15-17`, `KidUITests.swift:13-15` and `LostSessionUITests.swift:13-15` follow the same shape, each keeping its own flag — `-ui-testing`, `-ui-testing-kid`, `-ui-testing-lost-session` respectively. In each case the `launchArguments = [...]` line and the `app.launch()` line that follows it are replaced by the single `app.launchInEnglish(...)` call.

- [ ] **Step 3: Run the UI tests to verify the pinning changed nothing**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd test`
Expected: 13 UI tests pass. The simulator is already English, so this proves the helper launches the app correctly rather than proving the pinning works — that is confirmed in Task 7, Step 4.

- [ ] **Step 4: Commit**

```bash
git add App/ChoresUITests/
git commit -m 'Pin the UI tests to English, since that is what they assert'
```

---

### Task 3: Make every remaining call site localizable

Roughly 120 SwiftUI literals already resolve through a catalog untouched. This task fixes the ones that would not: `String` properties, ternaries whose overload is ambiguous, and two strings that must be excluded. English behaviour is unchanged throughout — this is preparation, verifiable by the suite staying green.

**Files:**
- Modify: `App/Chores/Onboarding/OnboardingView.swift:16`
- Modify: `App/Chores/Parent/ParentWeekView.swift:44`, `:135`
- Modify: `App/Chores/Parent/ParentRootView.swift:64-78`, `:149-151`, `:160-162`, `:189`
- Modify: `App/Chores/Kid/KidWeekView.swift:88-94`
- Modify: `App/Chores/Kid/ReminderScheduler.swift:34-37`
- Modify: `App/Chores/Parent/AssignChoreSheet.swift:26-31`
- Modify: `App/Chores/Parent/EditChildSheet.swift:54-58`, `:90`
- Modify: `App/Chores/Parent/PeopleView.swift:161`, `:174`, `:190`
- Modify: `App/Chores/Parent/ChoresView.swift:107`, `:121`, `:135`
- Modify: `App/Chores/Parent/ScheduleEditorView.swift:155`, `:165`, `:179`
- Modify: `App/Chores/Parent/ClaimCodeSheet.swift:57`
- Modify: `App/Chores/Onboarding/ParentSignInView.swift:92`

**Interfaces:**
- Consumes: nothing from Task 1 or 2.
- Produces: no new API. Task 4's catalog keys must match the literals this task leaves behind, including `"Chores today"` and the pluralized `"You have %lld chores today."`.

- [ ] **Step 1: Take two strings out of localization**

`OnboardingView.swift:16` is the app's own name on the launch screen. It must not be translated — and it collides with the `"Chores"` key used by the Manage row and the chore list, which *is* translated. Make it verbatim:

```swift
                Text(verbatim: "Chores")
```

`ParentWeekView.swift:44` is a spacer holding the width of the name column. As an empty `LocalizedStringKey` it would put an empty key in the catalog:

```swift
                        Text(verbatim: "").frame(width: 88, alignment: .leading)
```

- [ ] **Step 2: Convert the two computed `String` properties**

`ParentRootView.swift:64-78` — `leaveFooter` feeds `Text(leaveFooter)`, which does not localize a `String`:

```swift
    private var leaveFooter: String {
        switch (hasNoAccount, isLastParent) {
        case (true, true):
            return String(localized: "You're the only parent, so leaving removes the whole family.")
        case (true, false):
            return String(localized: "Leaving gives up your place. Getting back in needs a new code from the other parent.")
        case (false, true):
            return String(localized: "You're the only parent, so leaving or deleting your account removes the whole family.")
        case (false, false):
            return String(localized: """
                Signing out keeps your place — sign back in with Apple to return. Leaving gives it \
                up, and deleting your account removes your sign-in with it.
                """)
        }
    }
```

`KidWeekView.swift:88-94` — `hintText` feeds `Label(hintText, systemImage:)`, same problem. The `.allowed` branch is unreachable behind `if !isEditable` and stays a bare `""`:

```swift
    private var hintText: String {
        switch store.eligibility(for: day) {
        case .future:             return String(localized: "You can tick these off on the day.")
        case .outsideCurrentWeek: return String(localized: "This week only.")
        case .allowed:            return ""
        }
    }
```

- [ ] **Step 3: Pin the five ambiguous ternaries**

Each becomes a computed property with an explicit `LocalizedStringKey` annotation, so the overload is settled by declaration.

`AssignChoreSheet.swift` — add the property and use it at line 27:

```swift
    private var emptyMessage: LocalizedStringKey {
        chores.isEmpty
            ? "Add some chores under Manage → Chores first."
            : "\(child.displayName) already has every chore on this day."
    }
```

```swift
                if available.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                }
```

`EditChildSheet.swift` — add the property and use it at line 55:

```swift
    private var codeFooter: LocalizedStringKey {
        child.authUserID == nil
            ? "This child's device isn't set up yet."
            : "Only needed if they get a new device or reinstall the app."
    }
```

```swift
                } footer: {
                    Text(codeFooter)
                }
```

`ParentRootView.swift` — add two properties to `ManageView` and use them at lines 149 and 160:

```swift
    private var leaveWarning: LocalizedStringKey {
        isLastParent
            ? "You're the only parent, so this deletes the family, the children, the chores and all their history. This cannot be undone."
            : "You'll be removed from this family. The other parent can give you a new code if you want back in."
    }

    private var deleteAccountWarning: LocalizedStringKey {
        isLastParent
            ? "You're the only parent, so this deletes your Apple sign-in for Chores along with the family, the children, the chores and all their history. This cannot be undone."
            : "This deletes your Apple sign-in for Chores and removes you from the family. This cannot be undone."
    }
```

```swift
            } message: {
                Text(leaveWarning)
            }
```

```swift
            } message: {
                Text(deleteAccountWarning)
            }
```

`ParentWeekView.swift` — add to `WeekCell` and use it at line 135:

```swift
    private var accessibilityText: LocalizedStringKey {
        total == 0 ? "nothing scheduled" : "\(done) of \(total) done"
    }
```

```swift
            .accessibilityLabel(accessibilityText)
```

- [ ] **Step 4: Convert the notification content**

`ReminderScheduler.swift:34-37`. The ternary collapses into one pluralizable key — the catalog holds the singular and plural forms, not the code:

```swift
            content.title = String(localized: "Chores today")
            content.body = String(localized: "You have \(plan.choreCount) chores today.")
```

- [ ] **Step 5: Convert the thirteen error assignments**

Each becomes `String(localized:)` with its text unchanged. In `PeopleView.swift`, lines 161 and 174 are the same string and both become:

```swift
            errorMessage = String(localized: "Couldn't add \(name). Check your connection and try again.")
```

and line 190:

```swift
            errorMessage = String(localized: "Couldn't delete \(child.displayName). Check your connection and try again.")
```

In `ChoresView.swift`, line 107 takes the same `"Couldn't add \(name)…"` form as above; line 121 becomes `String(localized: "Couldn't rename that chore. Check your connection and try again.")`; line 135 becomes `String(localized: "Couldn't update \(chore.name). Check your connection and try again.")`.

In `ScheduleEditorView.swift`, line 155 becomes `String(localized: "Couldn't assign \(chore.name). Check your connection and try again.")`; line 165 `String(localized: "Couldn't remove that chore. Check your connection and try again.")`; line 179 `String(localized: "Couldn't copy the day. Check your connection and try again.")`.

In `ClaimCodeSheet.swift:57`: `String(localized: "Couldn't create a code. Check your connection and try again.")`.
In `EditChildSheet.swift:90`: `String(localized: "Couldn't save. Check your connection and try again.")`.
In `ParentRootView.swift:189`: `String(localized: "Couldn't do that. Check your connection and try again.")`.
In `ParentSignInView.swift:92`: `String(localized: "Couldn't sign in. Please try again.")`.

- [ ] **Step 6: Build and run both suites**

Run: `swift test`
Expected: PASS, 111 tests.

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd test`
Expected: BUILD SUCCEEDED, 13 UI tests pass. No catalog exists yet, so every string still renders its English key — the suite passing is the proof that nothing regressed.

- [ ] **Step 7: Commit**

```bash
git add App/Chores/
git commit -m 'Route the strings a catalog would miss through String(localized:)'
```

---

### Task 4: Create the catalog, wire up the project, and translate onboarding

The catalog arrives with the project settings it needs and the first slice of Finnish: the screens a new device sees. After this task a Finnish phone shows Finnish onboarding and English everywhere else, which is exactly what makes the slice verifiable.

**Files:**
- Create: `App/Chores/Localizable.xcstrings`
- Modify: `App/Chores.xcodeproj/project.pbxproj:140-143` (`knownRegions`), and both `XCBuildConfiguration` blocks for the Chores target (`SWIFT_EMIT_LOC_STRINGS`)

**Interfaces:**
- Consumes: the literals left by Task 3, including `OnboardingFailure.text`'s ten strings from Task 1.
- Produces: the catalog file. Tasks 5 and 6 add keys to it; its `sourceLanguage` and JSON shape are fixed here.

- [ ] **Step 1: Add `fi` to the project's known regions**

In `App/Chores.xcodeproj/project.pbxproj`, lines 140-143:

```
			knownRegions = (
				en,
				fi,
				Base,
			);
```

- [ ] **Step 2: Turn on string extraction for the target**

In both the Debug and Release `XCBuildConfiguration` blocks for the Chores app target — the ones containing `INFOPLIST_KEY_UILaunchScreen_Generation` around lines 329 and 364 — add:

```
				SWIFT_EMIT_LOC_STRINGS = YES;
```

This does not affect the command-line build. It is what makes Xcode keep extracting new strings into the catalog for whoever opens the project later.

- [ ] **Step 3: Create the catalog with the onboarding strings**

Create `App/Chores/Localizable.xcstrings`. This is the file's exact shape — a key with no substitution, and a key with one:

```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "Set up this device." : {
      "localizations" : {
        "fi" : {
          "stringUnit" : { "state" : "translated", "value" : "Ota tämä laite käyttöön." }
        }
      }
    },
    "Couldn't sign in. Please try again." : {
      "localizations" : {
        "fi" : {
          "stringUnit" : { "state" : "translated", "value" : "Kirjautuminen ei onnistunut. Yritä uudelleen." }
        }
      }
    }
  },
  "version" : "1.0"
}
```

English needs no entry of its own: it is the source language, and a key with no `en` localization resolves to the key itself.

Add an entry in that form for each row below. Keys are the English text exactly as it appears in source — a multi-line literal with `\` continuations joins into one line, so `"Signing in with Apple is what lets your family come back if this phone is replaced, wiped, or the app is reinstalled."` is a single key with single spaces.

**`OnboardingView`, `ParentSetupView`**

| Key (en) | fi |
|---|---|
| `Set up this device.` | `Ota tämä laite käyttöön.` |
| `I'm a parent` | `Olen vanhempi` |
| `I have a code` | `Minulla on koodi` |
| `You're signed in` | `Olet kirjautunut sisään` |
| `Start a new family, or join one you've been given a code for.` | `Aloita uusi perhe tai liity perheeseen, johon sinulle on annettu koodi.` |
| `Start a family` | `Aloita perhe` |

**`ParentSignInView`**

| Key (en) | fi |
|---|---|
| `Sign in to keep your family` | `Kirjaudu sisään, niin perheesi ei katoa` |
| `Signing in with Apple is what lets your family come back if this phone is replaced, wiped, or the app is reinstalled.` | `Apple-kirjautuminen on se, mikä tuo perheesi takaisin, jos puhelin vaihtuu, tyhjennetään tai sovellus asennetaan uudelleen.` |
| `Sign in with Apple` | `Kirjaudu Applella` |
| `Parent` | `Vanhempi` |
| `Cancel` | `Peruuta` |
| `Couldn't sign in. Please try again.` | `Kirjautuminen ei onnistunut. Yritä uudelleen.` |

**`CreateFamilyView`**

| Key (en) | fi |
|---|---|
| `Household` | `Koti` |
| `Family name` | `Perheen nimi` |
| `You` | `Sinä` |
| `Your name` | `Nimesi` |
| `Create` | `Luo` |
| `New family` | `Uusi perhe` |

**`ClaimCodeView`**

| Key (en) | fi |
|---|---|
| `ABC123` | `ABC123` |
| `Your code` | `Koodisi` |
| `Ask a parent to open Manage → People and show you a code.` | `Pyydä vanhempaa avaamaan Hallinta → Ihmiset ja näyttämään sinulle koodi.` |
| `Continue` | `Jatka` |
| `Enter code` | `Syötä koodi` |

**`OnboardingFailureText` — the ten strings moved in Task 1**

| Key (en) | fi |
|---|---|
| `Please fill in both names.` | `Täytä molemmat nimet.` |
| `Enter the code from your parent.` | `Syötä koodi, jonka sait vanhemmaltasi.` |
| `We don't recognise that code. Check for typos and try again.` | `Koodia ei löytynyt. Tarkista kirjoitusvirheet ja yritä uudelleen.` |
| `That code has already been used. Ask your parent for a new one.` | `Koodi on jo käytetty. Pyydä vanhemmaltasi uusi.` |
| `That code has expired. Ask your parent for a new one.` | `Koodi on vanhentunut. Pyydä vanhemmaltasi uusi.` |
| `This device is already set up.` | `Tämä laite on jo otettu käyttöön.` |
| `Can't reach the server. Check your connection and try again.` | `Palvelimeen ei saada yhteyttä. Tarkista verkkoyhteys ja yritä uudelleen.` |
| `Couldn't start a session. Try restarting the app.` | `Istunnon aloitus ei onnistunut. Käynnistä sovellus uudelleen.` |
| `Only a parent who has signed in with Apple can start a family. Sign in with Apple, then try again.` | `Vain Applella kirjautunut vanhempi voi aloittaa perheen. Kirjaudu Applella ja yritä uudelleen.` |
| `You're not able to do that.` | `Sinulla ei ole oikeutta tähän.` |

**`LostSessionView`, `BackendFailureView`, `BackendUnavailableView`**

| Key (en) | fi |
|---|---|
| `This device isn't set up` | `Tätä laitetta ei ole otettu käyttöön` |
| `Ask a parent to open Manage → People and show you a new code.` | `Pyydä vanhempaa avaamaan Hallinta → Ihmiset ja näyttämään sinulle uusi koodi.` |
| `Enter a code` | `Syötä koodi` |
| `I'm a parent — sign in` | `Olen vanhempi – kirjaudu sisään` |
| `The server refused the request` | `Palvelin hylkäsi pyynnön` |
| `This is a fault in the app or its database, not in this device's connection.` | `Vika on sovelluksessa tai sen tietokannassa, ei tämän laitteen verkkoyhteydessä.` |
| `Try again` | `Yritä uudelleen` |
| `Can't reach the server` | `Palvelimeen ei saada yhteyttä` |
| `Check this device's connection first.` | `Tarkista ensin tämän laitteen verkkoyhteys.` |
| `If other devices can't connect either, the Supabase project has probably paused after a week of inactivity. Open the Supabase dashboard and resume it — nothing is lost.` | `Jos muutkaan laitteet eivät saa yhteyttä, Supabase-projekti on todennäköisesti keskeytetty viikon käyttämättömyyden jälkeen. Avaa Supabasen hallintapaneeli ja jatka projektia – mitään ei katoa.` |

- [ ] **Step 4: Build and confirm the catalog compiled**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd build`
Expected: BUILD SUCCEEDED, with no `XCStringsTool` warning about malformed JSON.

Run: `plutil -p build/dd/Build/Products/Debug-iphonesimulator/Chores.app/fi.lproj/Localizable.strings`
Expected: the Finnish values from the tables above, one line each.

- [ ] **Step 5: Run both suites**

Run: `swift test`
Expected: PASS, 111 tests.

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd test`
Expected: 13 UI tests pass. Task 2 pinned them to English, so a catalog existing must not change a single assertion.

- [ ] **Step 6: Commit**

```bash
git add App/Chores/Localizable.xcstrings App/Chores.xcodeproj/project.pbxproj
git commit -m 'Add the string catalog, and Finnish for getting a device set up'
```

---

### Task 5: Translate the parent screens

The largest slice: Manage and everything under it. Watch the cross-references — `Hallinta`, `Ihmiset` and `Tehtävät` are chosen here, and four strings elsewhere name them.

**Files:**
- Modify: `App/Chores/Localizable.xcstrings`

**Interfaces:**
- Consumes: the catalog created in Task 4.
- Produces: nothing new. Task 6 adds the last keys to the same file.

- [ ] **Step 1: Add the Manage and tab-bar keys**

| Key (en) | fi |
|---|---|
| `Today` | `Tänään` |
| `Week` | `Viikko` |
| `Manage` | `Hallinta` |
| `People` | `Ihmiset` |
| `Chores` | `Tehtävät` |
| `Schedule` | `Aikataulu` |
| `Sign out` | `Kirjaudu ulos` |
| `Leave this family` | `Poistu perheestä` |
| `Delete account` | `Poista tili` |
| `Leave this family?` | `Poistutaanko perheestä?` |
| `Leave` | `Poistu` |
| `Delete your account?` | `Poistetaanko tilisi?` |
| `Something went wrong` | `Jotain meni vikaan` |
| `OK` | `OK` |
| `Couldn't do that. Check your connection and try again.` | `Toiminto ei onnistunut. Tarkista verkkoyhteys ja yritä uudelleen.` |

`Chores` translating to `Tehtävät` is why Task 3, Step 1 made the launch-screen `Text(verbatim: "Chores")` — the app's name and the chore list shared one key.

- [ ] **Step 2: Add the four `leaveFooter` branches and the four dialog warnings**

| Key (en) | fi |
|---|---|
| `You're the only parent, so leaving removes the whole family.` | `Olet perheen ainoa vanhempi, joten poistuminen poistaa koko perheen.` |
| `Leaving gives up your place. Getting back in needs a new code from the other parent.` | `Poistuminen luovuttaa paikkasi. Takaisin pääsy vaatii uuden koodin toiselta vanhemmalta.` |
| `You're the only parent, so leaving or deleting your account removes the whole family.` | `Olet perheen ainoa vanhempi, joten poistuminen tai tilin poistaminen poistaa koko perheen.` |
| `Signing out keeps your place — sign back in with Apple to return. Leaving gives it up, and deleting your account removes your sign-in with it.` | `Uloskirjautuminen säilyttää paikkasi – kirjaudu takaisin Applella. Poistuminen luovuttaa paikan, ja tilin poistaminen vie Apple-kirjautumisen mukanaan.` |
| `You're the only parent, so this deletes the family, the children, the chores and all their history. This cannot be undone.` | `Olet perheen ainoa vanhempi, joten tämä poistaa perheen, lapset, tehtävät ja koko historian. Tätä ei voi peruuttaa.` |
| `You'll be removed from this family. The other parent can give you a new code if you want back in.` | `Sinut poistetaan tästä perheestä. Toinen vanhempi voi antaa sinulle uuden koodin, jos haluat takaisin.` |
| `You're the only parent, so this deletes your Apple sign-in for Chores along with the family, the children, the chores and all their history. This cannot be undone.` | `Olet perheen ainoa vanhempi, joten tämä poistaa Chores-sovelluksen Apple-kirjautumisen sekä perheen, lapset, tehtävät ja koko historian. Tätä ei voi peruuttaa.` |
| `This deletes your Apple sign-in for Chores and removes you from the family. This cannot be undone.` | `Tämä poistaa Chores-sovelluksen Apple-kirjautumisen ja poistaa sinut perheestä. Tätä ei voi peruuttaa.` |

- [ ] **Step 3: Add the `PeopleView`, `EditChildSheet` and `ClaimCodeSheet` keys**

Note the two rewordings: `Delete %@?` and the removal warning both keep the name in the nominative, per spec §6.

| Key (en) | fi |
|---|---|
| `Children` | `Lapset` |
| `Parents` | `Vanhemmat` |
| `Not set up` | `Ei käytössä` |
| `This device` | `Tämä laite` |
| `No children yet.` | `Ei vielä lapsia.` |
| `Add child` | `Lisää lapsi` |
| `Add parent` | `Lisää vanhempi` |
| `Tap a child to rename them, change their colour, or show a setup code.` | `Napauta lasta vaihtaaksesi nimen tai värin, tai näyttääksesi käyttöönottokoodin.` |
| `Parents share everything: each can edit chores and the schedule, and tick anything off. Tap another parent to show a setup code for their device.` | `Vanhemmilla on samat oikeudet: kumpi tahansa voi muokata tehtäviä ja aikataulua ja merkitä mitä tahansa tehdyksi. Napauta toista vanhempaa näyttääksesi käyttöönottokoodin hänen laitteelleen.` |
| `Name` | `Nimi` |
| `Add` | `Lisää` |
| `Delete` | `Poista` |
| `Delete %@?` | `Poistetaanko %@?` |
| `This removes %@ from the family, takes them off the schedule, and deletes everything they've ever ticked off. This cannot be undone.` | `Tämä poistaa perheestä: %@. Hän katoaa aikataulusta, ja kaikki hänen tekemikseen merkityt tehtävät poistetaan. Tätä ei voi peruuttaa.` |
| `Colour` | `Väri` |
| `Show setup code` | `Näytä käyttöönottokoodi` |
| `This child's device isn't set up yet.` | `Tämän lapsen laitetta ei ole vielä otettu käyttöön.` |
| `Only needed if they get a new device or reinstall the app.` | `Tarvitaan vain, jos hän saa uuden laitteen tai asentaa sovelluksen uudelleen.` |
| `Save` | `Tallenna` |
| `Enter this on %@'s device` | `Syötä tämä koodi laitteella, jota %@ käyttää` |
| `Expires in 7 days. Generating a new code cancels this one.` | `Vanhenee 7 päivässä. Uuden koodin luominen mitätöi tämän.` |
| `New code` | `Uusi koodi` |
| `Done` | `Valmis` |
| `Couldn't add %@. Check your connection and try again.` | `Lisääminen epäonnistui: %@. Tarkista verkkoyhteys ja yritä uudelleen.` |
| `Couldn't delete %@. Check your connection and try again.` | `Poistaminen epäonnistui: %@. Tarkista verkkoyhteys ja yritä uudelleen.` |
| `Couldn't save. Check your connection and try again.` | `Tallennus epäonnistui. Tarkista verkkoyhteys ja yritä uudelleen.` |
| `Couldn't create a code. Check your connection and try again.` | `Koodin luominen epäonnistui. Tarkista verkkoyhteys ja yritä uudelleen.` |

- [ ] **Step 4: Add the `ChoresView` and `ScheduleEditorView` keys**

`Copy %@ to…` and `Copy %@` drop their placeholder in Finnish, deliberately — the day picker directly above already shows which day is selected. See spec §6.

| Key (en) | fi |
|---|---|
| `Active` | `Käytössä` |
| `No chores yet.` | `Ei vielä tehtäviä.` |
| `Tap to rename. Swipe to archive.` | `Napauta vaihtaaksesi nimen. Pyyhkäise arkistoidaksesi.` |
| `Archive` | `Arkistoi` |
| `Archived (%lld)` | `Arkistoidut (%lld)` |
| `Restore` | `Palauta` |
| `Archived chores keep their history and their place in the schedule, but don't appear on anyone's list.` | `Arkistoidut tehtävät säilyttävät historiansa ja paikkansa aikataulussa, mutta eivät näy kenenkään listalla.` |
| `Add chore` | `Lisää tehtävä` |
| `Rename chore` | `Vaihda tehtävän nimi` |
| `Couldn't rename that chore. Check your connection and try again.` | `Nimen vaihtaminen epäonnistui. Tarkista verkkoyhteys ja yritä uudelleen.` |
| `Couldn't update %@. Check your connection and try again.` | `Päivittäminen epäonnistui: %@. Tarkista verkkoyhteys ja yritä uudelleen.` |
| `Day` | `Päivä` |
| `Remove` | `Poista` |
| `Add a child under Manage → People first.` | `Lisää ensin lapsi kohdassa Hallinta → Ihmiset.` |
| `Copy %@ to…` | `Kopioi tämä päivä…` |
| `Copying replaces everything already assigned on the target days.` | `Kopiointi korvaa kaiken, mitä kohdepäiville on jo määritetty.` |
| `Copy to` | `Kopioi päiville` |
| `Copy %@` | `Kopioi päivä` |
| `Copy` | `Kopioi` |
| `Couldn't assign %@. Check your connection and try again.` | `Määrittäminen epäonnistui: %@. Tarkista verkkoyhteys ja yritä uudelleen.` |
| `Couldn't remove that chore. Check your connection and try again.` | `Tehtävän poistaminen epäonnistui. Tarkista verkkoyhteys ja yritä uudelleen.` |
| `Couldn't copy the day. Check your connection and try again.` | `Päivän kopiointi epäonnistui. Tarkista verkkoyhteys ja yritä uudelleen.` |

- [ ] **Step 5: Add the `ParentTodayView`, `ParentWeekView`, `DayDetailView` and `AssignChoreSheet` keys**

| Key (en) | fi |
|---|---|
| `No children yet` | `Ei vielä lapsia` |
| `Add them under Manage → People.` | `Lisää heidät kohdassa Hallinta → Ihmiset.` |
| `Showing saved data` | `Näytetään tallennetut tiedot` |
| `Last updated %@` | `Päivitetty viimeksi %@` |
| `This week` | `Tämä viikko` |
| `This day hasn't happened yet.` | `Tämä päivä ei ole vielä koittanut.` |
| `%@ · %@` | `%1$@ · %2$@` |
| `Add some chores under Manage → Chores first.` | `Lisää ensin tehtäviä kohdassa Hallinta → Tehtävät.` |
| `%@ already has every chore on this day.` | `Kaikki tämän päivän tehtävät on jo määritetty: %@.` |
| `Assign to %@` | `Lisää tehtävä: %@` |

- [ ] **Step 6: Build and run both suites**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd test`
Expected: BUILD SUCCEEDED, 13 UI tests pass.

Run: `swift test`
Expected: PASS, 111 tests.

- [ ] **Step 7: Commit**

```bash
git add App/Chores/Localizable.xcstrings
git commit -m 'Translate the parent side'
```

---

### Task 6: Translate the kid screens and the notification

The last keys, including the only pluralized one.

**Files:**
- Modify: `App/Chores/Localizable.xcstrings`

**Interfaces:**
- Consumes: the catalog from Tasks 4 and 5.
- Produces: a complete catalog. Task 7 verifies it.

- [ ] **Step 1: Add the kid-screen keys**

`%lld of %lld done` is worded rather than punctuated because it is also the VoiceOver label in `ProgressRing` and `WeekCell`, where a slash is read aloud as *kautta*. See spec §7.

| Key (en) | fi |
|---|---|
| `Nothing today` | `Ei tehtäviä tänään` |
| `Enjoy it.` | `Nauti siitä.` |
| `Nothing scheduled` | `Ei tehtäviä` |
| `nothing scheduled` | `ei tehtäviä` |
| `%lld of %lld done` | `%1$lld tehty, %2$lld yhteensä` |
| `%lld/%lld` | `%1$lld/%2$lld` |
| `You can tick these off on the day.` | `Voit merkitä nämä tehdyiksi kyseisenä päivänä.` |
| `This week only.` | `Vain tämä viikko.` |

- [ ] **Step 2: Add the notification title and the plural body**

The title is an ordinary key:

| Key (en) | fi |
|---|---|
| `Chores today` | `Tehtäviä tänään` |

The body needs plural variations rather than a `stringUnit`. Finnish takes the partitive singular after a number greater than one — `tehtävää`, not `tehtäviä`:

```json
    "You have %lld chores today." : {
      "localizations" : {
        "fi" : {
          "variations" : {
            "plural" : {
              "one" : {
                "stringUnit" : { "state" : "translated", "value" : "Sinulla on 1 tehtävä tänään." }
              },
              "other" : {
                "stringUnit" : { "state" : "translated", "value" : "Sinulla on %lld tehtävää tänään." }
              }
            }
          }
        }
      }
    }
```

The English source needs the same treatment, since the key's own text is the plural form and `one` must read "1 chore":

```json
        "en" : {
          "variations" : {
            "plural" : {
              "one" : {
                "stringUnit" : { "state" : "translated", "value" : "You have 1 chore today." }
              },
              "other" : {
                "stringUnit" : { "state" : "translated", "value" : "You have %lld chores today." }
              }
            }
          }
        }
```

- [ ] **Step 3: Build and confirm both plural forms compiled**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd build`
Expected: BUILD SUCCEEDED.

Run: `plutil -p build/dd/Build/Products/Debug-iphonesimulator/Chores.app/fi.lproj/Localizable.stringsdict`
Expected: a `NSStringPluralRuleType` dictionary holding `Sinulla on 1 tehtävä tänään.` and `Sinulla on %lld tehtävää tänään.`. A plural key compiles to `.stringsdict`, not `.strings` — if this file is missing, the variations block is malformed.

- [ ] **Step 4: Run both suites**

Run: `swift test`
Expected: PASS, 111 tests.

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd test`
Expected: 13 UI tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/Chores/Localizable.xcstrings
git commit -m 'Translate the kid side, and the reminder that counts chores'
```

---

### Task 7: Verify coverage, then see it in Finnish

A missing key compiles, runs, and shows English. The suites cannot catch that, so this task is the real gate.

**Files:**
- Modify: `README.md:9`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Diff the compiler's extracted keys against the catalog's**

The build emits one `.stringsdata` file per compilation under the derived-data path, each listing the keys extracted from that file. Collect them and compare against the catalog:

```bash
find build/dd -name '*.stringsdata' -print0 | xargs -0 cat | python3 -c "
import json, sys, re
raw = sys.stdin.read()
extracted = set(re.findall(r'\"([^\"]+)\"\s*:\s*\{', raw))
catalog = set(json.load(open('App/Chores/Localizable.xcstrings'))['strings'])
print('in code, not in catalog:', sorted(k for k in extracted - catalog))
print('in catalog, not in code:', sorted(catalog - extracted))
"
```

Expected: both lists empty. If the `.stringsdata` files turn out not to be emitted by a command-line build, fall back to grepping the call-site forms enumerated in spec §5 and comparing that set instead — weaker, since a grep only finds the patterns it is told about, so read the output rather than trusting an empty diff.

Anything in the first list is an untranslated string: add it to the catalog and re-run. Anything in the second is a stale key: delete it.

- [ ] **Step 2: Confirm what actually shipped in the bundle**

```bash
ls build/dd/Build/Products/Debug-iphonesimulator/Chores.app/fi.lproj/
```

Expected: `Localizable.strings` and `Localizable.stringsdict`.

- [ ] **Step 3: Walk the app in Finnish**

Boot the simulator, set Settings → General → Language & Region → iPhone Language to Suomi, and launch the app. Walk: onboarding (both doors), the claim-code screen with a wrong code to see an error, the parent's Today / Week / Manage tabs, People with a child added and its delete confirmation, Chores with an archive, Schedule with a copy, and the kid's Today and Week.

Check three things at each stop: nothing is still English; nothing overflows its control — Finnish runs longer, and `Tarkista verkkoyhteys ja yritä uudelleen` is much wider than `Check your connection`; and every `Hallinta → Ihmiset` reference matches what the tabs and rows actually say.

- [ ] **Step 4: Confirm the tests are genuinely pinned**

With the simulator still in Finnish, run the UI suite:

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd test`
Expected: 13 UI tests pass. This is what Task 2 was for, and it can only be checked here — on an English simulator the pinning is invisible.

- [ ] **Step 5: Note the languages in the README**

`README.md:9` becomes:

```markdown
- **Client:** SwiftUI (iOS), English and Finnish, distributed via TestFlight
```

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m 'Say which languages the app speaks'
```

---

## Notes for whoever executes this

- **Do not run `supabase db push`.** Nothing in this plan touches the database, and migrations are applied by hand in this repo regardless.
- **Do not push.** Every task commits locally; pushing is a separate decision.
- **`String(localized:)` needs no bundle argument** in the app target — it defaults to `Bundle.main`, which is where the catalog compiles to. It would need `bundle: .module` inside a package, which is exactly what Task 1 avoids.
- **If a Finnish string looks wrong to you, say so rather than fixing it silently.** The copy was reviewed as part of the spec; a change to it is a change to a reviewed decision.
