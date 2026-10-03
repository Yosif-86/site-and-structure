-- Automatic multi-quality conversion: after the admin approves an uploaded
-- lecture (live as one 1080p MP4), a GitHub Actions job converts it to
-- 480p/720p/1080p HLS and calls finish_lecture_conversion() to switch the
-- lecture over. Safe to run more than once.

-- Server-side secrets nobody can read through the API (RLS on, no policies).
create table if not exists public.app_secrets (
  name text primary key,
  value_sha256 text not null
);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

-- Only the SHA-256 of the conversion key is stored, never the key itself.
insert into public.app_secrets (name, value_sha256)
values ('convert_key', 'a768289c38f40c9522ddf0f706b5412c54556364a496acd77e774f1318d267b9')
on conflict (name) do update set value_sha256 = excluded.value_sha256;

-- The "only an admin can make a lecture live" rule (add-r2-lecture-uploads
-- .sql), with one exception: finish_lecture_conversion() below, which flags
-- its own transaction. set_config is not reachable through the API.
create or replace function public.enforce_lecture_publish_admin_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_admin() or current_setting('app.lecture_conversion', true) = 'on' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.r2_path := null;
  else
    new.r2_path := old.r2_path;
  end if;
  return new;
end;
$$;

-- Called by the conversion job (with the anon key + the conversion key).
-- Switches the lecture from its MP4 to the HLS folder, only if it is still
-- the approved MP4 (never touches pending or already-converted lectures).
create or replace function public.finish_lecture_conversion(
  p_lecture_id uuid, p_key text, p_duration integer default null)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ok boolean;
  v_count integer;
begin
  select exists (
    select 1 from app_secrets
     where name = 'convert_key'
       and value_sha256 = encode(extensions.digest(coalesce(p_key, ''), 'sha256'), 'hex')
  ) into v_ok;
  if not v_ok then
    raise exception 'Not authorized.';
  end if;
  perform set_config('app.lecture_conversion', 'on', true);
  update lectures
     set r2_path = 'videos/' || p_lecture_id::text,
         duration_seconds = coalesce(nullif(p_duration, 0), duration_seconds)
   where id = p_lecture_id
     and r2_path = 'videos/' || p_lecture_id::text || '/source.mp4';
  get diagnostics v_count = row_count;
  return v_count = 1;
end;
$$;

revoke all on function public.finish_lecture_conversion(uuid, text, integer) from public;
grant execute on function public.finish_lecture_conversion(uuid, text, integer) to anon, authenticated;

-- Check: 2 rows.
select 'convert key stored' as ok where exists (select 1 from public.app_secrets where name = 'convert_key')
union all select 'finish_lecture_conversion' where exists (select 1 from pg_proc where proname = 'finish_lecture_conversion');
