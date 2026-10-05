-- ============================================================
-- Table permissions for signed-in users. This project doesn't grant them
-- automatically on new tables, so these tables had row-level security
-- policies but no base permission, and every app read/write was refused:
--   notifications          -> the bell list never loaded (empty bell)
--   enrollment_rejections  -> students never saw why a payment was rejected
--   course_files           -> "ليست لديك صلاحية" when adding a course file
--   push_tokens            -> a phone couldn't unregister on sign-out
--   security_events        -> screenshot reports / admin list refused
-- RLS (already on, with policies) still limits every row to its owner /
-- admins. Secret tables (app_secrets, phone_otp_codes,
-- discount_code_attempts) stay closed on purpose.
-- Safe to run more than once.
-- ============================================================

grant select, update on public.notifications to authenticated;
grant select on public.enrollment_rejections to authenticated;
grant select, insert, update, delete on public.course_files to authenticated;
grant select on public.course_files to anon;
grant select, insert, update, delete on public.push_tokens to authenticated;
grant select, insert, delete on public.security_events to authenticated;

-- Check: each row should list the permissions.
select table_name, grantee,
  string_agg(privilege_type, ',' order by privilege_type) as privs
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('notifications', 'enrollment_rejections', 'course_files',
                     'push_tokens', 'security_events')
  and grantee in ('authenticated', 'anon')
  and privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
group by 1, 2
order by 1, 2;
