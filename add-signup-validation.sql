-- Server-side enforcement of the signup rules in signup-rules.js /
-- mobile_app/lib/services/signup_rules.dart. The client checks only exist to
-- show a clear message; these are what a modified client can't skip.
-- Password strength is enforced separately by the Supabase Auth password
-- policy (Authentication settings: min length 8, lower + upper + digits).

-- 1) Email domain allowlist for email/password accounts. Google sign-ins are
--    exempt: Google already verified the address, and workspace domains
--    (companies, universities) are legitimate there.

create or replace function public.is_allowed_signup_email(p_email text)
returns boolean
language sql
immutable
as $$
  select lower(split_part(p_email, '@', 2)) in (
      'gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'live.com',
      'msn.com', 'yahoo.com', 'ymail.com', 'icloud.com', 'me.com', 'mac.com',
      'proton.me', 'protonmail.com', 'aol.com')
    or lower(split_part(p_email, '@', 2)) like '%.edu.iq'
$$;

create or replace function public.enforce_signup_email_domain()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.raw_app_meta_data->>'provider', 'email') <> 'email' then
    return new;
  end if;
  if new.email is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.email is not distinct from old.email then
    return new;
  end if;
  if not public.is_allowed_signup_email(new.email) then
    raise exception 'err_email_domain' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_signup_email_domain() from public, anon, authenticated;
grant execute on function public.enforce_signup_email_domain() to supabase_auth_admin;

-- "update of email" only, so ordinary logins (which touch last_sign_in_at
-- etc.) never run this.
drop trigger if exists trg_enforce_signup_email_domain on auth.users;
create trigger trg_enforce_signup_email_domain
  before insert or update of email on auth.users
  for each row execute function public.enforce_signup_email_domain();

-- 2) Iraqi mobile format on profiles.phone: normalized to 07XXXXXXXXX
--    (075 Korek, 077 Asiacell, 078/079 Zain). Only runs when the phone is
--    set or changed, so existing rows with an older format keep working
--    until someone edits them. Empty/null is left alone (Google sign-ins
--    have no phone).

create or replace function public.normalize_profile_phone()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  d text;
begin
  if new.phone is null or btrim(new.phone) = '' then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.phone is not distinct from old.phone then
    return new;
  end if;
  d := regexp_replace(
         translate(new.phone, '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789'),
         '[^0-9]', '', 'g');
  if d like '00964%' then
    d := '0' || substr(d, 6);
  elsif d like '964%' then
    d := '0' || substr(d, 4);
  end if;
  if length(d) = 10 and d like '7%' then
    d := '0' || d;
  end if;
  if d !~ '^07[5789][0-9]{8}$' then
    raise exception 'err_phone_format' using errcode = 'check_violation';
  end if;
  new.phone := d;
  return new;
end;
$$;

drop trigger if exists trg_normalize_profile_phone on public.profiles;
create trigger trg_normalize_profile_phone
  before insert or update of phone on public.profiles
  for each row execute function public.normalize_profile_phone();
