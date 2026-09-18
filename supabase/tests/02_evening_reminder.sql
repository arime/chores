-- The evening reminder: reminder times, device tokens, the nightly work.
--
-- Everything that decides whether a parent's phone buzzes lives in SQL, and a
-- wrong decision is silent — a family that is never reminded, or one that is
-- reminded twice. These assertions are the gate. Run with:
--   supabase db reset && supabase test db

begin;
set local search_path to public, extensions;

select plan(6);

-- ---------------------------------------------------------------------------
-- Helpers (same shape as 01_rls_and_rpcs.sql; each file is its own transaction)
-- ---------------------------------------------------------------------------

create schema tests;
grant usage on schema tests to authenticated;

create function tests.auth_as(p_uid uuid, p_anonymous boolean default false)
returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid::text,
                      'role', 'authenticated',
                      'is_anonymous', p_anonymous)::text, true);
end $$;

create function tests.as_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- ---------------------------------------------------------------------------
-- Fixtures. Family A is in Helsinki (UTC+3 on 2026-09-21), family B in UTC.
-- 2026-09-21 is a Monday. Every schedule entry below is for Monday unless said.
-- ---------------------------------------------------------------------------

insert into auth.users (id) values
  ('a0000000-0000-0000-0000-000000000001'),  -- P1, parent, family A
  ('a0000000-0000-0000-0000-000000000002'),  -- P2, parent, family A, reminds at 23:30
  ('a0000000-0000-0000-0000-000000000003'),  -- C1, child,  family A
  ('b0000000-0000-0000-0000-000000000001');  -- PB, parent, family B

insert into public.families (id, name, timezone) values
  ('11111111-1111-1111-1111-111111111111', 'Family A', 'Europe/Helsinki'),
  ('22222222-2222-2222-2222-222222222222', 'Family B', 'UTC');

-- Inserted without reminder columns on purpose: the trigger is under test.
insert into public.profiles (id, family_id, auth_user_id, display_name, role) values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000001', 'P1', 'parent'),
  ('aaaa0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000003', 'C1', 'child'),
  ('aaaa0000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   null, 'C2', 'child'),
  ('bbbb0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'b0000000-0000-0000-0000-000000000001', 'PB', 'parent'),
  ('bbbb0000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   null, 'CB', 'child');

-- P2 provides an explicit time.
insert into public.profiles (id, family_id, auth_user_id, display_name, role, evening_reminder_at) values
  ('aaaa0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000002', 'P2', 'parent', time '23:30');

insert into public.chores (id, family_id, name, is_archived) values
  ('cccc0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bins',  false),
  ('cccc0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Old',   true),
  ('cccc0000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'B chore', false);

insert into public.schedule_entries (family_id, profile_id, chore_id, weekday) values
  -- C1: Bins on Monday and Tuesday, the archived chore on Monday.
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000001', 1),
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000001', 2),
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000002', 1),
  -- C2: Bins on Monday. The same chore on two children counts twice.
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000004',
   'cccc0000-0000-0000-0000-000000000001', 1),
  -- P1 put themselves on the schedule. A parent's own chores are not the child's.
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000001',
   'cccc0000-0000-0000-0000-000000000001', 1),
  -- Family B: the child has a chore on Monday; the parent put themselves on too.
  ('22222222-2222-2222-2222-222222222222', 'bbbb0000-0000-0000-0000-000000000002',
   'cccc0000-0000-0000-0000-000000000003', 1),
  ('22222222-2222-2222-2222-222222222222', 'bbbb0000-0000-0000-0000-000000000001',
   'cccc0000-0000-0000-0000-000000000003', 1);

-- ---------------------------------------------------------------------------
-- Reminder times: defaults by role, and who may change them
-- ---------------------------------------------------------------------------

select is(
  (select evening_reminder_at from public.profiles
     where id = 'aaaa0000-0000-0000-0000-000000000001'),
  time '21:00', 'a new parent reminds themselves at 21:00');

select is(
  (select afternoon_reminder_at from public.profiles
     where id = 'aaaa0000-0000-0000-0000-000000000001'),
  null::time, 'and has no afternoon reminder');

select is(
  (select (afternoon_reminder_at, evening_reminder_at)::text from public.profiles
     where id = 'aaaa0000-0000-0000-0000-000000000003'),
  '(15:00:00,20:00:00)', 'a new child gets 15:00 and 20:00');

select is(
  (select evening_reminder_at from public.profiles
     where id = 'aaaa0000-0000-0000-0000-000000000002'),
  time '23:30', 'a time given at insert is kept');

-- A child's UPDATE on their own row is filtered by the policy: zero rows, no error.
select tests.auth_as('a0000000-0000-0000-0000-000000000003');
with attempted as (
  update public.profiles set evening_reminder_at = null
   where id = 'aaaa0000-0000-0000-0000-000000000003'
  returning 1
)
select is((select count(*)::int from attempted), 0,
          'a child cannot change their own reminder times');

select tests.auth_as('a0000000-0000-0000-0000-000000000001');
select lives_ok(
  $$update public.profiles set evening_reminder_at = null
     where id = 'aaaa0000-0000-0000-0000-000000000001'$$,
  'a parent may switch their own reminder off');

-- Put it back for the tests that follow.
select tests.as_admin();
update public.profiles set evening_reminder_at = time '21:00'
 where id = 'aaaa0000-0000-0000-0000-000000000001';

select tests.as_admin();
select * from finish();
rollback;
