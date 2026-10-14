-- ============================================================
--  Dave.AI: database hardening (2026-10-14-b)
--    F-20261013-53  documents.content / documents.name had no size limit and
--                   there was no per-user row cap, so one account could fill
--                   the shared database. Adds size CHECKs (NOT VALID, so
--                   existing rows don't block it; new and updated rows are
--                   checked) and a BEFORE INSERT trigger that rejects a
--                   user's insert past 5,000 saved documents.
--    F-20261013-32  handle_new_user() is SECURITY DEFINER and was executable
--                   via RPC by anon / authenticated. Revoke EXECUTE. The
--                   signup trigger keeps working: triggers don't need an
--                   EXECUTE grant for the user whose action fires them.
--
--  Independent of the other migrations; no code depends on it.
--  Run this in Supabase -> SQL Editor -> New query -> Run.
--  Safe to run more than once. supabase/schema.sql has the same end result.
--
--  Limits are far above what the dashboard saves (drafts and research answers
--  are a few thousand characters; names are under ~80 characters). The
--  dashboard already shows "Not saved, retry" if an insert is rejected.
-- ============================================================

-- 1) Size limits on saved documents
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

-- 2) At most 5,000 saved documents per user
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

-- 3) The signup trigger function must not be callable as an RPC
revoke execute on function public.handle_new_user() from public, anon, authenticated;
