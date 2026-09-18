-- When each person's reminders fire, in the family's timezone.
--
-- Both columns are nullable and null means off. What they mean depends on the
-- role: a child has an afternoon heads-up and an evening nag, both scheduled
-- locally on the child's phone; a parent has only the evening one, which the
-- server sends as a push (20260918100200_evening_reminder.sql). A parent's
-- afternoon column is ignored.
--
-- Defaults come from a trigger rather than a column default because they differ
-- by role. Consequence, accepted: a profile is always created with reminders on
-- and switched off afterwards. There is no way to create one with them off,
-- which is what removes the ambiguity between "not provided" and "off".
--
-- See docs/superpowers/specs/2026-09-17-parent-evening-push-design.md §3.1.

alter table public.profiles
  add column afternoon_reminder_at time,
  add column evening_reminder_at   time;

create or replace function public.profiles_default_reminders()
returns trigger language plpgsql as $$
begin
  if new.role = 'parent' then
    new.evening_reminder_at   := coalesce(new.evening_reminder_at, time '21:00');
    new.afternoon_reminder_at := null;
  else
    new.afternoon_reminder_at := coalesce(new.afternoon_reminder_at, time '15:00');
    new.evening_reminder_at   := coalesce(new.evening_reminder_at,   time '20:00');
  end if;
  return new;
end $$;

create trigger profiles_default_reminders
  before insert on public.profiles
  for each row execute function public.profiles_default_reminders();

-- Everyone who already exists gets the same defaults the trigger would give.
update public.profiles
   set evening_reminder_at = coalesce(evening_reminder_at, time '21:00')
 where role = 'parent';

update public.profiles
   set afternoon_reminder_at = coalesce(afternoon_reminder_at, time '15:00'),
       evening_reminder_at   = coalesce(evening_reminder_at,   time '20:00')
 where role = 'child';

-- No policy or grant changes: profiles_update already lets a parent set these,
-- and profiles_select already lets everyone in the family read them.
