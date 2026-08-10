# Household Chores App — Design

**Date:** 2026-08-10
**Status:** Approved design, ready for implementation planning
**Working title:** Chores

## 1. Purpose

A native iOS app for running a household chore chart for three children (ages 11, 14, 16).
Each child sees their own chores for the day and ticks them off. The parent maintains the
list of children and chores, defines a repeating weekly schedule, and sees at a glance who
has done what.

Success means the parent stops being the scheduling system: the app answers "what am I
supposed to do today" without a parent in the loop, and answers "did they do it" without
an interrogation.

## 2. Requirements

### In scope for v1

- Parent maintains a list of children.
- Parent maintains a list of assignable chores.
- Parent defines a **weekly template**: for each weekday, which chores are assigned to
  which child. The same 7-day pattern repeats every week.
- Child sees their chores for today and can mark them complete.
- Child can complete a chore for a past day within the current week.
- Parent sees an overview of all children's status for today and for the week.
- Parent can revert (un-check) any completion.
- Local (on-device) daily reminder notification for children.

### Explicitly out of scope for v1

Each of these is deferred deliberately, and the data model is shaped so none requires a
destructive migration:

- Rewards, points, or allowance tracking
- Manual per-date schedule overrides (reassign / skip / one-off)
- Parent approval workflow for completions
- Sign in with Apple
- Server-side push notifications
- Android client
- Audit trail of who reverted which completion
- Public / multi-family release

## 3. Context and constraints

| Constraint | Value |
|---|---|
| Users | 1–2 parents, 3 children (11, 14, 16) |
| Devices | Each person has their own iPhone/iPad. No shared device. |
| Distribution | TestFlight, via an existing paid Apple Developer Program account |
| Backend budget | Free tier |
| Timezone | Europe/Helsinki |
| Maintainer | Comfortable with SwiftUI |

Scale is trivial: roughly 30 writes per day and a few thousand rows per year.

## 4. Technology decisions

### Client: SwiftUI (native)

Native was a stated requirement, and the maintainer is comfortable with SwiftUI. Uses the
official `supabase-swift` SDK via Swift Package Manager.

### Backend: Supabase

Chosen over CloudKit and Firebase for three reasons:

1. **The data is relational.** The weekly template is naturally a join table; "what does
   this child do on Tuesday" is one query. Firestore's document model would force
   denormalisation or read-then-filter.
2. **The auth story lines up exactly.** Supabase anonymous auth maps cleanly onto
   claim codes, and an Apple identity can later be *linked* onto an existing anonymous
   user — so the deferred Sign in with Apple migration preserves all history rather than
   forcing a re-registration. CloudKit's sharing model is built on iCloud identities and
   `CKShare` invitations, which cannot express "type this code" and would have forced
   Apple accounts on day one.
3. **It is just Postgres.** If Supabase's pricing or terms become unattractive, `pg_dump`
   moves the whole system to any Postgres host. CloudKit and Firestore have no comparable
   exit.

Accepted trade-offs:

- **Free projects pause after roughly 7 days of no API activity.** Daily use never trips
  this, but an extended family holiday would. Recovery is a click in the dashboard with
  data intact. The app detects this state and reports it specifically (see §9).
- **Offline support is DIY.** Addressed by the cache and outbox in §9.

### Scaling note (if this ever goes public)

Postgres will not be the bottleneck and neither will hosting: a family generates a few
hundred KB per year, and Supabase's Pro tier (~$25/month, 100k MAU included) covers on the
order of 20,000 families. The real costs of a public release are elsewhere — COPPA and
GDPR children's-data compliance, an Android client, and replacing claim codes with real
accounts. This spec does not attempt to solve those, but §5 keeps the door open by making
the system multi-tenant from the first migration.

## 5. Architecture

One app. The mode shown is derived from the signed-in profile's `role`, fixed at claim
time. A parent's device is a parent device permanently; a child's device is theirs. There
is no mode switcher and no PIN gate.

```
┌─────────────────┐   ┌─────────────────┐
│  Parent device  │   │   Kid device    │      one app,
│  role = parent  │   │  role = child   │      role-branched at the root
└────────┬────────┘   └────────┬────────┘
         └───────────┬─────────┘
                     │ supabase-swift (HTTPS + JWT)
         ┌───────────▼────────────┐
         │  Supabase (Postgres)   │
         │  · anonymous auth      │
         │  · RLS scoped by       │
         │    family_id           │
         │  · claim_profile() RPC │
         └────────────────────────┘
```

### Layers

- **Repositories** — thin, protocol-backed wrappers over Supabase queries
  (`FamilyRepository`, `ChoreRepository`, `ScheduleRepository`, `CompletionRepository`).
  The protocols exist so view models can be tested against fakes.
- **`ScheduleResolver`** — a pure function:
  `(template, completions, date, timezone) -> [ChoreForDay]`.
  No network, no Supabase types, no SwiftUI. This is the only real logic in the system and
  the primary test target.
- **Views** — SwiftUI, driven by observable view models. No business logic.

### Where resolution happens

Client-side, not in a Postgres view. The family's entire template is on the order of 100
rows, so the app fetches template + current-week completions in a single pass, caches it,
and resolves locally. This buys offline reads and trivially testable logic. The cost is
that a hypothetical Android client would reimplement about thirty lines.

### Proposed project structure

```
Chores/
  ChoresApp.swift
  Core/
    SupabaseClient.swift
    Models/            # Codable structs mirroring tables
    Repositories/      # protocols + Supabase implementations + fakes
    Schedule/
      ScheduleResolver.swift
    Sync/
      Outbox.swift
      SnapshotCache.swift
  Features/
    Onboarding/        # create family (parent) / enter claim code (child)
    Kid/               # TodayView, WeekView
    Parent/            # TodayOverview, WeekGrid, Children, Chores, ScheduleEditor
  DesignSystem/
supabase/
  migrations/
```

## 6. Data model

```sql
families
  id          uuid primary key
  name        text not null
  timezone    text not null default 'Europe/Helsinki'
  created_at  timestamptz not null default now()

profiles
  id            uuid primary key
  family_id     uuid not null references families(id)
  auth_user_id  uuid unique references auth.users(id)   -- null until claimed
  display_name  text not null
  role          text not null check (role in ('parent','child'))
  color         text not null                            -- hex string, e.g. '#4C8BF5'
  sort_order    int  not null default 0
  created_at    timestamptz not null default now()

claim_codes
  code        text primary key                -- 6 chars, unambiguous alphabet
  family_id   uuid not null references families(id)
  profile_id  uuid not null references profiles(id)
  expires_at  timestamptz not null
  claimed_at  timestamptz                     -- null while unused
  created_at  timestamptz not null default now()

chores
  id           uuid primary key
  family_id    uuid not null references families(id)
  name         text not null
  icon         text                            -- SF Symbol name
  points       int                             -- reserved for future rewards; unused
  is_archived  boolean not null default false
  created_at   timestamptz not null default now()

schedule_entries                               -- the weekly template
  id          uuid primary key
  family_id   uuid not null references families(id)
  profile_id  uuid not null references profiles(id)
  chore_id    uuid not null references chores(id)
  weekday     smallint not null check (weekday between 1 and 7)   -- ISO: 1=Mon
  created_at  timestamptz not null default now()
  unique (profile_id, chore_id, weekday)

completions
  id            uuid primary key
  family_id     uuid not null references families(id)
  profile_id    uuid not null references profiles(id)
  chore_id      uuid not null references chores(id)
  due_on        date not null
  completed_at  timestamptz not null default now()
  completed_by  uuid not null references profiles(id)
  unique (profile_id, chore_id, due_on)
```

### Load-bearing decisions

**`completions` is keyed by `(profile_id, chore_id, due_on)` — never by
`schedule_entries.id`.** This is the hinge that makes the deferred features safe. The
entire weekly template can be rewritten and historical completions stay intact and
correctly attributed. It also makes a future `schedule_overrides` table purely additive:
`ScheduleResolver` changes from *read template* to *read template, then apply overrides*,
and nothing else in the system is affected.

**The same unique constraint makes completion writes idempotent**, which is what allows
the offline outbox (§9) to be a simple replay queue with no deduplication logic.

**`family_id` on every table, with RLS from the first migration.** There is exactly one
family today. Multi-tenancy costs nothing to build in now and is miserable to retrofit.

**`timezone` lives on `families`.** "Today" is a Helsinki calendar day, never a UTC one.
Without this, a chore ticked at 23:50 local records against the wrong date.

**`chores.is_archived` rather than deletion.** Deleting a chore would orphan or destroy
completion history. Archiving hides it from scheduling while preserving the record.

**`completed_by` is always equal to `profile_id` in v1** (children complete their own
chores; parents only revert). It is retained as the minimum viable attribution column so
that a future "parent marked this done" or approval flow does not need a migration.

**`points` is nullable and unused in v1** — the reserved hook for a future rewards layer.

## 7. Authentication and the claim flow

1. On first launch the parent's app signs in **anonymously** and calls a
   `SECURITY DEFINER` RPC `create_family(family_name text, parent_name text)`, which
   creates the `families` row and the caller's `profiles` row with `role = 'parent'`.
   This must be an RPC rather than direct inserts: RLS restricts writes on `families` and
   `profiles` to parents, and at this moment the caller has no profile and is therefore
   not yet a parent. The RPC rejects any caller who already has a profile.
2. The parent adds each child as a `profiles` row with `role = 'child'` and generates a
   `claim_codes` row: 6 characters from an unambiguous alphabet (no `O`/`0`, no `I`/`1`),
   expiring after 7 days.
3. The child installs the app, signs in anonymously, and enters the code.
4. A `SECURITY DEFINER` RPC `claim_profile(code text)` validates that the code exists, is
   unexpired and unclaimed; sets `profiles.auth_user_id = auth.uid()`; and stamps
   `claimed_at`. It is the only path by which `auth_user_id` may be set.
5. From then on the device resolves its profile via `auth_user_id` on launch.

**Known limitation:** an anonymous session lives and dies with the app installation. If a
child deletes the app or moves to a new device, the session is gone and they need a fresh
claim code. Re-issuing is a two-tap parent action. Sign in with Apple, when added, removes
this limitation entirely — and because Supabase links an Apple identity onto the existing
anonymous user, no history is lost in that transition.

### Row Level Security

Helper functions: `current_profile()` returns the caller's `profiles` row;
`current_family_id()` returns its `family_id`.

| Table | Read | Write |
|---|---|---|
| `families` | own family | parent only |
| `profiles` | own family | parent only |
| `chores` | own family | parent only |
| `schedule_entries` | own family | parent only |
| `completions` | own family | child: insert/delete **only where `profile_id` = own profile**; parent: insert/delete anywhere in own family |
| `claim_codes` | parent only | parent only (plus the `SECURITY DEFINER` RPC) |

Two `SECURITY DEFINER` RPCs deliberately sit outside these policies, because both run for
a caller who has no profile yet: `create_family()` (§7 step 1) and `claim_profile()`
(§7 step 4). They are the only writes not covered by RLS and therefore need the closest
review and the RLS tests in §10.

## 8. User experience

### Kid mode

**Today** is the screen that matters. A date header, a progress count (`2 of 4`), and a
list of chore cards with large tap targets. Tapping completes with haptic feedback;
completed items dim and move to the bottom. Empty state reads "Nothing today."

**Week** shows a 7-day strip for the **current ISO week only** (Monday–Sunday containing
today; no navigation to other weeks in v1). Future days are read-only previews. Past days
show what did and did not happen, and **a child may complete a chore for any past day
within that current week** — children forget to tap, and a strict today-only rule makes
the app a source of arguments rather than a record of reality. Completing a chore dated in
the future is never permitted, and the `due_on` boundary is evaluated against the family's
timezone.

There is no settings screen and no navigation to parent functionality.

### Parent mode

Three tabs.

**Today** — one card per child with a progress ring and their chore list. Tapping a
completed chore reverts it to pending. Answers "who is behind" at a glance.

**Week** — children as rows, Mon–Sun as columns, each cell showing a done/total count.
Tapping a cell opens that child's day detail. Doubles as the fairness check across the
week. Current ISO week only; browsing previous weeks is out of scope for v1.

**Manage** — three sub-screens:

- *Children*: list, add, rename, set colour, show claim code. Deleting a child is **not**
  supported in v1 — it raises questions about their completion history that are not worth
  answering yet.
- *Chores*: list, add, edit, archive. Archiving does **not** delete the chore's
  `schedule_entries`; `ScheduleResolver` filters archived chores out, and the schedule
  editor does not offer them when adding. Un-archiving therefore restores the previous
  assignments intact.
- *Schedule*: the weekly template editor

### Schedule editor

A 7-day × 3-child grid does not fit a phone. The editor is **day-first**, mirroring how
the requirement was described ("on Monday child A does X and Y"):

```
 Mon │ Tue │ Wed │ Thu │ Fri │ Sat │ Sun     ← day picker
──────────────────────────────────────────
 ● Child A
     Dishwasher                        ⊖
     Vacuum living room                ⊖
     + Add chore
 ● Child B
     Take out bins                     ⊖
     + Add chore
──────────────────────────────────────────
            [ Copy Monday to… ]
```

**"Copy day to…" is required, not a nicety.** Most weekdays are near-identical; without it
initial setup is 21 cells of manual entry.

A child-first view is deliberately omitted — the Week tab already provides the per-child
perspective.

### Local notifications

A daily `UNCalendarNotificationTrigger` on each child's device, scheduled from the cached
template: "You have 3 chores today." Fires at **16:00 local, fixed and not configurable in
v1**. Entirely on-device — no APNs, no certificates, no push tokens, no backend
involvement. Rescheduled whenever the cached template changes. Days on which the child has
no chores are not scheduled. Permission is requested during child onboarding, and the app
degrades silently if denied.

## 9. Failure handling, offline behaviour, and sync

**Completion toggles are optimistic.** The checkmark flips immediately and the write is
issued behind it. On failure the UI reverts and shows an inline message, never a modal.

**Outbox.** Pending completion inserts and deletes are persisted to disk and flushed on
launch, on foreground, and on reconnect. Because `(profile_id, chore_id, due_on)` is
unique, replay is idempotent and the outbox needs no deduplication of its own.

**Snapshot cache.** The last successful fetch of template + current-week completions is
persisted. The app opens straight into it, showing a "last updated" indicator when stale.
A child with no connectivity can still see and tick their list.

**Conflict resolution is last-write-wins with no merge logic.** The realistic conflict is
a child ticking a chore offline while a parent reverts it online; the stakes are a
checkbox.

Three failure states get dedicated screens, because each has a different remedy:

| State | Message |
|---|---|
| Lost session / unresolvable profile | "Ask a parent for a new code" |
| Supabase project paused (free-tier idle) | Named explicitly — the fix is un-pausing in the dashboard, and a generic network error would send the maintainer debugging the app |
| Invalid claim code | Distinguishes expired / already used / not found |

## 10. Testing

In priority order.

**`ScheduleResolver`** — the main event, and cheap to test because it is pure:

- all seven ISO weekday mappings (1 = Monday)
- the Helsinki-vs-UTC date boundary (a completion recorded at 23:50 local)
- DST transitions
- archived chores excluded from resolution
- completions matched to the correct `due_on`
- current-week vs past-week completion rules

**RLS policies** — non-negotiable, because an RLS failure is *silent*: no crash, just data
visible to the wrong person. A SQL test script run against a local Supabase asserts:

- a child in family A cannot read family B
- a child cannot insert a completion for a sibling's `profile_id`
- a child cannot insert, update or delete chores or schedule entries
- a parent can delete any completion within their own family
- `auth_user_id` cannot be set except via `claim_profile()`
- `create_family()` rejects a caller who already has a profile
- `claim_profile()` rejects expired, already-claimed and unknown codes

**View models** — tested against fake repositories through the protocols.

**Outbox** — replay idempotency, and flush-on-reconnect behaviour.

UI and snapshot tests are out of scope for v1.

## 11. Tooling and workflow

- Xcode project; Swift Package Manager for `supabase-swift`
- Swift Testing for unit tests
- Bundle identifier chosen at project creation
- Migrations authored as SQL files under `supabase/migrations/`.
  **The maintainer applies migrations; the implementation does not run `supabase db push`.**
- Distribution via TestFlight

## 12. Future extensions and how the model accommodates them

| Feature | Change required |
|---|---|
| Rewards / points | Populate the existing `chores.points`; add an aggregation view |
| Manual overrides | New `schedule_overrides` table; `ScheduleResolver` applies it after the template. No change to existing tables. |
| Parent approval | Nullable `approved_at` / `approved_by` on `completions`; additive |
| Sign in with Apple | Link an Apple identity onto the existing anonymous user; no data migration |
| Server push | Edge function on a schedule + APNs; replaces or supplements local notifications |
| Android | Reimplement `ScheduleResolver` (~30 lines); schema and RLS unchanged |
| Public release | `family_id` and RLS already present; the real work is compliance, not architecture |
