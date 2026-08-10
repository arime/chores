# Chores

A native iOS app for running a household chore chart.

Children see their own chores for the day and tick them off; a parent maintains the list
of children and chores, defines a repeating weekly schedule, and sees at a glance who has
done what.

- **Client:** SwiftUI (iOS), distributed via TestFlight
- **Backend:** Supabase (Postgres, anonymous auth, row-level security)

## Status

Design approved; implementation not yet started.

See [`docs/superpowers/specs/2026-08-10-household-chores-app-design.md`](docs/superpowers/specs/2026-08-10-household-chores-app-design.md)
for the full design: data model, auth and claim flow, RLS policies, UX for both modes,
offline behaviour, and testing strategy.

## Database migrations

Migrations live in `supabase/migrations/` and are applied manually — nothing in this repo
runs `supabase db push` on your behalf.
