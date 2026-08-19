-- RLS and RPC regression tests.
--
-- An RLS failure is silent: no crash, just data visible to the wrong person.
-- These assertions are the only thing that catches it. Run with:
--   supabase db reset && supabase test db
--
-- Helpers are defined inside the transaction so nothing leaks into the database.

begin;
set local search_path to public, extensions;

select plan(45);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create schema tests;
-- The helpers are called while impersonating `authenticated`, which needs USAGE
-- on the schema to reach them.
grant usage on schema tests to authenticated;

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

-- Return to superuser for fixture setup.
create function tests.as_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- ---------------------------------------------------------------------------
-- Fixtures: two unrelated families. Built as superuser, which bypasses RLS.
-- ---------------------------------------------------------------------------

insert into auth.users (id) values
  ('a0000000-0000-0000-0000-000000000001'),  -- parent, family A
  ('a0000000-0000-0000-0000-000000000002'),  -- child,  family A
  ('b0000000-0000-0000-0000-000000000001'),  -- child,  family B
  ('c0000000-0000-0000-0000-000000000001'),  -- unclaimed device
  ('c0000000-0000-0000-0000-000000000002');  -- unclaimed device

insert into public.families (id, name) values
  ('11111111-1111-1111-1111-111111111111', 'Family A'),
  ('22222222-2222-2222-2222-222222222222', 'Family B');

insert into public.profiles (id, family_id, auth_user_id, display_name, role) values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000001', 'Parent A', 'parent'),
  ('aaaa0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000002', 'Child A', 'child'),
  ('aaaa0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   null, 'Sibling', 'child'),
  ('bbbb0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'b0000000-0000-0000-0000-000000000001', 'Child B', 'child');

insert into public.chores (id, family_id, name) values
  ('cccc0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Dishwasher'),
  ('cccc0000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'Family B chore');

-- ---------------------------------------------------------------------------
-- Family isolation, as Child A
-- ---------------------------------------------------------------------------

select tests.auth_as('a0000000-0000-0000-0000-000000000002');

select is((select count(*)::int from public.families), 1,
          'a child sees exactly one family');

select is((select count(*)::int from public.profiles), 3,
          'a child sees only their own family''s profiles');

select is((select count(*)::int from public.chores), 1,
          'a child cannot see another family''s chores');

-- ---------------------------------------------------------------------------
-- Completions, as Child A
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by)
    values ('11111111-1111-1111-1111-111111111111',
            'aaaa0000-0000-0000-0000-000000000003',
            'cccc0000-0000-0000-0000-000000000001', date '2026-08-10',
            'aaaa0000-0000-0000-0000-000000000003')$$,
  '42501', null, 'a child cannot complete a sibling''s chore');

select lives_ok(
  $$insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by)
    values ('11111111-1111-1111-1111-111111111111',
            'aaaa0000-0000-0000-0000-000000000002',
            'cccc0000-0000-0000-0000-000000000001', date '2026-08-10',
            'aaaa0000-0000-0000-0000-000000000002')$$,
  'a child may complete their own chore');

-- ---------------------------------------------------------------------------
-- Parent-only writes, attempted as Child A
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.chores (family_id, name)
    values ('11111111-1111-1111-1111-111111111111', 'Sneaky')$$,
  '42501', null, 'a child cannot create chores');

select throws_ok(
  $$insert into public.schedule_entries (family_id, profile_id, chore_id, weekday)
    values ('11111111-1111-1111-1111-111111111111',
            'aaaa0000-0000-0000-0000-000000000002',
            'cccc0000-0000-0000-0000-000000000001', 1)$$,
  '42501', null, 'a child cannot edit the schedule');

-- A child's UPDATE on a sibling is filtered out by the USING clause, so it
-- affects zero rows rather than raising. Asserting "throws" here would pass
-- for the wrong reason and hide a real policy regression.
with attempted as (
  update public.profiles set display_name = 'Hijacked'
  where id = 'aaaa0000-0000-0000-0000-000000000003'
  returning 1
)
select is((select count(*)::int from attempted), 0,
          'a child cannot rename a sibling (zero rows, no error)');

select is((select count(*)::int from public.claim_codes), 0,
          'a child cannot read claim codes');

-- ---------------------------------------------------------------------------
-- Parent capabilities
-- ---------------------------------------------------------------------------

select tests.auth_as('a0000000-0000-0000-0000-000000000001');

select lives_ok(
  $$delete from public.completions
    where profile_id = 'aaaa0000-0000-0000-0000-000000000002'$$,
  'a parent may revert any completion in their family');

-- Only claim_profile() may bind auth_user_id. A parent passes the policy, so
-- this reaches the trigger — which is the thing under test.
select throws_ok(
  $$update public.profiles
    set auth_user_id = 'c0000000-0000-0000-0000-000000000001'
    where id = 'aaaa0000-0000-0000-0000-000000000003'$$,
  'P0001', 'auth_user_id may only be set by claim_profile()',
  'auth_user_id cannot be bound by a direct update');

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select public.create_family('Second Family', 'Parent')$$,
  'P0001', 'caller already has a profile',
  'create_family rejects a caller who already has a profile');

-- Issue a code for the unclaimed sibling, then claim it from a fresh device.
select public.generate_claim_code('aaaa0000-0000-0000-0000-000000000003') as code \gset

select tests.auth_as('c0000000-0000-0000-0000-000000000001');

select throws_ok(
  $$select public.claim_profile('ZZZZZZ')$$,
  'P0001', 'unknown code', 'an unknown claim code is rejected');

select lives_ok(
  format($$select public.claim_profile(%L)$$, :'code'),
  'a valid claim code binds the profile');

select tests.auth_as('c0000000-0000-0000-0000-000000000002');

select throws_ok(
  format($$select public.claim_profile(%L)$$, :'code'),
  'P0002', 'code already used', 'a claim code cannot be reused');

-- ---------------------------------------------------------------------------
-- Parents must be signed in
-- ---------------------------------------------------------------------------

-- A child device is anonymous and must not be able to bootstrap a family.
select tests.auth_as('d0000000-0000-0000-0000-000000000001', true);
select throws_ok(
  $$select public.create_family('Sneaky', 'Kid', 'Europe/Helsinki')$$,
  'parents must sign in',
  'an anonymous caller cannot create a family');

-- The mapping from SQLSTATE to app error depends on this exact code, so it
-- gets its own assertion rather than riding along with the message check.
-- The five-character form is read by pgTAP as a SQLSTATE, not a message.
select throws_ok(
  $$select public.create_family('Sneaky', 'Kid', 'Europe/Helsinki')$$,
  'P0004');

-- The same caller, signed in, may. The auth.users row must exist first:
-- create_family inserts a profile whose auth_user_id references it, so without
-- this the call fails on the foreign key rather than proving anything.
select tests.as_admin();
insert into auth.users (id) values ('d0000000-0000-0000-0000-000000000001');
select tests.auth_as('d0000000-0000-0000-0000-000000000001', false);
select lives_ok(
  $$select public.create_family('Legit', 'Parent', 'Europe/Helsinki')$$,
  'a signed-in caller can create a family');

-- Parent codes, in contrast to create_family() above, may be claimed by either
-- kind of caller. An anonymous one is the second parent who has no Apple ID and
-- was handed a code by the first; the guard that used to refuse them is gone.
select tests.as_admin();
insert into auth.users (id) values ('e0000000-0000-0000-0000-000000000001');
insert into public.claim_codes (code, family_id, profile_id, expires_at)
  values ('PARENT', '11111111-1111-1111-1111-111111111111',
          'aaaa0000-0000-0000-0000-000000000001', now() + interval '1 day');

select tests.auth_as('e0000000-0000-0000-0000-000000000001', true);
select lives_ok(
  $$select public.claim_profile('PARENT')$$,
  'an anonymous caller can claim a parent profile');

select tests.as_admin();
select is(
  (select auth_user_id from public.profiles
     where id = 'aaaa0000-0000-0000-0000-000000000001'),
  'e0000000-0000-0000-0000-000000000001'::uuid,
  'and the profile is bound to the anonymous device that claimed it');

-- A signed-in claimer keeps working too — the parent who does hold an Apple ID
-- and joins an existing family rather than starting one. A fresh code and a
-- fresh target, since the code above is now spent and its claimer now has a
-- profile of their own.
select tests.as_admin();
insert into auth.users (id) values ('e0000000-0000-0000-0000-000000000006');
insert into public.profiles (id, family_id, display_name, role)
  values ('aaaa0000-0000-0000-0000-000000000008',
          '11111111-1111-1111-1111-111111111111', 'Invited Parent', 'parent');
insert into public.claim_codes (code, family_id, profile_id, expires_at)
  values ('PARNT2', '11111111-1111-1111-1111-111111111111',
          'aaaa0000-0000-0000-0000-000000000008', now() + interval '1 day');

select tests.auth_as('e0000000-0000-0000-0000-000000000006', false);
select lives_ok(
  $$select public.claim_profile('PARNT2')$$,
  'a signed-in caller can claim a parent profile');

-- A child code, in contrast, may be claimed by an anonymous device — that's
-- how every child device in this product actually onboards. Uses a fresh,
-- previously-unclaimed child profile rather than a fixture already bound
-- above, so a stale binding can't hide a real regression.
select tests.as_admin();
insert into public.profiles (id, family_id, display_name, role)
  values ('aaaa0000-0000-0000-0000-000000000004',
          '11111111-1111-1111-1111-111111111111', 'New Kid', 'child');
insert into auth.users (id) values ('f0000000-0000-0000-0000-000000000001');
insert into public.claim_codes (code, family_id, profile_id, expires_at)
  values ('CHILD1', '11111111-1111-1111-1111-111111111111',
          'aaaa0000-0000-0000-0000-000000000004', now() + interval '1 day');

select tests.auth_as('f0000000-0000-0000-0000-000000000001', true);
select lives_ok(
  $$select public.claim_profile('CHILD1')$$,
  'an anonymous caller can claim a child profile');

-- ---------------------------------------------------------------------------
-- Leaving a family, and deleting an account
-- ---------------------------------------------------------------------------

-- The parent-only-RPC guards this branch added all share one SQLSTATE
-- (P0005): none of them is reachable except through UI already restricted to
-- who may try, so the app has one honest, generic response for all of them.
-- leave_family()'s bare guard, exercised here by a caller who was never bound
-- to any profile, is one of them.
select tests.auth_as('c0000000-0000-0000-0000-000000000002', false);
select throws_ok(
  $$select public.leave_family()$$,
  'caller has no profile', 'leave_family refuses a caller with no profile');

-- Pinned separately from the message, the same way P0004 is above: the
-- five-character form is read by pgTAP as a SQLSTATE, not a message.
select throws_ok(
  $$select public.leave_family()$$,
  'P0005');

-- Leaving with another parent present removes only the leaver.
select tests.as_admin();
insert into auth.users (id) values ('e0000000-0000-0000-0000-000000000002');
insert into public.profiles (family_id, auth_user_id, display_name, role)
  values ('11111111-1111-1111-1111-111111111111',
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
     where id = '11111111-1111-1111-1111-111111111111'),
  0,
  'and the family survives because another parent remains');

-- delete_account()'s own bare guard, sharing the same P0005 as leave_family()'s
-- above. tests.as_admin() clears request.jwt.claims entirely, which is what
-- makes auth.uid() null here regardless of the calling role.
select tests.as_admin();
select throws_ok(
  $$select public.delete_account()$$,
  'not authenticated', 'delete_account refuses a caller with no session');
select throws_ok(
  $$select public.delete_account()$$,
  'P0005');

-- Deleting an account removes the auth user too. Note: not
-- 'a0000000-0000-0000-0000-000000000001' (Parent A's original auth id) — the
-- parent-claim block above rebound Parent A's profile to
-- 'e0000000-0000-0000-0000-000000000001', so that id is now an
-- orphaned auth user with no profile. Using it here would silently test
-- delete_account()'s no-profile branch instead of the profile-bearing one, so
-- a fresh parent is seated first.
select tests.as_admin();
insert into auth.users (id) values ('e0000000-0000-0000-0000-000000000004');
insert into public.profiles (family_id, auth_user_id, display_name, role)
  values ('11111111-1111-1111-1111-111111111111',
          'e0000000-0000-0000-0000-000000000004', 'Deleting Parent', 'parent');

select tests.auth_as('e0000000-0000-0000-0000-000000000004', false);
select lives_ok($$select public.delete_account()$$, 'a parent may delete their account');
select tests.as_admin();
select is(
  (select count(*)::int from auth.users
     where id = 'e0000000-0000-0000-0000-000000000004'),
  0,
  'delete_account removes the auth user');

-- delete_account() must also work for a caller with no profile at all — that
-- is exactly who changes their mind after signing in once and never joining a
-- family, and the one App Review guideline 5.1.1(v) obliges us to get right.
select tests.as_admin();
insert into auth.users (id) values ('e0000000-0000-0000-0000-000000000005');
select tests.auth_as('e0000000-0000-0000-0000-000000000005', false);
select public.delete_account();
select tests.as_admin();
select is(
  (select count(*)::int from auth.users
     where id = 'e0000000-0000-0000-0000-000000000005'),
  0,
  'delete_account removes the auth user even with no profile to leave');

-- The last parent out takes the family with them.
select tests.as_admin();
insert into auth.users (id) values ('e0000000-0000-0000-0000-000000000003');
insert into public.families (id, name, timezone)
  values ('ffff0000-0000-0000-0000-00000000000f', 'Solo', 'Europe/Helsinki');
insert into public.profiles (family_id, auth_user_id, display_name, role)
  values ('ffff0000-0000-0000-0000-00000000000f',
          'e0000000-0000-0000-0000-000000000003', 'Only Parent', 'parent');

select tests.auth_as('e0000000-0000-0000-0000-000000000003', false);
select public.leave_family();
select tests.as_admin();
select is(
  (select count(*)::int from public.families
     where id = 'ffff0000-0000-0000-0000-00000000000f'),
  0,
  'the last parent leaving deletes the family');

-- ---------------------------------------------------------------------------
-- Deleting a child, history and all
-- ---------------------------------------------------------------------------

-- A fresh parent is seated for the caller: the parent-claim block earlier
-- rebound Parent A's original auth id
-- ('a0000000-0000-0000-0000-000000000001') to a claiming device, so
-- impersonating it here would make is_parent() false and turn every
-- lives_ok below into a failure for the wrong reason (as Task 3 hit).
--
-- The children below are new profiles rather than Child A
-- ('aaaa0000-0000-0000-0000-000000000002'): the "completion outlives the
-- person who recorded it" section further down inserts a completion for
-- Child A, and if this block had already deleted them that insert would fail
-- on a foreign key.
select tests.as_admin();
insert into auth.users (id) values ('90000000-0000-0000-0000-000000000001');
insert into public.profiles (id, family_id, auth_user_id, display_name, role) values
  ('aaaa0000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111',
   '90000000-0000-0000-0000-000000000001', 'Third Parent', 'parent'),
  ('aaaa0000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111',
   null, 'Doomed Child', 'child'),
  ('aaaa0000-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111',
   null, 'Surviving Child', 'child');
insert into public.chores (id, family_id, name) values
  ('cccc0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Task 4 Chore');
insert into public.schedule_entries (family_id, profile_id, chore_id, weekday) values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000006',
   'cccc0000-0000-0000-0000-000000000003', 1);
insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by) values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000006',
   'cccc0000-0000-0000-0000-000000000003', '2026-08-11', 'aaaa0000-0000-0000-0000-000000000006'),
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000007',
   'cccc0000-0000-0000-0000-000000000003', '2026-08-11', 'aaaa0000-0000-0000-0000-000000000007');

-- A parent may delete a child in their own family, history and all.
select tests.auth_as('90000000-0000-0000-0000-000000000001', false);
select lives_ok(
  $$select public.delete_child('aaaa0000-0000-0000-0000-000000000006')$$,
  'a parent may delete a child in their family');

select tests.as_admin();
select is(
  (select count(*)::int from public.completions
     where profile_id = 'aaaa0000-0000-0000-0000-000000000006'),
  0,
  'the deleted child takes their completions with them');
select isnt(
  (select count(*)::int from public.completions
     where profile_id = 'aaaa0000-0000-0000-0000-000000000007'),
  0,
  'deleting one child leaves another child''s completions alone');
select is(
  (select count(*)::int from public.schedule_entries
     where profile_id = 'aaaa0000-0000-0000-0000-000000000006'),
  0,
  'and their schedule entries');

-- Scoping: another family's child is out of reach, and a parent is not a child.
select tests.auth_as('90000000-0000-0000-0000-000000000001', false);
select throws_ok(
  $$select public.delete_child('bbbb0000-0000-0000-0000-000000000001')$$,
  'profile not in caller family',
  'a parent cannot delete a child in another family');
-- Pinned separately from the message, the same way P0004 is above.
select throws_ok(
  $$select public.delete_child('bbbb0000-0000-0000-0000-000000000001')$$,
  'P0005');
select throws_ok(
  $$select public.delete_child('aaaa0000-0000-0000-0000-000000000005')$$,
  'only a child may be deleted',
  'delete_child refuses a parent target');
select throws_ok(
  $$select public.delete_child('aaaa0000-0000-0000-0000-000000000005')$$,
  'P0005');

-- A child cannot use it at all. Child A's original auth id is used because,
-- unlike Parent A's, it was never rebound by anything above.
select tests.auth_as('a0000000-0000-0000-0000-000000000002', false);
select throws_ok(
  $$select public.delete_child('aaaa0000-0000-0000-0000-000000000007')$$,
  'only a parent may delete a child',
  'a child cannot delete anyone');
select throws_ok(
  $$select public.delete_child('aaaa0000-0000-0000-0000-000000000007')$$,
  'P0005');

-- ---------------------------------------------------------------------------
-- A completion outlives the person who recorded it
-- ---------------------------------------------------------------------------

-- A parent's completion on a child's behalf must outlive the parent's profile.
select tests.as_admin();
insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by)
  values ('11111111-1111-1111-1111-111111111111',
          'aaaa0000-0000-0000-0000-000000000002',
          'cccc0000-0000-0000-0000-000000000001',
          '2026-08-10',
          'aaaa0000-0000-0000-0000-000000000001');

delete from public.profiles where id = 'aaaa0000-0000-0000-0000-000000000001';

select is(
  (select count(*)::int from public.completions
     where profile_id = 'aaaa0000-0000-0000-0000-000000000002'
       and due_on = '2026-08-10'),
  1,
  'deleting the parent who recorded a completion leaves the completion');

select is(
  (select completed_by from public.completions
     where profile_id = 'aaaa0000-0000-0000-0000-000000000002'
       and due_on = '2026-08-10'),
  null::uuid,
  'and completed_by becomes null rather than the row vanishing');

select tests.as_admin();
select * from finish();
rollback;
