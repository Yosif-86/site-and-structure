-- Lets admins view and remove trusted-device rows from the admin dashboard,
-- so they can free up a device slot for a capped account without touching
-- the database directly. Claiming a NEW device still only happens through
-- api/check-device.js (service_role) — this only adds admin SELECT/DELETE,
-- not INSERT/UPDATE, so the 2-device cap logic itself can't be bypassed by
-- a client.
create policy "Admins can view trusted devices"
  on trusted_devices for select
  using (public.is_admin());

create policy "Admins can remove trusted devices"
  on trusted_devices for delete
  using (public.is_admin());
