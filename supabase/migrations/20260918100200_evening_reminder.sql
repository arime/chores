-- The evening reminder, decided in SQL.
--
-- A parent is due when their family's local clock has passed their own
-- evening_reminder_at, for an hour. If the family's day is unfinished — some
-- child still has a scheduled chore with no completion for today — a claim row
-- is written and the parent's phones are returned to whoever will do the
-- sending. The claim comes *before* the send: a second run in the same hour
-- finds it and returns nothing, so a reminder can never arrive twice. The cost
-- is that a send which fails after claiming is not retried that evening; it
-- sits in the table with `failure` set, where it can be read.
--
-- Every function here runs as the service role only. Phones reach none of it.
--
-- See docs/superpowers/specs/2026-09-17-parent-evening-push-design.md §4.2, §5.

create table public.evening_reminder_sends (
  profile_id   uuid not null references public.profiles(id) on delete cascade,
  local_date   date not null,
  claimed_at   timestamptz not null default now(),
  sent_at      timestamptz,
  undone_count int  not null,
  device_count int  not null,
  failure      text,
  primary key (profile_id, local_date)
);

-- Enabled with no policies: nothing a phone can do reaches this table.
alter table public.evening_reminder_sends enable row level security;

-- How many of a family's scheduled chores for `p_date` no child has ticked off.
-- Its own function so pgTAP can test the rule in isolation, and so a future
-- per-child push could reuse it.
create or replace function public.family_undone_count(p_family_id uuid, p_date date)
returns int language sql stable security definer set search_path = public
as $$
  select count(*)::int
    from public.schedule_entries se
    join public.chores   c on c.id = se.chore_id and not c.is_archived
    join public.profiles p on p.id = se.profile_id and p.role = 'child'
   where se.family_id = p_family_id
     and se.weekday = extract(isodow from p_date)
     and not exists (select 1 from public.completions co
                      where co.profile_id = se.profile_id
                        and co.chore_id   = se.chore_id
                        and co.due_on     = p_date);
$$;

-- Claims every parent who is due right now, then returns their phones.
-- `p_now` is a parameter so the window can be tested; the job passes nothing.
create or replace function public.evening_reminder_work(p_now timestamptz default now())
returns table (profile_id uuid, local_date date, undone_count int, token text, environment text)
language plpgsql security definer set search_path = public
as $$
-- The RETURNS TABLE columns are also PL/pgSQL variables, and an unqualified
-- `profile_id` in the query below would be ambiguous between the two. Every
-- reference is qualified anyway; this makes the column win if one is missed.
#variable_conflict use_column
begin
  return query
  with due as (
    select p.id                                       as profile_id,
           (p_now at time zone f.timezone)::date      as local_date,
           f.id                                       as family_id
      from public.profiles p
      join public.families f on f.id = p.family_id
     where p.role = 'parent'
       and p.evening_reminder_at is not null
       -- The hour after the configured time, on timestamps rather than times so
       -- a 23:30 setting is clipped at midnight instead of wrapping.
       and (p_now at time zone f.timezone)
             >= (p_now at time zone f.timezone)::date + p.evening_reminder_at
       and (p_now at time zone f.timezone)
             <  (p_now at time zone f.timezone)::date + p.evening_reminder_at + interval '1 hour'
       and not exists (select 1 from public.evening_reminder_sends s
                        where s.profile_id = p.id
                          and s.local_date = (p_now at time zone f.timezone)::date)
  ),
  claimed as (
    insert into public.evening_reminder_sends (profile_id, local_date, undone_count, device_count)
    select d.profile_id,
           d.local_date,
           public.family_undone_count(d.family_id, d.local_date),
           (select count(*) from public.device_tokens t where t.profile_id = d.profile_id)
      from due d
     where public.family_undone_count(d.family_id, d.local_date) > 0
    returning evening_reminder_sends.profile_id,
              evening_reminder_sends.local_date,
              evening_reminder_sends.undone_count
  )
  select c.profile_id, c.local_date, c.undone_count, t.token, t.environment
    from claimed c
    join public.device_tokens t on t.profile_id = c.profile_id;
end $$;

-- The sender's report: when it went, or why it did not.
create or replace function public.evening_reminder_record(
  p_profile_id uuid, p_local_date date, p_sent_at timestamptz, p_failure text)
returns void language sql security definer set search_path = public
as $$
  update public.evening_reminder_sends
     set sent_at = p_sent_at, failure = p_failure
   where profile_id = p_profile_id and local_date = p_local_date;
$$;

-- Tokens Apple reported dead. Without this they accumulate forever and every
-- evening pays for them.
create or replace function public.device_tokens_forget(p_tokens text[])
returns void language sql security definer set search_path = public
as $$
  delete from public.device_tokens where token = any(p_tokens);
$$;

-- Service role only. Functions are executable by PUBLIC unless told otherwise,
-- and PostgREST would expose them to every signed-in phone.
revoke execute on function public.family_undone_count(uuid, date)                  from public, anon, authenticated;
revoke execute on function public.evening_reminder_work(timestamptz)                from public, anon, authenticated;
revoke execute on function public.evening_reminder_record(uuid, date, timestamptz, text) from public, anon, authenticated;
revoke execute on function public.device_tokens_forget(text[])                      from public, anon, authenticated;
grant  execute on function public.family_undone_count(uuid, date)                  to service_role;
grant  execute on function public.evening_reminder_work(timestamptz)                to service_role;
grant  execute on function public.evening_reminder_record(uuid, date, timestamptz, text) to service_role;
grant  execute on function public.device_tokens_forget(text[])                      to service_role;
