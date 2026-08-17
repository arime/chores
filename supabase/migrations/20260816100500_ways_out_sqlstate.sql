-- The rest of this branch's bare `raise exception`s.
--
-- 20260816100400_mustsignin_sqlstate.sql fixed the anonymous-caller guards in
-- create_family() and claim_profile(): a bare raise is always tagged P0001,
-- and SupabaseErrorMapping reads P0001 as "unknown claim code". The same
-- branch added five more bare raises that collide the same way —
-- leave_family()'s 'caller has no profile', delete_account()'s
-- 'not authenticated', and delete_child()'s three guards. Every one of them
-- currently reaches SupabaseErrorMapping as .unknownClaimCode too.
--
-- All five are "you are not allowed to do that" conditions reached only
-- through parent-only UI that already restricts who gets this far — none is a
-- case the app needs to tell apart from the others to respond differently.
-- One shared code, P0005, is enough; minting five would buy nothing since the
-- app has one honest, generic response for all of them.

create or replace function public.leave_family()
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_profile_id uuid;
  v_family_id uuid;
  v_other_parents int;
begin
  select id, family_id into v_profile_id, v_family_id
    from public.profiles where auth_user_id = auth.uid();
  if v_profile_id is null then
    raise exception 'caller has no profile' using errcode = 'P0005';
  end if;

  select count(*) into v_other_parents
    from public.profiles
    where family_id = v_family_id and role = 'parent' and id <> v_profile_id;

  if v_other_parents = 0 then
    -- Last parent out deletes the family; the cascades clear profiles, chores,
    -- schedule entries, completions and claim codes.
    delete from public.families where id = v_family_id;
  else
    delete from public.profiles where id = v_profile_id;
  end if;
end $$;

create or replace function public.delete_account()
returns void language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'P0005';
  end if;

  -- A caller with no profile may still delete their account: they signed in and
  -- never joined a family, which is exactly when someone changes their mind.
  if exists (select 1 from public.profiles where auth_user_id = auth.uid()) then
    perform public.leave_family();
  end if;

  delete from auth.users where id = auth.uid();
end $$;

create or replace function public.delete_child(p_profile_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_family_id uuid;
  v_role text;
begin
  if not public.is_parent() then
    raise exception 'only a parent may delete a child' using errcode = 'P0005';
  end if;

  select family_id, role into v_family_id, v_role
    from public.profiles where id = p_profile_id;

  if v_family_id is null or v_family_id <> public.current_family_id() then
    raise exception 'profile not in caller family' using errcode = 'P0005';
  end if;
  if v_role <> 'child' then
    raise exception 'only a child may be deleted' using errcode = 'P0005';
  end if;

  delete from public.profiles where id = p_profile_id;
end $$;
