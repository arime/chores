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

4. Xcode → Any iOS Device → Product → Archive → Distribute → TestFlight.

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
