-- The anonymous-caller guards in create_family() and claim_profile() used a
-- bare `raise exception`, which plpgsql always tags with SQLSTATE P0001 — the
-- same code already used for "unknown claim code". SupabaseErrorMapping maps
-- P0001 to .unknownClaimCode, so a parent who is merely signed in anonymously
-- was told "we don't recognise that code", which is wrong advice about a code
-- they never typed.
--
-- P0001/P0002/P0003 are already spoken for by the claim-code cases in
-- claim_profile(); P0004 is the next free code in that sequence. Nothing else
-- about either function changes here.

create or replace function public.create_family(
  family_name text,
  parent_name text,
  family_timezone text default 'Europe/Helsinki')
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_family_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if public.is_anonymous_caller() then
    raise exception 'parents must sign in' using errcode = 'P0004';
  end if;
  if exists (select 1 from public.profiles where auth_user_id = auth.uid()) then
    raise exception 'caller already has a profile';
  end if;

  insert into public.families (name, timezone)
    values (family_name, family_timezone)
    returning id into v_family_id;

  insert into public.profiles (family_id, auth_user_id, display_name, role, color, sort_order)
    values (v_family_id, auth.uid(), parent_name, 'parent', '#4C8BF5', 0);

  return v_family_id;
end $$;

create or replace function public.claim_profile(p_code text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_norm text := upper(trim(p_code));
  v_profile_id uuid;
  v_expires timestamptz;
  v_claimed timestamptz;
  v_role text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from public.profiles where auth_user_id = auth.uid()) then
    raise exception 'device already claimed';
  end if;

  select profile_id, expires_at, claimed_at
    into v_profile_id, v_expires, v_claimed
    from public.claim_codes where code = v_norm;

  if v_profile_id is null then
    raise exception 'unknown code' using errcode = 'P0001';
  end if;
  if v_claimed is not null then
    raise exception 'code already used' using errcode = 'P0002';
  end if;
  if v_expires < now() then
    raise exception 'code expired' using errcode = 'P0003';
  end if;

  -- Checked after the code itself, so a bad code still reports why it is bad.
  select role into v_role from public.profiles where id = v_profile_id;
  if v_role = 'parent' and public.is_anonymous_caller() then
    raise exception 'parents must sign in' using errcode = 'P0004';
  end if;

  perform set_config('app.allow_claim', 'on', true);
  update public.profiles set auth_user_id = auth.uid() where id = v_profile_id;
  update public.claim_codes set claimed_at = now() where code = v_norm;

  return v_profile_id;
end $$;
