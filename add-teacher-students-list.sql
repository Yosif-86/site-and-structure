-- Lets a teacher see who's enrolled in their own courses (name/phone/email)
-- without widening profiles/login_events RLS — security definer, scoped
-- strictly to courses.teacher_id = auth.uid() inside the function body, so
-- a teacher can never see another teacher's students by calling this.
create or replace function public.get_teacher_students()
returns table(
  course_title text,
  course_slug text,
  email text,
  full_name text,
  phone text,
  status text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select
    c.title,
    c.slug,
    (select le.email from login_events le where le.user_id = e.user_id order by le.created_at desc limit 1),
    p.full_name,
    p.phone,
    e.status,
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
