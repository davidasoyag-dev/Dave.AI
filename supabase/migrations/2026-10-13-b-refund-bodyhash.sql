-- ============================================================
--  Dave.AI: refunds for failed AI calls + request_id bound to content
--  (2026-10-13-b)
--    F-20261013-43  a failed AI call (Anthropic error, network failure,
--                   timeout) still used up one of the user's AI actions.
--                   New RPC refund_ai_action() lets the AI functions give
--                   that action back.
--    F-20261013-41  a repeat of a request_id (the free retry) was not tied
--                   to the same content. consume_ai_action() now stores a
--                   SHA-256 of the request body and only allows the free
--                   repeat when the hash matches.
--
--  ORDER (important):
--    1. 2026-10-12-money.sql      (already applied)
--    2. 2026-10-13-cost-guard.sql (apply first if not yet applied)
--    3. THIS FILE
--    4. THEN deploy the updated netlify/functions/ai-stream.mjs and
--       ai-proxy.js. (The old functions keep working with this SQL; they
--       just never get a free retry or a refund until the new ones deploy.)
--  Do NOT re-run 2026-10-13-cost-guard.sql after this file: it would
--  re-create the old 2-argument consume_ai_action next to the new one. If
--  that happens, simply run this file again.
--
--  Run this in Supabase -> SQL Editor -> New query -> Run.
--  Safe to run more than once. supabase/schema.sql has the same end result.
--
--  Design notes:
--  * consume_ai_action gains p_body_hash text DEFAULT NULL. The old
--    (text, text) version is dropped so PostgREST has exactly one function
--    to resolve; callers that send only p_feature / p_request_id still work.
--  * Free repeat only when the stored hash is non-null AND equals the new
--    one. Any mismatch (or a missing hash on either side) is counted as a
--    NEW action (never a free repeat, never a hard error, so honest retries
--    are never blocked; they just cost one action).
--  * Every counted action with a request_id gets a random refund_token,
--    returned ONLY to the calling function (ai_requests has no user access
--    and the functions never pass the token to the browser). Without it a
--    user could call refund_ai_action straight from the browser after a
--    successful answer and get the action back for free.
--  * A refund is only possible within 10 minutes, once, and only while the
--    request has had no free repeat (hits = 1). It decrements exactly the
--    ai_usage row (counted_day, feature) that the count incremented, never
--    below 0. After a refund, the next use of that request_id is counted
--    as a new action (no free repeat of a refunded action).
-- ============================================================

begin;

-- 1) New columns on ai_requests (no user access; only the RPCs touch it)
alter table public.ai_requests add column if not exists body_hash    text;
alter table public.ai_requests add column if not exists refund_token text;
alter table public.ai_requests add column if not exists counted_day  date;
alter table public.ai_requests add column if not exists refunded_at  timestamptz;

-- 2) consume_ai_action with p_body_hash (replaces the (text, text) version)
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

-- 3) refund_ai_action: called by the AI functions (with the user's own
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

commit;

-- Ask PostgREST to pick up the changed function signatures straight away
notify pgrst, 'reload schema';
