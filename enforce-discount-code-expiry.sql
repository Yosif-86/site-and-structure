-- teacher.html's "New code" form only checked that an expiry value was
-- present, not that it was actually in the future — a teacher could pick a
-- time already in the past (or a few minutes from now and wait it out) and
-- still successfully insert an already-expired-on-arrival code. Client-side
-- fix is in teacher.html (addCode) but that alone doesn't stop a raw API
-- call from doing the same thing.
--
-- This only fires on INSERT, not UPDATE — discount_codes.expires_at is
-- immutable in practice (the UI never edits an existing code, only revokes
-- it via is_active), but a code naturally passes its own expiry over time,
-- and a blanket "expires_at > now()" check on every UPDATE would make
-- revoking an already-expired code fail.
create or replace function public.enforce_discount_code_expiry_future()
returns trigger
language plpgsql
as $$
begin
  if new.expires_at <= now() then
    raise exception 'expires_at must be in the future';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_discount_code_expiry_future on discount_codes;
create trigger trg_enforce_discount_code_expiry_future
  before insert on discount_codes
  for each row
  execute function public.enforce_discount_code_expiry_future();
