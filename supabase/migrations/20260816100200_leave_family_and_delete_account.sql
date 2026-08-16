-- Ways out.
--
-- Making identity durable makes mistakes durable too: before Sign in with Apple
-- a parent could reset by deleting the app, and now they cannot. These are the
-- replacements. Account deletion is not optional polish either: App Review
-- guideline 5.1.1(v) requires any app supporting account creation to offer
-- account deletion in-app.
--
-- Leaving deletes the profile outright rather than unbinding it, so no ghost
-- seat is left in People. Because both functions are SECURITY DEFINER the
-- deletion happens server-side and `authenticated` still holds no DELETE grant
-- on profiles — the property asserted in 20260813120000_table_grants.sql.
--
-- Note that nothing here unbinds `auth_user_id`, so claim_profile() remains its
-- only writer and `app.allow_claim` keeps its accurate name.

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
    raise exception 'caller has no profile';
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
    raise exception 'not authenticated';
  end if;

  -- A caller with no profile may still delete their account: they signed in and
  -- never joined a family, which is exactly when someone changes their mind.
  if exists (select 1 from public.profiles where auth_user_id = auth.uid()) then
    perform public.leave_family();
  end if;

  delete from auth.users where id = auth.uid();
end $$;
