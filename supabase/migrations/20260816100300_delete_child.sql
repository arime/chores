-- Removing a child, history included.
--
-- Until now a profile could not be removed at all, which was a gap rather than
-- a policy: PeopleView said as much in a comment. Task 3 gave a parent a way to
-- leave; shipping that without this would have left an asymmetry — parents can
-- go, children are permanent.
--
-- Deletion is total and immediate. The cascades are all wanted: the child's
-- schedule_entries, their claim_codes, and their completions via
-- completions.profile_id. `completed_by` going null is for departing parents
-- only — a child can only ever be completed_by themselves, because the
-- completions_insert policy allows `is_parent() or profile_id = current_profile_id()`,
-- and those rows are removed by the profile_id cascade anyway.
--
-- Refusing a parent target is deliberate: removing another parent is a separate
-- question about who may evict whom, and this must not quietly become its tool.
--
-- 20260813120000_table_grants.sql says "No DELETE: a profile is archived by the
-- parent, never removed." Withholding the grant is still right — deletion goes
-- through this SECURITY DEFINER function, never through a client — but the
-- reason given there was wrong: no archive flag ever existed on profiles, and
-- profiles simply could not be removed at all.

create or replace function public.delete_child(p_profile_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_family_id uuid;
  v_role text;
begin
  if not public.is_parent() then
    raise exception 'only a parent may delete a child';
  end if;

  select family_id, role into v_family_id, v_role
    from public.profiles where id = p_profile_id;

  if v_family_id is null or v_family_id <> public.current_family_id() then
    raise exception 'profile not in caller family';
  end if;
  if v_role <> 'child' then
    raise exception 'only a child may be deleted';
  end if;

  delete from public.profiles where id = p_profile_id;
end $$;
