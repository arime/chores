-- One row per parent's phone: the APNs token the evening reminder is sent to.
--
-- The token is the primary key on purpose. Apple issues it per device and app,
-- so when a phone changes hands — one parent signs out, another signs in — the
-- row has to follow the phone, not stay with the previous person. That is why
-- clients do not write this table through RLS: a per-row policy would refuse
-- parent B's registration while parent A's row still held the token. Writes go
-- through two SECURITY DEFINER functions instead, and the token itself is the
-- proof of possession.
--
-- Children's devices never register. Their reminders are scheduled locally.
--
-- See docs/superpowers/specs/2026-09-17-parent-evening-push-design.md §4.1.

create table public.device_tokens (
  token       text primary key,
  family_id   uuid not null references public.families(id) on delete cascade,
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  environment text not null check (environment in ('development', 'production')),
  updated_at  timestamptz not null default now()
);
create index device_tokens_profile_idx on public.device_tokens(profile_id);

alter table public.device_tokens enable row level security;

-- Read your own; nobody has a reason to read anyone else's.
create policy device_tokens_select on public.device_tokens for select
  using (profile_id = public.current_profile_id());

grant select on public.device_tokens to authenticated;

-- Registers the caller's phone, taking the token over from whoever held it.
create or replace function public.device_token_register(p_token text, p_environment text)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
begin
  select * into v_profile from public.profiles where auth_user_id = auth.uid();
  if v_profile.id is null or v_profile.role <> 'parent' then
    raise exception 'only a parent may register a device' using errcode = 'P0005';
  end if;

  insert into public.device_tokens (token, family_id, profile_id, environment)
  values (p_token, v_profile.family_id, v_profile.id, p_environment)
  on conflict (token) do update
    set family_id   = excluded.family_id,
        profile_id  = excluded.profile_id,
        environment = excluded.environment,
        updated_at  = now();
end $$;

-- Removes the caller's own row for this token, if it is theirs. Scoped to the
-- caller so a forget sent late from a phone's previous holder cannot remove
-- the new holder's registration.
create or replace function public.device_token_forget(p_token text)
returns void language sql security definer set search_path = public
as $$
  delete from public.device_tokens
   where token = p_token
     and profile_id = public.current_profile_id();
$$;

revoke execute on function public.device_token_register(text, text) from public, anon;
grant  execute on function public.device_token_register(text, text) to authenticated;
revoke execute on function public.device_token_forget(text) from public, anon;
grant  execute on function public.device_token_forget(text) to authenticated;
