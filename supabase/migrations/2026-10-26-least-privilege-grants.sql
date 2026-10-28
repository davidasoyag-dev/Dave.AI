-- ============================================================
--  Dave.AI: least-privilege table grants (defence in depth)
--  Safe to run more than once. Does NOT change any row-level-security policy.
--
--  Why
--    Row-level security already stops signed-out visitors and other users from
--    reading or writing anyone's rows. But the anon and authenticated roles were
--    also granted far more than the app uses (DELETE, TRUNCATE, TRIGGER, ...).
--    Row-level security is then the only barrier. This removes the extra grants
--    so a future policy mistake cannot expose data.
--
--  What the app actually needs (checked against dashboard.html and the functions)
--    Signed-in browser:  documents  SELECT / INSERT / DELETE (UPDATE kept, unused)
--                        profiles   SELECT, and UPDATE of first_name/last_name/firm (column grant already in place)
--                        ai_usage   SELECT
--                        team_invites SELECT
--    Server only (service_role, unaffected by this file): team_invites INSERT,
--                        profile plan changes, ai_requests, usage counting.
--    Signed-out visitors: nothing on these tables.
--
--  Undo (only if something breaks):
--    grant select, insert, update, delete on public.documents to authenticated;
--    -- (and the specific line you need from below)
-- ============================================================

-- 1. Signed-out visitors: no access to any of these tables.
revoke all on public.documents    from anon;
revoke all on public.profiles     from anon;
revoke all on public.team_invites from anon;
revoke all on public.ai_usage     from anon;
revoke all on public.ai_requests  from anon;

-- 2. Signed-in users: drop the powers the browser never needs.
revoke truncate, references, trigger on public.documents    from authenticated;
revoke truncate, references, trigger on public.profiles     from authenticated;
revoke truncate, references, trigger on public.team_invites from authenticated;
revoke truncate, references, trigger on public.ai_usage     from authenticated;
revoke all on public.ai_requests from authenticated;

-- Profiles can never be deleted from the browser (no policy allows it either).
revoke delete on public.profiles from authenticated;

-- Team invites are created by the server (invite-team-member function, service role).
-- The browser only lists them.
revoke insert, update, delete on public.team_invites from authenticated;

-- ------------------------------------------------------------
-- Check afterwards (read-only):
--   select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type)
--     from information_schema.role_table_grants
--    where table_schema = 'public' and grantee in ('anon','authenticated')
--    group by 1, 2 order by 1, 2;
-- Expected: no anon rows; authenticated = documents DELETE/INSERT/SELECT/UPDATE,
-- profiles SELECT, ai_usage SELECT, team_invites SELECT.
-- ------------------------------------------------------------
