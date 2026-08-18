# Releasing

## Database changes

Migrations live in `supabase/migrations/`. Apply them yourself:

    supabase link --project-ref <project-ref>
    supabase db push

Run `supabase test db` locally first — the pgTAP suite in `supabase/tests/` is the
regression gate for RLS, and an RLS bug fails silently.

## Environments

`Secrets.swift` holds both projects, and the build configuration decides which one the
app uses:

| Build | Backend |
|---|---|
| Debug — simulator, or a phone run from Xcode | Local |
| Debug with `-hosted` ticked in the scheme's Run arguments | Hosted |
| Release — archive, TestFlight, or ⌘R in Release | Hosted, always |

The discriminator is the configuration rather than the platform, because a phone
tethered to Xcode is still development. Release is the only configuration an archive
can be built from, so a distributed build has no code path to the local stack.

The local URL is the Mac's Bonjour name (`scutil --get LocalHostName` plus `.local`),
not `127.0.0.1`, so that a phone on the same Wi-Fi reaches the stack as well — loopback
would mean the phone itself. `NSAllowsLocalNetworking` in `App/Info.plist` is what
permits the cleartext connection; it covers `.local` and loopback only.

A phone using the local stack must be on the same Wi-Fi as the Mac. USB tethering
carries the debugger, not the network, so on cellular or a guest network you get the
"Can't reach the server" screen.

## Installing a Release build without TestFlight

Edit Scheme → Run → Build Configuration → Release, then ⌘R to the device. It installs
and keeps working with the cable gone, until the provisioning profile expires — twelve
months on a paid membership, seven days on a free personal team. Set the configuration
back to Debug afterwards: the scheme is shared, so it changes what everyone's ⌘R does.

## App builds

1. Confirm the `Hosted` values in `App/Chores/Secrets.swift`. It is gitignored; copy
   `App/Chores/Secrets.swift.example` if it is missing.
2. Run `swift test` from the repo root — all ChoresCore tests must pass.
3. Run the UI suite once:

       xcodebuild -project App/Chores.xcodeproj -scheme Chores \
         -destination 'platform=iOS Simulator,name=iPhone 17' test

4. Sign in with Apple has **no automated coverage**, and cannot have any — no test can mint an
   Apple identity token, and XCTest cannot drive Apple's system sheet. The whole UI suite runs
   against a stub provider, so the production button and the real sign-in path are exercised by
   nothing. Check them by hand on a real device before every TestFlight build:

   - Tap the Sign in with Apple button itself. It is a `SignInWithAppleButton` with hit-testing
     disabled and a transparent `Button` overlaid, so confirm it actually receives the tap.
   - Sign in and create a family.
   - Cancel Apple's sheet on a second attempt: it must return quietly, with no error message.
   - Force-quit and relaunch — the family must return with no code.
   - Delete the app, reinstall, sign in again — the family must return again. That is the whole
     point of the feature, and the only step that proves it.

5. Xcode → Any iOS Device → Product → Archive → Distribute → TestFlight.

## Sign in with Apple: what makes it work

**The entitlement is in the repository.** `App/Chores/Chores.entitlements` declares
`com.apple.developer.applesignin`, and both Chores build configurations point at it through
`CODE_SIGN_ENTITLEMENTS`, so a fresh clone already builds a binary that can sign someone in. Do not
add the capability again in Signing & Capabilities — Xcode would write a second entitlements file
beside the tracked one.

Recognise the failure it causes, because nothing in it names the cause. Without the entitlement,
`akd` refuses the request before any network call and logs
`AKAuthenticationError Code=-7026`; `AuthenticationServices` flattens that into
`ASAuthorizationError Code=1000`, and the app shows "Couldn't sign in". Nothing in the test suite
notices, because the suite never reaches it.

Two cheap checks, worth running whenever the signing configuration changes:

    grep -n CODE_SIGN_ENTITLEMENTS App/Chores.xcodeproj/project.pbxproj
    plutil -p App/Chores/Chores.entitlements

Neither proves the entitlement survives into a build, and **only a device build can**. Xcode writes
an empty entitlements blob for simulator destinations, so a simulator binary shows nothing here and
that absence means nothing:

    xcodebuild -project App/Chores.xcodeproj -scheme Chores \
      -destination 'generic/platform=iOS' -configuration Debug build
    codesign -d --entitlements - --xml \
      ~/Library/Developer/Xcode/DerivedData/Chores-*/Build/Products/Debug-iphoneos/Chores.app \
      | plutil -p -

`com.apple.developer.applesignin` must appear alongside `application-identifier`.

Two things stay outside the repository.

**The App ID.** `com.metsahalme.Chores` needs Sign in with Apple enabled on the developer portal, or
the profile cannot carry the entitlement and signing fails. Automatic signing enables it and
regenerates the profile on the next device build. To see what the current profile permits:

    security cms -D -i ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision \
      | plutil -extract Entitlements xml1 -o - - | plutil -p -

**Hosted Supabase.** Authentication → Providers → **Apple** → enable, and put
`com.metsahalme.Chores` in Client IDs. Leave the Secret Key fields empty: they serve the OAuth web
flow, while native `signInWithIdToken` needs only the client ID so the server can check the token's
`aud` claim. Leave anonymous sign-ins enabled — children still depend on them.

**Local** is already configured: `[auth.external.apple]` in `supabase/config.toml` is enabled with
the same client ID.

## TestFlight

### What it needs that a development build does not

A **paid Apple Developer Program membership**. A free personal team cannot reach
TestFlight at all — it signs, but it cannot distribute. The tell is the provisioning
profile: seven days on a personal team, twelve months on a paid one.

    security cms -D -i ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision \
      | plutil -extract ExpirationDate raw -

Enrolment is not instant — identity verification takes a day or two, longer for an
organisation account — so start it before anything else here matters.

Then, once per app:

- Set `DEVELOPMENT_TEAM` to the paid team.
- Register `com.metsahalme.Chores` and create the app record in App Store Connect.
  The display name there is separate from the bundle ID and has to be unique across
  the store, so plain "Chores" may already be taken.

### Before every upload

- **Push the migrations to hosted first.** Release builds always use Hosted, so a
  migration that has not been pushed is a build that fails on a tester's first launch
  rather than on yours. Missing table grants are the version of this that looks like
  an outage: the app can reach the server perfectly well and is refused by it.
- Bump `CURRENT_PROJECT_VERSION`. App Store Connect rejects a build number it has
  already seen, and it is per-upload, not per-release — a rejected upload burns one.
  `MARKETING_VERSION` only changes when the version users see changes.

### Internal or external

**Internal** testing covers up to 100 people holding a role on the App Store Connect
team, and skips Beta App Review entirely — builds land minutes after processing. This
is what a family app wants.

**External** testing reaches up to 10,000 testers by public link, and needs Beta App
Review plus test notes and a contact address. Review is lighter than the App Store's
but is still a queue.

### Privacy and export answers

Both are declared in the repository, so App Store Connect should stop asking:

- `App/Chores/PrivacyInfo.xcprivacy` — the manifest. It ships inside the bundle, which
  is why it lives in the synchronized folder rather than beside `App/Info.plist`.
- `ITSAppUsesNonExemptEncryption` in `App/Info.plist` — false, because the only
  encryption is the system's own HTTPS.

The privacy answers given in App Store Connect must agree with the manifest. It declares
names and user content — display names, chore names, the schedule and completion history
— as collected, linked to the user, for app functionality, and no tracking. If what the
app stores ever changes, both sides change together.

## First-time setup of the hosted project

Enable **Authentication → Sign In / Providers → Anonymous sign-ins**. Without it every
device fails at first launch with "Can't reach the server".

## If the app says "Can't reach the server"

Free Supabase projects pause after roughly 7 days with no API activity. Open the
dashboard and resume the project; no data is lost. This is expected after a holiday.
