-- A teacher can step back down to a regular student account.
-- Blocked while the account still owns any course (published, draft or
-- pending), so no course is left without a teacher.
create or replace function public.leave_teacher_role()
returns boolean
language plpgsql
security definer
set search_path = 'public'
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  if exists (select 1 from courses where teacher_id = auth.uid()) then
    raise exception 'has courses';
  end if;
  update profiles set is_teacher = false where id = auth.uid();
  return true;
end;
$$;

revoke all on function public.leave_teacher_role() from public, anon;
grant execute on function public.leave_teacher_role() to authenticated;
