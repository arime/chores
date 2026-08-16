-- Table privileges for `authenticated`.
--
-- RLS decides which rows a caller may touch; it never grants the right to touch
-- the table at all. Postgres checks the GRANT first, so a table with perfect
-- policies and no grant is simply invisible — `42501 permission denied`, before
-- a single policy is consulted.
--
-- Nothing granted these until now because the local stack used to hand
-- anon/authenticated blanket CRUD on `public` through ALTER DEFAULT PRIVILEGES.
-- Current Supabase images have dropped that, leaving only TRUNCATE/REFERENCES/
-- TRIGGER, so every table went unreadable the next time the schema was rebuilt.
-- Relying on a default that has already changed once is how this recurs; each
-- table is spelled out instead, and new tables must add themselves here.
--
-- The verbs mirror the policies in 20260810120100_rls.sql exactly. Where that
-- file declines to write a policy, this one declines to grant — the two are
-- meant to be read side by side.
--
-- `anon` is deliberately absent: the app signs in anonymously before its first
-- query, so every caller is `authenticated`. A pre-auth caller has no family
-- and no reason to see any of this.

-- Creation goes through create_family(); no DELETE anywhere in the app.
grant select, update                 on public.families         to authenticated;

-- No DELETE: a profile is archived by the parent, never removed.
grant select, insert, update         on public.profiles         to authenticated;

grant select, insert, update, delete on public.claim_codes      to authenticated;
grant select, insert, update, delete on public.chores           to authenticated;
grant select, insert, update, delete on public.schedule_entries to authenticated;

-- No UPDATE, matching completions' missing UPDATE policy: a completion is
-- created or destroyed, never edited.
grant select, insert, delete         on public.completions      to authenticated;
