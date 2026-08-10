# Household Chores App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native iOS app where three children see and tick off their daily chores while a parent maintains a repeating weekly chore schedule and monitors completion.

**Architecture:** All domain logic lives in a `ChoresCore` Swift package that is testable from the command line with `swift test` — models, a pure `ScheduleResolver`, repository protocols, an offline snapshot cache, and a write outbox. A thin SwiftUI app target consumes it and branches at the root on the signed-in profile's role. Supabase (Postgres) stores everything, with row-level security scoping every table by `family_id` and two `SECURITY DEFINER` RPCs handling the two bootstrap moments where a caller has no profile yet.

**Tech Stack:** Swift 6 toolchain (language mode 5), SwiftUI, Swift Testing, `supabase-swift` 2.x, Supabase CLI, PostgreSQL 15, pgTAP.

**Spec:** `docs/superpowers/specs/2026-08-10-household-chores-app-design.md`

## Global Constraints

- **Deployment target:** iOS 17.0 minimum. Xcode 16 or later is required (the app target relies on file-system-synchronized folders).
- **Swift:** `swift-tools-version: 6.0`, with `.swiftLanguageMode(.v5)` on all targets. Strict concurrency is deliberately deferred; do not enable language mode 6.
- **Test framework:** Swift Testing (`import Testing`, `@Test`, `#expect`). Do not use XCTest.
- **Timezone:** all calendar arithmetic goes through the family's timezone, default `Europe/Helsinki`. Never use `Date()` directly for day arithmetic; never use `Calendar.current` inside `ChoresCore`.
- **Weekday encoding:** ISO 8601 — `1 = Monday` … `7 = Sunday`. This is *not* `Calendar`'s convention (which is `1 = Sunday`); conversion is centralised in `CalendarDay.isoWeekday`.
- **Database migrations:** authored as files under `supabase/migrations/`. **Never run `supabase db push`** — the maintainer applies migrations against the hosted project. Running the local stack (`supabase start`, `supabase db reset`, `supabase test db`) is expected and fine.
- **Commits:** every task ends with a commit. Use the `commit-commands:commit` skill.
- **Secrets:** the Supabase URL and anon key are read from `Chores/Secrets.xcconfig`, which is gitignored. Never commit keys.
- **Naming:** database identifiers are `snake_case`; Swift is `camelCase`; every model declares explicit `CodingKeys`. Do not rely on a global key-decoding strategy.

## File Structure

```
Package.swift                                   ChoresCore package manifest
Sources/ChoresCore/
  Calendar/
    CalendarDay.swift                           timezone-free Y/M/D value type, ISO weekday
    WeekCalendar.swift                          ISO week (Mon–Sun) containing a day
  Models/
    Family.swift  Profile.swift  Chore.swift
    ScheduleEntry.swift  Completion.swift       Codable mirrors of the tables
  Schedule/
    ChoreForDay.swift                           resolved chore + completion state
    ScheduleResolver.swift                      the pure function; the core of the app
    CompletionEligibility.swift                 which days may be ticked
  Repositories/
    Repositories.swift                          ChoresBackend protocol + error type
    InMemory/InMemoryChoresBackend.swift        fake for tests and previews
    Supabase/SupabaseChoresBackend.swift        live implementation
    Supabase/SupabaseErrorMapping.swift         PostgREST/URLError → ChoresBackendError
  Sync/
    FamilySnapshot.swift                        one-shot fetch bundle
    SnapshotCache.swift                         disk persistence of last good snapshot
    Outbox.swift                                queued, idempotent completion writes
  Notifications/
    ReminderSchedule.swift                      which weekdays deserve a reminder
  ViewModels/                                   @Observable, @MainActor, no SwiftUI
    SessionViewModel.swift                      loading / unclaimed / parent / child
    OnboardingViewModel.swift                   create family, claim code
    FamilyStore.swift                           snapshot + cache + optimistic writes
Tests/ChoresCoreTests/                          one test file per source area
App/Chores/                                     Xcode app target (synchronized folder)
  ChoresApp.swift  RootView.swift  AppEnvironment.swift
  Onboarding/  Parent/  Kid/  DesignSystem/  Failure/
supabase/
  migrations/*.sql
  tests/*.sql                                   pgTAP
```

**Boundary rule:** `ChoresCore` must not import SwiftUI, and the app target must not contain calendar arithmetic or SQL. If a task tempts you to break either, the logic belongs in `ChoresCore`.

---

## Phase 1 — Database foundation

### Task 1: Local Supabase stack and initial schema

**Files:**
- Create: `supabase/config.toml` (generated)
- Create: `supabase/migrations/20260810120000_initial_schema.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: tables `families`, `profiles`, `claim_codes`, `chores`, `schedule_entries`, `completions` with the columns and constraints used by every later task.

- [ ] **Step 1: Initialise the Supabase project scaffolding**

```bash
brew install supabase/tap/supabase   # skip if already installed
cd /Users/arime/chores
supabase init
```

Answer "no" if asked to generate VS Code settings.

- [ ] **Step 2: Start the local stack**

```bash
supabase start
```

Expected: a table of local URLs. Note the `DB URL` — later steps use `psql "$(supabase status -o env | grep DB_URL | cut -d= -f2- | tr -d '"')"`.

- [ ] **Step 3: Write the schema migration**

Create `supabase/migrations/20260810120000_initial_schema.sql`:

```sql
create extension if not exists "pgcrypto";

create table public.families (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  timezone   text not null default 'Europe/Helsinki',
  created_at timestamptz not null default now()
);

create table public.profiles (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references public.families(id) on delete cascade,
  auth_user_id uuid unique references auth.users(id) on delete set null,
  display_name text not null,
  role         text not null check (role in ('parent','child')),
  color        text not null default '#4C8BF5',
  sort_order   int  not null default 0,
  created_at   timestamptz not null default now()
);
create index profiles_family_idx on public.profiles(family_id);

create table public.claim_codes (
  code       text primary key,
  family_id  uuid not null references public.families(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  expires_at timestamptz not null,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);
create index claim_codes_profile_idx on public.claim_codes(profile_id);

create table public.chores (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families(id) on delete cascade,
  name        text not null,
  icon        text,
  points      int,
  is_archived boolean not null default false,
  created_at  timestamptz not null default now()
);
create index chores_family_idx on public.chores(family_id);

create table public.schedule_entries (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.families(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  chore_id   uuid not null references public.chores(id) on delete cascade,
  weekday    smallint not null check (weekday between 1 and 7),
  created_at timestamptz not null default now(),
  unique (profile_id, chore_id, weekday)
);
create index schedule_entries_family_idx on public.schedule_entries(family_id);

create table public.completions (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references public.families(id) on delete cascade,
  profile_id   uuid not null references public.profiles(id) on delete cascade,
  chore_id     uuid not null references public.chores(id) on delete cascade,
  due_on       date not null,
  completed_at timestamptz not null default now(),
  completed_by uuid not null references public.profiles(id) on delete cascade,
  unique (profile_id, chore_id, due_on)
);
create index completions_family_due_idx on public.completions(family_id, due_on);
```

- [ ] **Step 4: Apply and verify**

```bash
supabase db reset
```

Expected: migration applies with no error, ending in `Finished supabase db reset.`

- [ ] **Step 5: Verify the unique constraint is the one the outbox depends on**

```bash
psql "$(supabase status -o env | grep '^DB_URL' | cut -d= -f2- | tr -d '"')" \
  -c "\d public.completions" | grep -i unique
```

Expected: a line showing `UNIQUE CONSTRAINT` over `(profile_id, chore_id, due_on)`.

- [ ] **Step 6: Commit**

Use the `commit-commands:commit` skill. Stage `supabase/`.

---

### Task 2: RLS helpers, policies, and the auth_user_id lock

**Files:**
- Create: `supabase/migrations/20260810120100_rls.sql`

**Interfaces:**
- Consumes: all tables from Task 1.
- Produces: SQL functions `current_profile_id() -> uuid`, `current_family_id() -> uuid`, `is_parent() -> boolean`; RLS enabled on all six tables.

- [ ] **Step 1: Write the helper functions**

Create `supabase/migrations/20260810120100_rls.sql`, beginning with:

```sql
-- SECURITY DEFINER is required: these are called from policies ON profiles,
-- and a policy that queries its own table under RLS recurses infinitely.
create or replace function public.current_profile_id()
returns uuid language sql stable security definer set search_path = public
as $$ select id from public.profiles where auth_user_id = auth.uid() limit 1 $$;

create or replace function public.current_family_id()
returns uuid language sql stable security definer set search_path = public
as $$ select family_id from public.profiles where auth_user_id = auth.uid() limit 1 $$;

create or replace function public.is_parent()
returns boolean language sql stable security definer set search_path = public
as $$ select exists (
  select 1 from public.profiles
  where auth_user_id = auth.uid() and role = 'parent') $$;
```

- [ ] **Step 2: Append the auth_user_id lock trigger**

```sql
create or replace function public.prevent_auth_user_id_change()
returns trigger language plpgsql as $$
begin
  if new.auth_user_id is distinct from old.auth_user_id
     and coalesce(current_setting('app.allow_claim', true), '') <> 'on' then
    raise exception 'auth_user_id may only be set by claim_profile()';
  end if;
  return new;
end $$;

create trigger profiles_lock_auth_user_id
  before update on public.profiles
  for each row execute function public.prevent_auth_user_id_change();
```

- [ ] **Step 3: Append the policies**

```sql
alter table public.families         enable row level security;
alter table public.profiles         enable row level security;
alter table public.claim_codes      enable row level security;
alter table public.chores           enable row level security;
alter table public.schedule_entries enable row level security;
alter table public.completions      enable row level security;

-- families: no INSERT policy — creation goes through create_family() only.
create policy families_select on public.families for select
  using (id = public.current_family_id());
create policy families_update on public.families for update
  using (id = public.current_family_id() and public.is_parent());

create policy profiles_select on public.profiles for select
  using (family_id = public.current_family_id());
create policy profiles_insert on public.profiles for insert
  with check (family_id = public.current_family_id()
              and public.is_parent()
              and auth_user_id is null);
create policy profiles_update on public.profiles for update
  using (family_id = public.current_family_id() and public.is_parent());

create policy claim_codes_all on public.claim_codes for all
  using (family_id = public.current_family_id() and public.is_parent())
  with check (family_id = public.current_family_id() and public.is_parent());

create policy chores_select on public.chores for select
  using (family_id = public.current_family_id());
create policy chores_write on public.chores for all
  using (family_id = public.current_family_id() and public.is_parent())
  with check (family_id = public.current_family_id() and public.is_parent());

create policy schedule_select on public.schedule_entries for select
  using (family_id = public.current_family_id());
create policy schedule_write on public.schedule_entries for all
  using (family_id = public.current_family_id() and public.is_parent())
  with check (family_id = public.current_family_id() and public.is_parent());

create policy completions_select on public.completions for select
  using (family_id = public.current_family_id());
create policy completions_insert on public.completions for insert
  with check (family_id = public.current_family_id()
              and (public.is_parent() or profile_id = public.current_profile_id()));
create policy completions_delete on public.completions for delete
  using (family_id = public.current_family_id()
         and (public.is_parent() or profile_id = public.current_profile_id()));
```

Note there is deliberately no `completions` UPDATE policy: a completion is created or destroyed, never edited.

- [ ] **Step 4: Apply and verify RLS is on**

```bash
supabase db reset
psql "$(supabase status -o env | grep '^DB_URL' | cut -d= -f2- | tr -d '"')" \
  -c "select relname, relrowsecurity from pg_class
      where relname in ('families','profiles','claim_codes','chores','schedule_entries','completions');"
```

Expected: `relrowsecurity` is `t` for all six rows.

- [ ] **Step 5: Commit**

Use the `commit-commands:commit` skill.

---

### Task 3: Bootstrap RPCs

**Files:**
- Create: `supabase/migrations/20260810120200_rpcs.sql`

**Interfaces:**
- Consumes: Task 1 tables, Task 2 helpers.
- Produces: `create_family(family_name text, parent_name text, family_timezone text) -> uuid`, `generate_claim_code(p_profile_id uuid) -> text`, `claim_profile(p_code text) -> uuid`. Error codes: `P0001` unknown code, `P0002` already used, `P0003` expired.

- [ ] **Step 1: Write `create_family`**

Create `supabase/migrations/20260810120200_rpcs.sql`:

```sql
create or replace function public.create_family(
  family_name text,
  parent_name text,
  family_timezone text default 'Europe/Helsinki')
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_family_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from public.profiles where auth_user_id = auth.uid()) then
    raise exception 'caller already has a profile';
  end if;

  insert into public.families (name, timezone)
    values (family_name, family_timezone)
    returning id into v_family_id;

  insert into public.profiles (family_id, auth_user_id, display_name, role, color, sort_order)
    values (v_family_id, auth.uid(), parent_name, 'parent', '#4C8BF5', 0);

  return v_family_id;
end $$;
```

- [ ] **Step 2: Append `generate_claim_code`**

```sql
create or replace function public.generate_claim_code(p_profile_id uuid)
returns text language plpgsql security definer set search_path = public
as $$
declare
  v_code text;
  v_family uuid;
  -- Unambiguous alphabet: no I, O, 0 or 1.
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if not public.is_parent() then
    raise exception 'only a parent may generate claim codes';
  end if;

  select family_id into v_family from public.profiles where id = p_profile_id;
  if v_family is null or v_family <> public.current_family_id() then
    raise exception 'profile not in caller family';
  end if;

  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.claim_codes where code = v_code);
  end loop;

  -- Issuing a new code invalidates any outstanding unclaimed one.
  delete from public.claim_codes where profile_id = p_profile_id and claimed_at is null;

  insert into public.claim_codes (code, family_id, profile_id, expires_at)
    values (v_code, v_family, p_profile_id, now() + interval '7 days');

  return v_code;
end $$;
```

- [ ] **Step 3: Append `claim_profile`**

```sql
create or replace function public.claim_profile(p_code text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_norm text := upper(trim(p_code));
  v_profile_id uuid;
  v_expires timestamptz;
  v_claimed timestamptz;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from public.profiles where auth_user_id = auth.uid()) then
    raise exception 'device already claimed';
  end if;

  select profile_id, expires_at, claimed_at
    into v_profile_id, v_expires, v_claimed
    from public.claim_codes where code = v_norm;

  if v_profile_id is null then
    raise exception 'unknown code' using errcode = 'P0001';
  end if;
  if v_claimed is not null then
    raise exception 'code already used' using errcode = 'P0002';
  end if;
  if v_expires < now() then
    raise exception 'code expired' using errcode = 'P0003';
  end if;

  perform set_config('app.allow_claim', 'on', true);
  update public.profiles set auth_user_id = auth.uid() where id = v_profile_id;
  update public.claim_codes set claimed_at = now() where code = v_norm;

  return v_profile_id;
end $$;
```

- [ ] **Step 4: Apply and smoke-test**

```bash
supabase db reset
psql "$(supabase status -o env | grep '^DB_URL' | cut -d= -f2- | tr -d '"')" \
  -c "select proname from pg_proc where proname in ('create_family','generate_claim_code','claim_profile');"
```

Expected: all three function names listed.

- [ ] **Step 5: Commit**

Use the `commit-commands:commit` skill.

---

### Task 4: pgTAP tests for RLS and RPCs

**Files:**
- Create: `supabase/tests/00_helpers.sql`
- Create: `supabase/tests/01_rls.sql`
- Create: `supabase/tests/02_rpcs.sql`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: `supabase test db` as the regression gate for all future database changes.

An RLS failure is silent — no crash, just data visible to the wrong person. These tests are the only thing that catches it.

- [ ] **Step 1: Write the fixture helper**

Create `supabase/tests/00_helpers.sql`:

```sql
-- Creates an auth user and returns its uuid. Local-stack only.
create or replace function tests.create_auth_user(p_email text)
returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id, id, aud, role, email,
                          encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
          p_email, '', now(), now(), now());
  return v_id;
end $$;

-- Impersonate an authenticated user for subsequent statements in this transaction.
create or replace function tests.authenticate_as(p_uid uuid)
returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
end $$;
```

Prepend to the file:

```sql
create schema if not exists tests;
```

- [ ] **Step 2: Write the RLS test**

Create `supabase/tests/01_rls.sql`:

```sql
begin;
select plan(7);

-- Two families, built as superuser so RLS is bypassed during setup.
set local role postgres;
\set ON_ERROR_STOP on

select tests.create_auth_user('parent-a@test.local') as parent_a_uid \gset
select tests.create_auth_user('child-a@test.local')  as child_a_uid  \gset
select tests.create_auth_user('child-b@test.local')  as child_b_uid  \gset

insert into public.families (id, name) values
  ('11111111-1111-1111-1111-111111111111', 'Family A'),
  ('22222222-2222-2222-2222-222222222222', 'Family B');

insert into public.profiles (id, family_id, auth_user_id, display_name, role) values
  ('aaaaaaa1-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', :'parent_a_uid', 'Parent A', 'parent'),
  ('aaaaaaa1-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', :'child_a_uid',  'Child A',  'child'),
  ('aaaaaaa1-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', null,            'Sibling',  'child'),
  ('bbbbbbb2-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', :'child_b_uid',  'Child B',  'child');

insert into public.chores (id, family_id, name) values
  ('ccccccc1-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Dishwasher');

-- Child A sees only their own family.
select tests.authenticate_as(:'child_a_uid'::uuid);
select is((select count(*) from public.families)::int, 1,
          'child A sees exactly one family');
select is((select count(*) from public.profiles)::int, 3,
          'child A sees only family A profiles');

-- Child A cannot complete a sibling's chore.
select throws_ok(
  $$insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by)
    values ('11111111-1111-1111-1111-111111111111',
            'aaaaaaa1-0000-0000-0000-000000000003',
            'ccccccc1-0000-0000-0000-000000000001', current_date,
            'aaaaaaa1-0000-0000-0000-000000000003')$$,
  '42501', null, 'child cannot complete a sibling''s chore');

-- Child A may complete their own.
select lives_ok(
  $$insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by)
    values ('11111111-1111-1111-1111-111111111111',
            'aaaaaaa1-0000-0000-0000-000000000002',
            'ccccccc1-0000-0000-0000-000000000001', current_date,
            'aaaaaaa1-0000-0000-0000-000000000002')$$,
  'child may complete their own chore');

-- Child A cannot create chores.
select throws_ok(
  $$insert into public.chores (family_id, name)
    values ('11111111-1111-1111-1111-111111111111', 'Sneaky')$$,
  '42501', null, 'child cannot create chores');

-- Child A cannot claim a different profile by direct update.
select throws_ok(
  $$update public.profiles set auth_user_id = auth.uid()
    where id = 'aaaaaaa1-0000-0000-0000-000000000003'$$,
  null, null, 'auth_user_id cannot be set by direct update');

-- Parent A may delete the child's completion.
select tests.authenticate_as(:'parent_a_uid'::uuid);
select lives_ok(
  $$delete from public.completions
    where profile_id = 'aaaaaaa1-0000-0000-0000-000000000002'$$,
  'parent may revert a child completion');

select * from finish();
rollback;
```

- [ ] **Step 3: Write the RPC test**

Create `supabase/tests/02_rpcs.sql`:

```sql
begin;
select plan(6);

set local role postgres;
select tests.create_auth_user('newparent@test.local') as np_uid \gset
select tests.create_auth_user('newchild@test.local')  as nc_uid \gset

select tests.authenticate_as(:'np_uid'::uuid);
select lives_ok(
  $$select public.create_family('Test Family', 'Parent')$$,
  'create_family succeeds for a profile-less caller');
select throws_ok(
  $$select public.create_family('Second Family', 'Parent')$$,
  null, null, 'create_family rejects a caller who already has a profile');

set local role postgres;
insert into public.profiles (id, family_id, display_name, role)
  select 'ddddddd1-0000-0000-0000-000000000001', id, 'Kid', 'child'
  from public.families where name = 'Test Family';

select tests.authenticate_as(:'np_uid'::uuid);
select public.generate_claim_code('ddddddd1-0000-0000-0000-000000000001') as code \gset

select tests.authenticate_as(:'nc_uid'::uuid);
select throws_ok(
  $$select public.claim_profile('ZZZZZZ')$$,
  'P0001', null, 'unknown code is rejected with P0001');
select lives_ok(
  format($$select public.claim_profile(%L)$$, :'code'),
  'valid code claims the profile');

set local role postgres;
select is((select auth_user_id from public.profiles
           where id = 'ddddddd1-0000-0000-0000-000000000001'),
          :'nc_uid'::uuid, 'claim_profile bound auth_user_id');
select is((select claimed_at is not null from public.claim_codes where code = :'code'),
          true, 'claim_profile stamped claimed_at');

select * from finish();
rollback;
```

- [ ] **Step 4: Enable pgTAP and run the tests**

Add to `supabase/migrations/20260810120100_rls.sql` at the very top:

```sql
create extension if not exists pgtap with schema extensions;
```

Then:

```bash
supabase db reset && supabase test db
```

Expected: all tests pass; final line reports no failures. If `tests.create_auth_user` errors on a missing column, add the missing `auth.users` column to the insert with a sensible default — local Supabase auth schemas drift between CLI versions.

- [ ] **Step 5: Commit**

Use the `commit-commands:commit` skill.

---

## Phase 2 — ChoresCore package

### Task 5: Package scaffolding, `CalendarDay`, `WeekCalendar`

**Files:**
- Create: `Package.swift`
- Create: `Sources/ChoresCore/Calendar/CalendarDay.swift`
- Create: `Sources/ChoresCore/Calendar/WeekCalendar.swift`
- Test: `Tests/ChoresCoreTests/CalendarDayTests.swift`, `Tests/ChoresCoreTests/WeekCalendarTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct CalendarDay: Hashable, Codable, Comparable, Sendable` with `init(year:month:day:)`, `init(_ date: Date, in timeZone: TimeZone)`, `var isoWeekday: Int`, `func adding(days: Int) -> CalendarDay`, `func date(in timeZone: TimeZone) -> Date`. Codable representation is the string `"YYYY-MM-DD"`.
  - `enum WeekCalendar` with `static func isoWeek(containing day: CalendarDay) -> [CalendarDay]` returning exactly 7 days, Monday first.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChoresCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ChoresCore", targets: ["ChoresCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "ChoresCore",
            dependencies: [.product(name: "Supabase", package: "supabase-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChoresCoreTests",
            dependencies: ["ChoresCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
```

- [ ] **Step 2: Write the failing `CalendarDay` tests**

Create `Tests/ChoresCoreTests/CalendarDayTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

private let helsinki = TimeZone(identifier: "Europe/Helsinki")!
private let utc = TimeZone(identifier: "UTC")!

@Suite struct CalendarDayTests {

    @Test func isoWeekdayMapsMondayToOne() {
        // 2026-08-10 is a Monday.
        #expect(CalendarDay(year: 2026, month: 8, day: 10).isoWeekday == 1)
        #expect(CalendarDay(year: 2026, month: 8, day: 11).isoWeekday == 2)
        #expect(CalendarDay(year: 2026, month: 8, day: 12).isoWeekday == 3)
        #expect(CalendarDay(year: 2026, month: 8, day: 13).isoWeekday == 4)
        #expect(CalendarDay(year: 2026, month: 8, day: 14).isoWeekday == 5)
        #expect(CalendarDay(year: 2026, month: 8, day: 15).isoWeekday == 6)
        #expect(CalendarDay(year: 2026, month: 8, day: 16).isoWeekday == 7)
    }

    @Test func localDayDiffersFromUTCDayLateInTheEvening() {
        // 2026-08-10T21:10Z is 2026-08-11T00:10 in Helsinki (+03:00).
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 10
        components.hour = 21; components.minute = 10
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = utc
        let instant = utcCalendar.date(from: components)!

        #expect(CalendarDay(instant, in: helsinki) == CalendarDay(year: 2026, month: 8, day: 11))
        #expect(CalendarDay(instant, in: utc) == CalendarDay(year: 2026, month: 8, day: 10))
    }

    @Test func addingDaysCrossesMonthAndYearBoundaries() {
        #expect(CalendarDay(year: 2026, month: 8, day: 31).adding(days: 1)
                == CalendarDay(year: 2026, month: 9, day: 1))
        #expect(CalendarDay(year: 2026, month: 1, day: 1).adding(days: -1)
                == CalendarDay(year: 2025, month: 12, day: 31))
    }

    @Test func addingDaysIsUnaffectedByDSTTransitions() {
        // EU DST ends on the last Sunday of October; 2026-10-25 in Helsinki has 25 hours.
        #expect(CalendarDay(year: 2026, month: 10, day: 24).adding(days: 1)
                == CalendarDay(year: 2026, month: 10, day: 25))
        #expect(CalendarDay(year: 2026, month: 10, day: 25).adding(days: 1)
                == CalendarDay(year: 2026, month: 10, day: 26))
    }

    @Test func codableRoundTripsAsISOString() throws {
        let day = CalendarDay(year: 2026, month: 8, day: 9)
        let data = try JSONEncoder().encode(day)
        #expect(String(decoding: data, as: UTF8.self) == "\"2026-08-09\"")
        #expect(try JSONDecoder().decode(CalendarDay.self, from: data) == day)
    }

    @Test func comparableOrdersChronologically() {
        #expect(CalendarDay(year: 2026, month: 1, day: 2) < CalendarDay(year: 2026, month: 2, day: 1))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter CalendarDayTests`
Expected: compile failure — `cannot find 'CalendarDay' in scope`.

- [ ] **Step 4: Implement `CalendarDay`**

Create `Sources/ChoresCore/Calendar/CalendarDay.swift`:

```swift
import Foundation

/// A timezone-free calendar date. All day arithmetic in the app goes through this type
/// so that "today" is always a *local* day and never a UTC one.
public struct CalendarDay: Hashable, Sendable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local calendar day that `date` falls on in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Midnight at the start of this day, in `timeZone`.
    public func date(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        return calendar.date(from: c)!
    }

    /// ISO 8601 weekday: 1 = Monday … 7 = Sunday.
    /// This differs from `Calendar.component(.weekday:)`, which is 1 = Sunday.
    public var isoWeekday: Int {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let weekday = calendar.component(.weekday, from: date(in: utc))
        return weekday == 1 ? 7 : weekday - 1
    }

    /// Day arithmetic is performed in UTC so that DST transitions cannot shorten or
    /// lengthen a day and skew the result.
    public func adding(days: Int) -> CalendarDay {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let shifted = calendar.date(byAdding: .day, value: days, to: date(in: utc))!
        return CalendarDay(shifted, in: utc)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension CalendarDay: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Expected YYYY-MM-DD, got \(raw)"))
        }
        self.init(year: y, month: m, day: d)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(format: "%04d-%02d-%02d", year, month, day))
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter CalendarDayTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Write the failing `WeekCalendar` tests**

Create `Tests/ChoresCoreTests/WeekCalendarTests.swift`:

```swift
import Testing
@testable import ChoresCore

@Suite struct WeekCalendarTests {

    @Test func weekStartsOnMondayAndHasSevenDays() {
        // 2026-08-13 is a Thursday.
        let week = WeekCalendar.isoWeek(containing: CalendarDay(year: 2026, month: 8, day: 13))
        #expect(week.count == 7)
        #expect(week.first == CalendarDay(year: 2026, month: 8, day: 10))
        #expect(week.last == CalendarDay(year: 2026, month: 8, day: 16))
    }

    @Test func sundayBelongsToTheWeekThatStartedThePreviousMonday() {
        let week = WeekCalendar.isoWeek(containing: CalendarDay(year: 2026, month: 8, day: 16))
        #expect(week.first == CalendarDay(year: 2026, month: 8, day: 10))
    }

    @Test func mondayIsItsOwnWeekStart() {
        let week = WeekCalendar.isoWeek(containing: CalendarDay(year: 2026, month: 8, day: 10))
        #expect(week.first == CalendarDay(year: 2026, month: 8, day: 10))
    }

    @Test func weekSpanningAYearBoundaryIsContiguous() {
        // 2026-12-31 is a Thursday, so its week runs Mon 2026-12-28 … Sun 2027-01-03.
        let week = WeekCalendar.isoWeek(containing: CalendarDay(year: 2026, month: 12, day: 31))
        #expect(week.first == CalendarDay(year: 2026, month: 12, day: 28))
        #expect(week.last == CalendarDay(year: 2027, month: 1, day: 3))
    }
}
```

- [ ] **Step 7: Run to verify failure**

Run: `swift test --filter WeekCalendarTests`
Expected: compile failure — `cannot find 'WeekCalendar' in scope`.

- [ ] **Step 8: Implement `WeekCalendar`**

Create `Sources/ChoresCore/Calendar/WeekCalendar.swift`:

```swift
import Foundation

public enum WeekCalendar {
    /// The seven days of the ISO week containing `day`, Monday first.
    public static func isoWeek(containing day: CalendarDay) -> [CalendarDay] {
        let monday = day.adding(days: -(day.isoWeekday - 1))
        return (0..<7).map { monday.adding(days: $0) }
    }
}
```

- [ ] **Step 9: Run the full suite**

Run: `swift test`
Expected: PASS, 10 tests.

- [ ] **Step 10: Commit**

`.build/` and `Package.resolved` are already gitignored from the initial commit. Use the `commit-commands:commit` skill.

---

### Task 6: Domain models

**Files:**
- Create: `Sources/ChoresCore/Models/Family.swift`, `Profile.swift`, `Chore.swift`, `ScheduleEntry.swift`, `Completion.swift`
- Test: `Tests/ChoresCoreTests/ModelDecodingTests.swift`

**Interfaces:**
- Consumes: `CalendarDay`.
- Produces: `Family`, `Profile`, `Chore`, `ScheduleEntry`, `Completion` — all `Identifiable`, `Codable`, `Hashable`, `Sendable`, with explicit `CodingKeys` mapping snake_case columns. `Profile.Role` is `enum Role: String { case parent, child }`. `Family.timeZone` is a computed `TimeZone`. Also produces `enum ChoresJSON` exposing `decoder` and `encoder`, used by every repository.

- [ ] **Step 1: Write the failing decoding test**

Create `Tests/ChoresCoreTests/ModelDecodingTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

@Suite struct ModelDecodingTests {

    @Test func decodesFamilyAndResolvesTimeZone() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Koti",
         "timezone":"Europe/Helsinki","created_at":"2026-08-10T09:00:00Z"}
        """
        let family = try ChoresJSON.decoder.decode(Family.self, from: Data(json.utf8))
        #expect(family.name == "Koti")
        #expect(family.timeZone.identifier == "Europe/Helsinki")
    }

    @Test func decodesProfileWithNullAuthUser() throws {
        let json = """
        {"id":"22222222-2222-2222-2222-222222222222",
         "family_id":"11111111-1111-1111-1111-111111111111",
         "auth_user_id":null,"display_name":"Kid","role":"child",
         "color":"#FF8800","sort_order":2,"created_at":"2026-08-10T09:00:00Z"}
        """
        let profile = try ChoresJSON.decoder.decode(Profile.self, from: Data(json.utf8))
        #expect(profile.authUserID == nil)
        #expect(profile.role == .child)
        #expect(profile.sortOrder == 2)
    }

    @Test func decodesCompletionDueOnAsCalendarDay() throws {
        let json = """
        {"id":"33333333-3333-3333-3333-333333333333",
         "family_id":"11111111-1111-1111-1111-111111111111",
         "profile_id":"22222222-2222-2222-2222-222222222222",
         "chore_id":"44444444-4444-4444-4444-444444444444",
         "due_on":"2026-08-11","completed_at":"2026-08-11T15:00:00Z",
         "completed_by":"22222222-2222-2222-2222-222222222222"}
        """
        let completion = try ChoresJSON.decoder.decode(Completion.self, from: Data(json.utf8))
        #expect(completion.dueOn == CalendarDay(year: 2026, month: 8, day: 11))
    }

    @Test func encodesScheduleEntryWithSnakeCaseKeys() throws {
        let entry = ScheduleEntry(
            id: UUID(), familyID: UUID(), profileID: UUID(), choreID: UUID(), weekday: 3)
        let json = String(decoding: try ChoresJSON.encoder.encode(entry), as: UTF8.self)
        #expect(json.contains("\"profile_id\""))
        #expect(json.contains("\"chore_id\""))
        #expect(!json.contains("\"profileID\""))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ModelDecodingTests`
Expected: compile failure — `cannot find 'ChoresJSON' in scope`.

- [ ] **Step 3: Implement `ChoresJSON` and `Family`**

Create `Sources/ChoresCore/Models/Family.swift`:

```swift
import Foundation

/// Shared JSON coders. PostgREST emits ISO-8601 timestamps, sometimes with
/// fractional seconds and sometimes without, so both are accepted.
public enum ChoresJSON {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = iso8601WithFraction.date(from: raw) { return date }
            if let date = iso8601.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unparseable timestamp \(raw)"))
        }
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(iso8601WithFraction.string(from: date))
        }
        return e
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

public struct Family: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var timezone: String
    public let createdAt: Date

    public var timeZone: TimeZone { TimeZone(identifier: timezone) ?? .gmt }

    public init(id: UUID, name: String, timezone: String = "Europe/Helsinki",
                createdAt: Date = .init()) {
        self.id = id; self.name = name; self.timezone = timezone; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, timezone
        case createdAt = "created_at"
    }
}
```

- [ ] **Step 4: Implement `Profile`**

Create `Sources/ChoresCore/Models/Profile.swift`:

```swift
import Foundation

public struct Profile: Identifiable, Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case parent, child }

    public let id: UUID
    public let familyID: UUID
    public var authUserID: UUID?
    public var displayName: String
    public var role: Role
    public var color: String
    public var sortOrder: Int
    public let createdAt: Date

    public init(id: UUID, familyID: UUID, authUserID: UUID? = nil, displayName: String,
                role: Role, color: String = "#4C8BF5", sortOrder: Int = 0,
                createdAt: Date = .init()) {
        self.id = id; self.familyID = familyID; self.authUserID = authUserID
        self.displayName = displayName; self.role = role; self.color = color
        self.sortOrder = sortOrder; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, role, color
        case familyID = "family_id"
        case authUserID = "auth_user_id"
        case displayName = "display_name"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }
}
```

- [ ] **Step 5: Implement `Chore`, `ScheduleEntry`, `Completion`**

Create `Sources/ChoresCore/Models/Chore.swift`:

```swift
import Foundation

public struct Chore: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let familyID: UUID
    public var name: String
    public var icon: String?
    /// Reserved for a future rewards layer. Unused in v1.
    public var points: Int?
    public var isArchived: Bool
    public let createdAt: Date

    public init(id: UUID, familyID: UUID, name: String, icon: String? = nil,
                points: Int? = nil, isArchived: Bool = false, createdAt: Date = .init()) {
        self.id = id; self.familyID = familyID; self.name = name; self.icon = icon
        self.points = points; self.isArchived = isArchived; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, points
        case familyID = "family_id"
        case isArchived = "is_archived"
        case createdAt = "created_at"
    }
}
```

Create `Sources/ChoresCore/Models/ScheduleEntry.swift`:

```swift
import Foundation

public struct ScheduleEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let familyID: UUID
    public let profileID: UUID
    public let choreID: UUID
    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public let weekday: Int

    public init(id: UUID, familyID: UUID, profileID: UUID, choreID: UUID, weekday: Int) {
        self.id = id; self.familyID = familyID; self.profileID = profileID
        self.choreID = choreID; self.weekday = weekday
    }

    enum CodingKeys: String, CodingKey {
        case id, weekday
        case familyID = "family_id"
        case profileID = "profile_id"
        case choreID = "chore_id"
    }
}
```

Create `Sources/ChoresCore/Models/Completion.swift`:

```swift
import Foundation

public struct Completion: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let familyID: UUID
    public let profileID: UUID
    public let choreID: UUID
    public let dueOn: CalendarDay
    public let completedAt: Date
    public let completedBy: UUID

    public init(id: UUID, familyID: UUID, profileID: UUID, choreID: UUID,
                dueOn: CalendarDay, completedAt: Date = .init(), completedBy: UUID) {
        self.id = id; self.familyID = familyID; self.profileID = profileID
        self.choreID = choreID; self.dueOn = dueOn
        self.completedAt = completedAt; self.completedBy = completedBy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case familyID = "family_id"
        case profileID = "profile_id"
        case choreID = "chore_id"
        case dueOn = "due_on"
        case completedAt = "completed_at"
        case completedBy = "completed_by"
    }
}
```

- [ ] **Step 6: Run to verify the tests pass**

Run: `swift test --filter ModelDecodingTests`
Expected: PASS, 4 tests.

- [ ] **Step 7: Commit**

Use the `commit-commands:commit` skill.

---

### Task 7: `ScheduleResolver` and completion eligibility

This is the core of the application. Everything else is plumbing or pixels.

**Files:**
- Create: `Sources/ChoresCore/Schedule/ChoreForDay.swift`
- Create: `Sources/ChoresCore/Schedule/CompletionEligibility.swift`
- Create: `Sources/ChoresCore/Schedule/ScheduleResolver.swift`
- Test: `Tests/ChoresCoreTests/ScheduleResolverTests.swift`

**Interfaces:**
- Consumes: `CalendarDay`, `WeekCalendar`, `Chore`, `ScheduleEntry`, `Completion`.
- Produces:
  - `struct ChoreForDay: Identifiable, Hashable, Sendable` with `chore: Chore`, `profileID: UUID`, `dueOn: CalendarDay`, `completedAt: Date?`, `isCompleted: Bool`, `id: String`.
  - `enum CompletionEligibility: Equatable, Sendable { case allowed, future, outsideCurrentWeek }`.
  - `enum ScheduleResolver` with:
    - `static func chores(for profileID: UUID, on day: CalendarDay, template: [ScheduleEntry], chores: [Chore], completions: [Completion]) -> [ChoreForDay]`
    - `static func eligibility(for day: CalendarDay, today: CalendarDay) -> CompletionEligibility`
    - `static func progress(for profileID: UUID, on day: CalendarDay, template: [ScheduleEntry], chores: [Chore], completions: [Completion]) -> (done: Int, total: Int)`

- [ ] **Step 1: Write the failing resolver tests**

Create `Tests/ChoresCoreTests/ScheduleResolverTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

@Suite struct ScheduleResolverTests {

    // Fixed identifiers keep assertions readable.
    let family = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let kidA   = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let kidB   = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    let monday    = CalendarDay(year: 2026, month: 8, day: 10)
    let tuesday   = CalendarDay(year: 2026, month: 8, day: 11)
    let wednesday = CalendarDay(year: 2026, month: 8, day: 12)

    func chore(_ id: String, _ name: String, archived: Bool = false) -> Chore {
        Chore(id: UUID(uuidString: id)!, familyID: family, name: name, isArchived: archived)
    }

    func entry(_ profile: UUID, _ chore: Chore, _ weekday: Int) -> ScheduleEntry {
        ScheduleEntry(id: UUID(), familyID: family, profileID: profile,
                      choreID: chore.id, weekday: weekday)
    }

    var dishwasher: Chore { chore("44444444-0000-0000-0000-000000000001", "Dishwasher") }
    var vacuum:     Chore { chore("44444444-0000-0000-0000-000000000002", "Vacuum") }
    var bins:       Chore { chore("44444444-0000-0000-0000-000000000003", "Bins") }

    @Test func returnsOnlyChoresAssignedToThatChildOnThatWeekday() {
        let template = [
            entry(kidA, dishwasher, 1),   // Monday
            entry(kidA, vacuum, 1),       // Monday
            entry(kidB, bins, 1),         // Monday
            entry(kidA, bins, 2)          // Tuesday
        ]
        let result = ScheduleResolver.chores(
            for: kidA, on: monday, template: template,
            chores: [dishwasher, vacuum, bins], completions: [])

        #expect(result.map(\.chore.name).sorted() == ["Dishwasher", "Vacuum"])
        #expect(result.allSatisfy { $0.profileID == kidA })
        #expect(result.allSatisfy { $0.dueOn == monday })
    }

    @Test func swapsAssignmentsBetweenChildrenOnDifferentDays() {
        // The exact scenario from the spec: Monday A does X+Y and B does Z;
        // Tuesday A does Z and B does X+Y.
        let template = [
            entry(kidA, dishwasher, 1), entry(kidA, vacuum, 1), entry(kidB, bins, 1),
            entry(kidA, bins, 2), entry(kidB, dishwasher, 2), entry(kidB, vacuum, 2)
        ]
        let all = [dishwasher, vacuum, bins]

        #expect(ScheduleResolver.chores(for: kidA, on: tuesday, template: template,
                                        chores: all, completions: []).map(\.chore.name) == ["Bins"])
        #expect(ScheduleResolver.chores(for: kidB, on: tuesday, template: template,
                                        chores: all, completions: [])
                .map(\.chore.name).sorted() == ["Dishwasher", "Vacuum"])
    }

    @Test func marksChoresCompletedOnlyForTheMatchingDate() {
        let template = [entry(kidA, dishwasher, 1), entry(kidA, dishwasher, 3)]
        let completedMonday = Completion(
            id: UUID(), familyID: family, profileID: kidA, choreID: dishwasher.id,
            dueOn: monday, completedBy: kidA)

        let mondayResult = ScheduleResolver.chores(
            for: kidA, on: monday, template: template,
            chores: [dishwasher], completions: [completedMonday])
        let wednesdayResult = ScheduleResolver.chores(
            for: kidA, on: wednesday, template: template,
            chores: [dishwasher], completions: [completedMonday])

        #expect(mondayResult.first?.isCompleted == true)
        #expect(wednesdayResult.first?.isCompleted == false)
    }

    @Test func doesNotCreditACompletionBelongingToAnotherChild() {
        let template = [entry(kidA, dishwasher, 1), entry(kidB, dishwasher, 1)]
        let kidBCompletion = Completion(
            id: UUID(), familyID: family, profileID: kidB, choreID: dishwasher.id,
            dueOn: monday, completedBy: kidB)

        let result = ScheduleResolver.chores(
            for: kidA, on: monday, template: template,
            chores: [dishwasher], completions: [kidBCompletion])

        #expect(result.first?.isCompleted == false)
    }

    @Test func excludesArchivedChores() {
        let archived = chore("44444444-0000-0000-0000-000000000009", "Old job", archived: true)
        let template = [entry(kidA, dishwasher, 1), entry(kidA, archived, 1)]

        let result = ScheduleResolver.chores(
            for: kidA, on: monday, template: template,
            chores: [dishwasher, archived], completions: [])

        #expect(result.map(\.chore.name) == ["Dishwasher"])
    }

    @Test func ignoresTemplateEntriesReferencingAnUnknownChore() {
        let orphan = ScheduleEntry(id: UUID(), familyID: family, profileID: kidA,
                                   choreID: UUID(), weekday: 1)
        let result = ScheduleResolver.chores(
            for: kidA, on: monday, template: [orphan, entry(kidA, dishwasher, 1)],
            chores: [dishwasher], completions: [])

        #expect(result.count == 1)
    }

    @Test func sortsChoresByNameForStableDisplay() {
        let template = [entry(kidA, vacuum, 1), entry(kidA, bins, 1), entry(kidA, dishwasher, 1)]
        let result = ScheduleResolver.chores(
            for: kidA, on: monday, template: template,
            chores: [vacuum, bins, dishwasher], completions: [])

        #expect(result.map(\.chore.name) == ["Bins", "Dishwasher", "Vacuum"])
    }

    @Test func progressCountsDoneAgainstTotal() {
        let template = [entry(kidA, dishwasher, 1), entry(kidA, vacuum, 1), entry(kidA, bins, 1)]
        let done = Completion(id: UUID(), familyID: family, profileID: kidA,
                              choreID: vacuum.id, dueOn: monday, completedBy: kidA)

        let progress = ScheduleResolver.progress(
            for: kidA, on: monday, template: template,
            chores: [dishwasher, vacuum, bins], completions: [done])

        #expect(progress.done == 1)
        #expect(progress.total == 3)
    }

    // MARK: - Eligibility

    @Test func todayIsAlwaysCompletable() {
        #expect(ScheduleResolver.eligibility(for: wednesday, today: wednesday) == .allowed)
    }

    @Test func earlierDaysInTheCurrentWeekAreCompletable() {
        #expect(ScheduleResolver.eligibility(for: monday, today: wednesday) == .allowed)
        #expect(ScheduleResolver.eligibility(for: tuesday, today: wednesday) == .allowed)
    }

    @Test func futureDaysAreNeverCompletable() {
        #expect(ScheduleResolver.eligibility(for: wednesday, today: monday) == .future)
        // Even a future day inside the same week.
        #expect(ScheduleResolver.eligibility(
            for: CalendarDay(year: 2026, month: 8, day: 16), today: monday) == .future)
    }

    @Test func daysInAPreviousWeekAreNotCompletable() {
        // Sunday 2026-08-09 belongs to the previous ISO week.
        #expect(ScheduleResolver.eligibility(
            for: CalendarDay(year: 2026, month: 8, day: 9), today: wednesday) == .outsideCurrentWeek)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ScheduleResolverTests`
Expected: compile failure — `cannot find 'ScheduleResolver' in scope`.

- [ ] **Step 3: Implement `ChoreForDay` and `CompletionEligibility`**

Create `Sources/ChoresCore/Schedule/ChoreForDay.swift`:

```swift
import Foundation

/// A chore resolved against a specific child and date, carrying its completion state.
public struct ChoreForDay: Identifiable, Hashable, Sendable {
    public let chore: Chore
    public let profileID: UUID
    public let dueOn: CalendarDay
    public let completedAt: Date?

    public var isCompleted: Bool { completedAt != nil }

    /// Stable across refetches: the same tuple always yields the same id.
    public var id: String { "\(profileID)|\(chore.id)|\(dueOn.year)-\(dueOn.month)-\(dueOn.day)" }

    public init(chore: Chore, profileID: UUID, dueOn: CalendarDay, completedAt: Date?) {
        self.chore = chore
        self.profileID = profileID
        self.dueOn = dueOn
        self.completedAt = completedAt
    }
}
```

Create `Sources/ChoresCore/Schedule/CompletionEligibility.swift`:

```swift
/// Whether a chore on a given day may be ticked off.
public enum CompletionEligibility: Equatable, Sendable {
    case allowed
    /// The day has not happened yet.
    case future
    /// The day is real but falls outside the current ISO week.
    case outsideCurrentWeek
}
```

- [ ] **Step 4: Implement `ScheduleResolver`**

Create `Sources/ChoresCore/Schedule/ScheduleResolver.swift`:

```swift
import Foundation

/// The single source of truth for "what is due, for whom, on which day".
///
/// Deliberately a pure function over already-fetched data: no network, no storage,
/// no SwiftUI. When per-date overrides are added later, they are applied here and
/// nothing else in the app needs to change.
public enum ScheduleResolver {

    public static func chores(
        for profileID: UUID,
        on day: CalendarDay,
        template: [ScheduleEntry],
        chores: [Chore],
        completions: [Completion]
    ) -> [ChoreForDay] {
        let choresByID = Dictionary(uniqueKeysWithValues: chores.map { ($0.id, $0) })

        // Completion lookup keyed exactly as the database unique constraint is.
        var completionByKey: [CompletionKey: Completion] = [:]
        for completion in completions {
            completionByKey[CompletionKey(completion)] = completion
        }

        return template
            .filter { $0.profileID == profileID && $0.weekday == day.isoWeekday }
            .compactMap { entry -> ChoreForDay? in
                guard let chore = choresByID[entry.choreID], !chore.isArchived else { return nil }
                let key = CompletionKey(profileID: profileID, choreID: chore.id, dueOn: day)
                return ChoreForDay(chore: chore,
                                   profileID: profileID,
                                   dueOn: day,
                                   completedAt: completionByKey[key]?.completedAt)
            }
            .sorted { $0.chore.name.localizedStandardCompare($1.chore.name) == .orderedAscending }
    }

    public static func progress(
        for profileID: UUID,
        on day: CalendarDay,
        template: [ScheduleEntry],
        chores: [Chore],
        completions: [Completion]
    ) -> (done: Int, total: Int) {
        let resolved = self.chores(for: profileID, on: day, template: template,
                                   chores: chores, completions: completions)
        return (resolved.filter(\.isCompleted).count, resolved.count)
    }

    /// Children may tick off today and any earlier day in the current ISO week,
    /// but never a future day and never a previous week.
    public static func eligibility(for day: CalendarDay, today: CalendarDay) -> CompletionEligibility {
        if day > today { return .future }
        let week = WeekCalendar.isoWeek(containing: today)
        guard let monday = week.first, day >= monday else { return .outsideCurrentWeek }
        return .allowed
    }

    private struct CompletionKey: Hashable {
        let profileID: UUID
        let choreID: UUID
        let dueOn: CalendarDay

        init(profileID: UUID, choreID: UUID, dueOn: CalendarDay) {
            self.profileID = profileID; self.choreID = choreID; self.dueOn = dueOn
        }

        init(_ completion: Completion) {
            self.init(profileID: completion.profileID,
                      choreID: completion.choreID,
                      dueOn: completion.dueOn)
        }
    }
}
```

- [ ] **Step 5: Run to verify the tests pass**

Run: `swift test --filter ScheduleResolverTests`
Expected: PASS, 12 tests.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 26 tests.

- [ ] **Step 7: Commit**

Use the `commit-commands:commit` skill.

---

### Task 8: Repository protocols, `FamilySnapshot`, and in-memory fakes

**Files:**
- Create: `Sources/ChoresCore/Sync/FamilySnapshot.swift`
- Create: `Sources/ChoresCore/Repositories/Repositories.swift`
- Create: `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift`
- Test: `Tests/ChoresCoreTests/InMemoryBackendTests.swift`

**Interfaces:**
- Consumes: all models.
- Produces:
  - `struct FamilySnapshot: Codable, Equatable, Sendable` with `family`, `profiles`, `chores`, `template`, `completions`, `fetchedAt`.
  - `protocol ChoresBackend: Sendable` — the single repository protocol every view model depends on. Methods listed in Step 2.
  - `enum ChoresBackendError: Error, Equatable` with cases `unknownClaimCode`, `claimCodeAlreadyUsed`, `claimCodeExpired`, `notAuthenticated`, `alreadyClaimed`, `projectUnavailable`, `underlying(String)`.
  - `actor InMemoryChoresBackend: ChoresBackend` — a fake used by every view-model test and SwiftUI preview.

One protocol rather than five: the app always needs the whole family graph at once, and splitting it would only create five fakes to keep in sync.

- [ ] **Step 1: Write `FamilySnapshot`**

Create `Sources/ChoresCore/Sync/FamilySnapshot.swift`:

```swift
import Foundation

/// Everything the app needs to render any screen, fetched in one pass.
/// The whole family's data is on the order of a hundred rows, so paging is pointless.
public struct FamilySnapshot: Codable, Equatable, Sendable {
    public var family: Family
    public var profiles: [Profile]
    public var chores: [Chore]
    public var template: [ScheduleEntry]
    public var completions: [Completion]
    public var fetchedAt: Date

    public init(family: Family, profiles: [Profile], chores: [Chore],
                template: [ScheduleEntry], completions: [Completion], fetchedAt: Date) {
        self.family = family; self.profiles = profiles; self.chores = chores
        self.template = template; self.completions = completions; self.fetchedAt = fetchedAt
    }

    public var children: [Profile] {
        profiles.filter { $0.role == .child }.sorted { $0.sortOrder < $1.sortOrder }
    }

    public var activeChores: [Chore] {
        chores.filter { !$0.isArchived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
```

- [ ] **Step 2: Write the protocol**

Create `Sources/ChoresCore/Repositories/Repositories.swift`:

```swift
import Foundation

public enum ChoresBackendError: Error, Equatable, Sendable {
    case notAuthenticated
    case alreadyClaimed
    case unknownClaimCode
    case claimCodeAlreadyUsed
    case claimCodeExpired
    /// The Supabase project is paused or unreachable. Surfaced as its own screen,
    /// because the remedy is un-pausing in the dashboard rather than retrying.
    case projectUnavailable
    case underlying(String)
}

/// The app's entire data boundary. View models depend on this, never on Supabase types.
public protocol ChoresBackend: Sendable {

    // Session
    func signInAnonymouslyIfNeeded() async throws
    /// The profile bound to the current session, or nil if this device is unclaimed.
    func currentProfile() async throws -> Profile?

    // Bootstrap
    func createFamily(familyName: String, parentName: String, timezone: String) async throws -> UUID
    func claimProfile(code: String) async throws -> UUID

    // Reads
    func fetchSnapshot(familyID: UUID, weekOf day: CalendarDay) async throws -> FamilySnapshot

    // Children
    func addChild(familyID: UUID, name: String, color: String, sortOrder: Int) async throws -> Profile
    func updateProfile(_ profile: Profile) async throws
    func generateClaimCode(profileID: UUID) async throws -> String

    // Chores
    func addChore(familyID: UUID, name: String, icon: String?) async throws -> Chore
    func updateChore(_ chore: Chore) async throws

    // Schedule
    func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID, weekday: Int) async throws -> ScheduleEntry
    func removeScheduleEntry(id: UUID) async throws
    /// Replaces the assignments on each day in `toWeekdays` with those from `fromWeekday`.
    func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int]) async throws

    // Completions
    func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                  dueOn: CalendarDay, completedBy: UUID) async throws
    func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws
}
```

- [ ] **Step 3: Write the failing fake-backend test**

Create `Tests/ChoresCoreTests/InMemoryBackendTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

@Suite struct InMemoryBackendTests {

    @Test func createFamilyProducesAParentProfile() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        _ = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")

        let profile = try await backend.currentProfile()
        #expect(profile?.role == .parent)
        #expect(profile?.displayName == "Parent")
    }

    @Test func claimingAValidCodeBindsTheProfile() async throws {
        let parentBackend = InMemoryChoresBackend()
        try await parentBackend.signInAnonymouslyIfNeeded()
        let familyID = try await parentBackend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await parentBackend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let code = try await parentBackend.generateClaimCode(profileID: child.id)

        let kidBackend = parentBackend.newDevice()
        try await kidBackend.signInAnonymouslyIfNeeded()
        _ = try await kidBackend.claimProfile(code: code)

        let claimed = try await kidBackend.currentProfile()
        #expect(claimed?.id == child.id)
        #expect(claimed?.role == .child)
    }

    @Test func reusingAClaimCodeFails() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let code = try await backend.generateClaimCode(profileID: child.id)

        let first = backend.newDevice()
        try await first.signInAnonymouslyIfNeeded()
        _ = try await first.claimProfile(code: code)

        let second = backend.newDevice()
        try await second.signInAnonymouslyIfNeeded()
        await #expect(throws: ChoresBackendError.claimCodeAlreadyUsed) {
            _ = try await second.claimProfile(code: code)
        }
    }

    @Test func unknownClaimCodeFails() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        await #expect(throws: ChoresBackendError.unknownClaimCode) {
            _ = try await backend.claimProfile(code: "ZZZZZZ")
        }
    }

    @Test func completingTwiceIsIdempotent() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let chore = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)
        let day = CalendarDay(year: 2026, month: 8, day: 10)

        try await backend.complete(familyID: familyID, profileID: child.id,
                                   choreID: chore.id, dueOn: day, completedBy: child.id)
        try await backend.complete(familyID: familyID, profileID: child.id,
                                   choreID: chore.id, dueOn: day, completedBy: child.id)

        let snapshot = try await backend.fetchSnapshot(familyID: familyID, weekOf: day)
        #expect(snapshot.completions.count == 1)
    }

    @Test func copyDayReplacesTargetDayAssignments() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let dishes = try await backend.addChore(familyID: familyID, name: "Dishes", icon: nil)
        let bins = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)

        _ = try await backend.addScheduleEntry(familyID: familyID, profileID: child.id,
                                               choreID: dishes.id, weekday: 1)
        _ = try await backend.addScheduleEntry(familyID: familyID, profileID: child.id,
                                               choreID: bins.id, weekday: 2)

        try await backend.copyDay(familyID: familyID, from: 1, to: [2, 3])

        let snapshot = try await backend.fetchSnapshot(
            familyID: familyID, weekOf: CalendarDay(year: 2026, month: 8, day: 10))
        let tuesday = snapshot.template.filter { $0.weekday == 2 }
        let wednesday = snapshot.template.filter { $0.weekday == 3 }

        #expect(tuesday.count == 1)
        #expect(tuesday.first?.choreID == dishes.id)   // Bins was replaced, not merged
        #expect(wednesday.count == 1)
    }

    @Test func snapshotContainsOnlyTheRequestedWeeksCompletions() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let chore = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)

        let thisWeek = CalendarDay(year: 2026, month: 8, day: 12)
        let lastWeek = CalendarDay(year: 2026, month: 8, day: 5)
        try await backend.complete(familyID: familyID, profileID: child.id,
                                   choreID: chore.id, dueOn: thisWeek, completedBy: child.id)
        try await backend.complete(familyID: familyID, profileID: child.id,
                                   choreID: chore.id, dueOn: lastWeek, completedBy: child.id)

        let snapshot = try await backend.fetchSnapshot(familyID: familyID, weekOf: thisWeek)
        #expect(snapshot.completions.count == 1)
        #expect(snapshot.completions.first?.dueOn == thisWeek)
    }
}
```

- [ ] **Step 4: Run to verify failure**

Run: `swift test --filter InMemoryBackendTests`
Expected: compile failure — `cannot find 'InMemoryChoresBackend' in scope`.

- [ ] **Step 5: Implement the in-memory backend**

Create `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift`:

```swift
import Foundation

/// A complete, in-process implementation of `ChoresBackend`.
/// Used by view-model tests and SwiftUI previews. Shared state is held in a reference
/// box so that `newDevice()` can simulate a second device against the same "server".
public final class InMemoryChoresBackend: ChoresBackend, @unchecked Sendable {

    final class Store {
        var families: [UUID: Family] = [:]
        var profiles: [UUID: Profile] = [:]
        var claimCodes: [String: ClaimCodeRecord] = [:]
        var chores: [UUID: Chore] = [:]
        var template: [UUID: ScheduleEntry] = [:]
        var completions: [Completion] = []
        var nextCodeSuffix = 0
        let lock = NSLock()
    }

    struct ClaimCodeRecord {
        let profileID: UUID
        let familyID: UUID
        var claimed: Bool
        var expiresAt: Date
    }

    private let store: Store
    private var sessionUserID: UUID?

    public init() { self.store = Store() }
    private init(sharing store: Store) { self.store = store }

    /// A second client against the same shared state.
    public func newDevice() -> InMemoryChoresBackend { InMemoryChoresBackend(sharing: store) }

    private func withStore<T>(_ body: (Store) throws -> T) rethrows -> T {
        store.lock.lock()
        defer { store.lock.unlock() }
        return try body(store)
    }

    // MARK: Session

    public func signInAnonymouslyIfNeeded() async throws {
        if sessionUserID == nil { sessionUserID = UUID() }
    }

    public func currentProfile() async throws -> Profile? {
        guard let uid = sessionUserID else { return nil }
        return withStore { $0.profiles.values.first { $0.authUserID == uid } }
    }

    // MARK: Bootstrap

    public func createFamily(familyName: String, parentName: String,
                             timezone: String) async throws -> UUID {
        guard let uid = sessionUserID else { throw ChoresBackendError.notAuthenticated }
        if try await currentProfile() != nil { throw ChoresBackendError.alreadyClaimed }

        let family = Family(id: UUID(), name: familyName, timezone: timezone)
        let parent = Profile(id: UUID(), familyID: family.id, authUserID: uid,
                             displayName: parentName, role: .parent)
        withStore {
            $0.families[family.id] = family
            $0.profiles[parent.id] = parent
        }
        return family.id
    }

    public func claimProfile(code: String) async throws -> UUID {
        guard sessionUserID != nil else { throw ChoresBackendError.notAuthenticated }
        if try await currentProfile() != nil { throw ChoresBackendError.alreadyClaimed }
        let normalised = code.trimmingCharacters(in: .whitespaces).uppercased()

        return try withStore { store in
            guard let record = store.claimCodes[normalised] else {
                throw ChoresBackendError.unknownClaimCode
            }
            if record.claimed { throw ChoresBackendError.claimCodeAlreadyUsed }
            if record.expiresAt < Date() { throw ChoresBackendError.claimCodeExpired }

            store.profiles[record.profileID]?.authUserID = self.sessionUserID
            store.claimCodes[normalised]?.claimed = true
            return record.profileID
        }
    }

    // MARK: Reads

    public func fetchSnapshot(familyID: UUID, weekOf day: CalendarDay) async throws -> FamilySnapshot {
        let week = WeekCalendar.isoWeek(containing: day)
        return try withStore { store in
            guard let family = store.families[familyID] else {
                throw ChoresBackendError.underlying("no such family")
            }
            return FamilySnapshot(
                family: family,
                profiles: store.profiles.values.filter { $0.familyID == familyID },
                chores: store.chores.values.filter { $0.familyID == familyID },
                template: store.template.values.filter { $0.familyID == familyID },
                completions: store.completions.filter {
                    $0.familyID == familyID && week.contains($0.dueOn)
                },
                fetchedAt: Date())
        }
    }

    // MARK: Children

    public func addChild(familyID: UUID, name: String, color: String,
                         sortOrder: Int) async throws -> Profile {
        let profile = Profile(id: UUID(), familyID: familyID, displayName: name,
                              role: .child, color: color, sortOrder: sortOrder)
        withStore { $0.profiles[profile.id] = profile }
        return profile
    }

    public func updateProfile(_ profile: Profile) async throws {
        withStore { $0.profiles[profile.id] = profile }
    }

    public func generateClaimCode(profileID: UUID) async throws -> String {
        try withStore { store in
            guard let profile = store.profiles[profileID] else {
                throw ChoresBackendError.underlying("no such profile")
            }
            store.claimCodes = store.claimCodes.filter {
                !($0.value.profileID == profileID && !$0.value.claimed)
            }
            store.nextCodeSuffix += 1
            let code = String(format: "TEST%02d", store.nextCodeSuffix)
            store.claimCodes[code] = ClaimCodeRecord(
                profileID: profileID, familyID: profile.familyID,
                claimed: false, expiresAt: Date().addingTimeInterval(7 * 24 * 3600))
            return code
        }
    }

    // MARK: Chores

    public func addChore(familyID: UUID, name: String, icon: String?) async throws -> Chore {
        let chore = Chore(id: UUID(), familyID: familyID, name: name, icon: icon)
        withStore { $0.chores[chore.id] = chore }
        return chore
    }

    public func updateChore(_ chore: Chore) async throws {
        withStore { $0.chores[chore.id] = chore }
    }

    // MARK: Schedule

    public func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                                 weekday: Int) async throws -> ScheduleEntry {
        try withStore { store in
            let duplicate = store.template.values.first {
                $0.profileID == profileID && $0.choreID == choreID && $0.weekday == weekday
            }
            if let duplicate { return duplicate }
            let entry = ScheduleEntry(id: UUID(), familyID: familyID, profileID: profileID,
                                      choreID: choreID, weekday: weekday)
            store.template[entry.id] = entry
            return entry
        }
    }

    public func removeScheduleEntry(id: UUID) async throws {
        withStore { $0.template[id] = nil }
    }

    public func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int]) async throws {
        withStore { store in
            let source = store.template.values.filter {
                $0.familyID == familyID && $0.weekday == fromWeekday
            }
            for target in toWeekdays where target != fromWeekday {
                for existing in store.template.values
                where existing.familyID == familyID && existing.weekday == target {
                    store.template[existing.id] = nil
                }
                for entry in source {
                    let copy = ScheduleEntry(id: UUID(), familyID: familyID,
                                             profileID: entry.profileID,
                                             choreID: entry.choreID, weekday: target)
                    store.template[copy.id] = copy
                }
            }
        }
    }

    // MARK: Completions

    public func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                         dueOn: CalendarDay, completedBy: UUID) async throws {
        withStore { store in
            let exists = store.completions.contains {
                $0.profileID == profileID && $0.choreID == choreID && $0.dueOn == dueOn
            }
            guard !exists else { return }   // mirrors the DB unique constraint
            store.completions.append(Completion(
                id: UUID(), familyID: familyID, profileID: profileID, choreID: choreID,
                dueOn: dueOn, completedBy: completedBy))
        }
    }

    public func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws {
        withStore { store in
            store.completions.removeAll {
                $0.profileID == profileID && $0.choreID == choreID && $0.dueOn == dueOn
            }
        }
    }
}
```

- [ ] **Step 6: Run to verify the tests pass**

Run: `swift test --filter InMemoryBackendTests`
Expected: PASS, 7 tests.

- [ ] **Step 7: Commit**

Use the `commit-commands:commit` skill.

---

### Task 9: Supabase-backed `ChoresBackend`

**Files:**
- Create: `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift`
- Create: `Sources/ChoresCore/Repositories/Supabase/SupabaseErrorMapping.swift`
- Test: `Tests/ChoresCoreTests/SupabaseErrorMappingTests.swift`

**Interfaces:**
- Consumes: `ChoresBackend`, all models, `ChoresJSON`.
- Produces: `final class SupabaseChoresBackend: ChoresBackend` with `init(url: URL, anonKey: String)`; `enum SupabaseErrorMapping` with `static func map(_ error: Error) -> ChoresBackendError`.

This class is not unit tested against a live server — it is exercised manually against the local stack in Step 6. Only the error mapping, which carries real logic, gets tests.

- [ ] **Step 1: Write the failing error-mapping test**

Create `Tests/ChoresCoreTests/SupabaseErrorMappingTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

@Suite struct SupabaseErrorMappingTests {

    /// Mirrors the shape of a PostgREST error surfaced by supabase-swift.
    struct FakePostgrestError: Error { let code: String?; let message: String }

    @Test func mapsClaimCodeErrorCodes() {
        #expect(SupabaseErrorMapping.map(FakePostgrestError(code: "P0001", message: "unknown code"))
                == .unknownClaimCode)
        #expect(SupabaseErrorMapping.map(FakePostgrestError(code: "P0002", message: "code already used"))
                == .claimCodeAlreadyUsed)
        #expect(SupabaseErrorMapping.map(FakePostgrestError(code: "P0003", message: "code expired"))
                == .claimCodeExpired)
    }

    @Test func mapsOfflineAndPausedProjectToProjectUnavailable() {
        let notConnected = URLError(.notConnectedToInternet)
        let cannotFindHost = URLError(.cannotFindHost)
        let timedOut = URLError(.timedOut)
        #expect(SupabaseErrorMapping.map(notConnected) == .projectUnavailable)
        #expect(SupabaseErrorMapping.map(cannotFindHost) == .projectUnavailable)
        #expect(SupabaseErrorMapping.map(timedOut) == .projectUnavailable)
    }

    @Test func mapsUnrecognisedErrorsToUnderlying() {
        let result = SupabaseErrorMapping.map(
            FakePostgrestError(code: "23505", message: "duplicate key"))
        #expect(result == .underlying("duplicate key"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SupabaseErrorMappingTests`
Expected: compile failure — `cannot find 'SupabaseErrorMapping' in scope`.

- [ ] **Step 3: Implement the error mapping**

Create `Sources/ChoresCore/Repositories/Supabase/SupabaseErrorMapping.swift`:

```swift
import Foundation

public enum SupabaseErrorMapping {

    /// Translates transport and PostgREST failures into the app's error vocabulary.
    /// The claim-code cases rely on the custom SQLSTATE codes raised by `claim_profile()`.
    public static func map(_ error: Error) -> ChoresBackendError {
        if let backendError = error as? ChoresBackendError { return backendError }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .timedOut, .dnsLookupFailed:
                return .projectUnavailable
            default:
                return .underlying(urlError.localizedDescription)
            }
        }

        // supabase-swift surfaces PostgREST failures as a struct carrying `code` and
        // `message`. Read them reflectively so ChoresCore does not depend on the
        // concrete error type, which has changed between SDK releases.
        let mirror = Mirror(reflecting: error)
        var code: String?
        var message: String?
        for child in mirror.children {
            if child.label == "code" { code = unwrapString(child.value) }
            if child.label == "message" { message = unwrapString(child.value) }
        }

        switch code {
        case "P0001": return .unknownClaimCode
        case "P0002": return .claimCodeAlreadyUsed
        case "P0003": return .claimCodeExpired
        default:      return .underlying(message ?? error.localizedDescription)
        }
    }

    private static func unwrapString(_ value: Any) -> String? {
        if let string = value as? String { return string }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional, let first = mirror.children.first {
            return first.value as? String
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify the tests pass**

Run: `swift test --filter SupabaseErrorMappingTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Implement the live backend**

Create `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift`:

```swift
import Foundation
import Supabase

public final class SupabaseChoresBackend: ChoresBackend, @unchecked Sendable {

    private let client: SupabaseClient

    public init(url: URL, anonKey: String) {
        self.client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: .init(db: .init(encoder: ChoresJSON.encoder, decoder: ChoresJSON.decoder)))
    }

    private func run<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch { throw SupabaseErrorMapping.map(error) }
    }

    // MARK: Session

    public func signInAnonymouslyIfNeeded() async throws {
        try await run {
            if client.auth.currentSession == nil {
                _ = try await client.auth.signInAnonymously()
            }
        }
    }

    public func currentProfile() async throws -> Profile? {
        try await run {
            guard let userID = client.auth.currentSession?.user.id else { return nil }
            let rows: [Profile] = try await client
                .from("profiles").select().eq("auth_user_id", value: userID)
                .limit(1).execute().value
            return rows.first
        }
    }

    // MARK: Bootstrap

    public func createFamily(familyName: String, parentName: String,
                             timezone: String) async throws -> UUID {
        try await run {
            try await client.rpc("create_family", params: [
                "family_name": familyName,
                "parent_name": parentName,
                "family_timezone": timezone
            ]).execute().value
        }
    }

    public func claimProfile(code: String) async throws -> UUID {
        try await run {
            try await client.rpc("claim_profile", params: ["p_code": code])
                .execute().value
        }
    }

    // MARK: Reads

    public func fetchSnapshot(familyID: UUID, weekOf day: CalendarDay) async throws -> FamilySnapshot {
        try await run {
            let week = WeekCalendar.isoWeek(containing: day)
            let first = ChoresJSON.encodedDay(week.first!)
            let last  = ChoresJSON.encodedDay(week.last!)

            async let family: [Family] = client.from("families")
                .select().eq("id", value: familyID).execute().value
            async let profiles: [Profile] = client.from("profiles")
                .select().eq("family_id", value: familyID).execute().value
            async let chores: [Chore] = client.from("chores")
                .select().eq("family_id", value: familyID).execute().value
            async let template: [ScheduleEntry] = client.from("schedule_entries")
                .select().eq("family_id", value: familyID).execute().value
            async let completions: [Completion] = client.from("completions")
                .select().eq("family_id", value: familyID)
                .gte("due_on", value: first).lte("due_on", value: last)
                .execute().value

            guard let theFamily = try await family.first else {
                throw ChoresBackendError.underlying("family not found")
            }
            return FamilySnapshot(
                family: theFamily,
                profiles: try await profiles,
                chores: try await chores,
                template: try await template,
                completions: try await completions,
                fetchedAt: Date())
        }
    }

    // MARK: Children

    public func addChild(familyID: UUID, name: String, color: String,
                         sortOrder: Int) async throws -> Profile {
        try await run {
            let payload = NewProfile(familyID: familyID, displayName: name,
                                     role: "child", color: color, sortOrder: sortOrder)
            let rows: [Profile] = try await client.from("profiles")
                .insert(payload).select().execute().value
            guard let created = rows.first else {
                throw ChoresBackendError.underlying("insert returned no row")
            }
            return created
        }
    }

    public func updateProfile(_ profile: Profile) async throws {
        try await run {
            let payload = ProfileUpdate(displayName: profile.displayName,
                                        color: profile.color, sortOrder: profile.sortOrder)
            _ = try await client.from("profiles")
                .update(payload).eq("id", value: profile.id).execute()
        }
    }

    public func generateClaimCode(profileID: UUID) async throws -> String {
        try await run {
            try await client.rpc("generate_claim_code", params: ["p_profile_id": profileID])
                .execute().value
        }
    }

    // MARK: Chores

    public func addChore(familyID: UUID, name: String, icon: String?) async throws -> Chore {
        try await run {
            let payload = NewChore(familyID: familyID, name: name, icon: icon)
            let rows: [Chore] = try await client.from("chores")
                .insert(payload).select().execute().value
            guard let created = rows.first else {
                throw ChoresBackendError.underlying("insert returned no row")
            }
            return created
        }
    }

    public func updateChore(_ chore: Chore) async throws {
        try await run {
            let payload = ChoreUpdate(name: chore.name, icon: chore.icon,
                                      isArchived: chore.isArchived)
            _ = try await client.from("chores")
                .update(payload).eq("id", value: chore.id).execute()
        }
    }

    // MARK: Schedule

    public func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                                 weekday: Int) async throws -> ScheduleEntry {
        try await run {
            let payload = NewScheduleEntry(familyID: familyID, profileID: profileID,
                                           choreID: choreID, weekday: weekday)
            // The unique constraint makes a repeat add a no-op rather than an error.
            let rows: [ScheduleEntry] = try await client.from("schedule_entries")
                .upsert(payload, onConflict: "profile_id,chore_id,weekday")
                .select().execute().value
            guard let created = rows.first else {
                throw ChoresBackendError.underlying("upsert returned no row")
            }
            return created
        }
    }

    public func removeScheduleEntry(id: UUID) async throws {
        try await run {
            _ = try await client.from("schedule_entries").delete().eq("id", value: id).execute()
        }
    }

    public func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int]) async throws {
        try await run {
            let source: [ScheduleEntry] = try await client.from("schedule_entries")
                .select().eq("family_id", value: familyID)
                .eq("weekday", value: fromWeekday).execute().value

            for target in toWeekdays where target != fromWeekday {
                _ = try await client.from("schedule_entries").delete()
                    .eq("family_id", value: familyID).eq("weekday", value: target).execute()

                let copies = source.map {
                    NewScheduleEntry(familyID: familyID, profileID: $0.profileID,
                                     choreID: $0.choreID, weekday: target)
                }
                if !copies.isEmpty {
                    _ = try await client.from("schedule_entries").insert(copies).execute()
                }
            }
        }
    }

    // MARK: Completions

    public func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                         dueOn: CalendarDay, completedBy: UUID) async throws {
        try await run {
            let payload = NewCompletion(familyID: familyID, profileID: profileID,
                                        choreID: choreID, dueOn: dueOn, completedBy: completedBy)
            // Idempotent by the (profile_id, chore_id, due_on) unique constraint,
            // which is what allows the outbox to replay blindly.
            _ = try await client.from("completions")
                .upsert(payload, onConflict: "profile_id,chore_id,due_on",
                        ignoreDuplicates: true)
                .execute()
        }
    }

    public func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws {
        try await run {
            _ = try await client.from("completions").delete()
                .eq("profile_id", value: profileID)
                .eq("chore_id", value: choreID)
                .eq("due_on", value: ChoresJSON.encodedDay(dueOn))
                .execute()
        }
    }
}

// MARK: - Insert/update payloads
// Separate from the models because inserts omit server-generated columns.

private struct NewProfile: Encodable {
    let familyID: UUID; let displayName: String; let role: String
    let color: String; let sortOrder: Int
    enum CodingKeys: String, CodingKey {
        case role, color
        case familyID = "family_id"
        case displayName = "display_name"
        case sortOrder = "sort_order"
    }
}

private struct ProfileUpdate: Encodable {
    let displayName: String; let color: String; let sortOrder: Int
    enum CodingKeys: String, CodingKey {
        case color
        case displayName = "display_name"
        case sortOrder = "sort_order"
    }
}

private struct NewChore: Encodable {
    let familyID: UUID; let name: String; let icon: String?
    enum CodingKeys: String, CodingKey { case name, icon; case familyID = "family_id" }
}

private struct ChoreUpdate: Encodable {
    let name: String; let icon: String?; let isArchived: Bool
    enum CodingKeys: String, CodingKey { case name, icon; case isArchived = "is_archived" }
}

private struct NewScheduleEntry: Encodable {
    let familyID: UUID; let profileID: UUID; let choreID: UUID; let weekday: Int
    enum CodingKeys: String, CodingKey {
        case weekday
        case familyID = "family_id"
        case profileID = "profile_id"
        case choreID = "chore_id"
    }
}

private struct NewCompletion: Encodable {
    let familyID: UUID; let profileID: UUID; let choreID: UUID
    let dueOn: CalendarDay; let completedBy: UUID
    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case profileID = "profile_id"
        case choreID = "chore_id"
        case dueOn = "due_on"
        case completedBy = "completed_by"
    }
}
```

- [ ] **Step 6: Add the `encodedDay` helper**

Append to `Sources/ChoresCore/Models/Family.swift`, inside `extension ChoresJSON`:

```swift
extension ChoresJSON {
    /// A `CalendarDay` rendered for a PostgREST filter value.
    public static func encodedDay(_ day: CalendarDay) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }
}
```

- [ ] **Step 7: Verify the package builds**

Run: `swift build && swift test`
Expected: build succeeds; all previous tests still pass.

- [ ] **Step 8: Enable anonymous sign-in on the local stack**

Add to `supabase/config.toml` under `[auth]`:

```toml
enable_anonymous_sign_ins = true
```

Then `supabase stop && supabase start`.

Note for the maintainer: the same setting must be enabled in the hosted project's dashboard under Authentication → Sign In / Providers → Anonymous sign-ins, or every device will fail at first launch.

- [ ] **Step 9: Commit**

Use the `commit-commands:commit` skill.

---

### Task 10: `SnapshotCache`

**Files:**
- Create: `Sources/ChoresCore/Sync/SnapshotCache.swift`
- Test: `Tests/ChoresCoreTests/SnapshotCacheTests.swift`

**Interfaces:**
- Consumes: `FamilySnapshot`, `ChoresJSON`.
- Produces: `actor SnapshotCache` with `init(directory: URL)`, `func load() async -> FamilySnapshot?`, `func save(_ snapshot: FamilySnapshot) async`, `func clear() async`, and `static func defaultDirectory() -> URL`.

- [ ] **Step 1: Write the failing test**

Create `Tests/ChoresCoreTests/SnapshotCacheTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

@Suite struct SnapshotCacheTests {

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeSnapshot(familyName: String = "Koti") -> FamilySnapshot {
        let familyID = UUID()
        return FamilySnapshot(
            family: Family(id: familyID, name: familyName),
            profiles: [Profile(id: UUID(), familyID: familyID, displayName: "Kid", role: .child)],
            chores: [Chore(id: UUID(), familyID: familyID, name: "Bins")],
            template: [],
            completions: [],
            fetchedAt: Date(timeIntervalSince1970: 1_786_000_000))
    }

    @Test func loadReturnsNilWhenNothingHasBeenSaved() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory())
        #expect(await cache.load() == nil)
    }

    @Test func savedSnapshotRoundTrips() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory())
        let snapshot = makeSnapshot()
        await cache.save(snapshot)

        let loaded = await cache.load()
        #expect(loaded?.family.name == "Koti")
        #expect(loaded?.chores.first?.name == "Bins")
        #expect(loaded?.fetchedAt == snapshot.fetchedAt)
    }

    @Test func savingOverwritesThePreviousSnapshot() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory())
        await cache.save(makeSnapshot(familyName: "First"))
        await cache.save(makeSnapshot(familyName: "Second"))
        #expect(await cache.load()?.family.name == "Second")
    }

    @Test func clearRemovesTheSnapshot() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory())
        await cache.save(makeSnapshot())
        await cache.clear()
        #expect(await cache.load() == nil)
    }

    @Test func corruptFileIsTreatedAsAbsentRatherThanCrashing() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = SnapshotCache(directory: directory)
        try Data("not json".utf8)
            .write(to: directory.appendingPathComponent("snapshot.json"))
        #expect(await cache.load() == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SnapshotCacheTests`
Expected: compile failure — `cannot find 'SnapshotCache' in scope`.

- [ ] **Step 3: Implement `SnapshotCache`**

Create `Sources/ChoresCore/Sync/SnapshotCache.swift`:

```swift
import Foundation

/// Persists the last successfully fetched snapshot so the app opens instantly
/// and remains readable with no connectivity.
public actor SnapshotCache {

    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("snapshot.json")
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("Chores", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public func load() -> FamilySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // A corrupt cache is never fatal — the app just refetches.
        return try? ChoresJSON.decoder.decode(FamilySnapshot.self, from: data)
    }

    public func save(_ snapshot: FamilySnapshot) {
        guard let data = try? ChoresJSON.encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
```

- [ ] **Step 4: Run to verify the tests pass**

Run: `swift test --filter SnapshotCacheTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

Use the `commit-commands:commit` skill.

---

### Task 11: `Outbox`

**Files:**
- Create: `Sources/ChoresCore/Sync/Outbox.swift`
- Test: `Tests/ChoresCoreTests/OutboxTests.swift`

**Interfaces:**
- Consumes: `ChoresBackend`, `CalendarDay`, `ChoresJSON`.
- Produces:
  - `enum OutboxOperation: Codable, Equatable, Sendable` with `case complete(familyID: UUID, profileID: UUID, choreID: UUID, dueOn: CalendarDay, completedBy: UUID)` and `case uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay)`.
  - `actor Outbox` with `init(directory: URL, backend: ChoresBackend)`, `func enqueue(_ operation: OutboxOperation) async`, `@discardableResult func flush() async -> Int` (returns the number of operations successfully sent), `var pendingCount: Int { get async }`.

The queue collapses opposing operations on the same key: enqueuing an `uncomplete` for a key with a pending `complete` removes both, since the server never saw either.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ChoresCoreTests/OutboxTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

/// A backend that fails on demand, so flush behaviour can be driven deterministically.
final class FlakyBackend: ChoresBackend, @unchecked Sendable {
    private let inner = InMemoryChoresBackend()
    var shouldFail = false
    private(set) var completeCallCount = 0
    private(set) var uncompleteCallCount = 0

    func signInAnonymouslyIfNeeded() async throws { try await inner.signInAnonymouslyIfNeeded() }
    func currentProfile() async throws -> Profile? { try await inner.currentProfile() }
    func createFamily(familyName: String, parentName: String, timezone: String) async throws -> UUID {
        try await inner.createFamily(familyName: familyName, parentName: parentName, timezone: timezone)
    }
    func claimProfile(code: String) async throws -> UUID { try await inner.claimProfile(code: code) }
    func fetchSnapshot(familyID: UUID, weekOf day: CalendarDay) async throws -> FamilySnapshot {
        try await inner.fetchSnapshot(familyID: familyID, weekOf: day)
    }
    func addChild(familyID: UUID, name: String, color: String, sortOrder: Int) async throws -> Profile {
        try await inner.addChild(familyID: familyID, name: name, color: color, sortOrder: sortOrder)
    }
    func updateProfile(_ profile: Profile) async throws { try await inner.updateProfile(profile) }
    func generateClaimCode(profileID: UUID) async throws -> String {
        try await inner.generateClaimCode(profileID: profileID)
    }
    func addChore(familyID: UUID, name: String, icon: String?) async throws -> Chore {
        try await inner.addChore(familyID: familyID, name: name, icon: icon)
    }
    func updateChore(_ chore: Chore) async throws { try await inner.updateChore(chore) }
    func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID, weekday: Int) async throws -> ScheduleEntry {
        try await inner.addScheduleEntry(familyID: familyID, profileID: profileID,
                                         choreID: choreID, weekday: weekday)
    }
    func removeScheduleEntry(id: UUID) async throws { try await inner.removeScheduleEntry(id: id) }
    func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int]) async throws {
        try await inner.copyDay(familyID: familyID, from: fromWeekday, to: toWeekdays)
    }

    func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                  dueOn: CalendarDay, completedBy: UUID) async throws {
        if shouldFail { throw ChoresBackendError.projectUnavailable }
        completeCallCount += 1
        try await inner.complete(familyID: familyID, profileID: profileID,
                                 choreID: choreID, dueOn: dueOn, completedBy: completedBy)
    }

    func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws {
        if shouldFail { throw ChoresBackendError.projectUnavailable }
        uncompleteCallCount += 1
        try await inner.uncomplete(profileID: profileID, choreID: choreID, dueOn: dueOn)
    }
}

@Suite struct OutboxTests {

    let familyID = UUID(), profileID = UUID(), choreID = UUID()
    let day = CalendarDay(year: 2026, month: 8, day: 10)

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var completeOperation: OutboxOperation {
        .complete(familyID: familyID, profileID: profileID, choreID: choreID,
                  dueOn: day, completedBy: profileID)
    }

    var uncompleteOperation: OutboxOperation {
        .uncomplete(profileID: profileID, choreID: choreID, dueOn: day)
    }

    @Test func flushSendsQueuedOperationsAndEmptiesTheQueue() async throws {
        let backend = FlakyBackend()
        let outbox = Outbox(directory: try makeTemporaryDirectory(), backend: backend)
        await outbox.enqueue(completeOperation)

        let sent = await outbox.flush()

        #expect(sent == 1)
        #expect(backend.completeCallCount == 1)
        #expect(await outbox.pendingCount == 0)
    }

    @Test func failedFlushKeepsOperationsQueued() async throws {
        let backend = FlakyBackend()
        backend.shouldFail = true
        let outbox = Outbox(directory: try makeTemporaryDirectory(), backend: backend)
        await outbox.enqueue(completeOperation)

        let sent = await outbox.flush()

        #expect(sent == 0)
        #expect(await outbox.pendingCount == 1)
    }

    @Test func operationsSurviveAcrossInstances() async throws {
        let directory = try makeTemporaryDirectory()
        let firstBackend = FlakyBackend()
        firstBackend.shouldFail = true
        let first = Outbox(directory: directory, backend: firstBackend)
        await first.enqueue(completeOperation)
        _ = await first.flush()

        let secondBackend = FlakyBackend()
        let second = Outbox(directory: directory, backend: secondBackend)
        #expect(await second.pendingCount == 1)

        let sent = await second.flush()
        #expect(sent == 1)
        #expect(secondBackend.completeCallCount == 1)
    }

    @Test func replayingTheSameCompletionTwiceIsHarmless() async throws {
        let backend = FlakyBackend()
        let outbox = Outbox(directory: try makeTemporaryDirectory(), backend: backend)
        await outbox.enqueue(completeOperation)
        _ = await outbox.flush()
        await outbox.enqueue(completeOperation)
        _ = await outbox.flush()

        // The DB unique constraint makes the second write a no-op, so the
        // outbox is free to replay blindly.
        #expect(backend.completeCallCount == 2)
    }

    @Test func opposingOperationsOnTheSameKeyCancelOut() async throws {
        let backend = FlakyBackend()
        backend.shouldFail = true
        let outbox = Outbox(directory: try makeTemporaryDirectory(), backend: backend)

        await outbox.enqueue(completeOperation)
        await outbox.enqueue(uncompleteOperation)

        // The server never saw the complete, so neither operation needs sending.
        #expect(await outbox.pendingCount == 0)
    }

    @Test func operationsOnDifferentKeysDoNotCancel() async throws {
        let backend = FlakyBackend()
        backend.shouldFail = true
        let outbox = Outbox(directory: try makeTemporaryDirectory(), backend: backend)

        await outbox.enqueue(completeOperation)
        await outbox.enqueue(.uncomplete(profileID: profileID, choreID: UUID(), dueOn: day))

        #expect(await outbox.pendingCount == 2)
    }

    @Test func flushStopsAtTheFirstFailureToPreserveOrder() async throws {
        let backend = FlakyBackend()
        let outbox = Outbox(directory: try makeTemporaryDirectory(), backend: backend)
        await outbox.enqueue(completeOperation)
        await outbox.enqueue(.complete(familyID: familyID, profileID: profileID,
                                       choreID: UUID(), dueOn: day, completedBy: profileID))
        backend.shouldFail = true

        let sent = await outbox.flush()

        #expect(sent == 0)
        #expect(await outbox.pendingCount == 2)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OutboxTests`
Expected: compile failure — `cannot find 'Outbox' in scope`.

- [ ] **Step 3: Implement `OutboxOperation`**

Create `Sources/ChoresCore/Sync/Outbox.swift`, starting with:

```swift
import Foundation

/// A completion write that has not yet reached the server.
public enum OutboxOperation: Codable, Equatable, Sendable {
    case complete(familyID: UUID, profileID: UUID, choreID: UUID,
                  dueOn: CalendarDay, completedBy: UUID)
    case uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay)

    /// Identifies the completion row this operation targets — the same tuple the
    /// database uniqueness constraint uses.
    struct Key: Hashable, Sendable {
        let profileID: UUID
        let choreID: UUID
        let dueOn: CalendarDay
    }

    var key: Key {
        switch self {
        case let .complete(_, profileID, choreID, dueOn, _):
            return Key(profileID: profileID, choreID: choreID, dueOn: dueOn)
        case let .uncomplete(profileID, choreID, dueOn):
            return Key(profileID: profileID, choreID: choreID, dueOn: dueOn)
        }
    }

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}
```

- [ ] **Step 4: Implement `Outbox`**

Append to `Sources/ChoresCore/Sync/Outbox.swift`:

```swift
/// A durable, ordered queue of completion writes.
///
/// Replay is safe because the server upserts on (profile_id, chore_id, due_on),
/// so this deliberately contains no deduplication logic beyond collapsing a
/// pending pair that cancels out.
public actor Outbox {

    private let fileURL: URL
    private let backend: ChoresBackend
    private var queue: [OutboxOperation]

    public init(directory: URL, backend: ChoresBackend) {
        self.fileURL = directory.appendingPathComponent("outbox.json")
        self.backend = backend
        self.queue = (try? Data(contentsOf: fileURL))
            .flatMap { try? ChoresJSON.decoder.decode([OutboxOperation].self, from: $0) } ?? []
    }

    public var pendingCount: Int { queue.count }

    public func enqueue(_ operation: OutboxOperation) {
        // If an unsent operation targets the same row in the opposite direction,
        // the server never observed either — drop both.
        if let index = queue.lastIndex(where: { $0.key == operation.key }),
           queue[index].isComplete != operation.isComplete {
            queue.remove(at: index)
        } else {
            queue.append(operation)
        }
        persist()
    }

    /// Sends queued operations in order, stopping at the first failure so that
    /// ordering is preserved. Returns how many were sent.
    @discardableResult
    public func flush() async -> Int {
        var sent = 0
        while let operation = queue.first {
            do {
                switch operation {
                case let .complete(familyID, profileID, choreID, dueOn, completedBy):
                    try await backend.complete(familyID: familyID, profileID: profileID,
                                               choreID: choreID, dueOn: dueOn,
                                               completedBy: completedBy)
                case let .uncomplete(profileID, choreID, dueOn):
                    try await backend.uncomplete(profileID: profileID, choreID: choreID,
                                                 dueOn: dueOn)
                }
                queue.removeFirst()
                sent += 1
                persist()
            } catch {
                break
            }
        }
        return sent
    }

    private func persist() {
        guard let data = try? ChoresJSON.encoder.encode(queue) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 5: Run to verify the tests pass**

Run: `swift test --filter OutboxTests`
Expected: PASS, 7 tests.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: PASS, 48 tests. Phase 2 is complete and every piece of domain logic is covered.

- [ ] **Step 7: Commit**

Use the `commit-commands:commit` skill.

---

## Phase 3 — App shell and onboarding

**Where view models live:** in `ChoresCore`, under `Sources/ChoresCore/ViewModels/`, marked `@Observable` and `@MainActor`. They import `Observation`, never SwiftUI. This keeps them runnable under `swift test`, which is the whole reason the core package exists. Only `View` structs live in the app target.

### Task 12: Create the Xcode app target

This is the one task requiring the maintainer at a keyboard. Everything after it is automatable.

**Files:**
- Create: `App/Chores.xcodeproj` (via Xcode)
- Create: `App/Chores/Secrets.xcconfig` (gitignored)
- Create: `App/Chores/Secrets.example.xcconfig`
- Create: `App/Chores/AppEnvironment.swift`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the `ChoresCore` package.
- Produces: `@MainActor final class AppEnvironment` exposing `backend: ChoresBackend`, `snapshotCache: SnapshotCache`, `outbox: Outbox`, and `static func live() -> AppEnvironment`.

- [ ] **Step 1: Create the project in Xcode**

In Xcode: **File → New → Project → iOS → App**.

- Product Name: `Chores`
- Interface: SwiftUI
- Language: Swift
- Storage: None
- Uncheck "Include Tests" (tests live in the package)
- Save into `/Users/arime/chores/App`

Then select the project → target `Chores` → **General** → set **Minimum Deployments** to iOS 17.0.

- [ ] **Step 2: Add the ChoresCore package**

**File → Add Package Dependencies… → Add Local…** → select `/Users/arime/chores` (the folder containing `Package.swift`) → Add to target `Chores`.

Verify under target → **General → Frameworks, Libraries, and Embedded Content** that `ChoresCore` is listed.

- [ ] **Step 3: Confirm the source folder is synchronized**

In the Project navigator, select the blue `Chores` group. In the File inspector it should read **Folder: Chores** with a synchronized-folder icon rather than a plain yellow group. If it is a plain group, delete it and drag the `App/Chores` folder back in choosing "Create folder references".

This is what allows later tasks to add `.swift` files on disk without touching the project file.

- [ ] **Step 4: Create the secrets configuration**

Create `App/Chores/Secrets.example.xcconfig`:

```
// Copy to Secrets.xcconfig and fill in. Never commit Secrets.xcconfig.
// Local stack values come from `supabase status`.
SUPABASE_URL = http:/$()/127.0.0.1:54321
SUPABASE_ANON_KEY = your-local-anon-key
```

The `$()` is not a typo — it prevents `xcconfig` from treating `//` as a comment.

Copy it to `App/Chores/Secrets.xcconfig` and fill in real values from `supabase status`.

In Xcode: project → **Info → Configurations** → set both Debug and Release for the `Chores` target to use `Secrets`.

Then target → **Info** tab, add two rows:
- `SUPABASE_URL` → `$(SUPABASE_URL)`
- `SUPABASE_ANON_KEY` → `$(SUPABASE_ANON_KEY)`

- [ ] **Step 5: Ignore the secrets file**

Append to `.gitignore`:

```
App/Chores/Secrets.xcconfig
```

Verify: `git check-ignore -v App/Chores/Secrets.xcconfig` prints a matching rule.

- [ ] **Step 6: Write `AppEnvironment`**

Create `App/Chores/AppEnvironment.swift`:

```swift
import Foundation
import ChoresCore

/// Owns the app's long-lived collaborators. One instance, created at launch.
@MainActor
final class AppEnvironment {
    let backend: ChoresBackend
    let snapshotCache: SnapshotCache
    let outbox: Outbox

    init(backend: ChoresBackend, directory: URL) {
        self.backend = backend
        self.snapshotCache = SnapshotCache(directory: directory)
        self.outbox = Outbox(directory: directory, backend: backend)
    }

    static func live() -> AppEnvironment {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: urlString),
            let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            !key.isEmpty
        else {
            fatalError("""
                Missing SUPABASE_URL / SUPABASE_ANON_KEY.
                Copy Secrets.example.xcconfig to Secrets.xcconfig and fill it in.
                """)
        }
        return AppEnvironment(backend: SupabaseChoresBackend(url: url, anonKey: key),
                              directory: SnapshotCache.defaultDirectory())
    }

    /// An environment backed by in-memory fakes, for SwiftUI previews.
    static func preview() -> AppEnvironment {
        AppEnvironment(backend: InMemoryChoresBackend(),
                       directory: FileManager.default.temporaryDirectory
                           .appendingPathComponent(UUID().uuidString))
    }
}
```

Note `AppEnvironment.preview()` creates a fresh temporary directory each call, so previews never share cache or outbox state.

- [ ] **Step 7: Build and run once**

Build for an iPhone simulator (⌘R). Expected: the default "Hello, world!" screen. If it crashes with the `fatalError` above, `Secrets.xcconfig` is not wired to the configuration — revisit Step 4.

- [ ] **Step 8: Commit**

Stage `App/` (excluding `Secrets.xcconfig`) and the `.gitignore` change. Use the `commit-commands:commit` skill.

---

### Task 13: Session bootstrap and root routing

**Files:**
- Create: `Sources/ChoresCore/ViewModels/SessionViewModel.swift`
- Test: `Tests/ChoresCoreTests/SessionViewModelTests.swift`
- Create: `App/Chores/RootView.swift`
- Modify: `App/Chores/ChoresApp.swift`

**Interfaces:**
- Consumes: `ChoresBackend`, `Profile`.
- Produces:
  - `enum SessionState: Equatable, Sendable { case loading, unclaimed, parent(Profile), child(Profile), unavailable }`
  - `@MainActor @Observable final class SessionViewModel` with `init(backend: ChoresBackend)`, `private(set) var state: SessionState`, `func start() async`, `func refresh() async`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ChoresCoreTests/SessionViewModelTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

@MainActor
@Suite struct SessionViewModelTests {

    @Test func startWithNoProfileYieldsUnclaimed() async {
        let model = SessionViewModel(backend: InMemoryChoresBackend())
        await model.start()
        #expect(model.state == .unclaimed)
    }

    @Test func startAfterCreatingAFamilyYieldsParent() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                           timezone: "Europe/Helsinki")

        let model = SessionViewModel(backend: backend)
        await model.start()

        guard case let .parent(profile) = model.state else {
            Issue.record("expected .parent, got \(model.state)")
            return
        }
        #expect(profile.displayName == "Parent")
    }

    @Test func startAfterClaimingYieldsChild() async throws {
        let parentBackend = InMemoryChoresBackend()
        try await parentBackend.signInAnonymouslyIfNeeded()
        let familyID = try await parentBackend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await parentBackend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let code = try await parentBackend.generateClaimCode(profileID: child.id)

        let kidBackend = parentBackend.newDevice()
        try await kidBackend.signInAnonymouslyIfNeeded()
        _ = try await kidBackend.claimProfile(code: code)

        let model = SessionViewModel(backend: kidBackend)
        await model.start()

        guard case let .child(profile) = model.state else {
            Issue.record("expected .child, got \(model.state)")
            return
        }
        #expect(profile.displayName == "Kid")
    }

    @Test func backendFailureYieldsUnavailableRatherThanUnclaimed() async {
        // A paused project must not look like a fresh install, or the user
        // would be sent to re-enter a claim code they do not need.
        let backend = UnavailableBackend()
        let model = SessionViewModel(backend: backend)
        await model.start()
        #expect(model.state == .unavailable)
    }
}

/// Fails every call with `.projectUnavailable`.
private final class UnavailableBackend: ChoresBackend, @unchecked Sendable {
    func signInAnonymouslyIfNeeded() async throws { throw ChoresBackendError.projectUnavailable }
    func currentProfile() async throws -> Profile? { throw ChoresBackendError.projectUnavailable }
    func createFamily(familyName: String, parentName: String, timezone: String) async throws -> UUID {
        throw ChoresBackendError.projectUnavailable
    }
    func claimProfile(code: String) async throws -> UUID { throw ChoresBackendError.projectUnavailable }
    func fetchSnapshot(familyID: UUID, weekOf day: CalendarDay) async throws -> FamilySnapshot {
        throw ChoresBackendError.projectUnavailable
    }
    func addChild(familyID: UUID, name: String, color: String, sortOrder: Int) async throws -> Profile {
        throw ChoresBackendError.projectUnavailable
    }
    func updateProfile(_ profile: Profile) async throws { throw ChoresBackendError.projectUnavailable }
    func generateClaimCode(profileID: UUID) async throws -> String { throw ChoresBackendError.projectUnavailable }
    func addChore(familyID: UUID, name: String, icon: String?) async throws -> Chore {
        throw ChoresBackendError.projectUnavailable
    }
    func updateChore(_ chore: Chore) async throws { throw ChoresBackendError.projectUnavailable }
    func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID, weekday: Int) async throws -> ScheduleEntry {
        throw ChoresBackendError.projectUnavailable
    }
    func removeScheduleEntry(id: UUID) async throws { throw ChoresBackendError.projectUnavailable }
    func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int]) async throws {
        throw ChoresBackendError.projectUnavailable
    }
    func complete(familyID: UUID, profileID: UUID, choreID: UUID, dueOn: CalendarDay, completedBy: UUID) async throws {
        throw ChoresBackendError.projectUnavailable
    }
    func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws {
        throw ChoresBackendError.projectUnavailable
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SessionViewModelTests`
Expected: compile failure — `cannot find 'SessionViewModel' in scope`.

- [ ] **Step 3: Implement `SessionViewModel`**

Create `Sources/ChoresCore/ViewModels/SessionViewModel.swift`:

```swift
import Foundation
import Observation

public enum SessionState: Equatable, Sendable {
    case loading
    /// Signed in, but this device is not bound to any profile yet.
    case unclaimed
    case parent(Profile)
    case child(Profile)
    /// The backend could not be reached. Deliberately distinct from `.unclaimed`.
    case unavailable
}

@MainActor
@Observable
public final class SessionViewModel {

    private let backend: ChoresBackend
    public private(set) var state: SessionState = .loading

    public init(backend: ChoresBackend) {
        self.backend = backend
    }

    public func start() async {
        state = .loading
        do {
            try await backend.signInAnonymouslyIfNeeded()
            try await load()
        } catch {
            state = .unavailable
        }
    }

    public func refresh() async {
        do { try await load() } catch { state = .unavailable }
    }

    private func load() async throws {
        guard let profile = try await backend.currentProfile() else {
            state = .unclaimed
            return
        }
        state = profile.role == .parent ? .parent(profile) : .child(profile)
    }
}
```

- [ ] **Step 4: Run to verify the tests pass**

Run: `swift test --filter SessionViewModelTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Write `RootView`**

Create `App/Chores/RootView.swift`:

```swift
import SwiftUI
import ChoresCore

/// The only place the parent/child split is decided.
struct RootView: View {
    let environment: AppEnvironment
    @State private var session: SessionViewModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _session = State(initialValue: SessionViewModel(backend: environment.backend))
    }

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView()
            case .unclaimed:
                OnboardingView(environment: environment) {
                    await session.refresh()
                }
            case .parent(let profile):
                ParentRootView(environment: environment, profile: profile)
            case .child(let profile):
                KidRootView(environment: environment, profile: profile)
            case .unavailable:
                BackendUnavailableView { await session.start() }
            }
        }
        .task { await session.start() }
    }
}
```

- [ ] **Step 6: Add placeholder destinations so the project compiles**

Create `App/Chores/Placeholders.swift`. These are replaced in later tasks; they exist so Task 13 is independently buildable.

```swift
import SwiftUI
import ChoresCore

struct ParentRootView: View {
    let environment: AppEnvironment
    let profile: Profile
    var body: some View { Text("Parent: \(profile.displayName)") }
}

struct KidRootView: View {
    let environment: AppEnvironment
    let profile: Profile
    var body: some View { Text("Kid: \(profile.displayName)") }
}

struct BackendUnavailableView: View {
    let retry: () async -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Can't reach the server", systemImage: "wifi.exclamationmark")
        } description: {
            Text("The Supabase project may be paused. Open the dashboard and resume it, then try again.")
        } actions: {
            Button("Try again") { Task { await retry() } }
        }
    }
}

struct OnboardingView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void
    var body: some View { Text("Onboarding") }
}
```

Delete each placeholder as the task that replaces it lands: `OnboardingView` in Task 14, `ParentRootView` in Task 16, `KidRootView` in Task 21. `BackendUnavailableView` is replaced in Task 24, which also deletes this file.

- [ ] **Step 7: Wire up `ChoresApp`**

Replace `App/Chores/ChoresApp.swift`:

```swift
import SwiftUI

@main
struct ChoresApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
    }
}
```

- [ ] **Step 8: Build and run**

With the local stack running (`supabase start`), build and run on a simulator.
Expected: a brief spinner, then the placeholder text `Onboarding` — proving anonymous
sign-in succeeded and the device correctly reports itself as unclaimed.

If the spinner is followed by "Can't reach the server", the local stack is not running or
`Secrets.xcconfig` points at the wrong port. If it hangs on the spinner forever, anonymous
sign-ins are not enabled in `supabase/config.toml` (Task 9, Step 8).

- [ ] **Step 9: Commit**

Use the `commit-commands:commit` skill.

---

### Task 14: Onboarding — create a family, or claim a profile

**Files:**
- Create: `Sources/ChoresCore/ViewModels/OnboardingViewModel.swift`
- Test: `Tests/ChoresCoreTests/OnboardingViewModelTests.swift`
- Create: `App/Chores/Onboarding/OnboardingView.swift`
- Create: `App/Chores/Onboarding/CreateFamilyView.swift`
- Create: `App/Chores/Onboarding/ClaimCodeView.swift`
- Modify: `App/Chores/Placeholders.swift` (delete `OnboardingView`)

**Interfaces:**
- Consumes: `ChoresBackend`, `ChoresBackendError`.
- Produces: `@MainActor @Observable final class OnboardingViewModel` with `init(backend: ChoresBackend)`, `var familyName: String`, `var parentName: String`, `var code: String`, `private(set) var errorMessage: String?`, `private(set) var isBusy: Bool`, `func createFamily() async -> Bool`, `func claim() async -> Bool`. Both return `true` on success so the view can notify `RootView` to refresh.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ChoresCoreTests/OnboardingViewModelTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

@MainActor
@Suite struct OnboardingViewModelTests {

    @Test func createFamilySucceedsAndClearsError() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        let model = OnboardingViewModel(backend: backend)
        model.familyName = "Koti"
        model.parentName = "Parent"

        let ok = await model.createFamily()

        #expect(ok)
        #expect(model.errorMessage == nil)
        #expect(try await backend.currentProfile()?.role == .parent)
    }

    @Test func createFamilyRejectsBlankNames() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        let model = OnboardingViewModel(backend: backend)
        model.familyName = "   "
        model.parentName = "Parent"

        let ok = await model.createFamily()

        #expect(!ok)
        #expect(model.errorMessage != nil)
        #expect(try await backend.currentProfile() == nil)
    }

    @Test func claimWithAValidCodeSucceeds() async throws {
        let parentBackend = InMemoryChoresBackend()
        try await parentBackend.signInAnonymouslyIfNeeded()
        let familyID = try await parentBackend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await parentBackend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let code = try await parentBackend.generateClaimCode(profileID: child.id)

        let kidBackend = parentBackend.newDevice()
        try await kidBackend.signInAnonymouslyIfNeeded()
        let model = OnboardingViewModel(backend: kidBackend)
        model.code = code.lowercased()   // entry is case-insensitive

        let ok = await model.claim()

        #expect(ok)
        #expect(try await kidBackend.currentProfile()?.id == child.id)
    }

    @Test func eachClaimFailureGetsItsOwnMessage() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        let model = OnboardingViewModel(backend: backend)
        model.code = "ZZZZZZ"

        let ok = await model.claim()

        #expect(!ok)
        #expect(model.errorMessage?.contains("don't recognise") == true)
    }

    @Test func isBusyIsFalseAfterAFailedCall() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        let model = OnboardingViewModel(backend: backend)
        model.code = "ZZZZZZ"

        _ = await model.claim()

        #expect(!model.isBusy)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OnboardingViewModelTests`
Expected: compile failure — `cannot find 'OnboardingViewModel' in scope`.

- [ ] **Step 3: Implement `OnboardingViewModel`**

Create `Sources/ChoresCore/ViewModels/OnboardingViewModel.swift`:

```swift
import Foundation
import Observation

@MainActor
@Observable
public final class OnboardingViewModel {

    private let backend: ChoresBackend

    public var familyName: String = ""
    public var parentName: String = ""
    public var code: String = ""
    public private(set) var errorMessage: String?
    public private(set) var isBusy: Bool = false

    public init(backend: ChoresBackend) {
        self.backend = backend
    }

    public func createFamily() async -> Bool {
        let family = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty, !parent.isEmpty else {
            errorMessage = "Please fill in both names."
            return false
        }

        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        do {
            _ = try await backend.createFamily(familyName: family, parentName: parent,
                                               timezone: TimeZone.current.identifier)
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    public func claim() async -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else {
            errorMessage = "Enter the code from your parent."
            return false
        }

        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        do {
            _ = try await backend.claimProfile(code: trimmed)
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    /// Each failure gets a message that tells the reader what to actually do next.
    private static func message(for error: Error) -> String {
        switch error as? ChoresBackendError {
        case .unknownClaimCode:
            return "We don't recognise that code. Check for typos and try again."
        case .claimCodeAlreadyUsed:
            return "That code has already been used. Ask your parent for a new one."
        case .claimCodeExpired:
            return "That code has expired. Ask your parent for a new one."
        case .alreadyClaimed:
            return "This device is already set up."
        case .projectUnavailable:
            return "Can't reach the server. Check your connection and try again."
        case .notAuthenticated:
            return "Couldn't start a session. Try restarting the app."
        case .underlying(let detail):
            return detail
        case nil:
            return error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run to verify the tests pass**

Run: `swift test --filter OnboardingViewModelTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Write the onboarding views**

Create `App/Chores/Onboarding/OnboardingView.swift`:

```swift
import SwiftUI
import ChoresCore

struct OnboardingView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "checklist")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("Chores")
                    .font(.largeTitle.bold())
                Text("Set up this device.")
                    .foregroundStyle(.secondary)
                Spacer()

                NavigationLink("I'm a parent") {
                    CreateFamilyView(environment: environment, onFinished: onFinished)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                NavigationLink("I have a code") {
                    ClaimCodeView(environment: environment, onFinished: onFinished)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(32)
        }
    }
}

#Preview {
    OnboardingView(environment: .preview(), onFinished: {})
}
```

Create `App/Chores/Onboarding/CreateFamilyView.swift`:

```swift
import SwiftUI
import ChoresCore

struct CreateFamilyView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    @State private var model: OnboardingViewModel

    init(environment: AppEnvironment, onFinished: @escaping () async -> Void) {
        self.environment = environment
        self.onFinished = onFinished
        _model = State(initialValue: OnboardingViewModel(backend: environment.backend))
    }

    var body: some View {
        Form {
            Section("Household") {
                TextField("Family name", text: $model.familyName)
            }
            Section("You") {
                TextField("Your name", text: $model.parentName)
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button("Create") {
                    Task {
                        if await model.createFamily() { await onFinished() }
                    }
                }
                .disabled(model.isBusy)
            }
        }
        .navigationTitle("New family")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { CreateFamilyView(environment: .preview(), onFinished: {}) }
}
```

Create `App/Chores/Onboarding/ClaimCodeView.swift`:

```swift
import SwiftUI
import ChoresCore

struct ClaimCodeView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    @State private var model: OnboardingViewModel

    init(environment: AppEnvironment, onFinished: @escaping () async -> Void) {
        self.environment = environment
        self.onFinished = onFinished
        _model = State(initialValue: OnboardingViewModel(backend: environment.backend))
    }

    var body: some View {
        Form {
            Section("Your code") {
                TextField("ABC123", text: $model.code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.title2, design: .monospaced))
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button("Continue") {
                    Task {
                        if await model.claim() { await onFinished() }
                    }
                }
                .disabled(model.isBusy)
            }
        }
        .navigationTitle("Enter code")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { ClaimCodeView(environment: .preview(), onFinished: {}) }
}
```

- [ ] **Step 6: Delete the `OnboardingView` placeholder**

Remove the `OnboardingView` struct from `App/Chores/Placeholders.swift`. The other placeholders stay.

- [ ] **Step 7: Build, run, and create a real family**

Run the app against the local stack. Tap "I'm a parent", fill in both fields, tap Create.
Expected: the screen becomes `Parent: <your name>` — the placeholder from Task 13, now
reached through a genuine round trip.

Verify the row landed:

```bash
psql "$(supabase status -o env | grep '^DB_URL' | cut -d= -f2- | tr -d '"')" \
  -c "select f.name, p.display_name, p.role from public.profiles p
      join public.families f on f.id = p.family_id;"
```

Expected: one row, role `parent`.

- [ ] **Step 8: Commit**

Use the `commit-commands:commit` skill.

---

## Phase 4 — Shared data store and parent mode

### Task 15: `FamilyStore` — caching, refresh, and optimistic toggles

Every screen in both modes reads from this one object. It is also where offline behaviour
lives, so the UI tasks that follow need no sync logic of their own.

**Files:**
- Create: `Sources/ChoresCore/ViewModels/FamilyStore.swift`
- Test: `Tests/ChoresCoreTests/FamilyStoreTests.swift`

**Interfaces:**
- Consumes: `ChoresBackend`, `SnapshotCache`, `Outbox`, `ScheduleResolver`, `CalendarDay`.
- Produces: `@MainActor @Observable public final class FamilyStore` with:
  - `init(backend: ChoresBackend, cache: SnapshotCache, outbox: Outbox, familyID: UUID, clock: @escaping @Sendable () -> Date = { Date() })`
  - `private(set) var snapshot: FamilySnapshot?`
  - `private(set) var isStale: Bool` — true when showing cached data after a failed refresh
  - `private(set) var errorMessage: String?`
  - `var today: CalendarDay` — the current day in the family's timezone
  - `func start() async` — load cache, then refresh
  - `func refresh() async`
  - `func chores(for profileID: UUID, on day: CalendarDay) -> [ChoreForDay]`
  - `func progress(for profileID: UUID, on day: CalendarDay) -> (done: Int, total: Int)`
  - `func setCompleted(_ completed: Bool, chore: Chore, profileID: UUID, on day: CalendarDay, actor actorProfileID: UUID) async`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ChoresCoreTests/FamilyStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

@MainActor
@Suite struct FamilyStoreTests {

    struct Fixture {
        let backend: InMemoryChoresBackend
        let store: FamilyStore
        let familyID: UUID
        let childID: UUID
        let choreID: UUID
        let directory: URL
    }

    /// A family with one child assigned "Bins" every Monday.
    func makeFixture(now: Date = Date(timeIntervalSince1970: 1_786_060_800)) async throws -> Fixture {
        // 1_786_060_800 == 2026-08-10T12:00:00Z, a Monday.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let chore = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)
        _ = try await backend.addScheduleEntry(familyID: familyID, profileID: child.id,
                                               choreID: chore.id, weekday: 1)

        let store = FamilyStore(
            backend: backend,
            cache: SnapshotCache(directory: directory),
            outbox: Outbox(directory: directory, backend: backend),
            familyID: familyID,
            clock: { now })

        return Fixture(backend: backend, store: store, familyID: familyID,
                       childID: child.id, choreID: chore.id, directory: directory)
    }

    @Test func todayUsesTheFamilyTimezone() async throws {
        // 2026-08-10T21:10Z is already the 11th in Helsinki.
        let fixture = try await makeFixture(now: Date(timeIntervalSince1970: 1_786_072_200))
        await fixture.store.start()
        #expect(fixture.store.today == CalendarDay(year: 2026, month: 8, day: 11))
    }

    @Test func startLoadsChoresForTheChild() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()

        let chores = fixture.store.chores(for: fixture.childID,
                                          on: CalendarDay(year: 2026, month: 8, day: 10))
        #expect(chores.map(\.chore.name) == ["Bins"])
        #expect(chores.first?.isCompleted == false)
        #expect(fixture.store.isStale == false)
    }

    @Test func completingUpdatesTheUIImmediately() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()
        let monday = CalendarDay(year: 2026, month: 8, day: 10)
        let chore = fixture.store.chores(for: fixture.childID, on: monday)[0].chore

        await fixture.store.setCompleted(true, chore: chore, profileID: fixture.childID,
                                         on: monday, actor: fixture.childID)

        #expect(fixture.store.chores(for: fixture.childID, on: monday)[0].isCompleted)
        #expect(fixture.store.progress(for: fixture.childID, on: monday) == (done: 1, total: 1))
    }

    @Test func completionSurvivesARefresh() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()
        let monday = CalendarDay(year: 2026, month: 8, day: 10)
        let chore = fixture.store.chores(for: fixture.childID, on: monday)[0].chore

        await fixture.store.setCompleted(true, chore: chore, profileID: fixture.childID,
                                         on: monday, actor: fixture.childID)
        await fixture.store.refresh()

        #expect(fixture.store.chores(for: fixture.childID, on: monday)[0].isCompleted)
    }

    @Test func uncompletingRemovesTheCompletion() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()
        let monday = CalendarDay(year: 2026, month: 8, day: 10)
        let chore = fixture.store.chores(for: fixture.childID, on: monday)[0].chore

        await fixture.store.setCompleted(true, chore: chore, profileID: fixture.childID,
                                         on: monday, actor: fixture.childID)
        await fixture.store.setCompleted(false, chore: chore, profileID: fixture.childID,
                                         on: monday, actor: fixture.childID)
        await fixture.store.refresh()

        #expect(fixture.store.chores(for: fixture.childID, on: monday)[0].isCompleted == false)
    }

    @Test func cachedSnapshotIsShownWhenRefreshFails() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()   // populates the cache

        // A fresh store over the same directory, pointed at a dead backend.
        let deadStore = FamilyStore(
            backend: UnavailableBackend(),
            cache: SnapshotCache(directory: fixture.directory),
            outbox: Outbox(directory: fixture.directory, backend: UnavailableBackend()),
            familyID: fixture.familyID,
            clock: { Date(timeIntervalSince1970: 1_786_060_800) })

        await deadStore.start()

        #expect(deadStore.snapshot != nil)
        #expect(deadStore.isStale)
        #expect(deadStore.chores(for: fixture.childID,
                                 on: CalendarDay(year: 2026, month: 8, day: 10)).count == 1)
    }

    @Test func togglingWhileOfflineStillUpdatesTheUI() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()

        let deadStore = FamilyStore(
            backend: UnavailableBackend(),
            cache: SnapshotCache(directory: fixture.directory),
            outbox: Outbox(directory: fixture.directory, backend: UnavailableBackend()),
            familyID: fixture.familyID,
            clock: { Date(timeIntervalSince1970: 1_786_060_800) })
        await deadStore.start()

        let monday = CalendarDay(year: 2026, month: 8, day: 10)
        let chore = deadStore.chores(for: fixture.childID, on: monday)[0].chore
        await deadStore.setCompleted(true, chore: chore, profileID: fixture.childID,
                                     on: monday, actor: fixture.childID)

        // The tap sticks locally and the write waits in the outbox.
        #expect(deadStore.chores(for: fixture.childID, on: monday)[0].isCompleted)
    }
}
```

Reuse the `UnavailableBackend` written in Task 13 — move it out of
`SessionViewModelTests.swift` into a new shared file `Tests/ChoresCoreTests/TestDoubles.swift`
and drop the `private` modifier so both suites can use it.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FamilyStoreTests`
Expected: compile failure — `cannot find 'FamilyStore' in scope`.

- [ ] **Step 3: Implement `FamilyStore`**

Create `Sources/ChoresCore/ViewModels/FamilyStore.swift`:

```swift
import Foundation
import Observation

/// The app's single read model. Owns the snapshot, the cache, and the outbox, so that
/// no view needs to know whether the device is online.
@MainActor
@Observable
public final class FamilyStore {

    private let backend: ChoresBackend
    private let cache: SnapshotCache
    private let outbox: Outbox
    private let familyID: UUID
    private let clock: @Sendable () -> Date

    public private(set) var snapshot: FamilySnapshot?
    /// True when the displayed data came from cache after a failed refresh.
    public private(set) var isStale: Bool = false
    public private(set) var errorMessage: String?

    public init(backend: ChoresBackend,
                cache: SnapshotCache,
                outbox: Outbox,
                familyID: UUID,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.cache = cache
        self.outbox = outbox
        self.familyID = familyID
        self.clock = clock
    }

    public var timeZone: TimeZone { snapshot?.family.timeZone ?? .current }

    public var today: CalendarDay { CalendarDay(clock(), in: timeZone) }

    public func start() async {
        if let cached = await cache.load() {
            snapshot = cached
            isStale = true          // provisional until the refresh below succeeds
        }
        await refresh()
    }

    public func refresh() async {
        // Send anything queued before reading, so the server state we fetch is current.
        await outbox.flush()
        do {
            let fresh = try await backend.fetchSnapshot(familyID: familyID, weekOf: today)
            snapshot = fresh
            isStale = false
            errorMessage = nil
            await cache.save(fresh)
        } catch {
            isStale = snapshot != nil
            errorMessage = snapshot == nil ? Self.message(for: error) : nil
        }
    }

    // MARK: Reads

    public func chores(for profileID: UUID, on day: CalendarDay) -> [ChoreForDay] {
        guard let snapshot else { return [] }
        return ScheduleResolver.chores(
            for: profileID, on: day, template: snapshot.template,
            chores: snapshot.chores, completions: snapshot.completions)
    }

    public func progress(for profileID: UUID, on day: CalendarDay) -> (done: Int, total: Int) {
        guard let snapshot else { return (0, 0) }
        return ScheduleResolver.progress(
            for: profileID, on: day, template: snapshot.template,
            chores: snapshot.chores, completions: snapshot.completions)
    }

    public func eligibility(for day: CalendarDay) -> CompletionEligibility {
        ScheduleResolver.eligibility(for: day, today: today)
    }

    // MARK: Writes

    /// Applies the change locally first, then queues it. The outbox flushes immediately
    /// when online and survives a relaunch when not.
    public func setCompleted(_ completed: Bool, chore: Chore, profileID: UUID,
                             on day: CalendarDay, actor actorProfileID: UUID) async {
        guard snapshot != nil else { return }

        if completed {
            let optimistic = Completion(
                id: UUID(), familyID: familyID, profileID: profileID, choreID: chore.id,
                dueOn: day, completedAt: clock(), completedBy: actorProfileID)
            snapshot?.completions.removeAll {
                $0.profileID == profileID && $0.choreID == chore.id && $0.dueOn == day
            }
            snapshot?.completions.append(optimistic)
            await outbox.enqueue(.complete(
                familyID: familyID, profileID: profileID, choreID: chore.id,
                dueOn: day, completedBy: actorProfileID))
        } else {
            snapshot?.completions.removeAll {
                $0.profileID == profileID && $0.choreID == chore.id && $0.dueOn == day
            }
            await outbox.enqueue(.uncomplete(
                profileID: profileID, choreID: chore.id, dueOn: day))
        }

        if let snapshot { await cache.save(snapshot) }
        await outbox.flush()
    }

    /// Called after any parent edit to chores, children, or the schedule.
    public func reloadAfterEdit() async {
        await refresh()
    }

    private static func message(for error: Error) -> String {
        if case .projectUnavailable = error as? ChoresBackendError {
            return "Can't reach the server."
        }
        return (error as? ChoresBackendError).map(String.init(describing:))
            ?? error.localizedDescription
    }
}
```

- [ ] **Step 4: Run to verify the tests pass**

Run: `swift test --filter FamilyStoreTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS, 64 tests.

- [ ] **Step 6: Commit**

Use the `commit-commands:commit` skill.

---

### Task 16: Parent shell and children management

**Files:**
- Create: `App/Chores/DesignSystem/ProfileColor.swift`
- Create: `App/Chores/Parent/ParentRootView.swift`
- Create: `App/Chores/Parent/ChildrenView.swift`
- Create: `App/Chores/Parent/ClaimCodeSheet.swift`
- Modify: `App/Chores/Placeholders.swift` (delete `ParentRootView`)

**Interfaces:**
- Consumes: `FamilyStore`, `Profile`, `AppEnvironment`.
- Produces: `ParentRootView(environment:profile:)` — a three-tab shell whose tabs are `ParentTodayView` (Task 19), `ParentWeekView` (Task 20), and a Manage tab containing `ChildrenView`, `ChoresView` (Task 17) and `ScheduleEditorView` (Task 18). Also `extension Color { init(hexString: String) }`.

Build the shell with placeholder tabs so this task is independently runnable, then fill
each tab in the tasks that follow.

- [ ] **Step 1: Write the colour helper**

Create `App/Chores/DesignSystem/ProfileColor.swift`:

```swift
import SwiftUI

extension Color {
    /// Parses "#RRGGBB". Falls back to gray on anything unexpected, because a bad
    /// colour must never take a screen down.
    init(hexString: String) {
        let hex = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

/// The palette offered when adding a child. Distinguishable in both light and dark mode.
enum ProfilePalette {
    static let options = ["#4C8BF5", "#E8710A", "#1DB954", "#C2185B", "#7B5CD6", "#00897B"]
}
```

- [ ] **Step 2: Write the parent shell**

Create `App/Chores/Parent/ParentRootView.swift`:

```swift
import SwiftUI
import ChoresCore

struct ParentRootView: View {
    let environment: AppEnvironment
    let profile: Profile

    @State private var store: FamilyStore

    init(environment: AppEnvironment, profile: Profile) {
        self.environment = environment
        self.profile = profile
        _store = State(initialValue: FamilyStore(
            backend: environment.backend,
            cache: environment.snapshotCache,
            outbox: environment.outbox,
            familyID: profile.familyID))
    }

    var body: some View {
        TabView {
            ParentTodayView(store: store)
                .tabItem { Label("Today", systemImage: "checklist") }

            ParentWeekView(store: store)
                .tabItem { Label("Week", systemImage: "calendar") }

            ManageView(store: store, backend: environment.backend)
                .tabItem { Label("Manage", systemImage: "gearshape") }
        }
        .task { await store.start() }
    }
}

struct ManageView: View {
    let store: FamilyStore
    let backend: ChoresBackend

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ChildrenView(store: store, backend: backend)
                } label: {
                    Label("Children", systemImage: "person.2")
                }
                NavigationLink {
                    ChoresView(store: store, backend: backend)
                } label: {
                    Label("Chores", systemImage: "list.bullet")
                }
                NavigationLink {
                    ScheduleEditorView(store: store, backend: backend)
                } label: {
                    Label("Schedule", systemImage: "calendar.badge.clock")
                }
            }
            .navigationTitle("Manage")
        }
    }
}
```

- [ ] **Step 3: Add temporary tab placeholders**

Append to `App/Chores/Placeholders.swift` (and delete the old `ParentRootView` struct):

```swift
struct ParentTodayView: View {
    let store: FamilyStore
    var body: some View { Text("Today") }
}

struct ParentWeekView: View {
    let store: FamilyStore
    var body: some View { Text("Week") }
}

struct ChoresView: View {
    let store: FamilyStore
    let backend: ChoresBackend
    var body: some View { Text("Chores") }
}

struct ScheduleEditorView: View {
    let store: FamilyStore
    let backend: ChoresBackend
    var body: some View { Text("Schedule") }
}
```

`ParentTodayView` is replaced in Task 19, `ParentWeekView` in Task 20, `ChoresView` in
Task 17, `ScheduleEditorView` in Task 18.

- [ ] **Step 4: Write `ChildrenView`**

Create `App/Chores/Parent/ChildrenView.swift`:

```swift
import SwiftUI
import ChoresCore

struct ChildrenView: View {
    let store: FamilyStore
    let backend: ChoresBackend

    @State private var isAdding = false
    @State private var newName = ""
    @State private var editing: Profile?
    @State private var errorMessage: String?

    private var children: [Profile] { store.snapshot?.children ?? [] }

    var body: some View {
        List {
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }

            Section {
                ForEach(children) { child in
                    Button {
                        editing = child
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color(hexString: child.color))
                                .frame(width: 14, height: 14)
                            Text(child.displayName)
                            Spacer()
                            if child.authUserID == nil {
                                Text("Not set up")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                }
            } footer: {
                Text("Tap a child to rename them, change their colour, or show a setup code.")
            }

            Section {
                Button("Add child") { isAdding = true }
            }
        }
        .navigationTitle("Children")
        .alert("Add child", isPresented: $isAdding) {
            TextField("Name", text: $newName)
            Button("Add") { Task { await addChild() } }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .sheet(item: $editing) { child in
            EditChildSheet(child: child, store: store, backend: backend)
        }
    }

    private func addChild() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let familyID = store.snapshot?.family.id else { return }
        // Cycle the palette so consecutive children get distinct colours.
        let color = ProfilePalette.options[children.count % ProfilePalette.options.count]
        do {
            _ = try await backend.addChild(familyID: familyID, name: name,
                                           color: color, sortOrder: children.count)
            newName = ""
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't add \(name). Check your connection and try again."
        }
    }
}
```

Deleting a child is deliberately absent: it raises questions about their completion history
that v1 does not answer.

- [ ] **Step 5: Write `EditChildSheet`**

Create `App/Chores/Parent/EditChildSheet.swift`:

```swift
import SwiftUI
import ChoresCore

struct EditChildSheet: View {
    let child: Profile
    let store: FamilyStore
    let backend: ChoresBackend

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: String
    @State private var showingCode = false
    @State private var errorMessage: String?

    init(child: Profile, store: FamilyStore, backend: ChoresBackend) {
        self.child = child
        self.store = store
        self.backend = backend
        _name = State(initialValue: child.displayName)
        _color = State(initialValue: child.color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }

                Section("Colour") {
                    HStack(spacing: 12) {
                        ForEach(ProfilePalette.options, id: \.self) { option in
                            Button {
                                color = option
                            } label: {
                                Circle()
                                    .fill(Color(hexString: option))
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if option == color {
                                            Circle().strokeBorder(.primary, lineWidth: 3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button("Show setup code") { showingCode = true }
                } footer: {
                    Text(child.authUserID == nil
                         ? "This child's device isn't set up yet."
                         : "Only needed if they get a new device or reinstall the app.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(child.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showingCode) {
                ClaimCodeSheet(profile: child, backend: backend)
            }
        }
    }

    private func save() async {
        var updated = child
        updated.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.color = color
        do {
            try await backend.updateProfile(updated)
            await store.reloadAfterEdit()
            dismiss()
        } catch {
            errorMessage = "Couldn't save. Check your connection and try again."
        }
    }
}
```

- [ ] **Step 6: Write `ClaimCodeSheet`**

Create `App/Chores/Parent/ClaimCodeSheet.swift`:

```swift
import SwiftUI
import ChoresCore

struct ClaimCodeSheet: View {
    let profile: Profile
    let backend: ChoresBackend

    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                if let code {
                    Text("Enter this on \(profile.displayName)'s device")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Expires in 7 days. Generating a new code cancels this one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
                Spacer()
                Button("New code") { Task { await generate() } }
                    .buttonStyle(.bordered)
            }
            .padding(32)
            .navigationTitle(profile.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await generate() }
        }
    }

    private func generate() async {
        do {
            code = try await backend.generateClaimCode(profileID: profile.id)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't create a code. Check your connection and try again."
        }
    }
}
```

- [ ] **Step 7: Build, run, and add a child end to end**

Run the app as the parent created in Task 14. Manage → Children → Add child → name it.
Expected: the child appears with a colour dot and "Not set up". Tap it, rename it, pick a
different colour, Save — the list reflects both changes. Tap it again and "Show setup code"
produces a six-character code.

Verify: `psql "$(supabase status -o env | grep '^DB_URL' | cut -d= -f2- | tr -d '"')" -c "select display_name, role from public.profiles order by sort_order;"`
Expected: the parent and the new child.

- [ ] **Step 8: Claim the child profile on a second simulator**

Run the app on a *different* simulator device (so it has its own storage), tap "I have a
code", enter the code.
Expected: the screen becomes `Kid: <name>` — the Task 13 placeholder. Re-entering the same
code on a third device must show "That code has already been used."

- [ ] **Step 9: Commit**

Use the `commit-commands:commit` skill.

---

### Task 17: Chores management

**Files:**
- Create: `App/Chores/Parent/ChoresView.swift`
- Modify: `App/Chores/Placeholders.swift` (delete `ChoresView`)

**Interfaces:**
- Consumes: `FamilyStore`, `ChoresBackend`, `Chore`.
- Produces: `ChoresView(store:backend:)`.

Archiving rather than deleting: a deleted chore would orphan completion history. Archived
chores disappear from scheduling and from `ScheduleResolver` output, but their history and
their existing schedule entries survive, so un-archiving restores the old assignments.

- [ ] **Step 1: Write the view**

Create `App/Chores/Parent/ChoresView.swift`:

```swift
import SwiftUI
import ChoresCore

struct ChoresView: View {
    let store: FamilyStore
    let backend: ChoresBackend

    @State private var isAdding = false
    @State private var newName = ""
    @State private var renaming: Chore?
    @State private var renameText = ""
    @State private var showArchived = false
    @State private var errorMessage: String?

    private var active: [Chore] { store.snapshot?.activeChores ?? [] }

    private var archived: [Chore] {
        (store.snapshot?.chores ?? [])
            .filter(\.isArchived)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }

            Section {
                ForEach(active) { chore in
                    Button(chore.name) {
                        renameText = chore.name
                        renaming = chore
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button("Archive") {
                            Task { await setArchived(true, chore) }
                        }
                        .tint(.orange)
                    }
                }
                if active.isEmpty {
                    Text("No chores yet.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Active")
            } footer: {
                Text("Tap to rename. Swipe to archive.")
            }

            if !archived.isEmpty {
                Section {
                    DisclosureGroup("Archived (\(archived.count))", isExpanded: $showArchived) {
                        ForEach(archived) { chore in
                            Text(chore.name)
                                .foregroundStyle(.secondary)
                                .swipeActions {
                                    Button("Restore") {
                                        Task { await setArchived(false, chore) }
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                } footer: {
                    Text("Archived chores keep their history and their place in the schedule, but don't appear on anyone's list.")
                }
            }

            Section {
                Button("Add chore") { isAdding = true }
            }
        }
        .navigationTitle("Chores")
        .alert("Add chore", isPresented: $isAdding) {
            TextField("Name", text: $newName)
            Button("Add") { Task { await add() } }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename chore", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func rename() async {
        guard var updated = renaming else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !trimmed.isEmpty, trimmed != updated.name else { return }
        updated.name = trimmed
        do {
            try await backend.updateChore(updated)
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't rename that chore. Check your connection and try again."
        }
    }

    private func add() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let familyID = store.snapshot?.family.id else { return }
        do {
            _ = try await backend.addChore(familyID: familyID, name: name, icon: nil)
            newName = ""
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't add \(name). Check your connection and try again."
        }
    }

    private func setArchived(_ archived: Bool, _ chore: Chore) async {
        var updated = chore
        updated.isArchived = archived
        do {
            try await backend.updateChore(updated)
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't update \(chore.name). Check your connection and try again."
        }
    }
}
```

- [ ] **Step 2: Delete the placeholder**

Remove the `ChoresView` struct from `App/Chores/Placeholders.swift`.

- [ ] **Step 3: Build and exercise it**

Add three chores. Tap one and rename it — the list updates. Swipe another to Archive.
Expected: it moves under "Archived (1)"; restoring returns it to Active.

Renaming a chore that already appears in the schedule must leave its schedule entries
intact, since `schedule_entries` references the chore by id. Verify after Task 18 lands.

- [ ] **Step 4: Commit**

Use the `commit-commands:commit` skill.

---

### Task 18: Schedule editor

The hardest screen in the app. A 7-day × 3-child grid does not fit a phone, so the editor
is day-first — matching how the requirement was originally described: "on Monday child A
does X and Y."

**Files:**
- Create: `App/Chores/DesignSystem/WeekdayNames.swift`
- Create: `App/Chores/Parent/ScheduleEditorView.swift`
- Create: `App/Chores/Parent/AssignChoreSheet.swift`
- Modify: `App/Chores/Placeholders.swift` (delete `ScheduleEditorView`)

**Interfaces:**
- Consumes: `FamilyStore`, `ChoresBackend`, `ScheduleEntry`, `Chore`, `Profile`.
- Produces: `ScheduleEditorView(store:backend:)`; `enum WeekdayNames` with `static func short(_ isoWeekday: Int) -> String` and `static func full(_ isoWeekday: Int) -> String`.

- [ ] **Step 1: Write the weekday name helper**

Create `App/Chores/DesignSystem/WeekdayNames.swift`:

```swift
import Foundation

enum WeekdayNames {
    /// `isoWeekday` is 1 = Monday … 7 = Sunday. `DateFormatter` symbol arrays are
    /// indexed 0 = Sunday, hence the shift.
    private static func index(_ isoWeekday: Int) -> Int { isoWeekday % 7 }

    static func short(_ isoWeekday: Int) -> String {
        DateFormatter().shortStandaloneWeekdaySymbols[index(isoWeekday)].capitalized
    }

    static func full(_ isoWeekday: Int) -> String {
        DateFormatter().standaloneWeekdaySymbols[index(isoWeekday)].capitalized
    }
}
```

- [ ] **Step 2: Write the editor**

Create `App/Chores/Parent/ScheduleEditorView.swift`:

```swift
import SwiftUI
import ChoresCore

struct ScheduleEditorView: View {
    let store: FamilyStore
    let backend: ChoresBackend

    @State private var selectedWeekday = 1
    @State private var assigningTo: Profile?
    @State private var isCopying = false
    @State private var copyTargets: Set<Int> = []
    @State private var errorMessage: String?

    private var children: [Profile] { store.snapshot?.children ?? [] }
    private var chores: [Chore] { store.snapshot?.activeChores ?? [] }

    private func entries(for child: Profile) -> [(entry: ScheduleEntry, chore: Chore)] {
        guard let snapshot = store.snapshot else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.chores.map { ($0.id, $0) })
        return snapshot.template
            .filter { $0.profileID == child.id && $0.weekday == selectedWeekday }
            .compactMap { entry in
                guard let chore = byID[entry.choreID], !chore.isArchived else { return nil }
                return (entry, chore)
            }
            .sorted { $0.chore.name.localizedStandardCompare($1.chore.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Day", selection: $selectedWeekday) {
                ForEach(1...7, id: \.self) { weekday in
                    Text(WeekdayNames.short(weekday)).tag(weekday)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            List {
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }

                ForEach(children) { child in
                    Section {
                        ForEach(entries(for: child), id: \.entry.id) { pair in
                            Text(pair.chore.name)
                                .swipeActions {
                                    Button("Remove", role: .destructive) {
                                        Task { await remove(pair.entry) }
                                    }
                                }
                        }
                        Button("Add chore") { assigningTo = child }
                            .font(.callout)
                    } header: {
                        HStack {
                            Circle()
                                .fill(Color(hexString: child.color))
                                .frame(width: 10, height: 10)
                            Text(child.displayName)
                        }
                    }
                }

                if children.isEmpty {
                    Section {
                        Text("Add a child under Manage → Children first.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Copy \(WeekdayNames.full(selectedWeekday)) to…") {
                        copyTargets = []
                        isCopying = true
                    }
                    .disabled(children.isEmpty)
                } footer: {
                    Text("Copying replaces everything already assigned on the target days.")
                }
            }
        }
        .navigationTitle("Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $assigningTo) { child in
            AssignChoreSheet(
                child: child,
                chores: chores,
                alreadyAssigned: Set(entries(for: child).map(\.chore.id))
            ) { chore in
                await assign(chore, to: child)
            }
        }
        .sheet(isPresented: $isCopying) {
            copySheet
        }
    }

    private var copySheet: some View {
        NavigationStack {
            List {
                Section("Copy to") {
                    ForEach(1...7, id: \.self) { weekday in
                        if weekday != selectedWeekday {
                            Button {
                                if copyTargets.contains(weekday) {
                                    copyTargets.remove(weekday)
                                } else {
                                    copyTargets.insert(weekday)
                                }
                            } label: {
                                HStack {
                                    Text(WeekdayNames.full(weekday))
                                    Spacer()
                                    if copyTargets.contains(weekday) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Copy \(WeekdayNames.full(selectedWeekday))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isCopying = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") { Task { await copy() } }
                        .disabled(copyTargets.isEmpty)
                }
            }
        }
    }

    private func assign(_ chore: Chore, to child: Profile) async {
        guard let familyID = store.snapshot?.family.id else { return }
        do {
            _ = try await backend.addScheduleEntry(
                familyID: familyID, profileID: child.id, choreID: chore.id,
                weekday: selectedWeekday)
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't assign \(chore.name). Check your connection and try again."
        }
    }

    private func remove(_ entry: ScheduleEntry) async {
        do {
            try await backend.removeScheduleEntry(id: entry.id)
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't remove that chore. Check your connection and try again."
        }
    }

    private func copy() async {
        guard let familyID = store.snapshot?.family.id else { return }
        do {
            try await backend.copyDay(familyID: familyID, from: selectedWeekday,
                                      to: Array(copyTargets))
            errorMessage = nil
            isCopying = false
            await store.reloadAfterEdit()
        } catch {
            isCopying = false
            errorMessage = "Couldn't copy the day. Check your connection and try again."
        }
    }
}
```

- [ ] **Step 3: Write the assign sheet**

Create `App/Chores/Parent/AssignChoreSheet.swift`:

```swift
import SwiftUI
import ChoresCore

struct AssignChoreSheet: View {
    let child: Profile
    let chores: [Chore]
    let alreadyAssigned: Set<UUID>
    let onSelect: (Chore) async -> Void

    @Environment(\.dismiss) private var dismiss

    private var available: [Chore] { chores.filter { !alreadyAssigned.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                ForEach(available) { chore in
                    Button(chore.name) {
                        Task {
                            await onSelect(chore)
                            dismiss()
                        }
                    }
                    .tint(.primary)
                }
                if available.isEmpty {
                    Text(chores.isEmpty
                         ? "Add some chores under Manage → Chores first."
                         : "\(child.displayName) already has every chore on this day.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Assign to \(child.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
```

- [ ] **Step 4: Delete the placeholder**

Remove the `ScheduleEditorView` struct from `App/Chores/Placeholders.swift`.

- [ ] **Step 5: Build the spec's exact scenario**

On Monday, assign chores X and Y to child A and chore Z to child B. Switch to Tuesday and
assign Z to A, X and Y to B.

Verify:

```bash
psql "$(supabase status -o env | grep '^DB_URL' | cut -d= -f2- | tr -d '"')" \
  -c "select p.display_name, c.name, s.weekday
      from public.schedule_entries s
      join public.profiles p on p.id = s.profile_id
      join public.chores c on c.id = s.chore_id
      order by s.weekday, p.display_name, c.name;"
```

Expected: six rows showing the swap across weekdays 1 and 2.

- [ ] **Step 6: Verify "copy day" replaces rather than merges**

With Monday selected, copy it to Tuesday. Expected: Tuesday's assignments are now
identical to Monday's, and the Tuesday rows from Step 5 are gone — replaced, not merged.
Re-run the query to confirm.

- [ ] **Step 7: Commit**

Use the `commit-commands:commit` skill.

---

### Task 19: Parent Today overview

**Files:**
- Create: `App/Chores/Parent/ParentTodayView.swift`
- Create: `App/Chores/DesignSystem/ProgressRing.swift`
- Modify: `App/Chores/Placeholders.swift` (delete `ParentTodayView`)

**Interfaces:**
- Consumes: `FamilyStore`, `Profile`, `ChoreForDay`.
- Produces: `ParentTodayView(store:)`; `ProgressRing(done:total:color:)`.

- [ ] **Step 1: Write the progress ring**

Create `App/Chores/DesignSystem/ProgressRing.swift`:

```swift
import SwiftUI

struct ProgressRing: View {
    let done: Int
    let total: Int
    let color: Color

    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 6)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: fraction)
            Text("\(done)/\(total)")
                .font(.caption2.bold())
                .monospacedDigit()
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel("\(done) of \(total) done")
    }
}
```

- [ ] **Step 2: Add the date formatting helpers**

These land before the view, which uses them. Append to
`Sources/ChoresCore/Calendar/CalendarDay.swift`:

```swift
extension CalendarDay {
    /// e.g. "Monday 10 August". Rendered in the family's timezone and the device locale.
    public func formattedLong(in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: date(in: timeZone))
    }

    /// e.g. "10 Aug".
    public func formattedShort(in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter.string(from: date(in: timeZone))
    }
}
```

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Write the view**

Create `App/Chores/Parent/ParentTodayView.swift`:

```swift
import SwiftUI
import ChoresCore

struct ParentTodayView: View {
    let store: FamilyStore

    private var children: [Profile] { store.snapshot?.children ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if store.isStale {
                    StaleBanner(fetchedAt: store.snapshot?.fetchedAt)
                }

                ForEach(children) { child in
                    Section {
                        let chores = store.chores(for: child.id, on: store.today)
                        if chores.isEmpty {
                            Text("Nothing today").foregroundStyle(.secondary)
                        }
                        ForEach(chores) { item in
                            HStack {
                                Image(systemName: item.isCompleted
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isCompleted ? .green : .secondary)
                                Text(item.chore.name)
                                    .strikethrough(item.isCompleted)
                                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                            }
                            .swipeActions {
                                if item.isCompleted {
                                    Button("Undo") {
                                        Task {
                                            await store.setCompleted(
                                                false, chore: item.chore, profileID: child.id,
                                                on: store.today, actor: child.id)
                                        }
                                    }
                                    .tint(.orange)
                                }
                            }
                        }
                    } header: {
                        let progress = store.progress(for: child.id, on: store.today)
                        HStack {
                            ProgressRing(done: progress.done, total: progress.total,
                                         color: Color(hexString: child.color))
                            Text(child.displayName).font(.headline)
                            Spacer()
                        }
                        .textCase(nil)
                    }
                }

                if children.isEmpty {
                    ContentUnavailableView("No children yet",
                                           systemImage: "person.2",
                                           description: Text("Add them under Manage → Children."))
                }
            }
            .navigationTitle(store.today.formattedLong(in: store.timeZone))
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
        }
    }
}

struct StaleBanner: View {
    let fetchedAt: Date?

    var body: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath")
            VStack(alignment: .leading) {
                Text("Showing saved data").font(.footnote.bold())
                if let fetchedAt {
                    Text("Last updated \(fetchedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(Color.orange.opacity(0.15))
    }
}
```

- [ ] **Step 4: Delete the placeholder**

Remove the `ParentTodayView` struct from `App/Chores/Placeholders.swift`.

- [ ] **Step 5: Build and verify**

With the Monday schedule from Task 18 in place, open the Today tab. If today is not a
Monday, temporarily assign chores to today's weekday so the list is non-empty.
Expected: each child appears with a progress ring reading `0/n` and their chore list.

- [ ] **Step 6: Verify the parent revert path**

The kid UI does not exist yet, so simulate a completion directly. Substitute the real ids
from the previous query:

```bash
psql "$(supabase status -o env | grep '^DB_URL' | cut -d= -f2- | tr -d '"')" -c \
  "insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by)
   select p.family_id, p.id, c.id, current_date, p.id
   from public.profiles p, public.chores c
   where p.role = 'child' and c.is_archived = false
   limit 1;"
```

Pull to refresh on the parent device. Expected: that chore shows completed with a green
check. Swipe it, tap Undo, and confirm the row is gone:

```bash
psql "$(supabase status -o env | grep '^DB_URL' | cut -d= -f2- | tr -d '"')" \
  -c "select count(*) from public.completions;"
```

Expected: `0`.

- [ ] **Step 7: Commit**

Use the `commit-commands:commit` skill.

---

### Task 20: Parent Week grid

**Files:**
- Create: `App/Chores/Parent/ParentWeekView.swift`
- Create: `App/Chores/Parent/DayDetailView.swift`
- Modify: `App/Chores/Placeholders.swift` (delete `ParentWeekView`)

**Interfaces:**
- Consumes: `FamilyStore`, `WeekCalendar`, `CalendarDay`.
- Produces: `ParentWeekView(store:)`, `DayDetailView(store:child:day:)`.

Current ISO week only — browsing previous weeks is deliberately out of scope for v1.

- [ ] **Step 1: Write the grid**

Create `App/Chores/Parent/ParentWeekView.swift`:

```swift
import SwiftUI
import ChoresCore

struct ParentWeekView: View {
    let store: FamilyStore

    @State private var selection: WeekSelection?

    private var children: [Profile] { store.snapshot?.children ?? [] }
    private var week: [CalendarDay] { WeekCalendar.isoWeek(containing: store.today) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.isStale {
                        StaleBanner(fetchedAt: store.snapshot?.fetchedAt)
                            .padding(.horizontal)
                    }

                    // Header row of weekday initials.
                    HStack(spacing: 4) {
                        Text("").frame(width: 88, alignment: .leading)
                        ForEach(week, id: \.self) { day in
                            Text(WeekdayNames.short(day.isoWeekday))
                                .font(.caption2)
                                .foregroundStyle(day == store.today ? Color.accentColor : .secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal)

                    ForEach(children) { child in
                        HStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(hexString: child.color))
                                    .frame(width: 8, height: 8)
                                Text(child.displayName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            .frame(width: 88, alignment: .leading)

                            ForEach(week, id: \.self) { day in
                                let progress = store.progress(for: child.id, on: day)
                                Button {
                                    selection = WeekSelection(child: child, day: day)
                                } label: {
                                    WeekCell(done: progress.done,
                                             total: progress.total,
                                             isToday: day == store.today,
                                             color: Color(hexString: child.color))
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal)
                    }

                    if children.isEmpty {
                        ContentUnavailableView("No children yet",
                                               systemImage: "person.2",
                                               description: Text("Add them under Manage → Children."))
                            .padding(.top, 40)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("This week")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .navigationDestination(item: $selection) { selected in
                DayDetailView(store: store, child: selected.child, day: selected.day)
            }
        }
    }
}

/// `navigationDestination(item:)` needs a single Identifiable value.
struct WeekSelection: Identifiable, Hashable {
    let child: Profile
    let day: CalendarDay
    var id: String { "\(child.id)|\(day.year)-\(day.month)-\(day.day)" }
}

struct WeekCell: View {
    let done: Int
    let total: Int
    let isToday: Bool
    let color: Color

    private var background: Color {
        if total == 0 { return .secondary.opacity(0.08) }
        return done == total ? color.opacity(0.85) : color.opacity(0.18)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(background)
            .overlay {
                if total > 0 {
                    Text("\(done)/\(total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(done == total ? .white : .primary)
                }
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .frame(height: 34)
            .accessibilityLabel(total == 0 ? "nothing scheduled" : "\(done) of \(total) done")
    }
}
```

- [ ] **Step 2: Write the day detail**

Create `App/Chores/Parent/DayDetailView.swift`:

```swift
import SwiftUI
import ChoresCore

struct DayDetailView: View {
    let store: FamilyStore
    let child: Profile
    let day: CalendarDay

    var body: some View {
        List {
            let chores = store.chores(for: child.id, on: day)
            if chores.isEmpty {
                Text("Nothing scheduled").foregroundStyle(.secondary)
            }
            ForEach(chores) { item in
                HStack {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isCompleted ? .green : .secondary)
                    Text(item.chore.name)
                        .strikethrough(item.isCompleted)
                    Spacer()
                }
                .swipeActions {
                    if item.isCompleted {
                        Button("Undo") {
                            Task {
                                await store.setCompleted(false, chore: item.chore,
                                                         profileID: child.id, on: day,
                                                         actor: child.id)
                            }
                        }
                        .tint(.orange)
                    } else if store.eligibility(for: day) == .allowed {
                        Button("Mark done") {
                            Task {
                                await store.setCompleted(true, chore: item.chore,
                                                         profileID: child.id, on: day,
                                                         actor: child.id)
                            }
                        }
                        .tint(.green)
                    }
                }
            }
        }
        .navigationTitle("\(child.displayName) · \(WeekdayNames.full(day.isoWeekday))")
        .navigationBarTitleDisplayMode(.inline)
    }
}
```

- [ ] **Step 3: Delete the placeholder**

Remove the `ParentWeekView` struct from `App/Chores/Placeholders.swift`.

- [ ] **Step 4: Build and verify**

Open the Week tab. Expected: a row per child, seven cells each, today's column outlined.
Cells with no assignments are faint grey; partially done cells are tinted; fully done cells
are solid. Tapping a cell opens that child's day.

- [ ] **Step 5: Commit**

Use the `commit-commands:commit` skill.

---

## Phase 5 — Kid mode

### Task 21: Kid Today

**Files:**
- Create: `App/Chores/Kid/KidRootView.swift`
- Create: `App/Chores/Kid/KidTodayView.swift`
- Create: `App/Chores/Kid/ChoreRow.swift`
- Modify: `App/Chores/Placeholders.swift` (delete `KidRootView`)

**Interfaces:**
- Consumes: `FamilyStore`, `Profile`, `ChoreForDay`.
- Produces: `KidRootView(environment:profile:)`, `KidTodayView(store:profile:)`, `ChoreRow(item:isEnabled:onToggle:)`.

Design constraints from the spec: the children are 11, 14 and 16. Large tap targets, real
typography, no mascots, no settings screen, no route to parent functionality.

- [ ] **Step 1: Write the chore row**

Create `App/Chores/Kid/ChoreRow.swift`:

```swift
import SwiftUI
import ChoresCore

struct ChoreRow: View {
    let item: ChoreForDay
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 16) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.isCompleted ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))

                Text(item.chore.name)
                    .font(.body)
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)

                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .sensoryFeedback(.success, trigger: item.isCompleted) { _, new in new }
    }
}
```

- [ ] **Step 2: Write the kid shell and today view**

Create `App/Chores/Kid/KidRootView.swift`:

```swift
import SwiftUI
import ChoresCore

struct KidRootView: View {
    let environment: AppEnvironment
    let profile: Profile

    @State private var store: FamilyStore

    init(environment: AppEnvironment, profile: Profile) {
        self.environment = environment
        self.profile = profile
        _store = State(initialValue: FamilyStore(
            backend: environment.backend,
            cache: environment.snapshotCache,
            outbox: environment.outbox,
            familyID: profile.familyID))
    }

    var body: some View {
        TabView {
            KidTodayView(store: store, profile: profile)
                .tabItem { Label("Today", systemImage: "checklist") }

            KidWeekView(store: store, profile: profile)
                .tabItem { Label("Week", systemImage: "calendar") }
        }
        .task { await store.start() }
    }
}
```

Create `App/Chores/Kid/KidTodayView.swift`:

```swift
import SwiftUI
import ChoresCore

struct KidTodayView: View {
    let store: FamilyStore
    let profile: Profile

    private var items: [ChoreForDay] {
        // Completed chores sink to the bottom so what's left is always on top.
        store.chores(for: profile.id, on: store.today)
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
                return lhs.chore.name.localizedStandardCompare(rhs.chore.name) == .orderedAscending
            }
    }

    private var progress: (done: Int, total: Int) {
        store.progress(for: profile.id, on: store.today)
    }

    var body: some View {
        NavigationStack {
            List {
                if store.isStale {
                    StaleBanner(fetchedAt: store.snapshot?.fetchedAt)
                }

                if items.isEmpty {
                    ContentUnavailableView("Nothing today",
                                           systemImage: "checkmark.circle",
                                           description: Text("Enjoy it."))
                } else {
                    Section {
                        ForEach(items) { item in
                            ChoreRow(item: item, isEnabled: true) {
                                Task {
                                    await store.setCompleted(
                                        !item.isCompleted, chore: item.chore,
                                        profileID: profile.id, on: store.today,
                                        actor: profile.id)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(progress.done) of \(progress.total) done")
                                .font(.subheadline.bold())
                                .monospacedDigit()
                            Spacer()
                        }
                        .textCase(nil)
                    }
                }
            }
            .navigationTitle(store.today.formattedLong(in: store.timeZone))
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
        }
    }
}
```

- [ ] **Step 3: Add a `KidWeekView` placeholder**

Append to `App/Chores/Placeholders.swift` (and delete the old `KidRootView`):

```swift
struct KidWeekView: View {
    let store: FamilyStore
    let profile: Profile
    var body: some View { Text("Week") }
}
```

Replaced in Task 22.

- [ ] **Step 4: Build and verify on the kid simulator**

On the claimed kid device, open the app. Expected: today's date, a `0 of n done` header,
and the chore list. Tap a chore: it checks instantly, greys out, and drops to the bottom.

- [ ] **Step 5: Verify it reached the server and the parent**

```bash
psql "$(supabase status -o env | grep '^DB_URL' | cut -d= -f2- | tr -d '"')" \
  -c "select p.display_name, c.name, due_on
      from public.completions co
      join public.profiles p on p.id = co.profile_id
      join public.chores c on c.id = co.chore_id;"
```

Expected: one row. Pull to refresh on the parent device — the same chore shows completed.

- [ ] **Step 6: Verify offline behaviour**

Stop the local stack (`supabase stop`). On the kid device, tap another chore.
Expected: the tick still lands instantly and sticks. Force-quit and relaunch the app: the
saved data is still shown with the "Showing saved data" banner, and the tick survives.

Restart the stack (`supabase start`) and pull to refresh. Expected: the banner disappears
and the queued completion is now in the database — re-run the query above to confirm two
rows.

- [ ] **Step 7: Commit**

Use the `commit-commands:commit` skill.

---

### Task 22: Kid Week

**Files:**
- Create: `App/Chores/Kid/KidWeekView.swift`
- Modify: `App/Chores/Placeholders.swift` (delete `KidWeekView`)

**Interfaces:**
- Consumes: `FamilyStore`, `WeekCalendar`, `CompletionEligibility`.
- Produces: `KidWeekView(store:profile:)`.

The rule from the spec, enforced here: today and earlier days in the current ISO week are
tappable; future days are read-only previews. `ScheduleResolver.eligibility` already
encodes this and is already tested — this view only reads it.

- [ ] **Step 1: Write the view**

Create `App/Chores/Kid/KidWeekView.swift`:

```swift
import SwiftUI
import ChoresCore

struct KidWeekView: View {
    let store: FamilyStore
    let profile: Profile

    @State private var selectedDay: CalendarDay?

    private var week: [CalendarDay] { WeekCalendar.isoWeek(containing: store.today) }
    private var day: CalendarDay { selectedDay ?? store.today }
    private var isEditable: Bool { store.eligibility(for: day) == .allowed }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(week, id: \.self) { candidate in
                        let progress = store.progress(for: profile.id, on: candidate)
                        Button {
                            selectedDay = candidate
                        } label: {
                            VStack(spacing: 4) {
                                Text(WeekdayNames.short(candidate.isoWeekday))
                                    .font(.caption2)
                                Circle()
                                    .fill(dotColor(done: progress.done, total: progress.total))
                                    .frame(width: 8, height: 8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(candidate == day
                                          ? Color.accentColor.opacity(0.15) : .clear)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                List {
                    if !isEditable {
                        Section {
                            Label(hintText, systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    let items = store.chores(for: profile.id, on: day)
                    if items.isEmpty {
                        Text("Nothing scheduled").foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        ChoreRow(item: item, isEnabled: isEditable) {
                            Task {
                                await store.setCompleted(
                                    !item.isCompleted, chore: item.chore,
                                    profileID: profile.id, on: day, actor: profile.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle(day.formattedLong(in: store.timeZone))
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
        }
    }

    private var hintText: String {
        switch store.eligibility(for: day) {
        case .future:             return "You can tick these off on the day."
        case .outsideCurrentWeek: return "This week only."
        case .allowed:            return ""
        }
    }

    private func dotColor(done: Int, total: Int) -> Color {
        if total == 0 { return .secondary.opacity(0.25) }
        return done == total ? .green : .orange
    }
}
```

- [ ] **Step 2: Delete the placeholder**

Remove the `KidWeekView` struct from `App/Chores/Placeholders.swift`. The file should now
be empty apart from `BackendUnavailableView` — leave that one; Task 24 replaces it.

- [ ] **Step 3: Build and verify the eligibility rule**

On the kid device, open the Week tab and select a day earlier in the week. Expected: chores
are tappable. Select a day later in the week. Expected: rows are dimmed and untappable,
with "You can tick these off on the day."

- [ ] **Step 4: Verify a back-dated completion records the right date**

Tick a chore on an earlier day in the week, then:

```bash
psql "$(supabase status -o env | grep '^DB_URL' | cut -d= -f2- | tr -d '"')" \
  -c "select due_on, count(*) from public.completions group by due_on order by due_on;"
```

Expected: a row whose `due_on` is the earlier date, not today. This is the check that
`CalendarDay` is threading through correctly rather than everything collapsing onto `now()`.

- [ ] **Step 5: Commit**

Use the `commit-commands:commit` skill.

---

## Phase 6 — Resilience and release

### Task 23: Local daily reminder

**Files:**
- Create: `Sources/ChoresCore/Notifications/ReminderSchedule.swift`
- Test: `Tests/ChoresCoreTests/ReminderScheduleTests.swift`
- Create: `App/Chores/Kid/ReminderScheduler.swift`
- Modify: `App/Chores/Kid/KidRootView.swift`

**Interfaces:**
- Consumes: `FamilySnapshot`, `ScheduleResolver`.
- Produces:
  - `struct ReminderPlan: Equatable, Sendable { let isoWeekday: Int; let choreCount: Int }`
  - `enum ReminderSchedule` with `static func plans(for profileID: UUID, snapshot: FamilySnapshot) -> [ReminderPlan]` — one entry per weekday on which the child has at least one chore.
  - `@MainActor enum ReminderScheduler` (app target) with `static func requestAuthorization() async`, `static func reschedule(plans: [ReminderPlan], timeZone: TimeZone) async`.

Fires at 16:00 local, fixed and not configurable in v1. Entirely on-device — no APNs, no
certificates, no push tokens.

- [ ] **Step 1: Write the failing test**

Create `Tests/ChoresCoreTests/ReminderScheduleTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

@Suite struct ReminderScheduleTests {

    let familyID = UUID()
    let childID = UUID()
    let otherChildID = UUID()

    func snapshot(entries: [(profile: UUID, chore: Chore, weekday: Int)],
                  chores: [Chore]) -> FamilySnapshot {
        FamilySnapshot(
            family: Family(id: familyID, name: "Koti"),
            profiles: [],
            chores: chores,
            template: entries.map {
                ScheduleEntry(id: UUID(), familyID: familyID, profileID: $0.profile,
                              choreID: $0.chore.id, weekday: $0.weekday)
            },
            completions: [],
            fetchedAt: Date())
    }

    var bins: Chore { Chore(id: UUID(), familyID: familyID, name: "Bins") }
    var dishes: Chore { Chore(id: UUID(), familyID: familyID, name: "Dishes") }

    @Test func producesOnePlanPerWeekdayWithChores() {
        let bins = self.bins, dishes = self.dishes
        let snap = snapshot(entries: [
            (childID, bins, 1), (childID, dishes, 1), (childID, bins, 4)
        ], chores: [bins, dishes])

        let plans = ReminderSchedule.plans(for: childID, snapshot: snap)

        #expect(plans == [ReminderPlan(isoWeekday: 1, choreCount: 2),
                          ReminderPlan(isoWeekday: 4, choreCount: 1)])
    }

    @Test func skipsWeekdaysWithNoChores() {
        let bins = self.bins
        let snap = snapshot(entries: [(childID, bins, 3)], chores: [bins])
        let plans = ReminderSchedule.plans(for: childID, snapshot: snap)
        #expect(plans.map(\.isoWeekday) == [3])
    }

    @Test func ignoresOtherChildrensChores() {
        let bins = self.bins
        let snap = snapshot(entries: [(otherChildID, bins, 2)], chores: [bins])
        #expect(ReminderSchedule.plans(for: childID, snapshot: snap).isEmpty)
    }

    @Test func ignoresArchivedChores() {
        let archived = Chore(id: UUID(), familyID: familyID, name: "Old", isArchived: true)
        let snap = snapshot(entries: [(childID, archived, 5)], chores: [archived])
        #expect(ReminderSchedule.plans(for: childID, snapshot: snap).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ReminderScheduleTests`
Expected: compile failure — `cannot find 'ReminderSchedule' in scope`.

- [ ] **Step 3: Implement `ReminderSchedule`**

Create `Sources/ChoresCore/Notifications/ReminderSchedule.swift`:

```swift
import Foundation

public struct ReminderPlan: Equatable, Sendable {
    public let isoWeekday: Int
    public let choreCount: Int

    public init(isoWeekday: Int, choreCount: Int) {
        self.isoWeekday = isoWeekday
        self.choreCount = choreCount
    }
}

public enum ReminderSchedule {
    /// One plan per weekday on which this child has at least one active chore.
    /// Days with nothing scheduled produce no notification at all.
    public static func plans(for profileID: UUID, snapshot: FamilySnapshot) -> [ReminderPlan] {
        let activeChoreIDs = Set(snapshot.chores.filter { !$0.isArchived }.map(\.id))

        var countsByWeekday: [Int: Int] = [:]
        for entry in snapshot.template
        where entry.profileID == profileID && activeChoreIDs.contains(entry.choreID) {
            countsByWeekday[entry.weekday, default: 0] += 1
        }

        return countsByWeekday
            .sorted { $0.key < $1.key }
            .map { ReminderPlan(isoWeekday: $0.key, choreCount: $0.value) }
    }
}
```

- [ ] **Step 4: Run to verify the tests pass**

Run: `swift test --filter ReminderScheduleTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Write the scheduler**

Create `App/Chores/Kid/ReminderScheduler.swift`:

```swift
import Foundation
import UserNotifications
import ChoresCore

@MainActor
enum ReminderScheduler {

    private static let identifierPrefix = "chores.daily."
    /// Fixed in v1. Not configurable.
    private static let hour = 16

    static func requestAuthorization() async {
        // A refusal is fine — the app simply never notifies.
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// Replaces all previously scheduled reminders with the given plans.
    static func reschedule(plans: [ReminderPlan], timeZone: TimeZone) async {
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return }

        let existing = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: existing.map(\.identifier)
                .filter { $0.hasPrefix(identifierPrefix) })

        for plan in plans {
            let content = UNMutableNotificationContent()
            content.title = "Chores today"
            content.body = plan.choreCount == 1
                ? "You have 1 chore today."
                : "You have \(plan.choreCount) chores today."
            content.sound = .default

            var components = DateComponents()
            // UNCalendarNotificationTrigger uses 1 = Sunday, so ISO Monday (1) becomes 2.
            components.weekday = plan.isoWeekday == 7 ? 1 : plan.isoWeekday + 1
            components.hour = hour
            components.minute = 0
            components.timeZone = timeZone

            let request = UNNotificationRequest(
                identifier: "\(identifierPrefix)\(plan.isoWeekday)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))

            try? await center.add(request)
        }
    }
}
```

- [ ] **Step 6: Wire it into the kid shell**

In `App/Chores/Kid/KidRootView.swift`, replace the `.task` modifier on `TabView` with:

```swift
        .task {
            await store.start()
            await ReminderScheduler.requestAuthorization()
        }
        .onChange(of: store.snapshot?.template) { _, _ in
            guard let snapshot = store.snapshot else { return }
            let plans = ReminderSchedule.plans(for: profile.id, snapshot: snapshot)
            Task { await ReminderScheduler.reschedule(plans: plans,
                                                      timeZone: snapshot.family.timeZone) }
        }
```

Reminders are rescheduled whenever the template changes, which is exactly when the set of
chore-bearing days can change.

- [ ] **Step 7: Verify on the simulator**

Launch the kid app and accept the notification prompt. Then in the simulator:
**Features → Trigger Notification** is unavailable for scheduled local notifications, so
verify the schedule instead by temporarily changing `hour` to two minutes from now,
rebuilding, backgrounding the app, and waiting.

Expected: a notification reading "You have N chores today" on a weekday where the child has
chores, and none on a weekday where they have none. **Restore `hour = 16` before
committing.**

- [ ] **Step 8: Commit**

Use the `commit-commands:commit` skill.

---

### Task 24: Failure screens and background sync triggers

**Files:**
- Create: `App/Chores/Failure/BackendUnavailableView.swift`
- Create: `App/Chores/Failure/LostSessionView.swift`
- Modify: `App/Chores/RootView.swift`
- Delete: `App/Chores/Placeholders.swift`

**Interfaces:**
- Consumes: `SessionViewModel`, `FamilyStore`, `AppEnvironment`.
- Produces: `BackendUnavailableView(retry:)`, `LostSessionView(onReclaim:)`.

Each failure gets its own screen because each has a different remedy. A generic "network
error" would send the maintainer debugging the app when the fix is un-pausing a project.

- [ ] **Step 1: Write the unavailable screen**

Create `App/Chores/Failure/BackendUnavailableView.swift`:

```swift
import SwiftUI

struct BackendUnavailableView: View {
    let retry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        ContentUnavailableView {
            Label("Can't reach the server", systemImage: "wifi.exclamationmark")
        } description: {
            VStack(spacing: 12) {
                Text("Check this device's connection first.")
                Text("""
                    If other devices can't connect either, the Supabase project has \
                    probably paused after a week of inactivity. Open the Supabase \
                    dashboard and resume it — nothing is lost.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("Try again") {
                Task {
                    isRetrying = true
                    await retry()
                    isRetrying = false
                }
            }
            .disabled(isRetrying)
        }
    }
}

#Preview { BackendUnavailableView(retry: {}) }
```

- [ ] **Step 2: Write the lost-session screen**

Create `App/Chores/Failure/LostSessionView.swift`:

```swift
import SwiftUI

/// Shown when the anonymous session exists but no longer maps to a profile — for
/// example after the profile was removed server-side. The remedy is a new claim code.
struct LostSessionView: View {
    let onReclaim: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("This device isn't set up", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Ask a parent to open Manage → Children and show you a new code.")
        } actions: {
            Button("Enter a code") { onReclaim() }
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview { LostSessionView(onReclaim: {}) }
```

- [ ] **Step 3: Add sync triggers to `RootView`**

Replace `App/Chores/RootView.swift`:

```swift
import SwiftUI
import ChoresCore

struct RootView: View {
    let environment: AppEnvironment

    @Environment(\.scenePhase) private var scenePhase
    @State private var session: SessionViewModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _session = State(initialValue: SessionViewModel(backend: environment.backend))
    }

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView()
            case .unclaimed:
                OnboardingView(environment: environment) {
                    await session.refresh()
                }
            case .parent(let profile):
                ParentRootView(environment: environment, profile: profile)
            case .child(let profile):
                KidRootView(environment: environment, profile: profile)
            case .unavailable:
                BackendUnavailableView { await session.start() }
            }
        }
        .task { await session.start() }
        .onChange(of: scenePhase) { _, newPhase in
            // Anything queued while offline goes out as soon as the app is frontmost.
            guard newPhase == .active else { return }
            Task { await environment.outbox.flush() }
        }
    }
}
```

- [ ] **Step 4: Delete the placeholder file**

Delete `App/Chores/Placeholders.swift` entirely. In Xcode, confirm the build still
succeeds — with synchronized folders, removing the file on disk is sufficient.

- [ ] **Step 5: Verify each failure screen**

*Unavailable:* stop the stack (`supabase stop`), delete the app from the simulator (so
there is no cached snapshot), and launch. Expected: the "Can't reach the server" screen
with the paused-project explanation, not a spinner and not the onboarding screen.

*Offline flush:* with the stack still stopped, on an already-set-up kid device tick two
chores, then force-quit. Start the stack and reopen the app. Expected: both completions
appear in the database without any manual refresh.

```bash
psql "$(supabase status -o env | grep '^DB_URL' | cut -d= -f2- | tr -d '"')" \
  -c "select count(*) from public.completions;"
```

- [ ] **Step 6: Commit**

Use the `commit-commands:commit` skill.

---

### Task 25: Release to TestFlight

**Files:**
- Modify: `App/Chores/Secrets.xcconfig` (hosted project values)
- Create: `docs/RELEASING.md`

**Interfaces:**
- Consumes: everything.
- Produces: a build installed on all five family devices.

- [ ] **Step 1: Apply the migrations to the hosted project**

**The maintainer performs this step.** From the repo root, with the project linked:

```bash
supabase link --project-ref <your-project-ref>
supabase db push
```

Nothing in this plan runs `db push` on the maintainer's behalf.

- [ ] **Step 2: Enable anonymous sign-ins on the hosted project**

Supabase dashboard → Authentication → Sign In / Providers → enable **Anonymous sign-ins**.
Without this every device fails at first launch with "Can't reach the server."

- [ ] **Step 3: Point the app at the hosted project**

Update `App/Chores/Secrets.xcconfig` with the hosted project URL and anon key from
dashboard → Project Settings → API. Confirm `git status` does not list the file.

- [ ] **Step 4: Configure signing and archive**

In Xcode: target → Signing & Capabilities → select your team, set a unique bundle
identifier. Set the run destination to **Any iOS Device (arm64)**, then
**Product → Archive**.

- [ ] **Step 5: Upload and distribute**

In the Organizer, **Distribute App → TestFlight & App Store → Upload**. Once processed, add
each family member as an internal tester in App Store Connect.

- [ ] **Step 6: Set up the real household**

On your own device: create the family, add the three children, add the chores, and build
the weekly schedule. Then hand each child their claim code.

- [ ] **Step 7: Write the release notes**

Create `docs/RELEASING.md`:

```markdown
# Releasing

## Database changes

Migrations live in `supabase/migrations/`. Apply them yourself:

    supabase link --project-ref <project-ref>
    supabase db push

Run `supabase test db` locally first — the pgTAP suite in `supabase/tests/` is the
regression gate for RLS, and an RLS bug fails silently.

## App builds

1. Confirm `App/Chores/Secrets.xcconfig` points at the hosted project.
2. Run `swift test` from the repo root — all ChoresCore tests must pass.
3. Xcode → Any iOS Device → Product → Archive → Distribute → TestFlight.

## If the app says "Can't reach the server"

Free Supabase projects pause after roughly 7 days with no API activity. Open the
dashboard and resume the project; no data is lost. This is expected after a holiday.

## Adding a new device for a child

Manage → Children → tap the child → New code. Codes last 7 days, and generating a new
one cancels any outstanding code for that child.
```

- [ ] **Step 8: Commit**

Use the `commit-commands:commit` skill.

---

## Verification checklist

Run before declaring the project complete:

- [ ] `swift test` — all ChoresCore tests pass
- [ ] `supabase db reset && supabase test db` — all pgTAP tests pass
- [ ] Parent can add children, chores, and a full weekly schedule
- [ ] "Copy day to…" replaces rather than merges target days
- [ ] A child's device claims with a code and shows only their own chores
- [ ] A child can tick today and earlier days this week, but not future days
- [ ] A parent can revert any completion
- [ ] Ticking a chore offline sticks, survives relaunch, and syncs on reconnect
- [ ] A back-dated completion records the earlier `due_on`, not today
- [ ] The daily reminder fires only on days with chores
- [ ] Stopping the backend shows the paused-project screen, not the onboarding screen
