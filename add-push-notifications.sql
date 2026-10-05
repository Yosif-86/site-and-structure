-- ============================================================
-- Phone push notifications (Firebase Cloud Messaging).
-- Every row added to `notifications` (the in-app bell) is also sent to the
-- user's phones: a trigger calls api/push.js through pg_net, which looks the
-- row up itself and sends it with the Firebase service account.
-- Safe to run more than once.
-- ============================================================

create extension if not exists pg_net with schema extensions;

-- One row per phone (a user can have up to their device limit).
create table if not exists public.push_tokens (
  token text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null default 'android',
  updated_at timestamptz not null default now()
);

create index if not exists push_tokens_user_idx on public.push_tokens (user_id);

alter table public.push_tokens enable row level security;

drop policy if exists "Users manage own push tokens" on public.push_tokens;
create policy "Users manage own push tokens" on public.push_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- A phone that signs into another account moves its token to that account.
create or replace function public.register_push_token(p_token text, p_platform text default 'android')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or coalesce(p_token, '') = '' then
    return;
  end if;
  insert into push_tokens (token, user_id, platform, updated_at)
  values (p_token, auth.uid(), coalesce(p_platform, 'android'), now())
  on conflict (token) do update
    set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
end;
$$;

revoke all on function public.register_push_token(text, text) from public, anon;
grant execute on function public.register_push_token(text, text) to authenticated;

-- Each notification is pushed once (api/push.js sets this).
alter table public.notifications add column if not exists pushed_at timestamptz;

create or replace function public.trg_push_notification()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  -- Only users with a registered phone; the API checks everything else.
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
  -- A push problem must never block the notification itself.
  return new;
end;
$$;

drop trigger if exists trg_push_notification on public.notifications;
create trigger trg_push_notification
  after insert on public.notifications
  for each row execute function public.trg_push_notification();

-- Check: each row should say true.
select 'push_tokens' as item,
  exists (select 1 from information_schema.tables where table_name = 'push_tokens') as ok
union all select 'pg_net',
  exists (select 1 from pg_extension where extname = 'pg_net')
union all select 'push trigger',
  exists (select 1 from pg_trigger where tgname = 'trg_push_notification');
