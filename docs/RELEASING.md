# Releasing

## Database changes

Migrations live in `supabase/migrations/`. Apply them yourself:

    supabase link --project-ref <project-ref>
    supabase db push

Run `supabase test db` locally first — the pgTAP suite in `supabase/tests/` is the
regression gate for RLS, and an RLS bug fails silently.

## App builds

1. Confirm `App/Chores/Secrets.swift` points at the hosted project. It is gitignored;
   copy `App/Chores/Secrets.swift.example` if it is missing.
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
