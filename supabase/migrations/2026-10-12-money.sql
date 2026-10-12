-- ============================================================
--  Dave.AI: money fixes (2026-10-12)
--    F-20261012-2   users could give themselves a paid plan
--    F-20261012-6   server-side plan / usage enforcement for the AI endpoints
--    F-20261012-62  trial cap and fair-use caps
--
--  Run this in Supabase -> SQL Editor -> New query -> Run,
--  BEFORE deploying the matching Netlify functions (they fail closed
--  without consume_ai_action). Safe to run more than once.
--  supabase/schema.sql contains the same end result for a fresh install.
-- ============================================================

-- 1) PROFILES: display-only copy of the plan picked on the signup form.
--    Never used for access decisions (those use plan + plan_active only).
alter table public.profiles add column if not exists chosen_plan text;

update public.profiles
   set chosen_plan = plan
 where chosen_plan is null
   and plan in ('starter', 'pro', 'firm', 'enterprise');

-- 2) PROFILES: signed-in users may only edit their name and firm.
--    plan / plan_active / trial_start are written only by the server
--    (signup trigger below, and the Stripe webhook with the service-role key,
--    which bypasses these grants). The owner-only RLS policies stay as they are.
--    Nothing in the client inserts profiles (the signup trigger does), so
--    INSERT is revoked too; otherwise a user without a row could insert one
--    with plan_active = true.
revoke insert, update on public.profiles from anon, authenticated;
grant update (first_name, last_name, firm) on public.profiles to authenticated;

-- 3) SIGNUP TRIGGER: every new account starts as a 14-day trial.
--    Plan, planActive and trialStart in the signup metadata are ignored
--    (the browser controls that metadata). Names, firm and email are still copied.
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

-- 4) AI USAGE: one row per user per UK day per feature.
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

-- 5) AI REQUESTS: recent request ids, so one user action that is retried
--    (streaming first, then the buffered fallback) is only counted once.
--    No user access at all; only consume_ai_action() touches it.
create table if not exists public.ai_requests (
  user_id     uuid        not null references auth.users(id) on delete cascade,
  request_id  text        not null,
  feature     text        not null,
  hits        integer     not null default 1,
  created_at  timestamptz not null default now(),
  primary key (user_id, request_id)
);

alter table public.ai_requests enable row level security;
revoke all on public.ai_requests from anon, authenticated;

-- 6) consume_ai_action: called by the AI functions (with the user's own token)
--    before every Anthropic call. Decides whether the caller may run one more
--    AI action and, if so, counts it. Returns jsonb:
--      {allowed:true,  plan, used_today, used_month}
--      {allowed:true,  plan, repeat:true}            (retry of an already-counted action)
--      {allowed:false, reason, limit?}
--    Limits: everyone 100/day; trial 25/day; starter 20/month (research not
--    counted); pro and firm fair use 300/month; other active plans day cap only.
--    Days and months are UK calendar days/months (Europe/London).
drop function if exists public.consume_ai_action(text);

create or replace function public.consume_ai_action(p_feature text, p_request_id text default null)
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

  -- Retry of an action already counted in the last 10 minutes (same id and
  -- feature, at most 3 uses: 1 streaming attempt + 2 fallback attempts).
  if p_request_id is not null then
    select * into v_req
      from public.ai_requests r
     where r.user_id = v_uid and r.request_id = p_request_id;
    if found
       and v_req.feature = p_feature
       and v_req.hits < 3
       and v_req.created_at > now() - interval '10 minutes' then
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
    insert into public.ai_requests as r (user_id, request_id, feature, hits, created_at)
    values (v_uid, p_request_id, p_feature, 1, now())
    on conflict (user_id, request_id) do update
      set feature = excluded.feature, hits = 1, created_at = now();
    -- Housekeeping: request ids are only needed for 10 minutes
    delete from public.ai_requests r
     where r.user_id = v_uid and r.created_at < now() - interval '1 day';
  end if;

  return jsonb_build_object('allowed', true,
                            'plan', case when v_active then v_plan else 'trial' end,
                            'used_today', v_used_today + 1,
                            'used_month', v_used_month + 1);
end;
$$;

revoke all on function public.consume_ai_action(text, text) from public, anon;
grant execute on function public.consume_ai_action(text, text) to authenticated;
