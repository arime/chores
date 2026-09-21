-- Schedule history: validity ranges on the template, the three RPCs that
-- maintain them, and the undone count reading through them.
--
-- Every rule here is one the in-memory backend mirrors in Swift. If one of
-- these changes, InMemoryBackendTests changes with it. Run with:
--   supabase db reset && supabase test db

begin;
set local search_path to public, extensions;

select plan(28);

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
-- Fixtures. One family in Helsinki: a parent, a child, two chores.
-- 2026-08-10 is a Monday.
-- ---------------------------------------------------------------------------

insert into auth.users (id) values
  ('a0000000-0000-0000-0000-000000000001'),  -- P1, parent
  ('a0000000-0000-0000-0000-000000000003');  -- C1, child

insert into public.families (id, name, timezone) values
  ('11111111-1111-1111-1111-111111111111', 'Koti', 'Europe/Helsinki');

insert into public.profiles (id, family_id, auth_user_id, display_name, role) values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000001', 'P1', 'parent'),
  ('aaaa0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000003', 'C1', 'child');

insert into public.chores (id, family_id, name, archived_on) values
  ('cccc0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bins',   null),
  ('cccc0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Dishes', null);

-- ---------------------------------------------------------------------------
-- The columns and the index
-- ---------------------------------------------------------------------------

select has_column('public', 'schedule_entries', 'valid_from',  'schedule_entries.valid_from exists');
select has_column('public', 'schedule_entries', 'valid_until', 'schedule_entries.valid_until exists');
select has_column('public', 'chores', 'archived_on', 'chores.archived_on exists');
select hasnt_column('public', 'chores', 'is_archived', 'chores.is_archived is gone');

select throws_ok(
  $$insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from)
    values ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
            'cccc0000-0000-0000-0000-000000000001', 1, null)$$,
  '23502', null, 'valid_from is required');

select throws_ok(
  $$insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from, valid_until)
    values ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
            'cccc0000-0000-0000-0000-000000000001', 1, '2026-08-10', '2026-08-10')$$,
  '23514', null, 'a range must end after it begins');

-- A closed row and an open row may share a (profile, chore, weekday); two open rows may not.
insert into public.schedule_entries (id, family_id, profile_id, chore_id, weekday, valid_from, valid_until) values
  ('ee000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'aaaa0000-0000-0000-0000-000000000003', 'cccc0000-0000-0000-0000-000000000002', 1, '2026-07-01', '2026-07-15'),
  ('ee000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'aaaa0000-0000-0000-0000-000000000003', 'cccc0000-0000-0000-0000-000000000002', 1, '2026-08-01', null);
select pass('a closed and an open row for one triple coexist');
select throws_ok(
  $$insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from)
    values ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
            'cccc0000-0000-0000-0000-000000000002', 1, '2026-08-05')$$,
  '23505', null, 'but not two open rows');
delete from public.schedule_entries where id in
  ('ee000000-0000-0000-0000-000000000001', 'ee000000-0000-0000-0000-000000000002');

-- ---------------------------------------------------------------------------
-- schedule_entry_add / schedule_entry_remove, as the parent
-- ---------------------------------------------------------------------------

select tests.auth_as('a0000000-0000-0000-0000-000000000001');

-- Day 1: add Bins on Monday.
create temp table t as
  select * from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 1, date '2026-08-10');
select is((select valid_from from t), date '2026-08-10', 'add stamps valid_from with p_today');
select is((select valid_until from t), null::date, 'and leaves valid_until open');

-- Adding again returns the same open row.
select is(
  (select id from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 1, date '2026-08-12')),
  (select id from t),
  'adding an entry that already applies returns it unchanged');
select is((select count(*)::int from public.schedule_entries
            where chore_id = 'cccc0000-0000-0000-0000-000000000001'), 1, 'and inserts nothing');

-- Day 5: remove it. Closed, not deleted.
select public.schedule_entry_remove((select id from t), date '2026-08-14');
select is((select valid_until from public.schedule_entries where id = (select id from t)),
          date '2026-08-14', 'removing on a later day closes the entry from that day');

-- Removing a closed entry again does nothing.
select public.schedule_entry_remove((select id from t), date '2026-08-20');
select is((select valid_until from public.schedule_entries where id = (select id from t)),
          date '2026-08-14', 'removing an already closed entry leaves its close day alone');

-- Day 5 still: add it back. The same row reopens.
select is(
  (select id from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 1, date '2026-08-14')),
  (select id from t),
  'adding back on the close day reopens the same row');
select is((select valid_until from public.schedule_entries where id = (select id from t)),
          null::date, 'and it is open again');
select is((select valid_from from public.schedule_entries where id = (select id from t)),
          date '2026-08-10', 'with its original first day');

-- Close it again on day 5, then add on day 9: a new row.
select public.schedule_entry_remove((select id from t), date '2026-08-14');
create temp table t2 as
  select * from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 1, date '2026-08-18');
select isnt((select id from t2), (select id from t), 'adding after an older close starts a new row');
select is((select valid_from from t2), date '2026-08-18', 'from p_today');
select is((select count(*)::int from public.schedule_entries
            where chore_id = 'cccc0000-0000-0000-0000-000000000001'), 2, 'both rows remain');

-- An entry added and removed on the same day never existed.
select public.schedule_entry_remove((select id from t2), date '2026-08-18');
select is((select count(*)::int from public.schedule_entries where id = (select id from t2)), 0,
          'removing on the day it was added deletes it');

-- ---------------------------------------------------------------------------
-- schedule_copy_day
-- ---------------------------------------------------------------------------

-- Monday: Dishes. Tuesday: Bins and Dishes. All from day 1.
select public.schedule_entry_add(
  '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
  'cccc0000-0000-0000-0000-000000000002', 1, date '2026-08-10');
create temp table tue_bins as
  select * from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 2, date '2026-08-10');
create temp table tue_dishes as
  select * from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000002', 2, date '2026-08-10');

select public.schedule_copy_day('11111111-1111-1111-1111-111111111111', 1, array[2], date '2026-08-14');

select is((select valid_until from public.schedule_entries where id = (select id from tue_bins)),
          date '2026-08-14', 'copy-day closes a target entry the source lacks');
select is((select valid_until from public.schedule_entries where id = (select id from tue_dishes)),
          null::date, 'and leaves a matching one open');
select is((select count(*)::int from public.schedule_entries where weekday = 2 and valid_until is null), 1,
          'so Tuesday now looks like Monday');

-- ---------------------------------------------------------------------------
-- A child may not
-- ---------------------------------------------------------------------------

select tests.auth_as('a0000000-0000-0000-0000-000000000003');
select throws_ok(
  $$select public.schedule_entry_add(
      '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
      'cccc0000-0000-0000-0000-000000000002', 3, date '2026-08-10')$$,
  '42501', null, 'a child cannot add to the schedule through the RPC');

-- ---------------------------------------------------------------------------
-- family_undone_count reads through the ranges
-- ---------------------------------------------------------------------------

select tests.as_admin();
delete from public.schedule_entries;

-- Bins on Monday, valid 10–14 Aug (closed on the 14th). Dishes on Monday, open.
-- Dishes archived on Monday 17 Aug.
insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from, valid_until) values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000001', 1, '2026-08-10', '2026-08-14'),
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000002', 1, '2026-08-01', null);
update public.chores set archived_on = '2026-08-17' where id = 'cccc0000-0000-0000-0000-000000000002';

select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-08-10'), 2,
          'on 10 Aug both Monday chores are due');
select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-08-17'), 0,
          'on 17 Aug Bins is closed and Dishes is archived from that day');
select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-08-03'), 1,
          'on 3 Aug only Dishes existed');

select * from finish();
rollback;
