# Schedule History — Design

**Date:** 2026-09-21 (revised the same day: the two-table shape, see §2)
**Status:** Implemented on the `schedule-history` branch, after the
foreground-refresh fix and before any previous-week review, which is postponed.
Migration `20260921100000_schedule_history.sql` awaits the user's push to production.

## 1. Purpose

The schedule is a weekly template with no memory. `ScheduleResolver` answers "what was
due on day *d*" by reading the template as it is *now*, so a past day is drawn against
whatever the parent has edited since. Two things go wrong:

- **Archiving erases the week.** Archive "Bins" on Thursday and its Monday–Wednesday ticks
  vanish from this week's strip, because `guard !chore.isArchived` drops the chore from
  every day at once. This is a bug today, not only in some future history view.
- **Moving a chore rewrites the past.** Move Bins from Sunday to Saturday on Monday
  morning, and last Sunday now shows no Bins while last Saturday shows Bins *not done*.
  The kid did the chore; the record says they skipped one and never did the other.

The goal is that a past day resolves against the template *as it was on that day*, so
that "what did they do, and what did they miss" is answerable truthfully — this week now,
and last week once a review screen exists. The sooner the schema knows, the less history
is resolved against the wrong template: backfill can only guess.

## 2. Decisions

| Question | Decision |
|---|---|
| Must the shipped build keep working? | **Yes, indefinitely.** Production is the only environment a TestFlight build can talk to, and the App Store build is downloadable at any time. Every migration must therefore be compatible with the build currently in the store: expand, never contract. This decision shapes every row below. |
| Where do closed rows live? | **In their own table**, `schedule_entry_history`. `schedule_entries` keeps meaning exactly what it means today — the current template — so every read and write the shipped build makes still works. The first draft put a range on every row of one table; that broke the old build's `select *` (closed rows drawn as live) and its upsert (`on_conflict` cannot target a partial index). |
| Interval ends | `valid_from` inclusive on both tables; `valid_until` exclusive, on the history table only. An open row has no end. |
| Remove an entry | **Move it** to history with `valid_until = today` — except an entry added *today* (or later, under clock skew), which is deleted: it lived zero days. |
| Re-add an entry closed today | **Move it back**, same `id`, same `valid_from`. Remove-then-add within a day is a no-op, not a one-day gap. |
| `is_archived` | **Kept**, and kept in sync with the new `archived_on` by a trigger. The old build reads and writes the flag; the new build reads and writes the day; the row is always consistent. `Chore.isArchived` in Swift is a computed property over `archivedOn`. |
| Un-archive | `archived_on = null`, `is_archived = false`. The archived stretch is forgotten. |
| Whose "today"? | **The family's**, sent by the new client (`store.today`). For the old build, which sends no day, triggers stamp the family's local today from `families.timezone`. Never Postgres `current_date`, which is UTC. |
| Where do the rules live? | **In SQL, as RPCs** under RLS (`security invoker`). Moving a row between tables is two statements that must not interleave with another parent's. The in-memory backend mirrors the *semantics* — one collection with ranges — since what it models is behaviour, not storage; pgTAP proves the SQL, Swift Testing proves the mirror. |
| Uniqueness | `unique (profile_id, chore_id, weekday)` on `schedule_entries` **stays**: with only open rows in the table it is exactly right, and it is what the old build's upsert infers. History has no uniqueness beyond `id`. |
| Backfill | `valid_from = created_at` as a date in the family's timezone. Existing archived chores get `archived_on = created_at::date`: archived for their whole life, which is exactly how the app draws them today. |
| Fetch window | The new client reads a union view, `schedule_entries_all`, filtered to rows that **overlap** the fetched week: `valid_from <= sunday and (valid_until is null or valid_until > monday)`. All chores are fetched as today. |
| Old-build degradation | An old *parent* build's schedule edits work but leave no history (its delete is a delete). Old kid builds are unaffected. Nobody sees an error. |

## 3. Data

### 3.1 Migration

```sql
-- schedule_entries: the first day, stamped by the client or, for the old
-- build, by a trigger from the family's timezone.
alter table public.schedule_entries add column valid_from date;
update ... set valid_from = (created_at at time zone f.timezone)::date ...;
alter table public.schedule_entries alter column valid_from set not null;
create trigger schedule_entries_default_valid_from before insert ...;

-- Closed rows. Same id as the row had while open, so a reopen is the same row.
create table public.schedule_entry_history (
  id, family_id, profile_id, chore_id, weekday, created_at,   -- as schedule_entries
  valid_from  date not null,
  valid_until date not null,
  closed_at   timestamptz not null default now(),
  check (valid_until > valid_from)
);
-- RLS and grants mirror schedule_entries: family-scoped select, parents write.

-- chores: the day, alongside the flag, kept in step both ways.
alter table public.chores add column archived_on date;
update ... set archived_on = (created_at at time zone f.timezone)::date where is_archived;
create trigger chores_sync_archived before insert or update ...;

-- One relation over both tables for readers that want history.
create view public.schedule_entries_all with (security_invoker = true) as
  select ..., null::date as valid_until from public.schedule_entries
  union all
  select ..., valid_until from public.schedule_entry_history;
```

### 3.2 RPCs

All three run as the caller (`security invoker`); RLS on both tables applies. Each
takes `p_today date` from the client.

| Function | Rule |
|---|---|
| `schedule_entry_add(p_family_id, p_profile_id, p_chore_id, p_weekday, p_today) returns schedule_entries` | Open row exists → return it. History row closed *on* `p_today` → move it back (same `id`, `valid_from`, `created_at`) and return it. Otherwise insert with `valid_from = p_today`. |
| `schedule_entry_remove(p_id, p_today) returns void` | `valid_from >= p_today` → delete. Otherwise move the row to history with `valid_until = p_today`. An id that is already in history → no-op. |
| `schedule_copy_day(p_family_id, p_from, p_to int[], p_today) returns void` | For each target ≠ source: remove every open target entry, then add each open source entry onto the target, both by the rules above. One transaction. |

`execute` is granted to `authenticated` only; RLS does the family scoping.

### 3.3 Triggers

- **`schedule_entries_default_valid_from`** (before insert): when `valid_from` is null,
  stamp the family's local today. The old build's upsert sends no `valid_from`.
- **`chores_sync_archived`** (before insert or update): if `archived_on` changed, set
  `is_archived = archived_on is not null`; else if `is_archived` changed, set `archived_on`
  to the family's local today or null. On insert, whichever is given wins.

### 3.4 Reads

`family_undone_count` (`20260918100200_evening_reminder.sql`) reads `schedule_entries_all`
with the same filter the resolver applies:

```sql
   and se.valid_from <= p_date and (se.valid_until is null or se.valid_until > p_date)
   and (c.archived_on is null or c.archived_on > p_date)
```

## 4. Models and resolution

```swift
public struct ScheduleEntry {
    // ...existing fields...
    public let validFrom: CalendarDay
    public var validUntil: CalendarDay?          // exclusive; nil = open
    public var isCurrent: Bool { validUntil == nil }
    public func isValid(on day: CalendarDay) -> Bool
}

public struct Chore {
    public var archivedOn: CalendarDay?          // is_archived is not decoded
    public var isArchived: Bool { archivedOn != nil }
    public func isArchived(on day: CalendarDay) -> Bool
}
```

`ScheduleResolver.chores(for:on:...)` filters `entry.isValid(on: day)` and
`!chore.isArchived(on: day)`. That is the only change to it. `progress`,
`ReminderSchedule` and both week screens inherit the fix.

Every other reader of `snapshot.template` wants the *current* template and filters
`isCurrent`: `ScheduleEditorView.entries(for:)` and the in-memory `copyDay` source.

### 4.1 `ChoresBackend`

```swift
func addScheduleEntry(familyID:profileID:choreID:weekday:from today: CalendarDay) async throws -> ScheduleEntry
func removeScheduleEntry(id: UUID, on today: CalendarDay) async throws
func copyDay(familyID:from:to:on today: CalendarDay) async throws
```

`updateChore(_:)` is unchanged in signature; its payload carries `archived_on`
(explicit `null` to un-archive). The trigger keeps `is_archived` in step.
`ChoresView.setArchived` sets `archivedOn = isArchived ? store.today : nil`.

## 5. What this does not do

- **No previous-week screen.** The fetch window stays one week; this design only makes
  a past day inside it truthful. The review screen is a later design and gets smaller
  because of this one.
- **No history for profiles, names or icons.** A renamed chore is renamed in the past too.
- **No exact history for archived stretches** once un-archived (§2).
- **No history from old-build edits.** A parent still on the shipped build deletes rather
  than closes. The window is as long as that parent takes to update.
- **Existing data is a guess.** `created_at` is right for entries never edited and wrong
  for the rest; there is no way to do better.

## 6. Testing

| Layer | Proves |
|---|---|
| `ScheduleResolverTests` | Range boundaries: valid on `valid_from`, not on `valid_until`; open row valid forever; chore archived on *d* is due on *d − 1* and not on *d*; an archived chore's earlier ticks in the week still count. |
| `InMemoryBackendTests` | Remove closes (row still returned, closed); remove-same-day deletes; add after close-same-day reopens the same id; add after an older close inserts a new row and both are returned; copy-day closes and adds by the same rules; a snapshot carries only rows overlapping its week. |
| `ModelDecodingTests` | Both models round-trip the new keys; `valid_until`/`archived_on` decode from `null`. |
| pgTAP `03_schedule_history.sql` | **The old build's calls still work**: an insert with no `valid_from` is stamped with the family's local today; the upsert's `on_conflict` still resolves; flipping `is_archived` sets `archived_on` and vice versa. The three RPCs' rules across both tables. `schedule_entries_all` shows open and closed rows to the family. `family_undone_count` ignores a closed entry and a chore archived before `p_date`. |
| `SupabaseIntegrationTests` | The existing schedule and archive cases, updated to the new signatures, plus one round trip for close-and-reopen through the view. |
| UI tests | Unchanged in intent; the schedule editor still adds and removes. The seed gives every entry a fixed `validFrom` years before any seeded `today`. |
