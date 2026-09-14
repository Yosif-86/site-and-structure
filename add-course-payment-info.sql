-- Exposes just the receiving payment number for a published paid course's
-- checkout screen — reuses the existing teacher_payment_method/detail
-- columns on profiles (already there for teachers; the admin's own account
-- can set the same two columns on their own row as the site's default payout
-- number). Security definer because a student must be able to look this up
-- for any course without profiles' normal "only your own row" RLS getting
-- in the way, and it deliberately returns nothing else from that profile.
create or replace function public.get_course_payment_info(p_course_slug text)
returns table(payment_method text, payment_detail text)
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
      select p.teacher_payment_method, p.teacher_payment_detail
      from profiles p
      where p.id = v_course.teacher_id;
  else
    return query
      select p.teacher_payment_method, p.teacher_payment_detail
      from profiles p
      where p.is_admin = true
      order by p.created_at asc
      limit 1;
  end if;
end;
$$;

revoke all on function public.get_course_payment_info(text) from public, anon;
grant execute on function public.get_course_payment_info(text) to anon, authenticated;
