-- Client-side error log: every page reports uncaught JS errors and
-- unhandled promise rejections here (see the small catcher block added
-- after each page's `const sb = supabase.createClient(...)` line) so
-- admin can see what's breaking for real users without needing their
-- browser console. Insert is open to anon too — most errors happen
-- before/without login (e.g. a logged-out visitor hitting a broken page).
create table if not exists error_logs (
  id uuid primary key default gen_random_uuid(),
  message text not null,
  stack text,
  page text,
  user_id uuid references profiles(id) on delete set null,
  user_agent text,
  created_at timestamptz not null default now()
);

alter table error_logs enable row level security;

drop policy if exists "Anyone can report an error" on error_logs;
create policy "Anyone can report an error"
  on error_logs for insert
  to anon, authenticated
  with check (true);

drop policy if exists "Admins view error log" on error_logs;
create policy "Admins view error log"
  on error_logs for select
  to authenticated
  using (public.is_admin());

drop policy if exists "Admins delete error log" on error_logs;
create policy "Admins delete error log"
  on error_logs for delete
  to authenticated
  using (public.is_admin());

grant insert on error_logs to anon, authenticated;
grant select, delete on error_logs to authenticated;

create index if not exists idx_error_logs_created_at on error_logs (created_at desc);
