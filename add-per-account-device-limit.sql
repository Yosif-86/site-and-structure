-- Per-account device limit. Everyone stays at 1 device; the owner's admin
-- account gets 3 (phone, emulator, spare). api/check-device.js reads this
-- instead of its old hardcoded 1, and for accounts above 1 the devices
-- share one session token so they don't log each other out.
--
-- Not user-writable: profiles uses column-level grants (only full_name,
-- phone and the teacher/profile fields are updatable by `authenticated`,
-- see security-hardening-profiles-column-grants.sql), so a new column is
-- service-role/admin-only by default. Capped at 5 as a sanity limit.

alter table public.profiles
  add column if not exists max_devices int not null default 1;

alter table public.profiles drop constraint if exists profiles_max_devices_check;
alter table public.profiles add constraint profiles_max_devices_check
  check (max_devices between 1 and 5);

update public.profiles
set max_devices = 3
where id = (select id from auth.users where lower(email) = 'yosifj.86@gmail.com');

-- Verify: exactly one account above 1, and authenticated can't update it.
select p.max_devices, u.email
from public.profiles p join auth.users u on u.id = p.id
where p.max_devices > 1;

select privilege_type, column_name
from information_schema.column_privileges
where table_schema = 'public' and table_name = 'profiles'
  and grantee = 'authenticated' and column_name = 'max_devices';
