-- Teacher course students: the teacher's student list now carries the
-- account number (#public_id) and user id, and a teacher can remove a
-- student from one of their own courses.
-- No new tables, so no table grants are needed (functions only).

-- ------------------------------------------------------------
-- 1. get_teacher_students: same columns as before plus public_id, user_id.
-- ------------------------------------------------------------
drop function if exists public.get_teacher_students();
create function public.get_teacher_students()
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
  created_at timestamptz,
  list_price integer,
  amount_paid integer,
  discount_amount integer,
  public_id text,
  user_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select
    e.id, c.title, c.slug, c.price::text, c.pay_to_teacher,
    (select le.email from login_events le where le.user_id = e.user_id
      order by le.created_at desc limit 1),
    p.full_name, p.phone, e.status, e.payment_method, e.payment_detail,
    e.payment_proof_path, e.created_at, e.list_price, e.amount_paid,
    e.discount_amount, p.public_id, e.user_id
  from enrollments e
  join courses c on c.slug = e.course_slug
  join profiles p on p.id = e.user_id
  where c.teacher_id = auth.uid()
  order by e.created_at desc;
end;
$$;

revoke all on function public.get_teacher_students() from public, anon;
grant execute on function public.get_teacher_students() to authenticated;

-- ------------------------------------------------------------
-- 2. A teacher (or admin) removes one student from the teacher's own course.
--    Only the enrollment is deleted; the student's account stays.
-- ------------------------------------------------------------
create or replace function public.teacher_remove_student(p_enrollment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_teacher uuid;
begin
  select c.teacher_id into v_teacher
    from enrollments e
    join courses c on c.slug = e.course_slug
    where e.id = p_enrollment_id;

  if not found then
    raise exception 'Enrollment not found.';
  end if;
  if v_teacher is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Not authorized.';
  end if;

  delete from enrollments where id = p_enrollment_id;
end;
$$;

revoke all on function public.teacher_remove_student(uuid) from public, anon;
grant execute on function public.teacher_remove_student(uuid) to authenticated;

-- Verify (read-only): both functions exist.
select proname from pg_proc
 where proname in ('get_teacher_students', 'teacher_remove_student');
