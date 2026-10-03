-- Lecture videos uploaded from the teacher app straight to R2, approved by
-- the admin, then live; plus live updates for the app's screens.
-- Safe to run more than once.

-- ============================================================
-- 1. Only an admin can make a lecture live. Teachers manage their own
--    lectures (title, free flag, order, the pending upload), but r2_path --
--    what students actually play -- is admin-only, so nothing skips review.
-- ============================================================
create or replace function public.enforce_lecture_publish_admin_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.r2_path := null;
  else
    new.r2_path := old.r2_path;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_lecture_publish_admin_only on public.lectures;
create trigger trg_enforce_lecture_publish_admin_only
  before insert or update on public.lectures
  for each row execute function public.enforce_lecture_publish_admin_only();

-- ============================================================
-- 2. Notifications for lectures.
-- ============================================================
create or replace function public.trg_notify_lecture()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course record;
  v_data jsonb;
begin
  select id, slug, title, teacher_id into v_course from courses where id = new.course_id;
  v_data := jsonb_build_object('lecture_id', new.id, 'course_id', new.course_id,
                               'course_slug', v_course.slug);
  if tg_op = 'INSERT' and coalesce(new.pending_upload_path, '') <> '' then
    perform notify_admins('lecture_review', 'محاضرة جديدة بانتظار الموافقة',
      new.title || ' · ' || coalesce(v_course.title, ''), v_data);
  elsif tg_op = 'UPDATE' and old.r2_path is null and new.r2_path is not null then
    perform notify_user(v_course.teacher_id, 'lecture_published', 'تم نشر المحاضرة',
      new.title || ' أصبحت متاحة في دورة ' || coalesce(v_course.title, ''), v_data);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_lecture on public.lectures;
create trigger trg_notify_lecture
  after insert or update of r2_path on public.lectures
  for each row execute function public.trg_notify_lecture();

-- ============================================================
-- 3. Rejecting an uploaded lecture: tells the teacher why, then removes the
--    lecture row (the app deletes the R2 file through the Worker).
-- ============================================================
create or replace function public.reject_lecture(p_lecture_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_l record;
begin
  if not public.is_admin() then
    raise exception 'Not authorized.';
  end if;
  select l.id, l.title, l.r2_path, c.teacher_id, c.slug, c.title as course_title
    into v_l
    from lectures l join courses c on c.id = l.course_id
   where l.id = p_lecture_id;
  if v_l is null then
    raise exception 'Lecture not found.';
  end if;
  if v_l.r2_path is not null then
    raise exception 'Already live.';
  end if;
  perform notify_user(v_l.teacher_id, 'lecture_rejected', 'رُفضت المحاضرة',
    v_l.title || ': ' || coalesce(nullif(trim(p_reason), ''), '—'),
    jsonb_build_object('course_slug', v_l.slug));
  delete from lectures where id = p_lecture_id;
end;
$$;

revoke all on function public.reject_lecture(uuid, text) from public, anon;
grant execute on function public.reject_lecture(uuid, text) to authenticated;

-- ============================================================
-- 4. Live updates: screens listen to these tables and refresh themselves
--    (row-level security still decides what each user receives).
-- ============================================================
do $$
begin
  alter publication supabase_realtime add table public.courses;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.lectures;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.enrollments;
exception when duplicate_object then null;
end $$;

-- ============================================================
-- 5. Check: should return 4 rows.
-- ============================================================
select 'publish lock' as ok
 where exists (select 1 from pg_trigger where tgname = 'trg_enforce_lecture_publish_admin_only')
union all select 'lecture notifications'
 where exists (select 1 from pg_trigger where tgname = 'trg_notify_lecture')
union all select 'reject_lecture'
 where exists (select 1 from pg_proc where proname = 'reject_lecture')
union all select 'realtime tables'
 where (select count(*) from pg_publication_tables
         where pubname = 'supabase_realtime'
           and tablename in ('courses', 'lectures', 'enrollments', 'notifications')) = 4;
