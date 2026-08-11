-- Row level security. Every policy scopes to the caller's family.
--
-- An RLS bug here fails silently — no crash, just data visible to the wrong
-- person — so the pgTAP suite in supabase/tests is the real gate on this file.

create extension if not exists pgtap with schema extensions;

-- ---------------------------------------------------------------------------
-- Helpers
--
-- SECURITY DEFINER is required, not incidental: these are called from policies
-- ON public.profiles, and a policy that queries its own table under RLS
-- recurses infinitely. Running as the owner bypasses RLS inside the function.
-- ---------------------------------------------------------------------------

create or replace function public.current_profile_id()
returns uuid language sql stable security definer set search_path = public
as $$ select id from public.profiles where auth_user_id = auth.uid() limit 1 $$;

create or replace function public.current_family_id()
returns uuid language sql stable security definer set search_path = public
as $$ select family_id from public.profiles where auth_user_id = auth.uid() limit 1 $$;

create or replace function public.is_parent()
returns boolean language sql stable security definer set search_path = public
as $$ select exists (
  select 1 from public.profiles
  where auth_user_id = auth.uid() and role = 'parent') $$;

-- ---------------------------------------------------------------------------
-- auth_user_id may only be set by claim_profile(), which opts in by setting
-- app.allow_claim for the duration of its transaction.
-- ---------------------------------------------------------------------------

create or replace function public.prevent_auth_user_id_change()
returns trigger language plpgsql as $$
begin
  if new.auth_user_id is distinct from old.auth_user_id
     and coalesce(current_setting('app.allow_claim', true), '') <> 'on' then
    raise exception 'auth_user_id may only be set by claim_profile()';
  end if;
  return new;
end $$;

create trigger profiles_lock_auth_user_id
  before update on public.profiles
  for each row execute function public.prevent_auth_user_id_change();

-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------

alter table public.families         enable row level security;
alter table public.profiles         enable row level security;
alter table public.claim_codes      enable row level security;
alter table public.chores           enable row level security;
alter table public.schedule_entries enable row level security;
alter table public.completions      enable row level security;

-- families: no INSERT policy — creation goes through create_family() only.
create policy families_select on public.families for select
  using (id = public.current_family_id());
create policy families_update on public.families for update
  using (id = public.current_family_id() and public.is_parent());

create policy profiles_select on public.profiles for select
  using (family_id = public.current_family_id());
create policy profiles_insert on public.profiles for insert
  with check (family_id = public.current_family_id()
              and public.is_parent()
              and auth_user_id is null);
create policy profiles_update on public.profiles for update
  using (family_id = public.current_family_id() and public.is_parent());

create policy claim_codes_all on public.claim_codes for all
  using (family_id = public.current_family_id() and public.is_parent())
  with check (family_id = public.current_family_id() and public.is_parent());

create policy chores_select on public.chores for select
  using (family_id = public.current_family_id());
create policy chores_write on public.chores for all
  using (family_id = public.current_family_id() and public.is_parent())
  with check (family_id = public.current_family_id() and public.is_parent());

create policy schedule_select on public.schedule_entries for select
  using (family_id = public.current_family_id());
create policy schedule_write on public.schedule_entries for all
  using (family_id = public.current_family_id() and public.is_parent())
  with check (family_id = public.current_family_id() and public.is_parent());

-- A child may create and destroy only their own completions; a parent may do
-- either for anyone in the family. That parent DELETE is the entire
-- "un-check a completion" feature.
create policy completions_select on public.completions for select
  using (family_id = public.current_family_id());
create policy completions_insert on public.completions for insert
  with check (family_id = public.current_family_id()
              and (public.is_parent() or profile_id = public.current_profile_id()));
create policy completions_delete on public.completions for delete
  using (family_id = public.current_family_id()
         and (public.is_parent() or profile_id = public.current_profile_id()));

-- Deliberately no UPDATE policy on completions: a completion is created or
-- destroyed, never edited.
