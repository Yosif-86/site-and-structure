-- Adds phone-OTP verification (via OTPIQ) as a required step after signup.
--
-- profiles.phone_verified defaults to false so every NEW signup must verify
-- before the app treats the account as usable. The immediate backfill below
-- marks every EXISTING row true so current users are grandfathered in and
-- are never suddenly locked out by this migration.
--
-- phone_otp_codes holds the short-lived code for whichever phone number is
-- currently being verified. Only the two Vercel API routes touch it (via the
-- service-role key, which bypasses RLS) -- RLS is enabled with no policies
-- so it is completely unreachable from the client, same as
-- active_session_token on profiles.

alter table public.profiles
  add column if not exists phone_verified boolean not null default false;

update public.profiles set phone_verified = true where phone_verified = false;

create table if not exists public.phone_otp_codes (
  user_id uuid primary key references auth.users(id) on delete cascade,
  phone text not null,
  code_hash text not null,
  attempts int not null default 0,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

alter table public.phone_otp_codes enable row level security;

-- Confirm: phone_verified should be true for every existing row, and
-- phone_otp_codes should show zero grants for anon/authenticated.
select count(*) filter (where phone_verified = false) as unverified_existing_rows from public.profiles;
select grantee, privilege_type from information_schema.table_privileges
where table_schema = 'public' and table_name = 'phone_otp_codes';
