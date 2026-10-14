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
  created_at   timestamptz default now(),
  chosen_plan  text        -- plan picked on the signup form; display only, never used for access
);
alter table public.profiles add column if not exists chosen_plan text;

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
-- Size limits (NOT VALID: existing rows are not re-checked; new/updated rows are)
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'documents_content_len'
                   and conrelid = 'public.documents'::regclass) then
    alter table public.documents
      add constraint documents_content_len check (length(content) <= 600000) not valid;
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'documents_name_len'
                   and conrelid = 'public.documents'::regclass) then
    alter table public.documents
      add constraint documents_name_len check (length(name) <= 300) not valid;
  end if;
end $$;
-- At most 5,000 saved documents per user
create or replace function public.documents_row_cap()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (select count(*) from public.documents d where d.user_id = new.user_id) >= 5000 then
    raise exception 'Document limit reached (5,000 saved documents). Please delete some older documents first.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
revoke execute on function public.documents_row_cap() from public, anon, authenticated;
drop trigger if exists documents_row_cap on public.documents;
create trigger documents_row_cap
  before insert on public.documents
  for each row execute function public.documents_row_cap();

-- 3) ROW LEVEL SECURITY — the key part: users can only touch their own rows
alter table public.profiles  enable row level security;
alter table public.documents enable row level security;

drop policy if exists profiles_select_own on public.profiles;
drop policy if exists profiles_insert_own on public.profiles;
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_select_own on public.profiles for select using (auth.uid() = id);
create policy profiles_insert_own on public.profiles for insert with check (auth.uid() = id);
create policy profiles_update_own on public.profiles for update using (auth.uid() = id);
-- Users may only edit their name and firm. plan / plan_active / trial_start are
-- written only by the signup trigger and the Stripe webhook (service-role key).
revoke insert, update on public.profiles from anon, authenticated;
grant update (first_name, last_name, firm) on public.profiles to authenticated;

drop policy if exists documents_select_own on public.documents;
drop policy if exists documents_insert_own on public.documents;
drop policy if exists documents_update_own on public.documents;
drop policy if exists documents_delete_own on public.documents;
create policy documents_select_own on public.documents for select using (auth.uid() = user_id);
create policy documents_insert_own on public.documents for insert with check (auth.uid() = user_id);
create policy documents_update_own on public.documents for update using (auth.uid() = user_id);
create policy documents_delete_own on public.documents for delete using (auth.uid() = user_id);

-- 4) AUTO-CREATE a profile whenever a new user signs up. Every new account is a
--    14-day trial: plan / planActive / trialStart in the (browser-controlled)
--    signup metadata are ignored. Names, firm and email are still copied.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  v_chosen text := lower(coalesce(new.raw_user_meta_data->>'plan', ''));
begin
  if v_chosen not in ('starter', 'pro', 'firm', 'enterprise') then
    v_chosen := null;
  end if;
  insert into public.profiles (id, email, first_name, last_name, firm, plan, plan_active, trial_start, chosen_plan)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data->>'firstName',
    new.raw_user_meta_data->>'lastName',
    new.raw_user_meta_data->>'firm',
    'trial',
    false,
    now(),
    v_chosen
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
-- Trigger-only: must not be callable as an RPC (the trigger still fires)
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- 5) BACKFILL profiles for anyone who already signed up before this ran
--    (trial from their signup date; plan never taken from metadata)
insert into public.profiles (id, email, first_name, last_name, firm, plan, plan_active, trial_start)
select u.id, u.email,
       u.raw_user_meta_data->>'firstName',
       u.raw_user_meta_data->>'lastName',
       u.raw_user_meta_data->>'firm',
       'trial',
       false,
       coalesce(u.created_at, now())
from auth.users u
on conflict (id) do nothing;

-- 6) TEAM INVITES: tracks who a user has invited to join their Dave.AI team
create table if not exists public.team_invites (
  id            uuid primary key default gen_random_uuid(),
  inviter_id    uuid not null references auth.users(id) on delete cascade,
  invited_email text not null,
  status        text default 'pending',
  created_at    timestamptz default now()
);
create index if not exists team_invites_inviter_id_idx on public.team_invites(inviter_id);

alter table public.team_invites enable row level security;

drop policy if exists team_invites_select_own on public.team_invites;
drop policy if exists team_invites_insert_own on public.team_invites;
create policy team_invites_select_own on public.team_invites for select using (auth.uid() = inviter_id);
create policy team_invites_insert_own on public.team_invites for insert with check (auth.uid() = inviter_id);

-- 7) AI USAGE: one row per user per UK day per feature.
--    Users can read their own rows (the dashboard shows "N left");
--    only consume_ai_action() (security definer) writes them.
create table if not exists public.ai_usage (
  user_id  uuid    not null references auth.users(id) on delete cascade,
  day      date    not null,
  feature  text    not null,
  count    integer not null default 0,
  primary key (user_id, day, feature)
);

alter table public.ai_usage enable row level security;
drop policy if exists ai_usage_select_own on public.ai_usage;
create policy ai_usage_select_own on public.ai_usage for select using (auth.uid() = user_id);
revoke all on public.ai_usage from anon, authenticated;
grant select on public.ai_usage to authenticated;

-- 8) AI REQUESTS: recent request ids, so one user action that is retried
--    (streaming first, then the buffered fallback) is only counted once.
--    No user access at all; only consume_ai_action() touches it.
create table if not exists public.ai_requests (
  user_id     uuid        not null references auth.users(id) on delete cascade,
  request_id  text        not null,
  feature     text        not null,
  hits        integer     not null default 1,
  created_at  timestamptz not null default now(),
  body_hash    text,        -- SHA-256 of the forwarded body; a free repeat needs the same hash
  refund_token text,        -- secret for refund_ai_action; only the AI functions ever see it
  counted_day  date,        -- the ai_usage day row this action was counted in
  refunded_at  timestamptz, -- set once the action has been refunded
  primary key (user_id, request_id)
);
alter table public.ai_requests add column if not exists body_hash    text;
alter table public.ai_requests add column if not exists refund_token text;
alter table public.ai_requests add column if not exists counted_day  date;
alter table public.ai_requests add column if not exists refunded_at  timestamptz;

alter table public.ai_requests enable row level security;
revoke all on public.ai_requests from anon, authenticated;

-- 9) consume_ai_action: called by the AI functions (with the user's own token)
--    before every Anthropic call. Decides whether the caller may run one more
--    AI action and, if so, counts it. Returns jsonb:
--      {allowed:true,  plan, used_today, used_month, refund_token}
--      {allowed:true,  plan, repeat:true}            (retry of an already-counted action)
--      {allowed:false, reason, limit?}
--    Limits: everyone 100/day; trial 25/day; starter 20/month (research not
--    counted); pro and firm fair use 300/month; other active plans day cap only.
--    Days and months are UK calendar days/months (Europe/London).
--    A free repeat needs the same request_id, feature AND body hash
--    (p_body_hash, SHA-256 hex of the forwarded system + messages).
--    refund_ai_action (section 10) gives back an action whose AI call failed.
drop function if exists public.consume_ai_action(text);
drop function if exists public.consume_ai_action(text, text);

create or replace function public.consume_ai_action(p_feature text,
                                                    p_request_id text default null,
                                                    p_body_hash text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid          uuid := auth.uid();
  v_plan         text;
  v_active       boolean;
  v_trial_start  timestamptz;
  v_today        date := (now() at time zone 'Europe/London')::date;
  v_month_start  date := date_trunc('month', now() at time zone 'Europe/London')::date;
  v_used_today   integer;
  v_used_month   integer;
  v_used_metered integer;
  v_req          public.ai_requests%rowtype;
  v_token        text;
begin
  if v_uid is null then
    return jsonb_build_object('allowed', false, 'reason', 'not_signed_in');
  end if;
  if p_feature is null
     or p_feature not in ('draft', 'refine', 'review', 'research', 'docchat', 'compare', 'tools') then
    return jsonb_build_object('allowed', false, 'reason', 'bad_feature');
  end if;
  if p_request_id is not null
     and (length(p_request_id) > 64 or p_request_id !~ '^[A-Za-z0-9_-]+$') then
    return jsonb_build_object('allowed', false, 'reason', 'bad_request');
  end if;
  if p_body_hash is not null and p_body_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('allowed', false, 'reason', 'bad_request');
  end if;

  -- Lock the caller's profile row. Concurrent calls from the same user wait
  -- here, so the count-then-increment below cannot race.
  select lower(coalesce(p.plan, 'trial')),
         coalesce(p.plan_active, false),
         coalesce(p.trial_start, p.created_at)
    into v_plan, v_active, v_trial_start
    from public.profiles p
   where p.id = v_uid
     for update;
  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'trial_ended');
  end if;

  -- No paid plan and the 14-day trial is over (or has no start date)
  if not v_active
     and (v_trial_start is null or now() >= v_trial_start + interval '14 days') then
    return jsonb_build_object('allowed', false, 'reason', 'trial_ended');
  end if;

  -- Retry of an action already counted in the last 10 minutes (same id,
  -- feature and body hash, not refunded, at most 2 uses: the streaming
  -- attempt + one buffered fallback). Anything else is a new action.
  if p_request_id is not null then
    select * into v_req
      from public.ai_requests r
     where r.user_id = v_uid and r.request_id = p_request_id;
    if found
       and v_req.feature = p_feature
       and v_req.hits < 2
       and v_req.created_at > now() - interval '10 minutes'
       and v_req.refunded_at is null
       and v_req.body_hash is not null
       and v_req.body_hash = p_body_hash then
      update public.ai_requests r
         set hits = r.hits + 1
       where r.user_id = v_uid and r.request_id = p_request_id;
      return jsonb_build_object('allowed', true, 'repeat', true,
                                'plan', case when v_active then v_plan else 'trial' end);
    end if;
  end if;

  -- This UK month's usage (today's is a subset)
  select coalesce(sum(u.count) filter (where u.day = v_today), 0),
         coalesce(sum(u.count), 0),
         coalesce(sum(u.count) filter (where u.feature <> 'research'), 0)
    into v_used_today, v_used_month, v_used_metered
    from public.ai_usage u
   where u.user_id = v_uid
     and u.day >= v_month_start;

  if v_used_today >= 100 then
    return jsonb_build_object('allowed', false, 'reason', 'daily_limit', 'limit', 100);
  end if;
  if not v_active and v_used_today >= 25 then
    return jsonb_build_object('allowed', false, 'reason', 'trial_daily_limit', 'limit', 25);
  end if;
  if v_active and v_plan = 'starter' and p_feature <> 'research' and v_used_metered >= 20 then
    return jsonb_build_object('allowed', false, 'reason', 'monthly_limit', 'limit', 20);
  end if;
  if v_active and v_plan in ('pro', 'firm') and v_used_month >= 300 then
    return jsonb_build_object('allowed', false, 'reason', 'fair_use_limit', 'limit', 300);
  end if;

  -- Allowed: count it
  insert into public.ai_usage as u (user_id, day, feature, count)
  values (v_uid, v_today, p_feature, 1)
  on conflict (user_id, day, feature) do update set count = u.count + 1;

  if p_request_id is not null then
    v_token := replace(gen_random_uuid()::text, '-', '');
    insert into public.ai_requests as r
           (user_id, request_id, feature, hits, created_at,
            body_hash, refund_token, counted_day, refunded_at)
    values (v_uid, p_request_id, p_feature, 1, now(),
            p_body_hash, v_token, v_today, null)
    on conflict (user_id, request_id) do update
      set feature      = excluded.feature,
          hits         = 1,
          created_at   = now(),
          body_hash    = excluded.body_hash,
          refund_token = excluded.refund_token,
          counted_day  = excluded.counted_day,
          refunded_at  = null;
    -- Housekeeping: request ids are only needed for 10 minutes
    delete from public.ai_requests r
     where r.user_id = v_uid and r.created_at < now() - interval '1 day';
  end if;

  return jsonb_build_object('allowed', true,
                            'plan', case when v_active then v_plan else 'trial' end,
                            'used_today', v_used_today + 1,
                            'used_month', v_used_month + 1,
                            'refund_token', v_token);
end;
$$;

revoke all on function public.consume_ai_action(text, text, text) from public, anon;
grant execute on function public.consume_ai_action(text, text, text) to authenticated;

-- 10) refund_ai_action: called by the AI functions (with the user's own
--    token) when the Anthropic call failed. Gives back the one action that
--    consume_ai_action counted for this request_id. Returns jsonb:
--      {refunded:true}  or  {refunded:false, reason}
drop function if exists public.refund_ai_action(text);

create or replace function public.refund_ai_action(p_request_id text, p_refund_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_req  public.ai_requests%rowtype;
begin
  if v_uid is null then
    return jsonb_build_object('refunded', false, 'reason', 'not_signed_in');
  end if;
  if p_request_id is null or p_refund_token is null
     or length(p_request_id) > 64 or length(p_refund_token) > 64 then
    return jsonb_build_object('refunded', false, 'reason', 'bad_request');
  end if;

  -- Same lock order as consume_ai_action (profile first), so a refund and
  -- a new action from the same user cannot interleave or deadlock.
  perform 1 from public.profiles p where p.id = v_uid for update;
  if not found then
    return jsonb_build_object('refunded', false, 'reason', 'not_found');
  end if;

  select * into v_req
    from public.ai_requests r
   where r.user_id = v_uid and r.request_id = p_request_id
     for update;
  if not found
     or v_req.refund_token is null
     or v_req.refund_token <> p_refund_token
     or v_req.refunded_at is not null
     or v_req.hits <> 1
     or v_req.counted_day is null
     or v_req.created_at <= now() - interval '10 minutes' then
    return jsonb_build_object('refunded', false, 'reason', 'not_refundable');
  end if;

  update public.ai_usage u
     set count = greatest(u.count - 1, 0)
   where u.user_id = v_uid
     and u.day = v_req.counted_day
     and u.feature = v_req.feature;

  update public.ai_requests r
     set refunded_at = now(), refund_token = null
   where r.user_id = v_uid and r.request_id = p_request_id;

  return jsonb_build_object('refunded', true);
end;
$$;

revoke all on function public.refund_ai_action(text, text) from public, anon;
grant execute on function public.refund_ai_action(text, text) to authenticated;
