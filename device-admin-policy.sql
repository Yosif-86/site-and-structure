-- Lets admins view and remove trusted-device rows from the admin dashboard,
-- so they can free up a device slot for a capped account without touching
-- the database directly. Claiming a NEW device still only happens through
-- api/check-device.js (service_role) — this only adds admin SELECT/DELETE,
-- not INSERT/UPDATE, so the 2-device cap logic itself can't be bypassed by
-- a client.

-- RLS policies: which rows an admin is allowed to touch.
create policy "Admins can view trusted devices"
  on trusted_devices for select
  using (public.is_admin());

create policy "Admins can remove trusted devices"
  on trusted_devices for delete
  using (public.is_admin());

-- Table-level grants: this project's authenticated role has no default
-- grants on trusted_devices (it was locked down to service_role only when
-- the table was created), so the RLS policies above are necessary but not
-- sufficient on their own — Postgres checks the grant before it ever
-- evaluates a policy.
grant select, delete on trusted_devices to authenticated;
