-- Household chores app: core schema.
--
-- Every table carries family_id so the system is multi-tenant from the first
-- migration. There is exactly one family today; retrofitting this later is
-- miserable, building it in now is free.

create extension if not exists "pgcrypto";

create table public.families (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  timezone   text not null default 'Europe/Helsinki',
  created_at timestamptz not null default now()
);

create table public.profiles (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references public.families(id) on delete cascade,
  auth_user_id uuid unique references auth.users(id) on delete set null,
  display_name text not null,
  role         text not null check (role in ('parent','child')),
  color        text not null default '#4C8BF5',
  sort_order   int  not null default 0,
  created_at   timestamptz not null default now()
);
create index profiles_family_idx on public.profiles(family_id);

create table public.claim_codes (
  code       text primary key,
  family_id  uuid not null references public.families(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  expires_at timestamptz not null,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);
create index claim_codes_profile_idx on public.claim_codes(profile_id);

create table public.chores (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families(id) on delete cascade,
  name        text not null,
  icon        text,
  -- Reserved for a future rewards layer. Unused in v1.
  points      int,
  is_archived boolean not null default false,
  created_at  timestamptz not null default now()
);
create index chores_family_idx on public.chores(family_id);

-- The weekly template. weekday is ISO 8601: 1 = Monday ... 7 = Sunday.
create table public.schedule_entries (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.families(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  chore_id   uuid not null references public.chores(id) on delete cascade,
  weekday    smallint not null check (weekday between 1 and 7),
  created_at timestamptz not null default now(),
  unique (profile_id, chore_id, weekday)
);
create index schedule_entries_family_idx on public.schedule_entries(family_id);

-- Keyed by (profile_id, chore_id, due_on) and never by schedule_entries.id, so
-- the weekly template can be rewritten without corrupting history. The same
-- uniqueness makes completion writes idempotent, which is what lets the client
-- outbox replay blindly.
create table public.completions (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references public.families(id) on delete cascade,
  profile_id   uuid not null references public.profiles(id) on delete cascade,
  chore_id     uuid not null references public.chores(id) on delete cascade,
  due_on       date not null,
  completed_at timestamptz not null default now(),
  completed_by uuid not null references public.profiles(id) on delete cascade,
  unique (profile_id, chore_id, due_on)
);
create index completions_family_due_idx on public.completions(family_id, due_on);
