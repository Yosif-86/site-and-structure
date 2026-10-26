-- claim_device_slot: a known device now also refreshes its label, so rows that
-- say "Flutter app" pick up the real phone name on the next check. Limits and
-- the single-device rule are unchanged.
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
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select id into v_existing_id
  from trusted_devices
  where user_id = p_user_id and device_id = p_device_id;

  if v_existing_id is not null then
    update trusted_devices
       set last_seen = now(),
           device_label = coalesce(nullif(btrim(p_device_label), ''), device_label)
     where id = v_existing_id;
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

revoke all on function public.claim_device_slot(uuid, text, text, int) from public, anon, authenticated;
grant execute on function public.claim_device_slot(uuid, text, text, int) to service_role;
