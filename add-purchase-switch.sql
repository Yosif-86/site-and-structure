-- Review switch (2026-10-07): app_config.purchases_enabled turns all buying
-- in the app on or off instantly (prices, enroll buttons, payment form).
-- Off during Google/Apple review; on after approval. Admins flip it from the
-- admin screen; anyone (even signed out) can read it.

create table if not exists public.app_config (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.app_config enable row level security;

drop policy if exists "Anyone reads app config" on public.app_config;
create policy "Anyone reads app config" on public.app_config
  for select using (true);

drop policy if exists "Admins change app config" on public.app_config;
create policy "Admins change app config" on public.app_config
  for update using (public.is_admin()) with check (public.is_admin());

grant select on public.app_config to anon, authenticated;
grant update on public.app_config to authenticated;

-- Starts OFF: the app is about to go to review.
insert into public.app_config (key, value)
values ('purchases_enabled', 'false'::jsonb)
on conflict (key) do nothing;

-- Check: one row, purchases_enabled = false.
select key, value from public.app_config;
