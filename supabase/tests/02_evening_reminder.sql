-- The evening reminder: reminder times, device tokens, the nightly work.
--
-- Everything that decides whether a parent's phone buzzes lives in SQL, and a
-- wrong decision is silent — a family that is never reminded, or one that is
-- reminded twice. These assertions are the gate. Run with:
--   supabase db reset && supabase test db

begin;
set local search_path to public, extensions;

select plan(45);

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

-- ---------------------------------------------------------------------------
-- Device tokens: a token belongs to whoever holds the phone
-- ---------------------------------------------------------------------------

select tests.auth_as('a0000000-0000-0000-0000-000000000001');   -- P1
select lives_ok(
  $$select public.device_token_register('tok-p1-a', 'production')$$,
  'a parent may register their phone');
select public.device_token_register('tok-p1-b', 'development');

select tests.auth_as('b0000000-0000-0000-0000-000000000001');   -- PB
select public.device_token_register('tok-pb', 'production');

select tests.auth_as('a0000000-0000-0000-0000-000000000001');   -- P1 again
select is((select count(*)::int from public.device_tokens), 2,
          'a parent sees their own tokens and nobody else''s');

select tests.auth_as('a0000000-0000-0000-0000-000000000003');   -- C1
select throws_ok(
  $$select public.device_token_register('tok-kid', 'development')$$,
  'P0005', null, 'a child cannot register a token');
select is((select count(*)::int from public.device_tokens), 0,
          'and sees none');

-- P2 signs in on the phone that used to be P1's: the row moves.
select tests.auth_as('a0000000-0000-0000-0000-000000000002');   -- P2
select public.device_token_register('tok-p1-a', 'production');
select tests.as_admin();
select is(
  (select profile_id from public.device_tokens where token = 'tok-p1-a'),
  'aaaa0000-0000-0000-0000-000000000002'::uuid,
  'registering a token another parent held takes it over');

-- P1's late forget of the phone they no longer hold must not undo that.
select tests.auth_as('a0000000-0000-0000-0000-000000000001');   -- P1
select public.device_token_forget('tok-p1-a');
select tests.as_admin();
select is(
  (select profile_id from public.device_tokens where token = 'tok-p1-a'),
  'aaaa0000-0000-0000-0000-000000000002'::uuid,
  'forget removes only the caller''s own row');

-- Leave the fixtures as the later sections expect: P1 holds tok-p1-a and
-- tok-p1-b, P2 holds nothing, PB holds tok-pb.
select tests.auth_as('a0000000-0000-0000-0000-000000000002');   -- P2
select public.device_token_forget('tok-p1-a');
select tests.auth_as('a0000000-0000-0000-0000-000000000001');   -- P1
select public.device_token_register('tok-p1-a', 'production');
select tests.as_admin();

-- ---------------------------------------------------------------------------
-- What counts as undone
-- ---------------------------------------------------------------------------

select tests.as_admin();

select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-09-21'), 2,
          'undone counts each child''s open chores: the same chore on two children is two, an archived chore is not counted, a parent''s own entry is not counted');

insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by) values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000001', date '2026-09-21', 'aaaa0000-0000-0000-0000-000000000003');
select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-09-21'), 1,
          'a completion takes one off');

insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by) values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000004',
   'cccc0000-0000-0000-0000-000000000001', date '2026-09-21', 'aaaa0000-0000-0000-0000-000000000001');
select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-09-21'), 0,
          'a parent ticking on the child''s behalf counts the same');

select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-09-23'), 0,
          'a weekday with no entries has nothing undone');

-- Back to an unfinished Monday for the work() tests.
delete from public.completions where due_on = date '2026-09-21';

-- ---------------------------------------------------------------------------
-- The work: who is due, and the claim that stops a double-send
-- 18:05Z is 21:05 in Helsinki: P1 (21:00) is due, P2 (23:30) is not.
-- Family B is on UTC, so PB (21:00) is not due at 18:05Z.
-- ---------------------------------------------------------------------------

select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 17:55:00+00')), 0,
          'nobody is due at 20:55');
select is((select count(*)::int from public.evening_reminder_sends), 0,
          'and nothing was claimed');

select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 18:05:00+00')), 2,
          'at 21:05 P1 is due, once per device');
select is((select count(*)::int from public.evening_reminder_sends), 1,
          'one claim row per parent, not per device');
select is(
  (select (undone_count, device_count, sent_at is null)::text
     from public.evening_reminder_sends
    where profile_id = 'aaaa0000-0000-0000-0000-000000000001'
      and local_date = date '2026-09-21'),
  '(2,2,t)', 'the claim records the counts and is not yet sent');
select is((select count(*)::int from public.evening_reminder_sends
            where profile_id = 'bbbb0000-0000-0000-0000-000000000001'), 0,
          'a parent whose local clock says 18:05 is not due');
select is((select count(*)::int from public.evening_reminder_sends
            where profile_id = 'aaaa0000-0000-0000-0000-000000000002'), 0,
          'a parent set to 23:30 is not due at 21:05');

select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 18:10:00+00')), 0,
          'the next tick finds P1 already claimed and returns nothing');

-- PB, on UTC: after the hour is too late; inside it is fine.
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 22:05:00+00')), 0,
          'an hour after their time a parent is no longer due');
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 21:10:00+00')), 1,
          'PB is due at 21:10 UTC');
select is((select token from public.evening_reminder_work(timestamptz '2026-09-21 21:10:00+00')), null::text,
          'and only once');

-- P2 at 23:30, no phone registered: claimed, recorded with no devices, nothing returned.
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 20:45:00+00')), 0,
          'a due parent with no phone returns no work');
select is(
  (select device_count from public.evening_reminder_sends
    where profile_id = 'aaaa0000-0000-0000-0000-000000000002'
      and local_date = date '2026-09-21'),
  0, 'but is recorded with zero devices, so the absence can be explained');

-- The window is clipped at midnight: 21:10Z is 00:10 on the 22nd in Helsinki.
-- Tuesday has an unfinished chore too, so only the window can say no.
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 21:10:00+00')), 0,
          'a 23:30 window does not spill into the next day');
select is((select count(*)::int from public.evening_reminder_sends
            where profile_id = 'aaaa0000-0000-0000-0000-000000000002'), 1,
          'and no claim was made for the 22nd');

-- Switched off means never due. Clear P1's claim so the window is open again.
update public.profiles set evening_reminder_at = null
 where id = 'aaaa0000-0000-0000-0000-000000000001';
delete from public.evening_reminder_sends
 where profile_id = 'aaaa0000-0000-0000-0000-000000000001';
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 18:05:00+00')), 0,
          'a parent with the reminder off is never due');
update public.profiles set evening_reminder_at = time '21:00'
 where id = 'aaaa0000-0000-0000-0000-000000000001';

-- A finished day is nothing to say. Complete everything, then P1 is due but not claimed.
insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by) values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000001', date '2026-09-21', 'aaaa0000-0000-0000-0000-000000000003'),
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000004',
   'cccc0000-0000-0000-0000-000000000001', date '2026-09-21', 'aaaa0000-0000-0000-0000-000000000004');
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 18:05:00+00')), 0,
          'a family whose day is done gets no reminder');
select is((select count(*)::int from public.evening_reminder_sends
            where profile_id = 'aaaa0000-0000-0000-0000-000000000001'), 0,
          'and no claim row either');
delete from public.completions where due_on = date '2026-09-21';

-- ---------------------------------------------------------------------------
-- Reporting back
-- ---------------------------------------------------------------------------

select public.evening_reminder_record(
  'bbbb0000-0000-0000-0000-000000000001', date '2026-09-21',
  timestamptz '2026-09-21 21:10:04+00', null);
select is(
  (select sent_at from public.evening_reminder_sends
    where profile_id = 'bbbb0000-0000-0000-0000-000000000001'),
  timestamptz '2026-09-21 21:10:04+00', 'record() marks the claim sent');
select is(
  (select failure from public.evening_reminder_sends
    where profile_id = 'bbbb0000-0000-0000-0000-000000000001'),
  null::text, 'and leaves no failure on a success');

select public.evening_reminder_record(
  'aaaa0000-0000-0000-0000-000000000002', date '2026-09-21', null, 'apns 403');
select is(
  (select failure from public.evening_reminder_sends
    where profile_id = 'aaaa0000-0000-0000-0000-000000000002'),
  'apns 403', 'record() keeps a failure where it can be read');

select public.device_tokens_forget(array['tok-pb', 'never-existed']);
select is((select count(*)::int from public.device_tokens where token = 'tok-pb'), 0,
          'forget() removes the tokens Apple called dead');
select is((select count(*)::int from public.device_tokens), 2,
          'and leaves the others');

-- ---------------------------------------------------------------------------
-- None of this is reachable from a phone
-- ---------------------------------------------------------------------------

select tests.auth_as('a0000000-0000-0000-0000-000000000001');
select throws_ok($$select public.evening_reminder_work()$$, '42501', null,
                 'a signed-in user cannot run the work');
select throws_ok($$select public.family_undone_count('11111111-1111-1111-1111-111111111111', current_date)$$,
                 '42501', null, 'nor count another family''s undone chores');
select throws_ok($$select public.evening_reminder_record('aaaa0000-0000-0000-0000-000000000001', current_date, now(), null)$$,
                 '42501', null, 'nor mark a send');
select throws_ok($$select public.device_tokens_forget(array['tok-p1-a'])$$, '42501', null,
                 'nor forget tokens wholesale');
-- No grant on the table at all, so this is a refusal rather than an empty result.
select throws_ok($$select count(*) from public.evening_reminder_sends$$, '42501', null,
                 'and cannot read the log');
select tests.as_admin();

-- ---------------------------------------------------------------------------
-- The job exists
-- ---------------------------------------------------------------------------

select tests.as_admin();
select is(
  (select schedule from cron.job where jobname = 'evening-reminder'),
  '*/5 * * * *', 'the evening reminder runs every five minutes');

select tests.as_admin();
select * from finish();
rollback;
