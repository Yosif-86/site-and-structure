-- Free (no payment) enrollment: an admin asks to add a student, by the
-- student's public ID, to a course. The course's teacher must approve; only
-- then the student is enrolled. A rejection needs a reason. An admin who owns
-- the course cannot approve their own request (a second person is required).
--
-- Safe to run more than once.

create table if not exists public.free_enrollment_requests (
  id            uuid primary key default gen_random_uuid(),
  student_id    uuid not null references auth.users(id) on delete cascade,
  course_slug   text not null,
  teacher_id    uuid not null references auth.users(id) on delete cascade,
  requested_by  uuid not null references auth.users(id) on delete cascade,
  status        text not null default 'pending'
                check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  reject_reason text,
  created_at    timestamptz not null default now(),
  decided_at    timestamptz
);

create unique index if not exists free_enrollment_one_pending
  on public.free_enrollment_requests (student_id, course_slug)
  where status = 'pending';

alter table public.free_enrollment_requests enable row level security;

drop policy if exists "Admins and the course teacher read free requests"
  on public.free_enrollment_requests;
create policy "Admins and the course teacher read free requests"
  on public.free_enrollment_requests for select
  using (public.is_admin() or teacher_id = auth.uid());
-- No insert/update/delete policies: every change goes through the functions below.

-- Admin: ask to add a student (by #ID) to a course for free.
create or replace function public.admin_request_free_enrollment(
  p_public_id text, p_course_slug text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_student   record;
  v_course    record;
  v_id        uuid;
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;

  select id, coalesce(nullif(full_name, ''), 'طالب') as name into v_student
    from profiles where public_id = btrim(replace(coalesce(p_public_id, ''), '#', ''));
  if not found then
    raise exception 'no account with this ID';
  end if;

  select slug, title, teacher_id, is_free, status into v_course
    from courses where slug = p_course_slug;
  if not found or v_course.status <> 'published' then
    raise exception 'course not found';
  end if;
  if coalesce(v_course.is_free, false) then
    raise exception 'this course is already free';
  end if;
  if v_course.teacher_id is null then
    raise exception 'this course has no teacher to approve';
  end if;
  if v_student.id = v_course.teacher_id then
    raise exception 'the teacher cannot be added as a student';
  end if;
  if exists (select 1 from enrollments
              where user_id = v_student.id and course_slug = p_course_slug
                and status = 'active') then
    raise exception 'already enrolled';
  end if;

  insert into free_enrollment_requests (student_id, course_slug, teacher_id, requested_by)
  values (v_student.id, p_course_slug, v_course.teacher_id, auth.uid())
  returning id into v_id;

  perform notify_user(v_course.teacher_id, 'free_enroll_request',
    'طلب إضافة طالب مجاناً',
    v_student.name || ' · ' || coalesce(v_course.title, ''),
    jsonb_build_object('request_id', v_id, 'course_slug', p_course_slug, 'for', 'teacher'));
  return v_id;
exception when unique_violation then
  raise exception 'a request for this student and course is already waiting';
end;
$$;

-- Admin: withdraw a request that is still waiting.
create or replace function public.admin_cancel_free_enrollment(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  update free_enrollment_requests
     set status = 'cancelled', decided_at = now()
   where id = p_request_id and status = 'pending';
  if not found then
    raise exception 'request is no longer waiting';
  end if;
end;
$$;

-- Teacher: approve (enrolls the student) or reject (a reason is required).
create or replace function public.teacher_decide_free_enrollment(
  p_request_id uuid, p_approve boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_r      record;
  v_course record;
  v_price  integer;
begin
  select * into v_r from free_enrollment_requests
   where id = p_request_id and teacher_id = auth.uid() and status = 'pending'
   for update;
  if not found then
    raise exception 'request is no longer waiting';
  end if;
  if not coalesce(p_approve, false) and btrim(coalesce(p_reason, '')) = '' then
    raise exception 'a reason is required';
  end if;

  select title, price into v_course from courses where slug = v_r.course_slug;

  if p_approve then
    v_price := nullif(regexp_replace(coalesce(v_course.price, ''), '[^0-9]', '', 'g'), '')::integer;
    insert into enrollments (user_id, course_slug, status, payment_method,
                             payment_detail, list_price, amount_paid,
                             discount_amount, approved_by, approved_at)
    values (v_r.student_id, v_r.course_slug, 'active', 'free_add',
            'Added by admin, approved by teacher', v_price, 0, 0,
            auth.uid(), now())
    on conflict (user_id, course_slug) do update
      set status = 'active', payment_method = 'free_add',
          payment_detail = 'Added by admin, approved by teacher',
          list_price = excluded.list_price, amount_paid = 0, discount_amount = 0,
          approved_by = auth.uid(), approved_at = now();
    update free_enrollment_requests
       set status = 'approved', decided_at = now() where id = v_r.id;
    perform notify_user(v_r.student_id, 'payment_approved',
      'تمت إضافتك إلى دورة',
      'يمكنك الآن مشاهدة دورة ' || coalesce(v_course.title, ''),
      jsonb_build_object('course_slug', v_r.course_slug));
    perform notify_user(v_r.requested_by, 'free_enroll_result',
      'وافق المدرّس على الإضافة المجانية', coalesce(v_course.title, ''),
      jsonb_build_object('request_id', v_r.id, 'course_slug', v_r.course_slug, 'for', 'admin'));
  else
    update free_enrollment_requests
       set status = 'rejected', reject_reason = btrim(p_reason), decided_at = now()
     where id = v_r.id;
    perform notify_user(v_r.requested_by, 'free_enroll_result',
      'رفض المدرّس الإضافة المجانية',
      coalesce(v_course.title, '') || ' — ' || btrim(p_reason),
      jsonb_build_object('request_id', v_r.id, 'course_slug', v_r.course_slug, 'for', 'admin'));
  end if;
end;
$$;

revoke all on function public.admin_request_free_enrollment(text, text) from public, anon;
revoke all on function public.admin_cancel_free_enrollment(uuid) from public, anon;
revoke all on function public.teacher_decide_free_enrollment(uuid, boolean, text) from public, anon;
grant execute on function public.admin_request_free_enrollment(text, text) to authenticated;
grant execute on function public.admin_cancel_free_enrollment(uuid) to authenticated;
grant execute on function public.teacher_decide_free_enrollment(uuid, boolean, text) to authenticated;

-- Live refresh for the admin and teacher lists.
do $$
begin
  alter publication supabase_realtime add table public.free_enrollment_requests;
exception when duplicate_object or undefined_object then null;
end $$;
