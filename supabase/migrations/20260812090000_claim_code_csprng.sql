-- Draw claim codes from a CSPRNG instead of `random()`.
--
-- A claim code is a bearer credential: whoever types it binds their device to a
-- child's profile and gains read access to the whole family. `random()` is a
-- per-backend seeded PRNG, not a cryptographic one — an attacker who observes
-- some of its output can predict the rest, and PostgREST pools connections, so
-- backends are shared between callers.
--
-- The alphabet has exactly 32 symbols, so `byte % 32` divides 256 evenly and
-- introduces no modulo bias.

create extension if not exists pgcrypto with schema extensions;

create or replace function public.generate_claim_code(p_profile_id uuid)
returns text language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_code text;
  v_bytes bytea;
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
    v_bytes := extensions.gen_random_bytes(6);
    for i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + (get_byte(v_bytes, i - 1) % 32), 1);
    end loop;
    exit when not exists (select 1 from public.claim_codes where code = v_code);
  end loop;

  -- Issuing a new code invalidates any outstanding unclaimed one.
  delete from public.claim_codes where profile_id = p_profile_id and claimed_at is null;

  insert into public.claim_codes (code, family_id, profile_id, expires_at)
    values (v_code, v_family, p_profile_id, now() + interval '7 days');

  return v_code;
end $$;
