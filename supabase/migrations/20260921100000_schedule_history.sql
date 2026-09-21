-- Schedule history.
--
-- The template had no memory: ScheduleResolver read it as it stands now, so
-- archiving a chore on Thursday erased its Monday tick and moving a chore
-- rewrote what last week was due. Every template row now carries a validity
-- range and every chore the day it was archived, and the resolver applies
-- both by the day it is asked about.
--
-- valid_from is inclusive and valid_until exclusive; null = still current.
-- Removing an entry closes it rather than deleting it, except one added the
-- same day, which is deleted — it lived zero days. Those rules live in the
-- three RPCs below and are mirrored by InMemoryChoresBackend; pgTAP proves
-- the SQL, Swift Testing proves the mirror.
--
-- "Today" is the family's day and comes from the client as p_today. Postgres's
-- current_date is UTC, and a Helsinki parent editing at 01:00 Tuesday must
-- produce Tuesday.
--
-- See docs/superpowers/specs/2026-09-21-schedule-history-design.md.

-- ---------------------------------------------------------------------------
-- schedule_entries: the range
-- ---------------------------------------------------------------------------

alter table public.schedule_entries
  add column valid_from  date,
  add column valid_until date;

-- Backfill: the day the row was created, in its family's timezone. Right for
-- rows never edited, a guess for the rest, and the best guess there is.
update public.schedule_entries se
   set valid_from = (se.created_at at time zone f.timezone)::date
  from public.families f
 where f.id = se.family_id;

alter table public.schedule_entries
  alter column valid_from set not null,
  add constraint schedule_entries_range check (valid_until is null or valid_until > valid_from);

-- One open row per (child, chore, weekday); any number of closed ones.
alter table public.schedule_entries
  drop constraint schedule_entries_profile_id_chore_id_weekday_key;
create unique index schedule_entries_open_key
  on public.schedule_entries (profile_id, chore_id, weekday)
  where valid_until is null;

-- ---------------------------------------------------------------------------
-- chores: the archived-on day. is_archived goes last, after every reader of
-- it has been rewritten — a `language sql` body is parsed at creation.
-- ---------------------------------------------------------------------------

alter table public.chores add column archived_on date;

-- Existing archived chores: archived for their whole life, which is exactly
-- how the app has drawn them until now.
update public.chores c
   set archived_on = (c.created_at at time zone f.timezone)::date
  from public.families f
 where f.id = c.family_id and c.is_archived;

-- How many of a family's scheduled chores for `p_date` no child has ticked
-- off — now against the template as it stood on p_date.
create or replace function public.family_undone_count(p_family_id uuid, p_date date)
returns int language sql stable security definer set search_path = public
as $$
  select count(*)::int
    from public.schedule_entries se
    join public.chores   c on c.id = se.chore_id
                          and (c.archived_on is null or c.archived_on > p_date)
    join public.profiles p on p.id = se.profile_id and p.role = 'child'
   where se.family_id = p_family_id
     and se.weekday = extract(isodow from p_date)
     and se.valid_from <= p_date
     and (se.valid_until is null or se.valid_until > p_date)
     and not exists (select 1 from public.completions co
                      where co.profile_id = se.profile_id
                        and co.chore_id   = se.chore_id
                        and co.due_on     = p_date);
$$;

alter table public.chores drop column is_archived;

-- ---------------------------------------------------------------------------
-- The three writes. All run as the caller: schedule_write RLS scopes them to
-- the caller's family and to parents, exactly as the direct writes they
-- replace were scoped.
-- ---------------------------------------------------------------------------

-- Return the open row; else reopen a row closed today; else insert from today.
-- Reopening means remove-then-add within a day leaves no one-day gap.
create or replace function public.schedule_entry_add(
  p_family_id uuid, p_profile_id uuid, p_chore_id uuid, p_weekday int, p_today date)
returns public.schedule_entries language plpgsql security invoker set search_path = public
as $$
declare v_row public.schedule_entries;
begin
  select * into v_row from public.schedule_entries
   where profile_id = p_profile_id and chore_id = p_chore_id and weekday = p_weekday
     and valid_until is null;
  if found then return v_row; end if;

  -- At most one row per triple can be closed on any given day: closing the
  -- open row is the only way to make one, and there is only ever one open row.
  update public.schedule_entries set valid_until = null
   where profile_id = p_profile_id and chore_id = p_chore_id and weekday = p_weekday
     and valid_until = p_today
  returning * into v_row;
  if found then return v_row; end if;

  insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from)
  values (p_family_id, p_profile_id, p_chore_id, p_weekday, p_today)
  returning * into v_row;
  return v_row;
end $$;

-- Delete a row added today; close an open one from today; leave a closed one.
create or replace function public.schedule_entry_remove(p_id uuid, p_today date)
returns void language plpgsql security invoker set search_path = public
as $$
begin
  delete from public.schedule_entries where id = p_id and valid_from = p_today;
  if found then return; end if;

  update public.schedule_entries set valid_until = p_today
   where id = p_id and valid_until is null;
end $$;

-- Each target ends up looking like the source: its open entries are removed
-- and the source's open entries added, both by the rules above, so an entry
-- the two days share is closed and reopened in place.
create or replace function public.schedule_copy_day(
  p_family_id uuid, p_from int, p_to int[], p_today date)
returns void language plpgsql security invoker set search_path = public
as $$
declare
  v_target int;
  v_entry  record;
begin
  foreach v_target in array p_to loop
    continue when v_target = p_from;

    for v_entry in
      select id from public.schedule_entries
       where family_id = p_family_id and weekday = v_target and valid_until is null
    loop
      perform public.schedule_entry_remove(v_entry.id, p_today);
    end loop;

    for v_entry in
      select profile_id, chore_id from public.schedule_entries
       where family_id = p_family_id and weekday = p_from and valid_until is null
    loop
      perform public.schedule_entry_add(p_family_id, v_entry.profile_id, v_entry.chore_id,
                                        v_target, p_today);
    end loop;
  end loop;
end $$;

-- Signed-in phones only. RLS does the rest.
revoke execute on function public.schedule_entry_add(uuid, uuid, uuid, int, date) from public, anon;
revoke execute on function public.schedule_entry_remove(uuid, date)               from public, anon;
revoke execute on function public.schedule_copy_day(uuid, int, int[], date)      from public, anon;
grant  execute on function public.schedule_entry_add(uuid, uuid, uuid, int, date) to authenticated;
grant  execute on function public.schedule_entry_remove(uuid, date)               to authenticated;
grant  execute on function public.schedule_copy_day(uuid, int, int[], date)      to authenticated;
