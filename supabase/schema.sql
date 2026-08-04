-- ============================================================
--  Dave.AI — backend schema (Step 1)
--  Run this in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- ============================================================

-- 1) PROFILES: one row per user (plan, trial, name, firm)
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text,
  first_name   text,
  last_name    text,
  firm         text,
  plan         text        default 'trial',
  plan_active  boolean     default false,
  trial_start  timestamptz default now(),
  created_at   timestamptz default now()
);

-- 2) DOCUMENTS: every draft / review / research, tied to its owner
create table if not exists public.documents (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  type        text not null,          -- 'Draft' | 'Review' | 'Research'
  name        text not null,
  content     text,
  created_at  timestamptz default now()
);
create index if not exists documents_user_id_idx    on public.documents(user_id);
create index if not exists documents_created_at_idx on public.documents(created_at);

-- 3) ROW LEVEL SECURITY — the key part: users can only touch their own rows
alter table public.profiles  enable row level security;
alter table public.documents enable row level security;

drop policy if exists profiles_select_own on public.profiles;
drop policy if exists profiles_insert_own on public.profiles;
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_select_own on public.profiles for select using (auth.uid() = id);
create policy profiles_insert_own on public.profiles for insert with check (auth.uid() = id);
create policy profiles_update_own on public.profiles for update using (auth.uid() = id);

drop policy if exists documents_select_own on public.documents;
drop policy if exists documents_insert_own on public.documents;
drop policy if exists documents_update_own on public.documents;
drop policy if exists documents_delete_own on public.documents;
create policy documents_select_own on public.documents for select using (auth.uid() = user_id);
create policy documents_insert_own on public.documents for insert with check (auth.uid() = user_id);
create policy documents_update_own on public.documents for update using (auth.uid() = user_id);
create policy documents_delete_own on public.documents for delete using (auth.uid() = user_id);

-- 4) AUTO-CREATE a profile whenever a new user signs up (pulls signup metadata)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, first_name, last_name, firm, plan, plan_active, trial_start)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data->>'firstName',
    new.raw_user_meta_data->>'lastName',
    new.raw_user_meta_data->>'firm',
    coalesce(new.raw_user_meta_data->>'plan', 'trial'),
    coalesce((new.raw_user_meta_data->>'planActive')::boolean, false),
    coalesce((new.raw_user_meta_data->>'trialStart')::timestamptz, now())
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 5) BACKFILL profiles for anyone who already signed up before this ran
insert into public.profiles (id, email, first_name, last_name, firm, plan, plan_active, trial_start)
select u.id, u.email,
       u.raw_user_meta_data->>'firstName',
       u.raw_user_meta_data->>'lastName',
       u.raw_user_meta_data->>'firm',
       coalesce(u.raw_user_meta_data->>'plan', 'trial'),
       coalesce((u.raw_user_meta_data->>'planActive')::boolean, false),
       coalesce((u.raw_user_meta_data->>'trialStart')::timestamptz, now())
from auth.users u
on conflict (id) do nothing;
