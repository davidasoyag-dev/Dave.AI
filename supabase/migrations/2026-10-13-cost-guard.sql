-- ============================================================
--  Dave.AI: cost guard (2026-10-13)
--    F-20261012-6   one counted AI action could be replayed 3 times with the
--                   same client-chosen request_id. Now: at most ONE repeat
--                   (streaming attempt + one buffered fallback); a further
--                   use of the same id is counted as a new action.
--
--  Run this in Supabase -> SQL Editor -> New query -> Run.
--  Recreates consume_ai_action with the same signature, SECURITY DEFINER,
--  grants and fail-closed behaviour as 2026-10-12-money.sql; only the repeat
--  allowance changes (hits < 3  ->  hits < 2). Requires 2026-10-12-money.sql
--  to have been run first. Safe to run more than once.
--  supabase/schema.sql contains the same end result for a fresh install.
-- ============================================================

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
  -- feature, at most 2 uses: the streaming attempt + one buffered fallback).
  -- Any further use of the same id is counted as a new action.
  if p_request_id is not null then
    select * into v_req
      from public.ai_requests r
     where r.user_id = v_uid and r.request_id = p_request_id;
    if found
       and v_req.feature = p_feature
       and v_req.hits < 2
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
