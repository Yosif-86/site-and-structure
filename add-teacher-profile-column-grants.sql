-- Fixes "permission denied for table profiles" when a teacher saves their
-- profile (bio/specialty/photo) or payment info (ZainCash/Qi/QR), and when
-- the admin saves their own "My payment number".
--
-- security-hardening-profiles-column-grants.sql locked the UPDATE grant on
-- profiles down to just (full_name, phone) for the authenticated role, to
-- close an is_admin privilege-escalation hole. That was the right call, but
-- it was scoped too narrowly -- it never added back the other columns
-- teacher.html/admin.html legitimately let a user write to their own row:
-- teacher_bio, teacher_specialty, teacher_photo_url, teacher_payment_method,
-- teacher_payment_detail (admin's own payout number), and the newer
-- teacher_zaincash_phone/teacher_qi_account_number/teacher_qi_qr_url. GRANT
-- is additive, so this just adds those columns on top of the existing
-- (full_name, phone) grant -- it does not touch is_admin,
-- active_session_token, teacher_payment_enabled, or id, which must stay
-- admin/service-role only per that file's rationale.

grant update (
  teacher_bio, teacher_specialty, teacher_photo_url,
  teacher_payment_method, teacher_payment_detail,
  teacher_zaincash_phone, teacher_qi_account_number, teacher_qi_qr_url
) on public.profiles to authenticated;

-- Confirm: should now show update privileges for authenticated covering
-- full_name, phone, and the columns above -- still no is_admin,
-- active_session_token, teacher_payment_enabled, or id.
select grantee, privilege_type, column_name
from information_schema.column_privileges
where table_schema = 'public' and table_name = 'profiles' and grantee = 'authenticated'
order by privilege_type, column_name;
