-- Security hardening pass, part 3: fix the device-slot race condition flagged
-- during the overnight review.
--
-- check-device.js used to do this as two separate round trips:
--   1. count existing trusted_devices for user_id
--   2. if count < MAX_DEVICES, insert a new row
-- Nothing stopped two concurrent requests (e.g. the same account logging in
-- from two new devices in the same instant) from both reading count=1 before
-- either insert lands, so both pass the check and the account ends up with
-- 3 trusted devices instead of the intended cap of 2.
--
-- Fix: move the whole check-or-update-or-insert into one plpgsql function
-- that takes a per-user advisory lock first (pg_advisory_xact_lock), so a
-- second concurrent call for the same user_id blocks until the first one's
-- transaction commits and releases the lock. Different users never contend
-- with each other. SECURITY DEFINER because trusted_devices grants to
-- `authenticated` are select/delete only (see device-admin-policy.sql) —
-- this function does the insert/update as its owner instead of granting
-- direct table writes to every logged-in user.

create or replace function public.claim_device_slot(
  p_user_id uuid,
  p_device_id text,
  p_device_label text,
  p_max_devices int
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing_id uuid;
  v_count int;
begin
  -- Serializes concurrent calls for the same user; released automatically
  -- at transaction end (function call), so nothing to clean up on error.
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select id into v_existing_id
  from trusted_devices
  where user_id = p_user_id and device_id = p_device_id;

  if v_existing_id is not null then
    update trusted_devices set last_seen = now() where id = v_existing_id;
    return true;
  end if;

  select count(*) into v_count from trusted_devices where user_id = p_user_id;

  if v_count >= p_max_devices then
    return false;
  end if;

  insert into trusted_devices (user_id, device_id, device_label)
  values (p_user_id, p_device_id, p_device_label);
  return true;
end;
$$;

-- Only the service-role key (used by check-device.js's `admin` client) needs
-- to call this — it is never exposed to the anon/publishable key or called
-- directly from the browser/app.
revoke all on function public.claim_device_slot(uuid, text, text, int) from public, anon, authenticated;
grant execute on function public.claim_device_slot(uuid, text, text, int) to service_role;
