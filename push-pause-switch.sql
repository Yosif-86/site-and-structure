-- Global push pause. app_config.push_enabled = false stops every phone push
-- (the in-app notification list still fills). Turn push back on with:
--   update public.app_config set value = 'true'::jsonb, updated_at = now() where key = 'push_enabled';
-- Turn it off again with value = 'false'. A missing row counts as on.
insert into public.app_config (key, value) values ('push_enabled', 'false'::jsonb)
on conflict (key) do update set value = 'false'::jsonb, updated_at = now();

create or replace function public.trg_push_notification()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
begin
  if coalesce((select value from app_config where key = 'push_enabled'), 'true'::jsonb) = 'false'::jsonb then
    return new;
  end if;
  if exists (select 1 from push_tokens where user_id = new.user_id) then
    perform net.http_post(
      url := 'https://site-and-structure.vercel.app/api/push',
      body := jsonb_build_object('notificationId', new.id),
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 5000
    );
  end if;
  return new;
exception when others then
  return new;
end;
$function$;
