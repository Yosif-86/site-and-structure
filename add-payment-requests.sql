-- Payment requests in the app: who approves, rejections with a reason the
-- student sees, and the platform's own default payment details.
-- Safe to run more than once.

-- ============================================================
-- 1. Rejections. A rejected request is removed from enrollments (so the
--    student can submit again) and the reason is kept here for them to see.
-- ============================================================
create table if not exists public.enrollment_rejections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  course_slug text not null,
  reason text not null,
  rejected_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists enrollment_rejections_user_course_idx
  on public.enrollment_rejections (user_id, course_slug, created_at desc);

alter table public.enrollment_rejections enable row level security;

drop policy if exists "Students read own rejections" on public.enrollment_rejections;
create policy "Students read own rejections"
  on public.enrollment_rejections for select
  using (user_id = auth.uid() or public.is_admin());

-- Writes only through reject_enrollment() below.
revoke insert, update, delete on public.enrollment_rejections from anon, authenticated;

-- ============================================================
-- 2. Who decides a request:
--    course pays the teacher (pay_to_teacher) -> only that teacher
--    otherwise                                 -> only an admin
-- ============================================================
create or replace function public.reject_enrollment(p_enrollment_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_e record;
  v_teacher_paid boolean;
begin
  select e.id, e.user_id, e.course_slug, e.status, c.teacher_id, c.pay_to_teacher
    into v_e
    from enrollments e
    join courses c on c.slug = e.course_slug
    where e.id = p_enrollment_id;

  if v_e is null then
    raise exception 'Request not found.';
  end if;
  if v_e.status = 'active' then
    raise exception 'Already approved.';
  end if;

  v_teacher_paid := coalesce(v_e.pay_to_teacher, false) and v_e.teacher_id is not null;
  if v_teacher_paid and v_e.teacher_id <> auth.uid() then
    raise exception 'Not authorized.';
  end if;
  if not v_teacher_paid and not public.is_admin() then
    raise exception 'Not authorized.';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'A reason is required.';
  end if;

  insert into enrollment_rejections (user_id, course_slug, reason, rejected_by)
  values (v_e.user_id, v_e.course_slug, left(trim(p_reason), 300), auth.uid());

  delete from enrollments where id = p_enrollment_id;
end;
$$;

revoke all on function public.reject_enrollment(uuid, text) from public, anon;
grant execute on function public.reject_enrollment(uuid, text) to authenticated;

-- ============================================================
-- 3. Checkout destination. Teacher-paid courses use the teacher's details
--    (unchanged); everything else now uses the admin's Zain Cash number,
--    Qi Card account and QR (the same three fields), falling back to the old
--    single method/number pair if the new fields are still empty.
-- ============================================================
drop function if exists public.get_course_payment_info(text);

create function public.get_course_payment_info(p_course_slug text)
returns table(zaincash_phone text, qi_account_number text, qi_qr_url text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course record;
begin
  select id, teacher_id, pay_to_teacher, status, is_free
    into v_course
    from courses
    where slug = p_course_slug;

  if v_course is null or v_course.status <> 'published' or v_course.is_free then
    return;
  end if;

  if v_course.pay_to_teacher and v_course.teacher_id is not null then
    return query
      select p.teacher_zaincash_phone, p.teacher_qi_account_number, p.teacher_qi_qr_url
      from profiles p
      where p.id = v_course.teacher_id;
  else
    return query
      select
        coalesce(nullif(trim(p.teacher_zaincash_phone), ''),
                 case when p.teacher_payment_method = 'zain' then p.teacher_payment_detail end),
        coalesce(nullif(trim(p.teacher_qi_account_number), ''),
                 case when p.teacher_payment_method = 'qi' then p.teacher_payment_detail end),
        nullif(trim(p.teacher_qi_qr_url), '')
      from profiles p
      where p.is_admin = true
      order by p.created_at asc
      limit 1;
  end if;
end;
$$;

revoke all on function public.get_course_payment_info(text) from public, anon;
grant execute on function public.get_course_payment_info(text) to anon, authenticated;

-- ============================================================
-- 4. Ticking "pay to teacher" in the app first unlocks the teacher
--    (set_teacher_payment_enabled), which refuses if the teacher has no
--    payment details yet -- that check already exists. Nothing to add here;
--    listed so the flow is documented in one place.
-- ============================================================

-- ============================================================
-- 5. Check: these should all return a row.
-- ============================================================
select 'enrollment_rejections' as ok where to_regclass('public.enrollment_rejections') is not null
union all
select 'reject_enrollment' where exists (select 1 from pg_proc where proname = 'reject_enrollment')
union all
select 'teacher_approve_enrollment' where exists (select 1 from pg_proc where proname = 'teacher_approve_enrollment')
union all
select 'get_teacher_students' where exists (select 1 from pg_proc where proname = 'get_teacher_students');
