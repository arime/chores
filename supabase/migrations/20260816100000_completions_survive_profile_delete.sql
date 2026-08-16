-- A completion records that a chore was done. Who ticked it off is useful
-- context, not the point of the row.
--
-- `completed_by` cascaded, which meant deleting a parent silently erased every
-- completion that parent had ticked off on a child's behalf — the feature added
-- in 60ac940 and 1e5ce91. The child's history is the data worth keeping; the
-- departing parent's identity is not. Null now means "recorded by someone no
-- longer in the family", which is the truth.
--
-- `completions.profile_id` deliberately keeps cascading: that is the child the
-- chore belonged to, and when a child goes their history goes with them.

alter table public.completions alter column completed_by drop not null;

alter table public.completions drop constraint completions_completed_by_fkey;

alter table public.completions add constraint completions_completed_by_fkey
  foreign key (completed_by) references public.profiles(id) on delete set null;
