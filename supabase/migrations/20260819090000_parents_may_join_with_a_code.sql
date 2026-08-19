-- A parent may join an existing family with a claim code, on an anonymous
-- device, exactly as a child does.
--
-- This reverses one row of the decision table in
-- docs/superpowers/specs/2026-08-16-parent-apple-sign-in-design.md — "How does a
-- second parent join? Apple sign-in, then the existing claim code" — and with it
-- the identity model's rule that a parent profile may only ever be bound to a
-- non-anonymous auth user. The reason it was there was durability: an anonymous
-- seat lives only in one device's keychain. The reason it goes is that the
-- second parent should not need an Apple ID to be handed a place in a family
-- someone else already vouched for, and a lost device has the same remedy a
-- child's does — the other parent issues a new code.
--
-- create_family() keeps its guard, so this is narrower than it sounds:
--
--   * The *first* parent still signs in, so every family has at least one seat
--     that survives losing a device. Recovery for everyone else hangs off it.
--   * A child device still cannot bootstrap a family, which is what that guard
--     was really protecting.
--
-- What widens: whoever holds a parent code now gets full family powers from an
-- anonymous device. The code was already the whole secret — CSPRNG, single-use,
-- seven-day expiry — so the exposure is the same in kind, larger in consequence.
--
-- Only the role check goes. claim_profile() otherwise keeps every line,
-- including its place as the sole writer of auth_user_id.

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

-- P0004 still means "parents must sign in", raised by create_family() alone.
-- SupabaseErrorMapping keeps mapping it, and the app keeps showing it on the
-- one path that can still produce it: starting a family.
