-- Teachers can delete their own course again, even after the admin
-- published it (the app shows a strong warning when students are enrolled).
drop policy if exists "Teachers can delete own courses" on courses;
create policy "Teachers can delete own courses"
  on courses for delete
  using (teacher_id = auth.uid());

-- Check: should show the policy with "teacher_id = auth.uid()" only.
select policyname, cmd, qual
from pg_policies
where tablename = 'courses' and policyname = 'Teachers can delete own courses';
