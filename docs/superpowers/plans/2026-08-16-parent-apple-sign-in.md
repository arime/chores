# Parent Sign In with Apple — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parents sign in with Apple so a family survives reinstall, and family membership becomes reversible — a parent can leave or delete their account, and a child can be deleted.

**Architecture:** Identity is acquired on demand rather than at launch. The parent door signs in with Apple and gets a durable `auth.users` row; the child door signs in anonymously as part of claiming a code. The database enforces "parents are never anonymous" inside the two `SECURITY DEFINER` RPCs that are the only writers of `profiles.auth_user_id`, so the rule cannot be bypassed by a client. Three new RPCs cover leaving, account deletion and child deletion.

**Tech Stack:** Swift 6 / SwiftUI (iOS 17+), `ChoresCore` as a local SwiftPM package, supabase-swift 2.54.1, Postgres via Supabase with RLS, pgTAP for database tests, Swift Testing for unit and integration tests, XCTest for UI tests.

**Spec:** `docs/superpowers/specs/2026-08-16-parent-apple-sign-in-design.md`

## Global Constraints

- **Deployment target iOS 17.0.** No API newer than iOS 17 without checking availability.
- **`ChoresCore` must not expose Supabase or AuthenticationServices types.** `ChoresBackend` takes an already-obtained `idToken` and `nonce` as `String`. `ASAuthorizationAppleIDProvider` and `SignInWithAppleButton` live in the app target only.
- **Clients never delete `profiles`.** No `DELETE` grant is added; every deletion happens inside a `SECURITY DEFINER` RPC. This preserves the property asserted in `supabase/migrations/20260813120000_table_grants.sql`.
- **Apple's name and email are never persisted.** Apple returns them only on the first authorization ever; `CreateFamilyView` already asks for the parent's name.
- **Unit and integration tests use Swift Testing** (`@Suite` / `@Test` / `#expect` / `#require`), never XCTest. UI tests in `App/ChoresUITests` remain XCTest.
- **Bundle identifier:** `com.metsahalme.Chores`. **Team:** `HPD6U8BLB5`.
- **Migrations are applied locally only.** Use `supabase db reset` (destroys local data only). Never run `supabase db push` — pushing to hosted is the maintainer's action.
- **Indentation:** Swift 4 spaces, SQL 2 spaces, matching the existing files.
- **Commit after every task.** Do not push.

## Orientation

- `Sources/ChoresCore/` — the package. Models, view models, `ChoresBackend` protocol, and two implementations (`SupabaseChoresBackend`, `InMemoryChoresBackend`).
- `App/Chores/` — the SwiftUI app. Uses Xcode file-system synchronized folders, so **new files need no `.pbxproj` edit**.
- `supabase/migrations/` — ordered by filename timestamp. `supabase/tests/01_rls_and_rpcs.sql` is the pgTAP suite and the real gate on RLS.
- Run unit tests: `swift test` from the repo root.
- Run pgTAP: `supabase db reset && supabase test db`.
- Run the app build: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`.

---

### Task 1: A completion outlives the person who recorded it

`completions.completed_by` currently cascades. Deleting a departing parent would erase every completion that parent ticked off on a child's behalf. This must land before any deletion RPC exists.

**Files:**
- Create: `supabase/migrations/20260816100000_completions_survive_profile_delete.sql`
- Modify: `Sources/ChoresCore/Models/Completion.swift`
- Test: `supabase/tests/01_rls_and_rpcs.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: `Completion.completedBy` is `UUID?`. `completions.completed_by` is nullable with `on delete set null`. The write path is unchanged: `ChoresBackend.complete(..., completedBy: UUID)` and `OutboxOperation.complete(..., completedBy: UUID)` both keep the non-optional type.

- [ ] **Step 1: Write the failing pgTAP assertions**

In `supabase/tests/01_rls_and_rpcs.sql`, change `select plan(15);` to `select plan(17);` and add these two assertions immediately before `select tests.as_admin();` at the end of the file:

```sql
-- A parent's completion on a child's behalf must outlive the parent's profile.
select tests.as_admin();
insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by)
  values ('f0000000-0000-0000-0000-00000000000a',
          'a0000000-0000-0000-0000-000000000002',
          'c0000000-0000-0000-0000-00000000000a',
          '2026-08-10',
          'a0000000-0000-0000-0000-000000000001');

delete from public.profiles where id = 'a0000000-0000-0000-0000-000000000001';

select is(
  (select count(*)::int from public.completions
     where profile_id = 'a0000000-0000-0000-0000-000000000002'
       and due_on = '2026-08-10'),
  1,
  'deleting the parent who recorded a completion leaves the completion');

select is(
  (select completed_by from public.completions
     where profile_id = 'a0000000-0000-0000-0000-000000000002'
       and due_on = '2026-08-10'),
  null::uuid,
  'and completed_by becomes null rather than the row vanishing');
```

The fixture UUIDs above must match the ones already inserted at the top of the file. Read the fixture block first and substitute the real family, child, parent and chore IDs if they differ.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `supabase db reset && supabase test db`
Expected: FAIL. The `delete from public.profiles` cascades the completion away, so the first new assertion reports `0` instead of `1`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260816100000_completions_survive_profile_delete.sql`:

```sql
-- A completion records that a chore was done. Who ticked it off is useful
-- context, not the point of the row.
--
-- `completed_by` cascaded, which meant deleting a parent silently erased every
-- completion that parent had ticked off on a child's behalf — the feature added
-- in 60ac940 and 1e5ce91. The child's history is the data worth keeping; the
-- departing parent's identity is not. Null now means "recorded by someone no
-- longer in the family", which is the truth.
--
-- `completions.profile_id` deliberately keeps cascading: that is the child the
-- chore belonged to, and when a child goes their history goes with them.

alter table public.completions alter column completed_by drop not null;

alter table public.completions drop constraint completions_completed_by_fkey;

alter table public.completions add constraint completions_completed_by_fkey
  foreign key (completed_by) references public.profiles(id) on delete set null;
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: PASS, 17 of 17.

- [ ] **Step 5: Follow the column in the Swift read model**

In `Sources/ChoresCore/Models/Completion.swift`, make the property and its initialiser parameter optional and correct the now-false doc comment:

```swift
    /// Who ticked it off — the child themselves, or a parent doing it for them.
    ///
    /// Null once that person has left the family. Optional only here: every write
    /// path knows the actor by definition, so `ChoresBackend.complete` and
    /// `OutboxOperation.complete` keep the non-optional type.
    public let completedBy: UUID?

    public init(id: UUID, familyID: UUID, profileID: UUID, choreID: UUID,
                dueOn: CalendarDay, completedAt: Date = .init(), completedBy: UUID?) {
```

Change nothing else in the file. Existing call sites pass a non-optional `UUID`, which converts implicitly.

- [ ] **Step 6: Run the Swift tests**

Run: `swift test`
Expected: PASS, 117 tests in 13 suites. If anything fails to compile, it is a call site that reads `completedBy` — the spec says none exists, so investigate rather than force-unwrapping.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260816100000_completions_survive_profile_delete.sql supabase/tests/01_rls_and_rpcs.sql Sources/ChoresCore/Models/Completion.swift
git commit -m "Let a completion outlive the person who recorded it"
```

---

### Task 2: Parents must be signed in

**Files:**
- Create: `supabase/migrations/20260816100100_parents_must_sign_in.sql`
- Test: `supabase/tests/01_rls_and_rpcs.sql`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `public.is_anonymous_caller() returns boolean`. `create_family` raises `parents must sign in` for an anonymous caller. `claim_profile` raises the same when the code's target profile has `role = 'parent'`. `tests.auth_as(p_uid uuid, p_anonymous boolean default false)`.

- [ ] **Step 1: Extend the pgTAP impersonation helper**

The helper sets only `sub` and `role`, so `auth.jwt() ->> 'is_anonymous'` would be null for every existing test. In `supabase/tests/01_rls_and_rpcs.sql`, replace the `tests.auth_as` definition with:

```sql
-- Impersonate an authenticated user for the rest of the transaction.
-- `p_anonymous` mirrors the claim Supabase puts in a real JWT; it defaults to
-- false so every pre-existing assertion keeps the identity it always had.
create function tests.auth_as(p_uid uuid, p_anonymous boolean default false)
returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid::text,
                      'role', 'authenticated',
                      'is_anonymous', p_anonymous)::text, true);
end $$;
```

- [ ] **Step 2: Write the failing assertions**

Change `select plan(17);` to `select plan(21);` and add before the final `select tests.as_admin();`:

```sql
-- A child device is anonymous and must not be able to bootstrap a family.
select tests.auth_as('d0000000-0000-0000-0000-000000000001', true);
select throws_ok(
  $$select public.create_family('Sneaky', 'Kid', 'Europe/Helsinki')$$,
  'parents must sign in',
  'an anonymous caller cannot create a family');

-- The same caller, signed in, may. The auth.users row must exist first:
-- create_family inserts a profile whose auth_user_id references it, so without
-- this the call fails on the foreign key rather than proving anything.
select tests.as_admin();
insert into auth.users (id) values ('d0000000-0000-0000-0000-000000000001');
select tests.auth_as('d0000000-0000-0000-0000-000000000001', false);
select lives_ok(
  $$select public.create_family('Legit', 'Parent', 'Europe/Helsinki')$$,
  'a signed-in caller can create a family');

-- Parent codes require a signed-in claimer; child codes do not.
select tests.as_admin();
insert into auth.users (id) values ('e0000000-0000-0000-0000-000000000001');
insert into public.claim_codes (code, family_id, profile_id, expires_at)
  values ('PARENT', 'f0000000-0000-0000-0000-00000000000a',
          'a0000000-0000-0000-0000-000000000001', now() + interval '1 day');

select tests.auth_as('e0000000-0000-0000-0000-000000000001', true);
select throws_ok(
  $$select public.claim_profile('PARENT')$$,
  'parents must sign in',
  'an anonymous caller cannot claim a parent profile');

select tests.auth_as('e0000000-0000-0000-0000-000000000001', false);
select lives_ok(
  $$select public.claim_profile('PARENT')$$,
  'a signed-in caller can claim a parent profile');
```

Substitute the real fixture UUIDs for the family and the parent profile.

- [ ] **Step 3: Run the suite to verify it fails**

Run: `supabase db reset && supabase test db`
Expected: FAIL — `create_family` currently accepts any authenticated caller, so the first `throws_ok` reports that nothing was raised.

- [ ] **Step 4: Write the migration**

Create `supabase/migrations/20260816100100_parents_must_sign_in.sql`:

```sql
-- A parent profile may only ever be bound to a non-anonymous auth user.
--
-- Enforced here rather than in the app because `auth_user_id` has exactly two
-- writers — create_family() and claim_profile() — since the profiles_insert
-- policy demands `auth_user_id is null` and prevent_auth_user_id_change() blocks
-- every direct UPDATE outside its window. Guard the two functions and the whole
-- model is guarded.
--
-- Children stay anonymous and keep claiming child codes exactly as before.

create or replace function public.is_anonymous_caller()
returns boolean language sql stable
as $$ select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) $$;

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
  if public.is_anonymous_caller() then
    raise exception 'parents must sign in';
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

create or replace function public.claim_profile(p_code text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_norm text := upper(trim(p_code));
  v_profile_id uuid;
  v_expires timestamptz;
  v_claimed timestamptz;
  v_role text;
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

  -- Checked after the code itself, so a bad code still reports why it is bad.
  select role into v_role from public.profiles where id = v_profile_id;
  if v_role = 'parent' and public.is_anonymous_caller() then
    raise exception 'parents must sign in';
  end if;

  perform set_config('app.allow_claim', 'on', true);
  update public.profiles set auth_user_id = auth.uid() where id = v_profile_id;
  update public.claim_codes set claimed_at = now() where code = v_norm;

  return v_profile_id;
end $$;
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: PASS, 21 of 21. All pre-existing assertions must still pass — if any now fail, the `p_anonymous` default is not being applied somewhere.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260816100100_parents_must_sign_in.sql supabase/tests/01_rls_and_rpcs.sql
git commit -m "Require a signed-in caller for anything parent-shaped"
```

---

### Task 3: Leaving a family, and deleting an account

**Files:**
- Create: `supabase/migrations/20260816100200_leave_family_and_delete_account.sql`
- Test: `supabase/tests/01_rls_and_rpcs.sql`

**Interfaces:**
- Consumes: `is_anonymous_caller()` from Task 2; the nullable `completed_by` from Task 1.
- Produces: `public.leave_family() returns void`, `public.delete_account() returns void`.

- [ ] **Step 1: Write the failing assertions**

Change the plan count to `select plan(26);` and add before the final `select tests.as_admin();`:

```sql
-- Leaving with another parent present removes only the leaver.
select tests.as_admin();
insert into auth.users (id) values ('e0000000-0000-0000-0000-000000000002');
insert into public.profiles (family_id, auth_user_id, display_name, role)
  values ('f0000000-0000-0000-0000-00000000000a',
          'e0000000-0000-0000-0000-000000000002', 'Second Parent', 'parent');

select tests.auth_as('e0000000-0000-0000-0000-000000000002', false);
select lives_ok($$select public.leave_family()$$, 'a parent may leave');

select tests.as_admin();
select is(
  (select count(*)::int from public.profiles
     where auth_user_id = 'e0000000-0000-0000-0000-000000000002'),
  0,
  'leaving deletes the profile rather than leaving a ghost seat');
select isnt(
  (select count(*)::int from public.families
     where id = 'f0000000-0000-0000-0000-00000000000a'),
  0,
  'and the family survives because another parent remains');

-- Deleting an account removes the auth user too.
select tests.auth_as('a0000000-0000-0000-0000-000000000001', false);
select lives_ok($$select public.delete_account()$$, 'a parent may delete their account');
select tests.as_admin();
select is(
  (select count(*)::int from auth.users
     where id = 'a0000000-0000-0000-0000-000000000001'),
  0,
  'delete_account removes the auth user');
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `supabase db reset && supabase test db`
Expected: FAIL with `function public.leave_family() does not exist`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260816100200_leave_family_and_delete_account.sql`:

```sql
-- Ways out.
--
-- Making identity durable makes mistakes durable too: before Sign in with Apple
-- a parent could reset by deleting the app, and now they cannot. These are the
-- replacements.
--
-- Leaving deletes the profile outright rather than unbinding it, so no ghost
-- seat is left in People. Because both functions are SECURITY DEFINER the
-- deletion happens server-side and `authenticated` still holds no DELETE grant
-- on profiles — the property asserted in 20260813120000_table_grants.sql.
--
-- Note that nothing here unbinds `auth_user_id`, so claim_profile() remains its
-- only writer and `app.allow_claim` keeps its accurate name.

create or replace function public.leave_family()
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_profile_id uuid;
  v_family_id uuid;
  v_other_parents int;
begin
  select id, family_id into v_profile_id, v_family_id
    from public.profiles where auth_user_id = auth.uid();
  if v_profile_id is null then
    raise exception 'caller has no profile';
  end if;

  select count(*) into v_other_parents
    from public.profiles
    where family_id = v_family_id and role = 'parent' and id <> v_profile_id;

  if v_other_parents = 0 then
    -- Last parent out deletes the family; the cascades clear profiles, chores,
    -- schedule entries, completions and claim codes.
    delete from public.families where id = v_family_id;
  else
    delete from public.profiles where id = v_profile_id;
  end if;
end $$;

create or replace function public.delete_account()
returns void language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  -- A caller with no profile may still delete their account: they signed in and
  -- never joined a family, which is exactly when someone changes their mind.
  if exists (select 1 from public.profiles where auth_user_id = auth.uid()) then
    perform public.leave_family();
  end if;

  delete from auth.users where id = auth.uid();
end $$;
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: PASS, 26 of 26.

- [ ] **Step 5: Add the last-parent case**

Change the plan count to `select plan(27);` and add:

```sql
-- The last parent out takes the family with them.
select tests.as_admin();
insert into auth.users (id) values ('e0000000-0000-0000-0000-000000000003');
insert into public.families (id, name, timezone)
  values ('f0000000-0000-0000-0000-00000000000f', 'Solo', 'Europe/Helsinki');
insert into public.profiles (family_id, auth_user_id, display_name, role)
  values ('f0000000-0000-0000-0000-00000000000f',
          'e0000000-0000-0000-0000-000000000003', 'Only Parent', 'parent');

select tests.auth_as('e0000000-0000-0000-0000-000000000003', false);
select public.leave_family();
select tests.as_admin();
select is(
  (select count(*)::int from public.families
     where id = 'f0000000-0000-0000-0000-00000000000f'),
  0,
  'the last parent leaving deletes the family');
```

- [ ] **Step 6: Run the suite to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: PASS, 27 of 27.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260816100200_leave_family_and_delete_account.sql supabase/tests/01_rls_and_rpcs.sql
git commit -m "Give a parent a way out of a family, and out of the app"
```

---

### Task 4: Deleting a child

**Files:**
- Create: `supabase/migrations/20260816100300_delete_child.sql`
- Test: `supabase/tests/01_rls_and_rpcs.sql`

**Interfaces:**
- Consumes: nothing from Task 3.
- Produces: `public.delete_child(p_profile_id uuid) returns void`.

- [ ] **Step 1: Write the failing assertions**

Change the plan count to `select plan(33);` and add before the final `select tests.as_admin();`:

```sql
-- A parent may delete a child in their own family, history and all.
select tests.auth_as('a0000000-0000-0000-0000-000000000001', false);
select lives_ok(
  $$select public.delete_child('a0000000-0000-0000-0000-000000000002')$$,
  'a parent may delete a child in their family');

select tests.as_admin();
select is(
  (select count(*)::int from public.completions
     where profile_id = 'a0000000-0000-0000-0000-000000000002'),
  0,
  'the deleted child takes their completions with them');
select is(
  (select count(*)::int from public.schedule_entries
     where profile_id = 'a0000000-0000-0000-0000-000000000002'),
  0,
  'and their schedule entries');

-- Scoping: another family's child is out of reach, and a parent is not a child.
select tests.auth_as('a0000000-0000-0000-0000-000000000001', false);
select throws_ok(
  $$select public.delete_child('b0000000-0000-0000-0000-000000000001')$$,
  'profile not in caller family',
  'a parent cannot delete a child in another family');
select throws_ok(
  $$select public.delete_child('a0000000-0000-0000-0000-000000000001')$$,
  'only a child may be deleted',
  'delete_child refuses a parent target');

-- A child cannot use it at all.
select tests.auth_as('a0000000-0000-0000-0000-000000000003', true);
select throws_ok(
  $$select public.delete_child('a0000000-0000-0000-0000-000000000003')$$,
  'only a parent may delete a child',
  'a child cannot delete anyone');
```

Substitute the real fixture UUIDs. If family A has only one child in the fixtures, add a second child and a completion for them at the top of the file so the "other children survive" case in Step 5 has something to check.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `supabase db reset && supabase test db`
Expected: FAIL with `function public.delete_child(uuid) does not exist`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260816100300_delete_child.sql`:

```sql
-- Removing a child, history included.
--
-- Until now a profile could not be removed at all, which was a gap rather than a
-- policy: PeopleView said as much in a comment. Adding a parent's ability to
-- leave without this would have shipped an asymmetry — parents can go, children
-- are permanent.
--
-- Deletion is total and immediate. The cascades are all wanted: the child's
-- schedule_entries, their claim_codes, and their completions via
-- completions.profile_id. `completed_by` going null is for departing parents
-- only — a child can only ever be completed_by themselves, because the
-- completions_insert policy allows `is_parent() or profile_id = current_profile_id()`,
-- and those rows are removed by the profile_id cascade anyway.
--
-- Refusing a parent target is deliberate: removing another parent is a separate
-- question about who may evict whom, and this must not quietly become its tool.
--
-- 20260813120000_table_grants.sql says "No DELETE: a profile is archived by the
-- parent, never removed." Withholding the grant is still right — deletion goes
-- through this SECURITY DEFINER function, never through a client — but the
-- reason given there was wrong: no archive flag ever existed on profiles, and
-- profiles simply could not be removed at all.

create or replace function public.delete_child(p_profile_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_family_id uuid;
  v_role text;
begin
  if not public.is_parent() then
    raise exception 'only a parent may delete a child';
  end if;

  select family_id, role into v_family_id, v_role
    from public.profiles where id = p_profile_id;

  if v_family_id is null or v_family_id <> public.current_family_id() then
    raise exception 'profile not in caller family';
  end if;
  if v_role <> 'child' then
    raise exception 'only a child may be deleted';
  end if;

  delete from public.profiles where id = p_profile_id;
end $$;
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: PASS, 33 of 33.

- [ ] **Step 5: Assert the blast radius is bounded**

The cascade is scoped by `completions.profile_id`; a mistake there would be silent. Change the plan count to `select plan(34);` and add, immediately after the "takes their completions with them" assertion:

```sql
select isnt(
  (select count(*)::int from public.completions
     where profile_id = 'a0000000-0000-0000-0000-000000000004'),
  0,
  'deleting one child leaves another child''s completions alone');
```

Use the second child's UUID from the fixtures.

- [ ] **Step 6: Run the suite to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: PASS, 34 of 34.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260816100300_delete_child.sql supabase/tests/01_rls_and_rpcs.sql
git commit -m "Let a parent delete a child, history included"
```

---

### Task 5: `DeviceIdentity` and the session protocol

**Files:**
- Modify: `Sources/ChoresCore/Repositories/Repositories.swift`
- Modify: `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift`
- Modify: `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift`
- Modify: `Tests/ChoresCoreTests/TestDoubles.swift`
- Test: `Tests/ChoresCoreTests/InMemoryBackendTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  ```swift
  public enum DeviceIdentity: Equatable, Sendable { case none, anonymous, signedIn }
  func currentIdentity() async throws -> DeviceIdentity
  func signInAnonymously() async throws
  func signInWithApple(idToken: String, nonce: String) async throws
  func signOut() async throws
  ```
  `signInAnonymouslyIfNeeded()` is **removed**. Task 7 updates its only caller.

- [ ] **Step 1: Write the failing test**

Add to `Tests/ChoresCoreTests/InMemoryBackendTests.swift`:

```swift
@Test func identityStartsAtNoneAndFollowsHowYouSignedIn() async throws {
    let backend = InMemoryChoresBackend()
    #expect(try await backend.currentIdentity() == .none)

    try await backend.signInAnonymously()
    #expect(try await backend.currentIdentity() == .anonymous)

    try await backend.signOut()
    #expect(try await backend.currentIdentity() == .none)

    try await backend.signInWithApple(idToken: "token", nonce: "nonce")
    #expect(try await backend.currentIdentity() == .signedIn)
}

/// The same Apple identity must resolve to the same user, or a reinstall would
/// look like a new person and the whole feature would be pointless.
@Test func signingInWithTheSameAppleTokenTwiceIsTheSamePerson() async throws {
    let backend = InMemoryChoresBackend()
    try await backend.signInWithApple(idToken: "ari", nonce: "n1")
    _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                       timezone: "Europe/Helsinki")

    try await backend.signOut()
    try await backend.signInWithApple(idToken: "ari", nonce: "n2")

    let profile = try #require(try await backend.currentProfile())
    #expect(profile.displayName == "Parent")
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter InMemoryBackendTests`
Expected: FAIL to compile — `currentIdentity`, `signInAnonymously`, `signInWithApple` and `signOut` do not exist.

- [ ] **Step 3: Change the protocol**

In `Sources/ChoresCore/Repositories/Repositories.swift`, add above the protocol:

```swift
/// What kind of identity this device currently holds.
///
/// The distinction is drawn from the session's `is_anonymous` claim rather than
/// from which provider was used: the database rule is about durability of
/// identity, not about Apple. Apple is simply the only way a person can obtain
/// a `.signedIn` session today.
public enum DeviceIdentity: Equatable, Sendable {
    case none
    case anonymous
    case signedIn
}
```

and replace the `// MARK: Session` block:

```swift
    // MARK: Session

    func currentIdentity() async throws -> DeviceIdentity
    /// A child device. Parents never take this path.
    func signInAnonymously() async throws
    /// The token and nonce come from `AuthenticationServices` in the app target;
    /// this layer never imports it.
    func signInWithApple(idToken: String, nonce: String) async throws
    func signOut() async throws
    /// The profile bound to the current session, or nil if this device is unclaimed.
    func currentProfile() async throws -> Profile?
```

- [ ] **Step 4: Implement in the in-memory backend**

In `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift`, add to `Store`:

```swift
        /// Apple identity token -> the auth user it resolves to, so signing in
        /// twice with the same token is the same person, as it is for real.
        var appleUsers: [String: UUID] = [:]
```

and replace the `// MARK: Session` block:

```swift
    // MARK: Session

    var sessionIsAnonymous = false

    public func currentIdentity() async throws -> DeviceIdentity {
        guard sessionUserID != nil else { return .none }
        return sessionIsAnonymous ? .anonymous : .signedIn
    }

    public func signInAnonymously() async throws {
        sessionUserID = UUID()
        sessionIsAnonymous = true
    }

    public func signInWithApple(idToken: String, nonce: String) async throws {
        sessionUserID = withStore { store in
            if let existing = store.appleUsers[idToken] { return existing }
            let created = UUID()
            store.appleUsers[idToken] = created
            return created
        }
        sessionIsAnonymous = false
    }

    public func signOut() async throws {
        sessionUserID = nil
        sessionIsAnonymous = false
    }
```

- [ ] **Step 5: Implement in the Supabase backend**

In `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift`, replace `signInAnonymouslyIfNeeded()` with the following. The disowned-session detection is preserved from `c471444` but its response changes: it can no longer silently mint a session, because a parent cannot be silently re-authenticated against Apple.

```swift
    public func currentIdentity() async throws -> DeviceIdentity {
        try await run {
            guard let session = client.auth.currentSession else { return .none }
            // A stored session can name a user the server no longer has:
            // `supabase db reset` in development, a restore from backup in
            // production. Verifying costs one request per launch and is the only
            // way to tell a live session from a hollow one.
            do {
                _ = try await client.auth.user()
            } catch {
                // Only a refusal counts. A device that is merely offline keeps
                // the session it will need the moment the network returns.
                guard let authError = error as? AuthError,
                      Self.serverDisownsSession(authError) else {
                    return session.user.isAnonymous == true ? .anonymous : .signedIn
                }
                try? await client.auth.signOut()
                return .none
            }
            return session.user.isAnonymous == true ? .anonymous : .signedIn
        }
    }

    public func signInAnonymously() async throws {
        try await run { _ = try await client.auth.signInAnonymously() }
    }

    public func signInWithApple(idToken: String, nonce: String) async throws {
        try await run {
            _ = try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: nonce))
        }
    }

    public func signOut() async throws {
        try await run { try await client.auth.signOut() }
    }
```

Keep `serverDisownsSession(_:)` exactly as it is.

- [ ] **Step 6: Update the test doubles**

In `Tests/ChoresCoreTests/TestDoubles.swift`, replace `UnavailableBackend`'s two session methods and add the new ones:

```swift
    func currentIdentity() async throws -> DeviceIdentity { throw error }
    func signInAnonymously() async throws { throw error }
    func signInWithApple(idToken: String, nonce: String) async throws { throw error }
    func signOut() async throws { throw error }
    func currentProfile() async throws -> Profile? { throw error }
```

`ForwardingBackend` and `FlakyBackend` subclass `InMemoryChoresBackend`, so they inherit the new methods and need no change.

- [ ] **Step 7: Run the tests**

Run: `swift test`
Expected: FAIL — `SessionViewModel` still calls `signInAnonymouslyIfNeeded()`. Fix it minimally so the package compiles by replacing that one call with:

```swift
            if try await backend.currentIdentity() == .none {
                try await backend.signInAnonymously()
            }
```

Task 7 replaces this properly. Re-run `swift test`; expected PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/ChoresCore Tests/ChoresCoreTests
git commit -m "Describe which identity a device holds, not merely that it has one"
```

---

### Task 6: Membership actions on the protocol

**Files:**
- Modify: `Sources/ChoresCore/Repositories/Repositories.swift`
- Modify: `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift`
- Modify: `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift`
- Modify: `Tests/ChoresCoreTests/TestDoubles.swift`
- Test: `Tests/ChoresCoreTests/InMemoryBackendTests.swift`

**Interfaces:**
- Consumes: `DeviceIdentity` from Task 5; the RPCs from Tasks 3 and 4.
- Produces: `func leaveFamily() async throws`, `func deleteAccount() async throws`, `func deleteChild(profileID: UUID) async throws`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/ChoresCoreTests/InMemoryBackendTests.swift`:

```swift
@Test func leavingRemovesYouAndFreesYouToStartAgain() async throws {
    let backend = InMemoryChoresBackend()
    try await backend.signInWithApple(idToken: "ari", nonce: "n")
    _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                       timezone: "Europe/Helsinki")

    try await backend.leaveFamily()

    #expect(try await backend.currentProfile() == nil)
    // The point of leaving: create_family refuses a caller who already has a
    // profile, so leaving must actually clear it.
    _ = try await backend.createFamily(familyName: "Uusi", parentName: "Parent",
                                       timezone: "Europe/Helsinki")
    #expect(try await backend.currentProfile() != nil)
}

@Test func deletingAChildTakesTheirCompletionsAndLeavesSiblingsAlone() async throws {
    let backend = InMemoryChoresBackend()
    try await backend.signInWithApple(idToken: "ari", nonce: "n")
    let familyID = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                                  timezone: "Europe/Helsinki")
    let doomed = try await backend.addChild(familyID: familyID, name: "A",
                                            color: "#FF8800", sortOrder: 0)
    let sibling = try await backend.addChild(familyID: familyID, name: "B",
                                             color: "#1DB954", sortOrder: 1)
    let chore = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)
    let monday = CalendarDay(year: 2026, month: 8, day: 10)
    try await backend.complete(familyID: familyID, profileID: doomed.id, choreID: chore.id,
                               dueOn: monday, completedBy: doomed.id)
    try await backend.complete(familyID: familyID, profileID: sibling.id, choreID: chore.id,
                               dueOn: monday, completedBy: sibling.id)

    try await backend.deleteChild(profileID: doomed.id)

    let snapshot = try await backend.fetchSnapshot(familyID: familyID, weekOf: monday)
    #expect(!snapshot.profiles.contains { $0.id == doomed.id })
    #expect(snapshot.completions.count == 1)
    #expect(snapshot.completions.first?.profileID == sibling.id)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter InMemoryBackendTests`
Expected: FAIL to compile — `leaveFamily` and `deleteChild` do not exist.

- [ ] **Step 3: Add to the protocol**

In `Repositories.swift`, under the `// MARK: People` section:

```swift
    /// Removes the caller's own profile. Deletes the family too when no other
    /// parent remains, since a family with no parent cannot be administered.
    func leaveFamily() async throws
    /// `leaveFamily()`, then removes the auth user. Required by App Review
    /// guideline 5.1.1(v) once an app supports account creation.
    func deleteAccount() async throws
    /// Deletes a child and everything they have ever ticked off. Irreversible.
    func deleteChild(profileID: UUID) async throws
```

- [ ] **Step 4: Implement in the in-memory backend**

```swift
    public func leaveFamily() async throws {
        guard let profile = try await currentProfile() else {
            throw ChoresBackendError.notAuthenticated
        }
        withStore { store in
            let otherParents = store.profiles.values.filter {
                $0.familyID == profile.familyID && $0.role == .parent && $0.id != profile.id
            }
            if otherParents.isEmpty {
                Self.deleteFamily(profile.familyID, in: store)
            } else {
                Self.deleteProfile(profile.id, in: store)
            }
        }
    }

    public func deleteAccount() async throws {
        if try await currentProfile() != nil { try await leaveFamily() }
        withStore { store in
            if let userID = sessionUserID {
                store.appleUsers = store.appleUsers.filter { $0.value != userID }
            }
        }
        try await signOut()
    }

    public func deleteChild(profileID: UUID) async throws {
        guard let me = try await currentProfile(), me.role == .parent else {
            throw ChoresBackendError.underlying("only a parent may delete a child")
        }
        let target = withStore { $0.profiles[profileID] }
        guard let target, target.familyID == me.familyID else {
            throw ChoresBackendError.underlying("profile not in caller family")
        }
        guard target.role == .child else {
            throw ChoresBackendError.underlying("only a child may be deleted")
        }
        withStore { Self.deleteProfile(profileID, in: $0) }
    }

    /// Mirrors the database's `on delete cascade` from `profiles`.
    private static func deleteProfile(_ id: UUID, in store: Store) {
        store.profiles[id] = nil
        store.completions.removeAll { $0.profileID == id }
        store.template = store.template.filter { $0.value.profileID != id }
        store.claimCodes = store.claimCodes.filter { $0.value.profileID != id }
        // `completed_by` is `on delete set null`, not a cascade.
        store.completions = store.completions.map {
            $0.completedBy == id
                ? Completion(id: $0.id, familyID: $0.familyID, profileID: $0.profileID,
                             choreID: $0.choreID, dueOn: $0.dueOn,
                             completedAt: $0.completedAt, completedBy: nil)
                : $0
        }
    }

    /// Mirrors the database's `on delete cascade` from `families`.
    private static func deleteFamily(_ id: UUID, in store: Store) {
        for profile in store.profiles.values where profile.familyID == id {
            deleteProfile(profile.id, in: store)
        }
        store.chores = store.chores.filter { $0.value.familyID != id }
        store.template = store.template.filter { $0.value.familyID != id }
        store.completions.removeAll { $0.familyID == id }
        store.families[id] = nil
    }
```

- [ ] **Step 5: Implement in the Supabase backend**

```swift
    public func leaveFamily() async throws {
        try await run { _ = try await client.rpc("leave_family").execute() }
    }

    public func deleteAccount() async throws {
        try await run { _ = try await client.rpc("delete_account").execute() }
        // The session now names a user that no longer exists. Clearing it here
        // saves `currentIdentity()` a round trip to discover that.
        try? await client.auth.signOut()
    }

    public func deleteChild(profileID: UUID) async throws {
        try await run {
            _ = try await client
                .rpc("delete_child", params: ["p_profile_id": profileID])
                .execute()
        }
    }
```

- [ ] **Step 6: Update the test doubles**

Add to `UnavailableBackend` in `TestDoubles.swift`:

```swift
    func leaveFamily() async throws { throw error }
    func deleteAccount() async throws { throw error }
    func deleteChild(profileID: UUID) async throws { throw error }
```

- [ ] **Step 7: Run the tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/ChoresCore Tests/ChoresCoreTests
git commit -m "Add leaving, account deletion and child deletion to the backend"
```

---

### Task 7: `SessionState` splits, and `RootView` routes the new cases

**Files:**
- Modify: `Sources/ChoresCore/ViewModels/SessionViewModel.swift`
- Modify: `App/Chores/RootView.swift`
- Test: `Tests/ChoresCoreTests/SessionViewModelTests.swift`

**Interfaces:**
- Consumes: `DeviceIdentity` and `currentIdentity()` from Task 5.
- Produces: `SessionState.signedOut` and `SessionState.parentWithoutFamily`. `.unclaimed` now means specifically "anonymous identity, no profile". `SessionViewModel.start()` no longer signs anyone in.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ChoresCoreTests/SessionViewModelTests.swift`:

```swift
/// Launch must not mint an identity for someone who has not said who they are.
/// A parent device that did so would leave an orphaned anonymous user behind on
/// every first run.
@Test func startWithNoIdentityYieldsSignedOutWithoutSigningAnyoneIn() async throws {
    let backend = InMemoryChoresBackend()
    let model = SessionViewModel(backend: backend)

    await model.start()

    #expect(model.state == .signedOut)
    #expect(try await backend.currentIdentity() == .none)
}

@Test func anAppleIdentityWithNoProfileWantsToStartOrJoinAFamily() async throws {
    let backend = InMemoryChoresBackend()
    try await backend.signInWithApple(idToken: "ari", nonce: "n")

    let model = SessionViewModel(backend: backend)
    await model.start()

    #expect(model.state == .parentWithoutFamily)
}

@Test func anAnonymousIdentityWithNoProfileIsAwaitingACode() async throws {
    let backend = InMemoryChoresBackend()
    try await backend.signInAnonymously()

    let model = SessionViewModel(backend: backend)
    await model.start()

    #expect(model.state == .unclaimed)
}
```

Then update `startWithNoProfileYieldsUnclaimed` — a fresh backend now yields `.signedOut`, so that test is superseded by the first one above. Delete it.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SessionViewModelTests`
Expected: FAIL to compile — `.signedOut` and `.parentWithoutFamily` do not exist.

- [ ] **Step 3: Add the cases**

In `Sources/ChoresCore/ViewModels/SessionViewModel.swift`:

```swift
    /// No identity at all. The device has not said whether it belongs to a
    /// parent or a child, and nothing has been signed in on its behalf.
    case signedOut
    /// Signed in with Apple, but bound to no profile — either a genuinely new
    /// parent, or one who has just left a family.
    case parentWithoutFamily
```

Keep `.unclaimed`, and narrow its doc comment to "an anonymous device that has not yet claimed a code".

- [ ] **Step 4: Rewrite `start()` and `load()`**

```swift
    public func start() async {
        state = .loading
        await refresh()
    }

    /// Re-reads identity and profile without resetting to `.loading`. Called
    /// after onboarding completes and after any action that changes membership.
    public func refresh() async {
        do {
            try await load()
        } catch {
            state = Self.failure(for: error)
        }
    }

    private func load() async throws {
        let identity = try await backend.currentIdentity()
        guard identity != .none else {
            state = .signedOut
            return
        }
        guard let profile = try await backend.currentProfile() else {
            state = identity == .signedIn ? .parentWithoutFamily : .unclaimed
            return
        }
        state = profile.role == .parent ? .parent(profile) : .child(profile)
    }
```

`start()` now delegates to `refresh()` after showing `.loading`; the duplicated `do/catch` goes away. Leave `failure(for:)` untouched.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter SessionViewModelTests`
Expected: PASS.

- [ ] **Step 6: Route the new cases**

`App/Chores/RootView.swift` will not compile until the switch is exhaustive. Replace the `.unclaimed` case block with:

```swift
            case .signedOut:
                OnboardingView(environment: environment) {
                    await session.refresh()
                }
            case .parentWithoutFamily:
                ParentSetupView(environment: environment) {
                    await session.refresh()
                }
            case .unclaimed:
                if !hasBeenClaimed {
                    NavigationStack {
                        ClaimCodeView(environment: environment) {
                            await session.refresh()
                        }
                    }
                } else if isReclaiming {
                    NavigationStack {
                        ClaimCodeView(environment: environment) {
                            await session.refresh()
                        }
                    }
                } else {
                    LostSessionView(onReclaim: { isReclaiming = true },
                                    onStartOver: { hasBeenClaimed = false })
                }
```

`ParentSetupView` does not exist yet. Create a placeholder in `App/Chores/Onboarding/ParentSetupView.swift` so the target builds; Task 10 fills it in:

```swift
import SwiftUI
import ChoresCore

/// Signed in, but not yet in a family. Filled in by Task 10.
struct ParentSetupView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    var body: some View { ProgressView() }
}
```

- [ ] **Step 7: Build the app**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Sources/ChoresCore/ViewModels/SessionViewModel.swift Tests/ChoresCoreTests/SessionViewModelTests.swift App/Chores/RootView.swift App/Chores/Onboarding/ParentSetupView.swift
git commit -m "Tell no-identity apart from identity-without-a-family"
```

---

### Task 8: Onboarding acquires identity on demand

**Files:**
- Modify: `Sources/ChoresCore/ViewModels/OnboardingViewModel.swift`
- Test: `Tests/ChoresCoreTests/OnboardingViewModelTests.swift`

**Interfaces:**
- Consumes: `currentIdentity()` and `signInAnonymously()` from Task 5.
- Produces: `OnboardingViewModel.claim()` signs in anonymously first when the device holds no identity, and leaves an existing identity alone.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ChoresCoreTests/OnboardingViewModelTests.swift`:

```swift
/// The child door is the only place an anonymous identity is created now that
/// launch no longer does it.
@Test func claimingSignsInAnonymouslyWhenTheDeviceHasNoIdentity() async throws {
    let parentBackend = InMemoryChoresBackend()
    try await parentBackend.signInWithApple(idToken: "ari", nonce: "n")
    let familyID = try await parentBackend.createFamily(
        familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
    let child = try await parentBackend.addChild(familyID: familyID, name: "Kid",
                                                 color: "#FF8800", sortOrder: 0)
    let code = try await parentBackend.generateClaimCode(profileID: child.id)

    let kidBackend = parentBackend.newDevice()
    let model = OnboardingViewModel(backend: kidBackend)
    model.code = code

    #expect(await model.claim())
    #expect(try await kidBackend.currentIdentity() == .anonymous)
}

/// A second parent reaches the same screen already signed in. Signing them in
/// anonymously would throw away the identity that makes them a parent.
@Test func claimingLeavesAnExistingIdentityAlone() async throws {
    let parentBackend = InMemoryChoresBackend()
    try await parentBackend.signInWithApple(idToken: "ari", nonce: "n")
    let familyID = try await parentBackend.createFamily(
        familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
    let second = try await parentBackend.addParent(familyID: familyID, name: "Other")
    let code = try await parentBackend.generateClaimCode(profileID: second.id)

    let secondDevice = parentBackend.newDevice()
    try await secondDevice.signInWithApple(idToken: "other", nonce: "n")
    let model = OnboardingViewModel(backend: secondDevice)
    model.code = code

    #expect(await model.claim())
    #expect(try await secondDevice.currentIdentity() == .signedIn)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter OnboardingViewModelTests`
Expected: FAIL — the first test's claim fails because the device has no session, so `claimProfile` throws `notAuthenticated`.

- [ ] **Step 3: Acquire the identity inside `claim()`**

In `OnboardingViewModel.claim()`, inside the `do` block and before `claimProfile`:

```swift
        do {
            // A child arrives here with no identity; a second parent arrives
            // already signed in with Apple. Only the former needs one minting,
            // and minting one for the latter would discard what makes them a
            // parent.
            if try await backend.currentIdentity() == .none {
                try await backend.signInAnonymously()
            }
            _ = try await backend.claimProfile(code: trimmed)
            return true
        } catch {
```

- [ ] **Step 4: Run the tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ChoresCore/ViewModels/OnboardingViewModel.swift Tests/ChoresCoreTests/OnboardingViewModelTests.swift
git commit -m "Mint a child's anonymous identity when they claim, not at launch"
```

---

### Task 9: Sign in with Apple in the app

**Files:**
- Create: `App/Chores/Auth/AppleTokenProviding.swift`
- Create: `App/Chores/Auth/AppleSignInProvider.swift`
- Create: `App/Chores/Onboarding/ParentSignInView.swift`
- Modify: `App/Chores/AppEnvironment.swift`
- Modify: `App/Chores/Onboarding/OnboardingView.swift`

**Interfaces:**
- Consumes: `signInWithApple(idToken:nonce:)` from Task 5.
- Produces: `AppleToken` (`idToken`, `nonce`), `protocol AppleTokenProviding { var presentsSystemUI: Bool { get }; func requestToken() async throws -> AppleToken }`, `AppEnvironment.appleTokens: any AppleTokenProviding`, and `ParentSignInView(environment:onFinished:)`.

- [ ] **Step 1: Define the seam**

Create `App/Chores/Auth/AppleTokenProviding.swift`:

```swift
import Foundation

struct AppleToken: Equatable, Sendable {
    let idToken: String
    let nonce: String
}

/// Where the Apple identity token comes from.
///
/// A seam rather than a direct call, because Apple's sheet is system UI that
/// XCTest cannot drive: every parent UI test would otherwise stall on it. The
/// stub under `-ui-testing` returns a canned token that `InMemoryChoresBackend`
/// accepts like any other.
protocol AppleTokenProviding: Sendable {
    /// False when tapping goes nowhere near Apple, so the view can render an
    /// ordinary button instead of one that promises a sheet it will not show.
    var presentsSystemUI: Bool { get }
    func requestToken() async throws -> AppleToken
}

/// Always the same token, so a relaunch in a UI test is the same person.
struct StubAppleTokenProvider: AppleTokenProviding {
    let presentsSystemUI = false
    func requestToken() async throws -> AppleToken {
        AppleToken(idToken: "ui-testing-parent", nonce: "ui-testing-nonce")
    }
}
```

- [ ] **Step 2: Implement the real provider**

Create `App/Chores/Auth/AppleSignInProvider.swift`:

```swift
import AuthenticationServices
import CryptoKit
import Foundation

/// Drives `ASAuthorizationController` and returns the identity token.
///
/// The nonce is sent to Apple hashed and to Supabase raw; Supabase re-hashes it
/// and compares, which is what stops a token captured elsewhere being replayed
/// here. Apple's name and email are deliberately ignored — they arrive only on
/// the very first authorization for an Apple ID, so anything built on them
/// breaks after a reinstall.
final class AppleSignInProvider: NSObject, AppleTokenProviding,
                                 ASAuthorizationControllerDelegate, @unchecked Sendable {
    let presentsSystemUI = true

    private var continuation: CheckedContinuation<AppleToken, Error>?
    private var currentNonce = ""

    func requestToken() async throws -> AppleToken {
        let nonce = Self.randomNonce()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        request.nonce = Self.sha256(nonce)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let data = credential.identityToken,
            let token = String(data: data, encoding: .utf8)
        else {
            continuation?.resume(throwing: ChoresBackendError.underlying(
                "Apple returned no identity token."))
            continuation = nil
            return
        }
        continuation?.resume(returning: AppleToken(idToken: token, nonce: currentNonce))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private static func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
```

Add `import ChoresCore` at the top if `ChoresBackendError` is not otherwise visible.

- [ ] **Step 3: Supply it from the environment**

In `App/Chores/AppEnvironment.swift`, add a stored property and set it in both factories:

```swift
    let appleTokens: any AppleTokenProviding
```

Extend `init` with `appleTokens: any AppleTokenProviding` and assign it. In `live()`, pass `isUITesting ? StubAppleTokenProvider() : AppleSignInProvider()`. In `preview()`, pass `StubAppleTokenProvider()`. Update the three `AppEnvironment(...)` call sites inside `live()` to include the new argument.

- [ ] **Step 4: Build the sign-in screen**

Create `App/Chores/Onboarding/ParentSignInView.swift`:

```swift
import AuthenticationServices
import SwiftUI
import ChoresCore

/// The parent door. Everything a parent does begins here, because their family
/// hangs off their Apple ID rather than off this device.
struct ParentSignInView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.badge.key")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Sign in to keep your family")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("""
                Signing in with Apple is what lets your family come back if this \
                phone is replaced, wiped, or the app is reinstalled.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }

            Spacer()

            if environment.appleTokens.presentsSystemUI {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = []
                } onCompletion: { _ in
                    // The provider drives its own controller; this button only
                    // supplies Apple's required appearance and hit target.
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .allowsHitTesting(false)
                .overlay {
                    Button { Task { await signIn() } } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel("Sign in with Apple")
                    .accessibilityIdentifier("parentSignIn.button")
                }
            } else {
                Button("Sign in with Apple") { Task { await signIn() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("parentSignIn.button")
            }
        }
        .disabled(isBusy)
        .padding(32)
        .navigationTitle("Parent")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func signIn() async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            let token = try await environment.appleTokens.requestToken()
            try await environment.backend.signInWithApple(idToken: token.idToken,
                                                          nonce: token.nonce)
            await onFinished()
        } catch is CancellationError {
            // The user backed out of Apple's sheet; nothing to report.
        } catch {
            errorMessage = "Couldn't sign in. Please try again."
        }
    }
}
```

- [ ] **Step 5: Point the parent door at it**

In `App/Chores/Onboarding/OnboardingView.swift`, change the first `NavigationLink`'s destination from `CreateFamilyView` to:

```swift
                NavigationLink("I'm a parent") {
                    ParentSignInView(environment: environment, onFinished: onFinished)
                }
```

Leave its accessibility identifier `onboarding.parent` unchanged so existing UI tests keep finding it.

- [ ] **Step 6: Fill in `ParentSetupView`**

Task 7 left this as a `ProgressView()` placeholder. It has to be real before Step 7 points every
parent UI test at its button, or the whole parent suite ends this task red.

```swift
import SwiftUI
import ChoresCore

/// Signed in, but in no family yet — a new parent, or one who has just left.
/// The app cannot tell which, and does not need to: both choices are offered.
struct ParentSetupView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "house")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("You're signed in")
                    .font(.title2.bold())
                Text("Start a new family, or join one you've been given a code for.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()

                NavigationLink("Start a family") {
                    CreateFamilyView(environment: environment, onFinished: onFinished)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("parentSetup.createFamily")

                NavigationLink("I have a code") {
                    ClaimCodeView(environment: environment, onFinished: onFinished)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("parentSetup.claimCode")
            }
            .padding(32)
        }
    }
}
```

- [ ] **Step 7: Repair every parent UI test**

`ParentUITestCase.launchIntoParentMode()` taps `onboarding.parent` and then expects
`createFamily.familyName` immediately. There are now two screens in between, so **every parent UI
test fails without this**. In `App/ChoresUITests/ParentUITestCase.swift`, replace the two lines
after the `onboarding.parent` tap with:

```swift
        XCTAssertTrue(app.buttons["onboarding.parent"].waitForExistence(timeout: 10))
        app.buttons["onboarding.parent"].tap()

        // Under `-ui-testing` this is an ordinary button backed by
        // StubAppleTokenProvider — Apple's own sheet is system UI that XCTest
        // cannot tap.
        let signIn = app.buttons["parentSignIn.button"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()

        let startFamily = app.buttons["parentSetup.createFamily"]
        XCTAssertTrue(startFamily.waitForExistence(timeout: 10),
                      "signing in with no family should offer to start one")
        startFamily.tap()

        let familyName = app.textFields["createFamily.familyName"]
```

Everything from `XCTAssertTrue(familyName.waitForExistence(timeout: 5))` onwards is unchanged.

- [ ] **Step 8: Build and run the full UI suite**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`
Expected: TEST SUCCEEDED. Every parent test now walks through sign-in; a stall on a system sheet
means the stub provider is not being selected, so check `AppEnvironment.live()` reads
`isUITesting`.

- [ ] **Step 9: Commit**

```bash
git add App/Chores/Auth App/Chores/Onboarding App/Chores/AppEnvironment.swift App/ChoresUITests/ParentUITestCase.swift
git commit -m "Sign a parent in with Apple"
```

---

### Task 10: A lost device gets a way back

**Files:**
- Modify: `App/Chores/Failure/LostSessionView.swift`
- Modify: `App/Chores/RootView.swift`

**Interfaces:**
- Consumes: `ParentSignInView` from Task 9.
- Produces: `LostSessionView(onReclaim:onSignIn:)` — the `onStartOver` parameter is **replaced**, not added to.

- [ ] **Step 1: Rework `LostSessionView`**

Its "Set up as a new family" button would now fail outright: the caller is anonymous and `create_family` refuses them. Replace the escape hatch with the one that works.

```swift
/// Shown when an anonymous device that was set up no longer maps to a profile.
///
/// A claim code is the usual remedy, so it leads. Signing in is offered second:
/// if this is really a parent's device, their family is one sign-in away, and
/// without it a family that has genuinely gone would leave this screen a dead
/// end. A child can no longer start a family here by mistake — the database
/// refuses an anonymous caller — which is what the old wording was worried about.
struct LostSessionView: View {
    let onReclaim: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("This device isn't set up", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Ask a parent to open Manage → People and show you a new code.")
        } actions: {
            VStack(spacing: 16) {
                Button("Enter a code") { onReclaim() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("lostSession.reclaim")

                Button("I'm a parent — sign in") { onSignIn() }
                    .font(.footnote)
                    .accessibilityIdentifier("lostSession.signIn")
            }
        }
    }
}

#Preview { LostSessionView(onReclaim: {}, onSignIn: {}) }
```

The `@State private var isConfirmingStartOver` and its `confirmationDialog` are deleted with the old button.

- [ ] **Step 2: Wire the new callback**

In `App/Chores/RootView.swift`, add `@State private var isSigningIn = false`, and in the `.unclaimed` branch replace the `LostSessionView` construction with:

```swift
                } else if isSigningIn {
                    NavigationStack {
                        ParentSignInView(environment: environment) {
                            await session.refresh()
                        }
                    }
                } else {
                    LostSessionView(onReclaim: { isReclaiming = true },
                                    onSignIn: { isSigningIn = true })
                }
```

The `hasBeenClaimed = false` reset that `onStartOver` performed is no longer reachable from this screen; leave the `@AppStorage` property and its `onChange` writer alone.

- [ ] **Step 3: Check the UI tests that touch this screen**

Run: `grep -rn "lostSession" App/ChoresUITests`
`LostSessionUITests` asserts on `lostSession.startOver`. Update it to tap `lostSession.signIn` and assert that `parentSignIn.button` appears, replacing the assertion that it reaches onboarding.

- [ ] **Step 4: Build and run the UI suite**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ChoresUITests/LostSessionUITests test`
Expected: TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/Chores/Failure/LostSessionView.swift App/Chores/RootView.swift App/ChoresUITests/LostSessionUITests.swift
git commit -m "Offer a signed-in parent a family, and a lost device a way back"
```

---

### Task 11: Sign out, leave, and delete account in Manage

**Files:**
- Modify: `App/Chores/Parent/ParentRootView.swift`
- Modify: `App/Chores/RootView.swift`

**Interfaces:**
- Consumes: `leaveFamily()`, `deleteAccount()`, `signOut()` from Tasks 5 and 6.
- Produces: `ManageView(store:backend:parent:onSessionChanged:)` — a new trailing parameter the caller must supply.

- [ ] **Step 1: Add the actions**

In `ManageView`, add `let onSessionChanged: () async -> Void`, plus state and a section below the existing code section:

```swift
    @State private var isConfirmingLeave = false
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    private var isLastParent: Bool { (store.snapshot?.parents.count ?? 1) <= 1 }
```

```swift
                Section {
                    Button("Sign out") {
                        Task { await perform { try await backend.signOut() } }
                    }
                    .accessibilityIdentifier("manage.signOut")

                    Button("Leave this family", role: .destructive) {
                        isConfirmingLeave = true
                    }
                    .accessibilityIdentifier("manage.leave")

                    Button("Delete account", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .accessibilityIdentifier("manage.deleteAccount")
                } footer: {
                    Text(isLastParent
                         ? "You're the only parent, so leaving or deleting your account removes the whole family."
                         : "Signing out keeps your place. Leaving gives it up.")
                }
```

and the dialogs, attached beside the existing `.sheet`:

```swift
            .confirmationDialog("Leave this family?",
                                isPresented: $isConfirmingLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) {
                    Task { await perform { try await backend.leaveFamily() } }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(isLastParent
                     ? "You're the only parent, so this deletes the family, the children, the chores and all their history. This cannot be undone."
                     : "You'll be removed from this family. The other parent can give you a new code if you want back in.")
            }
            .confirmationDialog("Delete your account?",
                                isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    Task { await perform { try await backend.deleteAccount() } }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(isLastParent
                     ? "This deletes your Apple sign-in for Chores and the whole family with it. This cannot be undone."
                     : "This deletes your Apple sign-in for Chores and removes you from the family. This cannot be undone.")
            }
            .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
```

and the helper:

```swift
    /// Every one of these ends the session, so the root has to re-read it —
    /// staying on a Manage screen for a family you just left would be a ghost.
    private func perform(_ action: @escaping () async throws -> Void) async {
        do {
            try await action()
            await onSessionChanged()
        } catch {
            errorMessage = "Couldn't do that. Check your connection and try again."
        }
    }
```

- [ ] **Step 2: Pass the callback down**

In `ParentRootView`'s body:

```swift
            ManageView(store: store, backend: environment.backend, parent: profile,
                       onSessionChanged: onSessionChanged)
```

Add `let onSessionChanged: () async -> Void` to `ParentRootView`, and in `RootView` construct it as:

```swift
            case .parent(let profile):
                ParentRootView(environment: environment, profile: profile) {
                    await session.refresh()
                }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Write a UI test**

Create `App/ChoresUITests/ManageSessionUITests.swift`:

```swift
import XCTest

final class ManageSessionUITests: ParentUITestCase {

    func testSigningOutReturnsToTheFirstScreen() {
        let app = launchIntoParentMode()
        app.tabBars.buttons["Manage"].tap()

        let signOut = app.buttons["manage.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()

        XCTAssertTrue(app.buttons["onboarding.parent"].waitForExistence(timeout: 10),
                      "signing out should land back on the two doors")
    }

    func testLeavingWarnsThatTheFamilyGoesWithYou() {
        let app = launchIntoParentMode()
        app.tabBars.buttons["Manage"].tap()

        let leave = app.buttons["manage.leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        leave.tap()

        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'cannot be undone'")).firstMatch
            .waitForExistence(timeout: 5),
            "the only parent must be told the family goes too")
    }
}
```

`launchIntoParentMode()` is defined on `ParentUITestCase` and, after Task 9, walks through
onboarding → sign-in → start a family → parent mode. A family created that way has exactly one
parent, so both tests above exercise the last-parent wording.

- [ ] **Step 5: Run it**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ChoresUITests/ManageSessionUITests test`
Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add App/Chores/Parent/ParentRootView.swift App/Chores/RootView.swift App/ChoresUITests/ManageSessionUITests.swift
git commit -m "Let a parent sign out, leave, or delete their account"
```

---

### Task 12: Deleting a child from People

**Files:**
- Modify: `App/Chores/Parent/PeopleView.swift`
- Test: `App/ChoresUITests/PeopleUITests.swift` (create if absent)

**Interfaces:**
- Consumes: `deleteChild(profileID:)` from Task 6.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Add the action**

In `PeopleView`, add state:

```swift
    @State private var deleting: Profile?
```

Give each child row an identifier and a destructive swipe action, inside the `ForEach(children)`
after `.tint(.primary)`. The identifier is needed because child rows currently have none — only
parent rows do — and a UI test cannot reliably address a row by its rendered label when the row
also contains a "Not set up" badge:

```swift
                    .accessibilityIdentifier("people.child.\(child.displayName)")
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { deleting = child }
                            .accessibilityIdentifier("people.deleteChild.\(child.displayName)")
                    }
```

and the confirmation, beside the existing sheets:

```swift
        .confirmationDialog("Delete \(deleting?.displayName ?? "")?",
                            isPresented: .constant(deleting != nil),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let child = deleting { Task { await delete(child) } }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            // Naming what goes, rather than asking "are you sure?", which invites
            // a reflex yes.
            Text("""
                This removes \(deleting?.displayName ?? "") from the family, takes them off \
                the schedule, and deletes everything they've ever ticked off. This cannot be \
                undone.
                """)
        }
```

and the method:

```swift
    private func delete(_ child: Profile) async {
        do {
            try await backend.deleteChild(profileID: child.id)
            deleting = nil
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            deleting = nil
            errorMessage = "Couldn't delete \(child.displayName). Check your connection and try again."
        }
    }
```

- [ ] **Step 2: Replace the comment that says this is impossible**

The file ends with a comment stating deletion is deliberately absent because it raises questions v1 does not answer. Those questions are answered now. Replace it with:

```swift
// Only children can be deleted here. Removing another parent raises a separate
// question about who may evict whom; each parent leaves under their own account
// from Manage instead.
```

- [ ] **Step 3: Write the UI test**

```swift
import XCTest

final class PeopleUITests: ParentUITestCase {

    func testDeletingAChildNamesWhatWillBeLost() {
        let app = launchIntoParentMode()
        addChild(app, named: "Kid")
        app.tabBars.buttons["Manage"].tap()
        app.buttons["People"].tap()

        let row = app.buttons["people.child.Kid"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        app.buttons["people.deleteChild.Kid"].tap()

        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'ticked off'")).firstMatch
            .waitForExistence(timeout: 5),
            "the confirmation must say the history goes too")

        app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(app.buttons["people.child.Kid"].waitForExistence(timeout: 5))
    }
}
```

`addChild(_:named:)` and `launchIntoParentMode()` are both defined on `ParentUITestCase`. Note
that `addChild` leaves the app on the Manage tab, having popped back out of People, which is why
the test navigates into People again.

- [ ] **Step 4: Run it**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ChoresUITests/PeopleUITests test`
Expected: TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/Chores/Parent/PeopleView.swift App/ChoresUITests/PeopleUITests.swift
git commit -m "Let a parent delete a child from People"
```

---

### Task 13: Integration tests against the real server

Apple's token exchange cannot be automated — no test can mint an Apple identity token. But the database rule is about `is_anonymous`, not about Apple, so an email user is a faithful stand-in at exactly the level the rule operates.

**Files:**
- Modify: `Tests/ChoresCoreTests/SupabaseIntegrationTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Add a helper that mints a signed-in session**

The suite already reads and writes `EphemeralStorage` directly and already holds the service-role key. Pre-seeding storage with a real non-anonymous session makes the backend behave as a signed-in parent, with no test-only method added to the production protocol.

```swift
    /// A confirmed email user, signed in, with the session planted in `storage`.
    ///
    /// Apple cannot be automated, but the rule under test is `is_anonymous`, not
    /// which provider was used — so this exercises the real server on the real
    /// code path a parent takes.
    static func makeSignedInBackend(storage: EphemeralStorage) async throws
        -> SupabaseChoresBackend {
        let environment = ProcessInfo.processInfo.environment
        let urlString = environment["SUPABASE_URL"] ?? "http://127.0.0.1:54321"
        let anonKey = try #require(environment["SUPABASE_ANON_KEY"])
        let email = "parent-\(UUID().uuidString)@example.com"

        var request = URLRequest(url: URL(string: "\(urlString)/auth/v1/signup")!)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email, "password": "hunter2hunter2"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 200, "signup failed with \(status)")

        let backend = try makeBackend(storage: storage)
        try await storage.plantSession(from: data)
        return backend
    }
```

Add to `EphemeralStorage`, translating the wire response into the shape the SDK stores. Read one real stored session first with `storedSession` to confirm the key names, then:

```swift
        /// Writes a session obtained over HTTP into the SDK's own storage slot,
        /// so the backend comes up already signed in.
        func plantSession(from signupResponse: Data) throws {
            let wire = try JSONSerialization.jsonObject(with: signupResponse) as? [String: Any]
            // The SDK encodes camelCase, the wire is snake_case.
            let session: [String: Any] = [
                "accessToken": wire?["access_token"] as Any,
                "refreshToken": wire?["refresh_token"] as Any,
                "expiresIn": wire?["expires_in"] as Any,
                "expiresAt": wire?["expires_at"] as Any,
                "tokenType": wire?["token_type"] as Any,
                "user": wire?["user"] as Any
            ]
            lock.withLock {
                values["sb-127-auth-token"] =
                    try? JSONSerialization.data(withJSONObject: session)
            }
        }
```

If the backend does not come up signed in, dump `storedSession` from a real anonymous sign-in and match the encoding exactly — the SDK's `User` shape uses camelCase keys and epoch-second dates.

- [ ] **Step 2: Write the tests**

```swift
/// The rule the whole design rests on, seen through the real server.
@Test func anAnonymousCallerCannotCreateAFamily() async throws {
    let backend = try Self.makeBackend()
    try await backend.signInAnonymously()

    await #expect(throws: ChoresBackendError.self) {
        _ = try await backend.createFamily(familyName: "Sneaky", parentName: "Kid",
                                           timezone: "Europe/Helsinki")
    }
}

@Test func aSignedInParentCanCreateLeaveAndStartAgain() async throws {
    let storage = EphemeralStorage()
    let backend = try await Self.makeSignedInBackend(storage: storage)
    #expect(try await backend.currentIdentity() == .signedIn)

    _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                       timezone: "Europe/Helsinki")
    #expect(try await backend.currentProfile() != nil)

    try await backend.leaveFamily()
    #expect(try await backend.currentProfile() == nil)

    // Leaving is only worth anything if it frees you to start over.
    _ = try await backend.createFamily(familyName: "Uusi", parentName: "Parent",
                                       timezone: "Europe/Helsinki")
    #expect(try await backend.currentProfile() != nil)
}

@Test func deletingAChildTakesTheirHistoryAndSparesTheirSibling() async throws {
    let storage = EphemeralStorage()
    let backend = try await Self.makeSignedInBackend(storage: storage)
    let familyID = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                                  timezone: "Europe/Helsinki")
    let doomed = try await backend.addChild(familyID: familyID, name: "A",
                                            color: "#FF8800", sortOrder: 0)
    let sibling = try await backend.addChild(familyID: familyID, name: "B",
                                             color: "#1DB954", sortOrder: 1)
    let chore = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)
    let monday = CalendarDay(year: 2026, month: 8, day: 10)
    try await backend.complete(familyID: familyID, profileID: doomed.id, choreID: chore.id,
                               dueOn: monday, completedBy: doomed.id)
    try await backend.complete(familyID: familyID, profileID: sibling.id, choreID: chore.id,
                               dueOn: monday, completedBy: sibling.id)

    try await backend.deleteChild(profileID: doomed.id)

    let snapshot = try await backend.fetchSnapshot(familyID: familyID, weekOf: monday)
    #expect(!snapshot.profiles.contains { $0.id == doomed.id })
    #expect(snapshot.completions.count == 1)
}

/// A parent who ticks a chore off for a child, then leaves, must not take the
/// child's record with them.
@Test func aDepartingParentLeavesTheChildrensHistoryIntact() async throws {
    let storage = EphemeralStorage()
    let first = try await Self.makeSignedInBackend(storage: storage)
    let familyID = try await first.createFamily(familyName: "Koti", parentName: "First",
                                                timezone: "Europe/Helsinki")
    let child = try await first.addChild(familyID: familyID, name: "Kid",
                                         color: "#FF8800", sortOrder: 0)
    let chore = try await first.addChore(familyID: familyID, name: "Bins", icon: nil)
    let monday = CalendarDay(year: 2026, month: 8, day: 10)
    let me = try #require(try await first.currentProfile())
    try await first.complete(familyID: familyID, profileID: child.id, choreID: chore.id,
                             dueOn: monday, completedBy: me.id)

    // A second parent, so leaving does not delete the family outright.
    let secondSeat = try await first.addParent(familyID: familyID, name: "Second")
    let code = try await first.generateClaimCode(profileID: secondSeat.id)
    let secondStorage = EphemeralStorage()
    let second = try await Self.makeSignedInBackend(storage: secondStorage)
    _ = try await second.claimProfile(code: code)

    try await first.leaveFamily()

    let snapshot = try await second.fetchSnapshot(familyID: familyID, weekOf: monday)
    #expect(snapshot.completions.count == 1,
            "the child's record must outlive the parent who entered it")
    #expect(snapshot.completions.first?.completedBy == nil)
}
```

- [ ] **Step 3: Run them**

```bash
supabase db reset
SUPABASE_INTEGRATION=1 \
SUPABASE_ANON_KEY="$(supabase status -o env | grep ANON_KEY | cut -d= -f2 | tr -d '"')" \
SUPABASE_SERVICE_ROLE_KEY="$(supabase status -o env | grep SERVICE_ROLE_KEY | cut -d= -f2 | tr -d '"')" \
swift test --filter SupabaseIntegrationTests
```

Expected: PASS, all tests including the four pre-existing ones.

- [ ] **Step 4: Commit**

```bash
git add Tests/ChoresCoreTests/SupabaseIntegrationTests.swift
git commit -m "Cover the parent paths against the real server"
```

---

### Task 14: Capability, provider configuration, and the manual check

**Files:**
- Create: `App/Chores/Chores.entitlements` (via Xcode)
- Modify: `App/Chores.xcodeproj/project.pbxproj` (via Xcode)
- Modify: `supabase/config.toml`
- Modify: `docs/RELEASING.md`

**Interfaces:**
- Consumes: everything.
- Produces: a build that can actually reach Apple.

- [ ] **Step 1: Add the capability**

In Xcode: select the Chores target → Signing & Capabilities → **+ Capability** → **Sign In with Apple**. This creates the entitlements file, sets `CODE_SIGN_ENTITLEMENTS`, and regenerates the provisioning profile. Confirm afterwards:

```bash
grep -n "CODE_SIGN_ENTITLEMENTS" App/Chores.xcodeproj/project.pbxproj
plutil -p App/Chores/Chores.entitlements
```

Expected: the setting is present for both configurations, and the plist contains `com.apple.developer.applesignin`.

- [ ] **Step 2: Enable the provider locally**

In `supabase/config.toml`, under `[auth.external.apple]`:

```toml
enabled = true
client_id = "com.metsahalme.Chores"
secret = ""
```

`secret` serves the OAuth web flow only; native `signInWithIdToken` needs just the client ID so the server can validate the token's `aud`. Leaving the `env(...)` substitution in place points at a variable that is never set.

- [ ] **Step 3: Confirm the stack still starts**

Run: `supabase stop && supabase start && supabase db reset && supabase test db`
Expected: the stack starts without complaining about the Apple secret, and pgTAP passes 34 of 34.

- [ ] **Step 4: Record the manual check**

Apple's token exchange has no automated coverage at any layer. Add to `docs/RELEASING.md`, inside the "App builds" list before the Archive step:

```markdown
4. Sign in with Apple has no automated coverage — no test can mint an Apple identity
   token — so check it by hand on a real device before every TestFlight build:
   sign in as a parent and create a family; force-quit and relaunch, confirming the
   family returns without a code; delete the app, reinstall, sign in again, and
   confirm it returns again. That last step is the whole point of the feature.
```

Renumber the Archive step that follows.

- [ ] **Step 5: Note the hosted setup**

In the same file's "First-time setup of the hosted project" section, add:

```markdown
Enable **Authentication → Providers → Apple**, and put `com.metsahalme.Chores` in
Client IDs. The Secret Key fields are for the OAuth web flow and stay empty — native
sign-in only needs the client ID so the server can check the token's `aud` claim.
Leave anonymous sign-ins enabled; children still depend on them.
```

- [ ] **Step 6: Full verification**

```bash
swift test
supabase db reset && supabase test db
xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Expected: unit tests pass, pgTAP 34 of 34, UI suite green.

- [ ] **Step 7: Commit**

```bash
git add App/Chores.xcodeproj App/Chores/Chores.entitlements supabase/config.toml docs/RELEASING.md
git commit -m "Turn on Sign in with Apple, and record the check no test can do"
```

---

## Manual verification before TestFlight

Once Task 14 is committed, the maintainer must:

1. Run `supabase db push` to apply all four migrations to the hosted project. Release builds always use Hosted, so a migration that has not been pushed is a build that fails on a tester's first launch.
2. Enable the Apple provider in the hosted dashboard as recorded in `RELEASING.md`.
3. Perform the on-device sign-in check from Task 14, Step 4.
