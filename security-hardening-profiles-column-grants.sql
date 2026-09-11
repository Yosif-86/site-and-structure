-- Security hardening pass, part 4: close a privilege-escalation hole on
-- `profiles` found while reviewing where admin status comes from.
--
-- is_admin() (public.is_admin, used by every admin-only RLS policy in this
-- repo) is:
--   select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
-- so it trusts profiles.is_admin completely. That's fine IF that column can
-- only ever be set by something trusted. It currently isn't:
--
--   "Users can update own profile"  (UPDATE, using: auth.uid() = id, with_check: NULL)
--   "Users can insert own profile"  (INSERT, with_check: auth.uid() = id)
--
-- Neither policy restricts which COLUMNS a user can write — only which ROW
-- (their own). with_check being NULL on the update policy in particular
-- means Postgres accepts any new column values as long as the row's id still
-- matches auth.uid(). So any authenticated user can currently call, straight
-- against the REST API (no need to go through this app's UI at all):
--   update profiles set is_admin = true where id = auth.uid();
-- ...and become an admin. Same hole on insert: is_admin could be set to true
-- in the initial signup insert.
--
-- Neither the website nor the mobile app ever needs to write is_admin or
-- active_session_token through a user's own token — those are only ever
-- set by the service-role key (api/check-device.js, and admin.html/the
-- mobile admin screen use the RLS-gated is_admin() path, not a user setting
-- their own flag). The only legitimate self-service writes are full_name
-- and phone at signup. Column-level grants are checked BEFORE RLS, so this
-- closes the hole regardless of how the row-level policy is worded.

revoke update, insert on public.profiles from authenticated;
grant insert (id, full_name, phone) on public.profiles to authenticated;
grant update (full_name, phone) on public.profiles to authenticated;

-- Confirm: should show update/insert limited to (full_name, phone) for
-- authenticated, with no mention of is_admin, active_session_token, or id
-- in the update grant.
select grantee, privilege_type, column_name
from information_schema.column_privileges
where table_schema = 'public' and table_name = 'profiles' and grantee = 'authenticated'
order by privilege_type, column_name;
