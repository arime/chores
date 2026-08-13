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

## First-time setup of the hosted project

Enable **Authentication → Sign In / Providers → Anonymous sign-ins**. Without it every
device fails at first launch with "Can't reach the server".

## If the app says "Can't reach the server"

Free Supabase projects pause after roughly 7 days with no API activity. Open the
dashboard and resume the project; no data is lost. This is expected after a holiday.
