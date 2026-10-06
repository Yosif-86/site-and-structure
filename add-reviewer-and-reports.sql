-- Store review + content reports (2026-10-06).
--  1. profiles.is_reviewer: an account for Google/Apple reviewers. It can
--     open every published lecture and file without enrollments (so revenue
--     and teacher earnings stay clean). Set by the admin only (column is not
--     user-writable). Pair it with max_devices = 5 and phone_verified = true.
--  2. content_reports: users report a course; admins are notified and
--     resolve or dismiss reports in the admin screen.

alter table public.profiles
  add column if not exists is_reviewer boolean not null default false;

create or replace function public.is_reviewer()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select is_reviewer from profiles where id = auth.uid()), false);
$$;

-- Course files: reviewers can open every published file.
create or replace function public.can_view_course_file(p_file_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from course_files f
    join courses c on c.id = f.course_id
    where f.id = p_file_id
      and (
        public.is_admin()
        or c.teacher_id = auth.uid()
        or (f.status = 'published' and (
              f.is_free
              or public.is_reviewer()
              or exists (select 1 from enrollments e
                         where e.course_slug = c.slug and e.user_id = auth.uid()
                           and e.status = 'active')))));
$$;

-- Content reports.
create table if not exists public.content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid default auth.uid() references auth.users(id) on delete set null,
  course_id uuid not null references public.courses(id) on delete cascade,
  reason text not null check (reason in ('inappropriate', 'copyright', 'misleading', 'other')),
  details text check (details is null or length(details) <= 1000),
  status text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  handled_at timestamptz,
  created_at timestamptz not null default now()
);

-- One open report per person per course (no spamming).
create unique index if not exists content_reports_one_open
  on public.content_reports (reporter_id, course_id) where status = 'open';

alter table public.content_reports enable row level security;

drop policy if exists "Users report content" on public.content_reports;
create policy "Users report content" on public.content_reports
  for insert to authenticated
  with check (reporter_id = auth.uid() and status = 'open');

drop policy if exists "Admins read reports" on public.content_reports;
create policy "Admins read reports" on public.content_reports
  for select using (public.is_admin());

drop policy if exists "Admins handle reports" on public.content_reports;
create policy "Admins handle reports" on public.content_reports
  for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Admins delete reports" on public.content_reports;
create policy "Admins delete reports" on public.content_reports
  for delete using (public.is_admin());

grant select, insert, update, delete on public.content_reports to authenticated;

create or replace function public.trg_notify_content_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text;
begin
  select title into v_title from courses where id = new.course_id;
  perform notify_admins('content_report', 'بلاغ عن محتوى',
    coalesce(v_title, ''), jsonb_build_object('course_id', new.course_id, 'report_id', new.id));
  return new;
end;
$$;

drop trigger if exists trg_notify_content_report on public.content_reports;
create trigger trg_notify_content_report
  after insert on public.content_reports
  for each row execute function public.trg_notify_content_report();

-- Check: each row should say true.
select 'profiles.is_reviewer' as item,
  exists (select 1 from information_schema.columns
          where table_name = 'profiles' and column_name = 'is_reviewer')::text as ok
union all select 'content_reports',
  exists (select 1 from information_schema.tables where table_name = 'content_reports')::text
union all select 'report trigger',
  exists (select 1 from pg_trigger where tgname = 'trg_notify_content_report')::text
union all select 'reviewer can view files',
  (position('is_reviewer' in pg_get_functiondef('public.can_view_course_file(uuid)'::regprocedure)) > 0)::text;
