-- RLS and RPC regression tests.
--
-- An RLS failure is silent: no crash, just data visible to the wrong person.
-- These assertions are the only thing that catches it. Run with:
--   supabase db reset && supabase test db
--
-- Helpers are defined inside the transaction so nothing leaks into the database.

begin;
set local search_path to public, extensions;

select plan(21);

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
  values ('PARENT', '11111111-1111-1111-1111-111111111111',
          'aaaa0000-0000-0000-0000-000000000001', now() + interval '1 day');

select tests.auth_as('e0000000-0000-0000-0000-000000000001', true);
select throws_ok(
  $$select public.claim_profile('PARENT')$$,
  'parents must sign in',
  'an anonymous caller cannot claim a parent profile');

select tests.auth_as('e0000000-0000-0000-0000-000000000001', false);
select lives_ok(
  $$select public.claim_profile('PARENT')$$,
  'a signed-in caller can claim a parent profile');

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
