# Schedule History — Design

**Date:** 2026-09-21
**Status:** Designed, not implemented. Lands after the foreground-refresh fix
(commit "Bring the week screen up to date when the app comes back to the front")
and before any previous-week review, which is postponed.

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
| Ranges or weekly snapshots? | **Validity ranges** on each template row. A frozen copy per week needs a job to make it, duplicates rows weekly, and leaves a Wednesday edit ambiguous. A range answers that: the edit applies from today. |
| Which rows carry a range? | `schedule_entries` (`valid_from`, `valid_until`) and `chores` (`archived_on`). Profiles are not versioned: a deleted child cascades away as today. |
| Interval ends | `valid_from` inclusive, `valid_until` **exclusive**, `null` = still current. "Removed on Tuesday" means valid through Monday. |
| Remove an entry | **Close it** (`valid_until = today`) rather than delete — except an entry added *today*, which is deleted: it lived zero days and never existed. |
| Re-add an entry closed today | **Reopen** the same row (`valid_until = null`). Remove-then-add within a day is a no-op, not a one-day gap. |
| `is_archived` | **Replaced** by `archived_on date null`. Two columns for one fact would drift. `Chore.isArchived` stays as a computed property so most call sites do not change. |
| Un-archive | Sets `archived_on = null`. The archived stretch is forgotten — the chore reads as never archived. Acceptable: un-archive means "never mind". |
| Whose "today"? | **The family's**, sent by the client (`store.today`). Postgres `current_date` is UTC; a Helsinki parent editing at 01:00 Tuesday must produce Tuesday. |
| Where do the rules live? | **In SQL, as RPCs** under RLS (`security invoker`). Close-or-delete, reopen-or-insert and copy-day are each several statements that must not interleave with another parent's, and the partial unique index below cannot be targeted by PostgREST's `on_conflict`. The in-memory backend mirrors the rules for the UI tests; pgTAP proves the SQL, Swift Testing proves the mirror. |
| Uniqueness | `unique (profile_id, chore_id, weekday)` becomes a **partial unique index** `where valid_until is null`. One open row per triple; any number of closed ones. |
| Backfill | `valid_from = created_at` as a date in the family's timezone. Existing archived chores get `archived_on = created_at::date`: archived for their whole life, which is exactly how the app draws them today. Neither guess can be better than that. |
| Fetch window | Entries whose range **overlaps** the fetched week, not only open ones: `valid_from <= sunday and (valid_until is null or valid_until > monday)`. Closed rows accumulate but the window bounds what a phone ever holds. All chores are fetched as today. |

## 3. Data

### 3.1 Migration

```sql
alter table public.schedule_entries
  add column valid_from  date,
  add column valid_until date;

update public.schedule_entries se
   set valid_from = (se.created_at at time zone f.timezone)::date
  from public.families f
 where f.id = se.family_id;

alter table public.schedule_entries
  alter column valid_from set not null,
  add constraint schedule_entries_range check (valid_until is null or valid_until > valid_from),
  drop constraint schedule_entries_profile_id_chore_id_weekday_key;

create unique index schedule_entries_open_key
  on public.schedule_entries (profile_id, chore_id, weekday)
  where valid_until is null;

alter table public.chores add column archived_on date;
update public.chores c
   set archived_on = (c.created_at at time zone f.timezone)::date
  from public.families f
 where f.id = c.family_id and c.is_archived;
alter table public.chores drop column is_archived;
```

The constraint name is Postgres's default for the inline `unique (...)`; the migration
confirms it with `\d` on the local stack before it is trusted.

### 3.2 RPCs

All three run as the caller (`security invoker`), so `schedule_write` RLS applies as it
does to the direct writes they replace. Each takes `p_today date` from the client.

| Function | Rule |
|---|---|
| `schedule_entry_add(p_family_id, p_profile_id, p_chore_id, p_weekday, p_today) returns schedule_entries` | Open row exists → return it. Row closed *on* `p_today` (`valid_until = p_today`) → reopen it and return it. Otherwise insert with `valid_from = p_today`. |
| `schedule_entry_remove(p_id, p_today) returns void` | `valid_from = p_today` → delete. Else, if open → `valid_until = p_today`. Already closed → no-op. |
| `schedule_copy_day(p_family_id, p_from, p_to int[], p_today) returns void` | For each target ≠ source: remove every open target entry (by the rule above), then add each open source entry onto the target (by the rule above). One transaction. |

`execute` is granted to `authenticated` only; RLS does the family scoping.

### 3.3 Reads

`family_undone_count` (`20260918100200_evening_reminder.sql`) gains the same filter the
resolver applies:

```sql
   and se.valid_from <= p_date and (se.valid_until is null or se.valid_until > p_date)
   and (c.archived_on is null or c.archived_on > p_date)
```

## 4. Models and resolution

```swift
public struct ScheduleEntry {
    // ...existing fields...
    public let validFrom: CalendarDay
    public let validUntil: CalendarDay?          // exclusive
    public var isCurrent: Bool { validUntil == nil }
    public func isValid(on day: CalendarDay) -> Bool {
        day >= validFrom && (validUntil.map { day < $0 } ?? true)
    }
}

public struct Chore {
    // is_archived is gone
    public var archivedOn: CalendarDay?
    public var isArchived: Bool { archivedOn != nil }
    public func isArchived(on day: CalendarDay) -> Bool {
        archivedOn.map { day >= $0 } ?? false
    }
}
```

`ScheduleResolver.chores(for:on:...)` filters `entry.isValid(on: day)` and
`!chore.isArchived(on: day)`. That is the only change to it. `progress`,
`ReminderSchedule` and both week screens inherit the fix.

Every other reader of `snapshot.template` wants the *current* template and filters
`isCurrent`: `ScheduleEditorView.entries(for:)` and the in-memory `copyDay` source.
`FamilySnapshot.activeChores` is unchanged in meaning (`!isArchived` = not archived now).

### 4.1 `ChoresBackend`

```swift
func addScheduleEntry(familyID:profileID:choreID:weekday:from today: CalendarDay) async throws -> ScheduleEntry
func removeScheduleEntry(id: UUID, on today: CalendarDay) async throws
func copyDay(familyID:from:to:on today: CalendarDay) async throws
```

`updateChore(_:)` is unchanged in signature; its payload carries `archived_on`
(explicit `null` to un-archive, as `updateProfile` already does for reminder times).
`ChoresView.setArchived` sets `archivedOn = isArchived ? store.today : nil`.

## 5. What this does not do

- **No previous-week screen.** The fetch window stays one week; this design only makes
  a past day inside it truthful. The review screen is a later design and gets smaller
  because of this one.
- **No history for profiles, names or icons.** A renamed chore is renamed in the past too.
- **No exact history for archived stretches** once un-archived (§2).
- **Existing data is a guess.** `created_at` is right for entries never edited and wrong
  for the rest; there is no way to do better.

## 6. Testing

| Layer | Proves |
|---|---|
| `ScheduleResolverTests` | Range boundaries: valid on `valid_from`, not on `valid_until`; open row valid forever; chore archived on *d* is due on *d − 1* and not on *d*; an archived chore's earlier ticks in the week still count. |
| `InMemoryBackendTests` | Remove closes (row still returned, closed); remove-same-day deletes; add after close-same-day reopens the same id; add after an older close inserts a new row and both are returned; copy-day closes and adds by the same rules. |
| `ModelDecodingTests` | Both models round-trip the new keys; `valid_until`/`archived_on` decode from `null`. |
| pgTAP `03_schedule_history.sql` | The three RPCs' rules; the partial index allows a closed and an open row for one triple and rejects two open; `family_undone_count` ignores a closed entry and a chore archived before `p_date`, counts one archived after. |
| `SupabaseIntegrationTests` | The existing schedule and archive cases, updated to the new signatures, plus one round trip for close-and-reopen. |
| UI tests | Unchanged in intent; the schedule editor still adds and removes. The seed gives every entry a fixed `validFrom` years before any seeded `today` (one seed has no `today` to count back from). |
