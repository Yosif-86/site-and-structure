-- Course files (2026-10-05):
--  1. A file can belong to one lecture (lecture_id) or to the whole course (null).
--  2. New files wait for the admin: processing -> pending_review -> published
--     (or rejected). Files an admin uploads are published straight away.
--     Files already published stay published.

alter table public.course_files
  add column if not exists lecture_id uuid references public.lectures(id) on delete cascade;

create index if not exists course_files_lecture_idx
  on public.course_files (lecture_id);

alter table public.course_files drop constraint if exists course_files_status_check;
alter table public.course_files add constraint course_files_status_check
  check (status in ('processing', 'pending_review', 'published', 'rejected', 'failed'));

-- The teacher and the admin can open a file before it is published
-- (preview while reviewing). Students only see published ones.
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
              or exists (select 1 from enrollments e
                         where e.course_slug = c.slug and e.user_id = auth.uid()
                           and e.status = 'active')))));
$$;

-- A lecture_id must belong to the same course.
create or replace function public.trg_check_course_file_lecture()
returns trigger
language plpgsql
as $$
begin
  if new.lecture_id is not null and not exists (
      select 1 from lectures where id = new.lecture_id and course_id = new.course_id) then
    raise exception 'lecture belongs to another course';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_check_course_file_lecture on public.course_files;
create trigger trg_check_course_file_lecture
  before insert or update of lecture_id on public.course_files
  for each row execute function public.trg_check_course_file_lecture();

-- Called by api/course-file.js (service role) when processing finishes.
create or replace function public.finish_course_file(
  p_file_id uuid, p_view_path text, p_view_type text, p_ok boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_f record;
  v_admin boolean;
begin
  select f.uploaded_by, coalesce(p.is_admin, false) as is_admin
    into v_f
    from course_files f left join profiles p on p.id = f.uploaded_by
   where f.id = p_file_id;
  v_admin := coalesce(v_f.is_admin, false);

  perform set_config('app.course_file_job', 'on', true);
  update course_files
     set view_path = case when p_ok then p_view_path else null end,
         view_type = case when p_ok then p_view_type else null end,
         status = case when not p_ok then 'failed'
                       when v_admin then 'published'
                       else 'pending_review' end,
         raw_path = case when p_ok then null else raw_path end
   where id = p_file_id
   returning course_id, title, uploaded_by into v_f;

  if v_f.uploaded_by is not null then
    perform notify_user(v_f.uploaded_by, 'course_file',
      case when not p_ok then 'تعذرت معالجة الملف'
           when v_admin then 'الملف جاهز'
           else 'الملف بانتظار موافقة الإدارة' end,
      v_f.title,
      jsonb_build_object('course_id', v_f.course_id));
  end if;
  if p_ok and not v_admin then
    perform notify_admins('course_file_review', 'ملف بانتظار الموافقة', v_f.title,
      jsonb_build_object('course_id', v_f.course_id, 'file_id', p_file_id));
  end if;
end;
$$;

revoke all on function public.finish_course_file(uuid, text, text, boolean) from public, anon, authenticated;
grant execute on function public.finish_course_file(uuid, text, text, boolean) to service_role;

-- Admin approves or rejects a file waiting for review.
create or replace function public.admin_review_course_file(
  p_file_id uuid, p_approve boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_f record;
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  perform set_config('app.course_file_job', 'on', true);
  update course_files
     set status = case when p_approve then 'published' else 'rejected' end
   where id = p_file_id and status = 'pending_review'
   returning course_id, title, uploaded_by into v_f;
  if not found then
    raise exception 'file is not waiting for review';
  end if;
  perform notify_user(v_f.uploaded_by, 'course_file',
    case when p_approve then 'تمت الموافقة على الملف' else 'تم رفض الملف' end,
    case when p_approve or coalesce(p_reason, '') = '' then v_f.title
         else v_f.title || ' — ' || p_reason end,
    jsonb_build_object('course_id', v_f.course_id));
end;
$$;

revoke all on function public.admin_review_course_file(uuid, boolean, text) from public, anon;
grant execute on function public.admin_review_course_file(uuid, boolean, text) to authenticated;

-- Check: each row should say true.
select 'course_files.lecture_id' as item,
  exists (select 1 from information_schema.columns
          where table_name = 'course_files' and column_name = 'lecture_id') as ok
union all select 'admin_review_course_file',
  exists (select 1 from pg_proc where proname = 'admin_review_course_file')
union all select 'status allows pending_review',
  exists (select 1 from pg_constraint where conname = 'course_files_status_check'
          and pg_get_constraintdef(oid) like '%pending_review%');
