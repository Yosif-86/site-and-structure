-- Lets admin unlock specific teachers to manage their own course payments:
-- approve their students' payment proofs themselves and edit their own
-- payout number, instead of everything going through the admin. Unlocked
-- teachers are still only ever unlocked per-course via the existing
-- courses.pay_to_teacher checkbox (admin still flips that per course) --
-- this new flag is the master gate that pay_to_teacher now requires.

alter table profiles add column if not exists teacher_payment_enabled boolean not null default false;

-- ============================================================
-- 1. Admin-only setter (mirrors is_admin()-gated functions elsewhere —
--    no new RLS/grant surface on profiles itself).
-- ============================================================
create or replace function public.set_teacher_payment_enabled(p_teacher_id uuid, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins can change this.';
  end if;
  update profiles set teacher_payment_enabled = p_enabled where id = p_teacher_id and is_teacher = true;
  -- Revoking access also turns off pay_to_teacher on every one of their
  -- courses, so payments fall back to admin-collected immediately.
  if not p_enabled then
    update courses set pay_to_teacher = false where teacher_id = p_teacher_id;
  end if;
end;
$$;

revoke all on function public.set_teacher_payment_enabled(uuid, boolean) from public, anon;
grant execute on function public.set_teacher_payment_enabled(uuid, boolean) to authenticated;

-- ============================================================
-- 2. courses.pay_to_teacher can now only be turned on for a teacher who is
--    unlocked (extends the existing admin-only lock from
--    lock-pay-to-teacher-to-admin.sql with the new gate).
-- ============================================================
create or replace function public.enforce_pay_to_teacher_admin_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    if tg_op = 'INSERT' then
      new.pay_to_teacher := false;
    else
      new.pay_to_teacher := old.pay_to_teacher;
    end if;
  elsif new.pay_to_teacher = true and not exists (
    select 1 from profiles where id = new.teacher_id and teacher_payment_enabled = true
  ) then
    -- Admin tried to turn this on for a teacher who isn't unlocked yet.
    if tg_op = 'INSERT' then
      new.pay_to_teacher := false;
    else
      new.pay_to_teacher := old.pay_to_teacher;
    end if;
  end if;
  return new;
end;
$$;

-- ============================================================
-- 3. A teacher's own payment_method/detail can now only be edited once
--    unlocked (same columns any authenticated user can already write on
--    their own row per add-teacher-role-schema.sql's grant — this adds the
--    unlock requirement on top, admin's own row is always exempt).
-- ============================================================
create or replace function public.enforce_teacher_payment_fields_gate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.teacher_payment_method is distinct from old.teacher_payment_method
      or new.teacher_payment_detail is distinct from old.teacher_payment_detail)
     and not public.is_admin()
     and coalesce(old.teacher_payment_enabled, false) = false then
    new.teacher_payment_method := old.teacher_payment_method;
    new.teacher_payment_detail := old.teacher_payment_detail;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_teacher_payment_fields_gate on profiles;
create trigger trg_enforce_teacher_payment_fields_gate
  before update on profiles
  for each row
  execute function public.enforce_teacher_payment_fields_gate();

-- ============================================================
-- 4. Teacher approves their own students' payments — only for courses
--    that are BOTH theirs and currently pay_to_teacher = true. No new RLS
--    on enrollments; the auth check lives inside this function instead.
-- ============================================================
create or replace function public.teacher_approve_enrollment(p_enrollment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ok boolean;
begin
  select exists(
    select 1 from enrollments e
    join courses c on c.slug = e.course_slug
    where e.id = p_enrollment_id and c.teacher_id = auth.uid() and c.pay_to_teacher = true
  ) into v_ok;
  if not v_ok then
    raise exception 'Not authorized to approve this enrollment.';
  end if;
  update enrollments set status = 'active', approved_by = auth.uid(), approved_at = now() where id = p_enrollment_id;
end;
$$;

revoke all on function public.teacher_approve_enrollment(uuid) from public, anon;
grant execute on function public.teacher_approve_enrollment(uuid) to authenticated;

-- ============================================================
-- 5. Storage: a teacher can view payment-proof screenshots uploaded by
--    students of their own pay_to_teacher courses (their students, their
--    money to verify). Locked courses' proofs stay admin-only, same as today.
-- ============================================================
drop policy if exists "Teachers can view own course students payment proofs" on storage.objects;
create policy "Teachers can view own course students payment proofs"
  on storage.objects for select
  using (
    bucket_id = 'payment-proofs'
    and exists (
      select 1 from enrollments e
      join courses c on c.slug = e.course_slug
      where c.teacher_id = auth.uid()
        and c.pay_to_teacher = true
        and e.payment_proof_path = storage.objects.name
    )
  );

-- ============================================================
-- 6. What the teacher's payment/students view reads — every student across
--    all of the teacher's own courses (locked and unlocked alike, so they
--    have visibility even into admin-collected courses per Yosif's call),
--    with enough to compute an estimated amount and to gate the
--    proof/approve UI by course.pay_to_teacher client-side.
-- ============================================================
create or replace function public.get_teacher_students()
returns table(
  enrollment_id uuid,
  course_title text,
  course_slug text,
  course_price text,
  pay_to_teacher boolean,
  email text,
  full_name text,
  phone text,
  status text,
  payment_method text,
  payment_detail text,
  payment_proof_path text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select
    e.id,
    c.title,
    c.slug,
    c.price,
    c.pay_to_teacher,
    (select le.email from login_events le where le.user_id = e.user_id order by le.created_at desc limit 1),
    p.full_name,
    p.phone,
    e.status,
    e.payment_method,
    e.payment_detail,
    e.payment_proof_path,
    e.created_at
  from enrollments e
  join courses c on c.slug = e.course_slug
  join profiles p on p.id = e.user_id
  where c.teacher_id = auth.uid()
  order by e.created_at desc;
end;
$$;

revoke all on function public.get_teacher_students() from public, anon;
grant execute on function public.get_teacher_students() to authenticated;
