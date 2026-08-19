# Chores

A native iOS app for running a household chore chart.

Children see their own chores for the day and tick them off; a parent maintains the list
of children and chores, defines a repeating weekly schedule, and sees at a glance who has
done what.

- **Client:** SwiftUI (iOS), distributed via TestFlight
- **Backend:** Supabase (Postgres, anonymous auth, row-level security)

## Status

Feature-complete for v1 and ready to archive. Not yet released.

See [`docs/superpowers/specs/2026-08-10-household-chores-app-design.md`](docs/superpowers/specs/2026-08-10-household-chores-app-design.md)
for the full design: data model, auth and claim flow, RLS policies, UX for both modes,
offline behaviour, and testing strategy.

## Layout

- `Sources/ChoresCore/` — models, schedule resolution, offline cache and outbox, view
  models. Everything testable from the command line lives here.
- `App/` — the Xcode project: SwiftUI screens for both modes, plus the XCUITest suite.
- `supabase/` — migrations and the pgTAP suite that guards row-level security.

## Running the tests

    swift test                                    # 111 unit tests
    supabase test db                              # 15 pgTAP assertions (needs Docker)
    xcodebuild -project App/Chores.xcodeproj -scheme Chores \
      -destination 'platform=iOS Simulator,name=iPhone 17' test   # 13 UI tests

The UI tests launch with `-ui-testing`, which swaps Supabase for an in-memory backend:
no stack required, no state carried between runs.

## Building the app

`App/Chores/Secrets.swift` holds the URL and anon key for both the local stack and the
hosted project. It is gitignored — copy `App/Chores/Secrets.swift.example` and fill it in.

Debug builds use the local values, Release builds the hosted ones, and ticking `-hosted`
in the scheme's Run arguments points a Debug build at the hosted project. See
[`docs/RELEASING.md`](docs/RELEASING.md) for why it splits that way.

## Shipping to TestFlight

    tools/testflight.sh

Archives, verifies the archive, and uploads to App Store Connect — no Xcode needed. It
picks its own build number, refuses to build if hosted Supabase has pending migrations,
and never touches git. The test suites and the manual Sign in with Apple checks are not
part of it; see [`docs/RELEASING.md`](docs/RELEASING.md) for the full pre-flight and for
what the script verifies.

## Database migrations

Migrations live in `supabase/migrations/` and are applied manually — nothing in this repo
runs `supabase db push` on your behalf. See [`docs/RELEASING.md`](docs/RELEASING.md).
