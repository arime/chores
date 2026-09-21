-- Schedule history: the current template stays in schedule_entries, closed
-- rows move to schedule_entry_history, and the build already in the App
-- Store keeps working against both.
--
-- The compatibility assertions come first and matter most: the shipped
-- client inserts without valid_from, upserts on (profile_id, chore_id,
-- weekday), and reads and writes chores.is_archived. Every rule the RPCs
-- enforce is one the in-memory backend mirrors in Swift. Run with:
--   supabase db reset && supabase test db

begin;
set local search_path to public, extensions;

select plan(39);

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

-- The family's local today, as the triggers compute it.
create function tests.helsinki_today() returns date language sql stable as
  $$ select (now() at time zone 'Europe/Helsinki')::date $$;

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

insert into public.chores (id, family_id, name) values
  ('cccc0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bins'),
  ('cccc0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Dishes');

-- ---------------------------------------------------------------------------
-- Shape
-- ---------------------------------------------------------------------------

select has_column('public', 'schedule_entries', 'valid_from', 'schedule_entries.valid_from exists');
select hasnt_column('public', 'schedule_entries', 'valid_until', 'an open row has no end');
select has_table('public', 'schedule_entry_history', 'schedule_entry_history exists');
select has_view('public', 'schedule_entries_all', 'schedule_entries_all exists');
select has_column('public', 'chores', 'archived_on', 'chores.archived_on exists');
select has_column('public', 'chores', 'is_archived', 'chores.is_archived is kept for the shipped build');

select throws_ok(
  $$insert into public.schedule_entry_history
      (id, family_id, profile_id, chore_id, weekday, valid_from, valid_until)
    values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111',
            'aaaa0000-0000-0000-0000-000000000003', 'cccc0000-0000-0000-0000-000000000001',
            1, '2026-08-10', '2026-08-10')$$,
  '23514', null, 'a closed range must end after it begins');

-- ---------------------------------------------------------------------------
-- The shipped build, as the parent: no valid_from, upsert, is_archived
-- ---------------------------------------------------------------------------

select tests.auth_as('a0000000-0000-0000-0000-000000000001');

insert into public.schedule_entries (id, family_id, profile_id, chore_id, weekday)
values ('ee000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'aaaa0000-0000-0000-0000-000000000003', 'cccc0000-0000-0000-0000-000000000002', 4);
select is((select valid_from from public.schedule_entries where id = 'ee000000-0000-0000-0000-000000000001'),
          tests.helsinki_today(),
          'an insert with no valid_from is stamped with the family''s local today');

with upserted as (
  insert into public.schedule_entries (family_id, profile_id, chore_id, weekday)
  values ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
          'cccc0000-0000-0000-0000-000000000002', 4)
  on conflict (profile_id, chore_id, weekday) do update set weekday = excluded.weekday
  returning id)
select is((select id from upserted), 'ee000000-0000-0000-0000-000000000001'::uuid,
          'the shipped upsert still resolves on (profile_id, chore_id, weekday)');
delete from public.schedule_entries where id = 'ee000000-0000-0000-0000-000000000001';

update public.chores set is_archived = true where id = 'cccc0000-0000-0000-0000-000000000002';
select is((select archived_on from public.chores where id = 'cccc0000-0000-0000-0000-000000000002'),
          tests.helsinki_today(), 'flipping is_archived on stamps archived_on with today');
update public.chores set is_archived = false where id = 'cccc0000-0000-0000-0000-000000000002';
select is((select archived_on from public.chores where id = 'cccc0000-0000-0000-0000-000000000002'),
          null::date, 'flipping it off clears archived_on');

update public.chores set archived_on = date '2026-08-17' where id = 'cccc0000-0000-0000-0000-000000000002';
select is((select is_archived from public.chores where id = 'cccc0000-0000-0000-0000-000000000002'),
          true, 'setting archived_on sets is_archived');
update public.chores set archived_on = null where id = 'cccc0000-0000-0000-0000-000000000002';
select is((select is_archived from public.chores where id = 'cccc0000-0000-0000-0000-000000000002'),
          false, 'clearing archived_on clears is_archived');

-- ---------------------------------------------------------------------------
-- schedule_entry_add / schedule_entry_remove
-- ---------------------------------------------------------------------------

-- Day 1: add Bins on Monday.
create temp table t as
  select * from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 1, date '2026-08-10');
select is((select valid_from from t), date '2026-08-10', 'add stamps valid_from with p_today');

-- Adding again returns the same open row.
select is(
  (select id from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 1, date '2026-08-12')),
  (select id from t),
  'adding an entry that already applies returns it unchanged');
select is((select count(*)::int from public.schedule_entries
            where chore_id = 'cccc0000-0000-0000-0000-000000000001'), 1, 'and inserts nothing');

-- Day 5: remove it. Moved to history, not deleted.
select public.schedule_entry_remove((select id from t), date '2026-08-14');
select is((select count(*)::int from public.schedule_entries where id = (select id from t)), 0,
          'removing on a later day takes the row out of the template');
select is((select valid_until from public.schedule_entry_history where id = (select id from t)),
          date '2026-08-14', 'and files it in history, closed from that day');
select is((select valid_from from public.schedule_entry_history where id = (select id from t)),
          date '2026-08-10', 'with its first day intact');

-- Removing an id that is already history does nothing.
select public.schedule_entry_remove((select id from t), date '2026-08-20');
select is((select valid_until from public.schedule_entry_history where id = (select id from t)),
          date '2026-08-14', 'removing an already closed entry leaves its close day alone');

-- Day 5 still: add it back. The same row comes back.
select is(
  (select id from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 1, date '2026-08-14')),
  (select id from t),
  'adding back on the close day brings the same row back');
select is((select count(*)::int from public.schedule_entry_history where id = (select id from t)), 0,
          'and it leaves history');
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
select is((select count(*)::int from public.schedule_entry_history where id = (select id from t)), 1,
          'while the closed one stays in history');

-- An entry added and removed on the same day never existed.
select public.schedule_entry_remove((select id from t2), date '2026-08-18');
select is((select count(*)::int from public.schedule_entries where id = (select id from t2)), 0,
          'removing on the day it was added deletes it');
select is((select count(*)::int from public.schedule_entry_history where id = (select id from t2)), 0,
          'and files nothing');

-- ---------------------------------------------------------------------------
-- schedule_entries_all: what the new client reads
-- ---------------------------------------------------------------------------

select is((select count(*)::int from public.schedule_entries_all
            where chore_id = 'cccc0000-0000-0000-0000-000000000001'), 1,
          'the view shows the closed row');
select is((select valid_until from public.schedule_entries_all where id = (select id from t)),
          date '2026-08-14', 'with its end');

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

select is((select valid_until from public.schedule_entry_history where id = (select id from tue_bins)),
          date '2026-08-14', 'copy-day closes a target entry the source lacks');
select is((select count(*)::int from public.schedule_entries where id = (select id from tue_dishes)), 1,
          'and leaves a matching one open');
select is((select count(*)::int from public.schedule_entries where weekday = 2), 1,
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
select throws_ok(
  $$insert into public.schedule_entry_history
      (id, family_id, profile_id, chore_id, weekday, valid_from, valid_until)
    values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111',
            'aaaa0000-0000-0000-0000-000000000003', 'cccc0000-0000-0000-0000-000000000001',
            5, '2026-08-01', '2026-08-02')$$,
  '42501', null, 'nor write history directly');
select is((select count(*)::int from public.schedule_entries_all), 4,
          'but reads the family''s whole template, history included');

-- ---------------------------------------------------------------------------
-- family_undone_count reads through both tables
-- ---------------------------------------------------------------------------

select tests.as_admin();
delete from public.schedule_entries;
delete from public.schedule_entry_history;

-- Bins on Monday, valid 10–14 Aug (closed on the 14th). Dishes on Monday, open.
-- Dishes archived on Monday 17 Aug.
insert into public.schedule_entry_history
  (id, family_id, profile_id, chore_id, weekday, valid_from, valid_until) values
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000001', 1, '2026-08-10', '2026-08-14');
insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from) values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000002', 1, '2026-08-01');
update public.chores set archived_on = '2026-08-17' where id = 'cccc0000-0000-0000-0000-000000000002';

select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-08-10'), 2,
          'on 10 Aug both Monday chores are due');
select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-08-17'), 0,
          'on 17 Aug Bins is closed and Dishes is archived from that day');
select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-08-03'), 1,
          'on 3 Aug only Dishes existed');

select * from finish();
rollback;
