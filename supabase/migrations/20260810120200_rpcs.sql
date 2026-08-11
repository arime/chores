-- Bootstrap RPCs.
--
-- These two functions are the only writes that sit outside RLS, because both
-- run for a caller who has no profile yet and therefore fails every policy.
-- They deserve the closest review in the schema.

-- ---------------------------------------------------------------------------
-- First launch on a parent's device.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- A parent issues a short code for a child's device.
-- ---------------------------------------------------------------------------
create or replace function public.generate_claim_code(p_profile_id uuid)
returns text language plpgsql security definer set search_path = public
as $$
declare
  v_code text;
  v_family uuid;
  -- Unambiguous alphabet: no I, O, 0 or 1.
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if not public.is_parent() then
    raise exception 'only a parent may generate claim codes';
  end if;

  select family_id into v_family from public.profiles where id = p_profile_id;
  if v_family is null or v_family <> public.current_family_id() then
    raise exception 'profile not in caller family';
  end if;

  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.claim_codes where code = v_code);
  end loop;

  -- Issuing a new code invalidates any outstanding unclaimed one.
  delete from public.claim_codes where profile_id = p_profile_id and claimed_at is null;

  insert into public.claim_codes (code, family_id, profile_id, expires_at)
    values (v_code, v_family, p_profile_id, now() + interval '7 days');

  return v_code;
end $$;

-- ---------------------------------------------------------------------------
-- First launch on a child's device. Distinct SQLSTATEs let the app tell the
-- reader what to actually do next rather than showing one generic failure.
-- ---------------------------------------------------------------------------
create or replace function public.claim_profile(p_code text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_norm text := upper(trim(p_code));
  v_profile_id uuid;
  v_expires timestamptz;
  v_claimed timestamptz;
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

  perform set_config('app.allow_claim', 'on', true);
  update public.profiles set auth_user_id = auth.uid() where id = v_profile_id;
  update public.claim_codes set claimed_at = now() where code = v_norm;

  return v_profile_id;
end $$;
