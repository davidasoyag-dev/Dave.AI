-- ============================================================
--  Dave.AI: 30-day document history for the Starter plan
--  Run in Supabase -> SQL Editor (or via a migration). Safe to run more than once.
--
--  What it does
--    * purge_expired_documents(): deletes saved documents older than 30 days for
--      accounts that are on an ACTIVE Starter plan (plan_active = true AND plan = 'starter').
--    * Schedules it nightly at 03:17 UTC with pg_cron.
--
--  What it deliberately does NOT touch
--    * Trial accounts, Pro, Firm, Enterprise: no automatic deletion.
--    * Anything that is not a saved document (profiles, usage counts, auth).
--
--  Before you run it, preview the effect (read-only):
--    select count(*) from public.documents d join public.profiles p on p.id = d.user_id
--     where p.plan_active and lower(p.plan) = 'starter' and d.created_at < now() - interval '30 days';
--
--  To undo the schedule later:
--    select cron.unschedule('purge-expired-documents');
-- ============================================================

create extension if not exists pg_cron with schema pg_catalog;

create or replace function public.purge_expired_documents()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  with gone as (
    delete from public.documents d
    using public.profiles p
    where d.user_id = p.id
      and p.plan_active is true
      and lower(coalesce(p.plan, '')) = 'starter'
      and d.created_at < now() - interval '30 days'
    returning 1
  )
  select count(*) into n from gone;
  return n;
end;
$$;

-- Only the database owner (which runs pg_cron jobs) may call it: never a signed-in user.
revoke all on function public.purge_expired_documents() from public, anon, authenticated;

-- (Re)schedule nightly
select cron.unschedule(jobid) from cron.job where jobname = 'purge-expired-documents';
select cron.schedule('purge-expired-documents', '17 3 * * *', 'select public.purge_expired_documents()');
