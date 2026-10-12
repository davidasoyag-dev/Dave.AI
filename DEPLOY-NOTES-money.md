# Deploy notes: money fixes (branch ops/g-money, 2026-10-12)

Findings covered: F-20261012-2, -6, -62, -63, -64 (seat enforcement only).

**Order matters.** The AI functions now *fail closed*: if the database function
`consume_ai_action` is missing, every AI request returns 503 "Usage check unavailable".
So the SQL goes in first, then the beta users are checked, and only then is the code deployed.

---

## Step 1: Apply the SQL (Supabase, before any code deploy)

1. Supabase dashboard → project `wyribnzwosqzfnhomhig` → **SQL Editor** → New query.
2. Paste the whole of `supabase/migrations/2026-10-12-money.sql` and click **Run**.
   It is safe to run twice.
3. Check it worked (should return 3 rows: `ai_requests`, `ai_usage`, `consume_ai_action`):

```sql
select 'table' as kind, table_name as name from information_schema.tables
 where table_schema = 'public' and table_name in ('ai_usage', 'ai_requests')
union all
select 'function', routine_name from information_schema.routines
 where routine_schema = 'public' and routine_name = 'consume_ai_action';
```

The old (currently live) code keeps working with the new SQL, because it doesn't call the new function.
The only immediate change is that users can no longer edit `plan`, `plan_active` or `trial_start`
on their own profile.

## Step 2: Check existing users BEFORE deploying the code

After the code deploy, access depends **only** on `profiles.plan_active` and
`profiles.trial_start`. Anyone with `plan_active = false` and a trial older than
14 days is locked out (the "trial ended" screen, and the AI returns 402).
The beta firm's trials started in mid-June, so they will show as **EXPIRED**.

See everyone's status:

```sql
select email, plan, chosen_plan, plan_active, trial_start,
       trial_start + interval '14 days' as trial_ends,
       case when plan_active then 'PAID'
            when now() < trial_start + interval '14 days' then 'trial'
            else 'EXPIRED' end as status
  from public.profiles
 order by created_at;
```

**Also check every `PAID` row against Stripe.** Before this fix, any user could set
`plan_active = true` on their own profile. If a `PAID` row has no matching active Stripe
subscription (and isn't someone you granted yourself), set it back:
`update public.profiles set plan_active = false where lower(email) = lower('<email>');`

### Give the beta users access (Firm plan)

Replace the placeholders with the real beta emails (one per line, keep the quotes and commas):

```sql
update public.profiles
   set plan = 'firm', plan_active = true
 where lower(email) in (
   lower('<beta-user-1@their-firm.co.uk>'),
   lower('<beta-user-2@their-firm.co.uk>'),
   lower('<beta-user-3@their-firm.co.uk>')
 )
returning email, plan, plan_active;
```

Check that the `returning` list shows every beta user. If someone is missing, their
email in `profiles` is different (check with the status query above).

Alternative, if you'd rather give someone a fresh 14-day trial instead of a free plan:
`update public.profiles set trial_start = now() where lower(email) = lower('<email>');`

Firm limits after the deploy: fair use 300 AI actions per month and 100 per day per user.

## Step 3: Deploy the code

Merge `ops/g-money` (via the ops fixes branch) and push to `main`. Netlify auto-deploys.
Files changed: `dashboard.html`, `netlify/functions/ai-stream.mjs`,
`netlify/functions/ai-proxy.js`, `netlify/functions/invite-team-member.js`,
`supabase/schema.sql`, plus the new migration file.

## Step 4: Smoke-test (on https://daveai.law, signed in)

1. **Beta/paid user:** the dashboard shows "FIRM · ACTIVE". Draft, Review, Research,
   Ask a Document, Compare and both Quick Tools all answer. The sidebar counter goes up
   by 1 per action and not by 2 (Research and Draft may stream and then fall back; that
   still counts once).
2. **New trial user** (sign up with a test email): the badge shows "· TRIAL" and "25 / 25 AI actions
   left today". After one Draft it shows 24.
3. **Self-grant is blocked:** as that trial user, open the browser console on the dashboard and run
   `await _sb.from('profiles').update({ plan_active: true }).eq('id', (await _sb.auth.getUser()).data.user.id)`.
   The result must contain an error ("permission denied"), and after reload the badge still says TRIAL.
   `await _sb.from('profiles').update({ first_name: 'Test' }).eq('id', (await _sb.auth.getUser()).data.user.id)`
   must still work (Settings → Save changes too).
4. **Expired trial:** in SQL, set a test user's `trial_start = now() - interval '15 days'`. Reload as that user:
   the "trial has ended" screen appears. If you call the AI anyway, you get the message
   "Your free trial has ended. Choose a plan to keep using Dave.AI."
5. **Starter limit** (optional): set a test user to `plan='starter', plan_active=true` and insert
   `insert into public.ai_usage values ('<user-uuid>', (now() at time zone 'Europe/London')::date, 'draft', 20);`.
   Then Draft, Compare, Doc Chat and Tools are refused with the Starter message, and Research still works.
6. **Invites:** a trial or Starter user gets "Inviting team members needs an active Pro, Firm or
   Enterprise plan". A Pro user can invite 4 people, and the 5th is refused.
7. **Wrong site:** `curl -i -X OPTIONS https://daveai.law/.netlify/functions/ai-proxy -H 'Origin: https://evil.example'`
   returns `Access-Control-Allow-Origin: https://daveai.law` (not `*`).

If AI requests all fail with "Dave.AI could not check your plan just now", the SQL from
Step 1 is missing or failed. Run it again (or roll back the code deploy).

## Step 5: What the Stripe webhook must write (David's part)

**Important:** right now `stripe-webhook.js` only writes `user_metadata.planActive` / `plan`.
After this deploy, **nothing reads user_metadata for access**, because users can edit
their own metadata. So paying customers only get access once the webhook updates **`profiles`**:

- On `checkout.session.completed` (or subscription active): with the **service-role key**,
  `PATCH {SUPABASE_URL}/rest/v1/profiles?id=eq.<user id>` with body
  `{"plan": "<starter|pro|firm|enterprise>", "plan_active": true}`
  (headers: `apikey` + `Authorization: Bearer <service key>`, `Content-Type: application/json`).
  Lowercase plan keys only: the limits check `starter`, `pro`, `firm`.
- On cancellation or subscription deleted: `{"plan_active": false}`.
- Take the plan from Stripe (price id → plan), not from anything the browser sent.
- The service-role key bypasses the new column grants and RLS, so no SQL change is needed for this.
- Note: the webhook uses env var `SUPABASE_SERVICE_KEY`, while `invite-team-member.js`
  uses `SUPABASE_SERVICE_ROLE_KEY`. Make sure both are set in Netlify, or unify the names.

Until the webhook is updated, activate paying customers by hand with the SQL in Step 2.

## Limits now enforced server-side (consume_ai_action)

| Who | Limit |
|---|---|
| Everyone | 100 AI actions per UK day (all features) |
| Trial (14 days, no paid plan) | 25 per UK day |
| Starter (active) | 20 per calendar month across Draft, Refine, Review, Doc Chat, Compare, Tools (Research not counted) |
| Pro / Firm (active) | fair use 300 per calendar month (all features) |
| Enterprise / other active | day limit only |
| No paid plan and trial over | blocked (402 `trial_ended`) |

Max tokens per request are also capped per feature (draft/refine/review 4000,
compare 2500, research/docchat 2000, tools 1500), and inputs over ~450,000 characters are rejected.

Also recommended (from F-20261012-6): set a monthly **spend limit in the Anthropic Console**
as a final backstop.
