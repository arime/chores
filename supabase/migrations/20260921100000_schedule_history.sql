-- Schedule history.
--
-- The template had no memory: ScheduleResolver read it as it stands now, so
-- archiving a chore on Thursday erased its Monday tick and moving a chore
-- rewrote what last week was due. From here on every template row knows its
-- first day, a removed row is filed in schedule_entry_history with its last,
-- every chore knows the day it was archived, and the resolver applies all of
-- it by the day it is asked about.
--
-- Shaped so the build already in the App Store keeps working, because a
-- TestFlight build can only talk to production and the store build can be
-- installed at any time. schedule_entries still means the current template:
-- the shipped client's select, its upsert on (profile_id, chore_id, weekday)
-- and its delete all behave as before. chores.is_archived stays, kept in
-- step with archived_on by a trigger, so the shipped client reads and writes
-- the flag while the new one reads and writes the day. What the shipped
-- client cannot do is leave history — its delete is a delete — and that is
-- the whole cost of the window until every parent has updated.
--
-- "Today" is the family's day. The new client sends it as p_today; for the
-- shipped client, which sends nothing, triggers compute it from
-- families.timezone. Postgres's current_date is UTC and never used.
--
-- The close-or-delete and reopen-or-insert rules live in the RPCs below and
-- are mirrored by InMemoryChoresBackend; pgTAP proves the SQL, Swift Testing
-- proves the mirror. See docs/superpowers/specs/2026-09-21-schedule-history-design.md.

-- ---------------------------------------------------------------------------
-- The family's local today, for triggers filling in what the shipped client
-- does not send.
-- ---------------------------------------------------------------------------

-- Callable by authenticated because the triggers below run as the caller;
-- it answers a date for a family id and nothing more.
create or replace function public.family_today(p_family_id uuid)
returns date language sql stable security definer set search_path = public
as $$
  select (now() at time zone f.timezone)::date from public.families f where f.id = p_family_id
$$;
revoke execute on function public.family_today(uuid) from public, anon;
grant  execute on function public.family_today(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- schedule_entries: the first day
-- ---------------------------------------------------------------------------

alter table public.schedule_entries add column valid_from date;

-- Backfill: the day the row was created, in its family's timezone. Right for
-- rows never edited, a guess for the rest, and the best guess there is.
update public.schedule_entries se
   set valid_from = (se.created_at at time zone f.timezone)::date
  from public.families f
 where f.id = se.family_id;

alter table public.schedule_entries alter column valid_from set not null;

-- The shipped client inserts without valid_from. BEFORE triggers run before
-- the NOT NULL check, so the column can be required and still filled here.
create or replace function public.schedule_entries_default_valid_from()
returns trigger language plpgsql as $$
begin
  if new.valid_from is null then
    new.valid_from := public.family_today(new.family_id);
  end if;
  return new;
end $$;

create trigger schedule_entries_default_valid_from
  before insert on public.schedule_entries
  for each row execute function public.schedule_entries_default_valid_from();

-- ---------------------------------------------------------------------------
-- schedule_entry_history: rows that used to be in the template
--
-- Same id as the row had while open, so bringing one back is the same row.
-- No uniqueness beyond id: the same (child, chore, weekday) can be closed
-- any number of times.
-- ---------------------------------------------------------------------------

create table public.schedule_entry_history (
  id          uuid primary key,
  family_id   uuid not null references public.families(id) on delete cascade,
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  chore_id    uuid not null references public.chores(id) on delete cascade,
  weekday     smallint not null check (weekday between 1 and 7),
  valid_from  date not null,
  valid_until date not null,
  created_at  timestamptz not null default now(),
  closed_at   timestamptz not null default now(),
  constraint schedule_entry_history_range check (valid_until > valid_from)
);
create index schedule_entry_history_family_idx on public.schedule_entry_history(family_id, valid_until);

-- Policies and grants mirror schedule_entries (20260810120100_rls.sql,
-- 20260813120000_table_grants.sql): the family reads, parents write. The
-- writes happen inside the RPCs, which run as the caller.
alter table public.schedule_entry_history enable row level security;
create policy schedule_history_select on public.schedule_entry_history for select
  using (family_id = public.current_family_id());
create policy schedule_history_write on public.schedule_entry_history for all
  using (family_id = public.current_family_id() and public.is_parent())
  with check (family_id = public.current_family_id() and public.is_parent());
grant select, insert, delete on public.schedule_entry_history to authenticated;

-- One relation over both, for readers that want the past as well as the
-- present. security_invoker so each table's own policies apply.
create view public.schedule_entries_all with (security_invoker = true) as
  select id, family_id, profile_id, chore_id, weekday, valid_from, null::date as valid_until, created_at
    from public.schedule_entries
  union all
  select id, family_id, profile_id, chore_id, weekday, valid_from, valid_until, created_at
    from public.schedule_entry_history;
grant select on public.schedule_entries_all to authenticated;

-- ---------------------------------------------------------------------------
-- chores: the archived-on day, beside the flag
-- ---------------------------------------------------------------------------

alter table public.chores add column archived_on date;

-- Existing archived chores: archived for their whole life, which is exactly
-- how the app has drawn them until now.
update public.chores c
   set archived_on = (c.created_at at time zone f.timezone)::date
  from public.families f
 where f.id = c.family_id and c.is_archived;

-- Whichever column a client writes, the other follows. The shipped client
-- flips is_archived; the new one sets archived_on.
create or replace function public.chores_sync_archived()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.archived_on is not null then
      new.is_archived := true;
    elsif new.is_archived then
      new.archived_on := public.family_today(new.family_id);
    end if;
  elsif new.archived_on is distinct from old.archived_on then
    new.is_archived := new.archived_on is not null;
  elsif new.is_archived is distinct from old.is_archived then
    new.archived_on := case when new.is_archived then public.family_today(new.family_id) end;
  end if;
  return new;
end $$;

create trigger chores_sync_archived
  before insert or update on public.chores
  for each row execute function public.chores_sync_archived();

-- ---------------------------------------------------------------------------
-- The evening reminder counts against the template as it stood on p_date.
-- ---------------------------------------------------------------------------

create or replace function public.family_undone_count(p_family_id uuid, p_date date)
returns int language sql stable security definer set search_path = public
as $$
  select count(*)::int
    from public.schedule_entries_all se
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

-- ---------------------------------------------------------------------------
-- The new client's three writes. All run as the caller: the policies on both
-- tables scope them to the caller's family and to parents.
-- ---------------------------------------------------------------------------

-- Return the open row; else bring back a row closed today; else insert from
-- today. Bringing back means remove-then-add within a day leaves no gap.
create or replace function public.schedule_entry_add(
  p_family_id uuid, p_profile_id uuid, p_chore_id uuid, p_weekday int, p_today date)
returns public.schedule_entries language plpgsql security invoker set search_path = public
as $$
declare
  v_row  public.schedule_entries;
  v_past public.schedule_entry_history;
begin
  select * into v_row from public.schedule_entries
   where profile_id = p_profile_id and chore_id = p_chore_id and weekday = p_weekday;
  if found then return v_row; end if;

  delete from public.schedule_entry_history
   where id = (select id from public.schedule_entry_history
                where profile_id = p_profile_id and chore_id = p_chore_id
                  and weekday = p_weekday and valid_until = p_today
                limit 1)
  returning * into v_past;
  if found then
    insert into public.schedule_entries (id, family_id, profile_id, chore_id, weekday, valid_from, created_at)
    values (v_past.id, v_past.family_id, v_past.profile_id, v_past.chore_id, v_past.weekday,
            v_past.valid_from, v_past.created_at)
    returning * into v_row;
    return v_row;
  end if;

  insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from)
  values (p_family_id, p_profile_id, p_chore_id, p_weekday, p_today)
  returning * into v_row;
  return v_row;
end $$;

-- Delete a row added today or later; file an older one in history, closed
-- from today; leave an id that is already history alone.
create or replace function public.schedule_entry_remove(p_id uuid, p_today date)
returns void language plpgsql security invoker set search_path = public
as $$
begin
  delete from public.schedule_entries where id = p_id and valid_from >= p_today;
  if found then return; end if;

  with moved as (
    delete from public.schedule_entries where id = p_id returning *
  )
  insert into public.schedule_entry_history
    (id, family_id, profile_id, chore_id, weekday, valid_from, valid_until, created_at)
  select id, family_id, profile_id, chore_id, weekday, valid_from, p_today, created_at
    from moved;
end $$;

-- Each target ends up looking like the source: its entries are removed and
-- the source's added, both by the rules above, so an entry the two days
-- share is filed and brought back in place.
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
       where family_id = p_family_id and weekday = v_target
    loop
      perform public.schedule_entry_remove(v_entry.id, p_today);
    end loop;

    for v_entry in
      select profile_id, chore_id from public.schedule_entries
       where family_id = p_family_id and weekday = p_from
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
