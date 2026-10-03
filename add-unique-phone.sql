-- One account per phone number (email is already unique in Supabase Auth).
-- Numbers are compared in one normalized form (964XXXXXXXXXX) so 0782...,
-- +964782... and 964782... all count as the same number.
-- Safe to run more than once.

create or replace function public.normalize_iq_phone(p text)
returns text
language sql
immutable
as $$
  select case
           when d = '' then null
           when d like '00%' then substr(d, 3)
           when d like '0%' then '964' || substr(d, 2)
           when d like '964%' then d
           else '964' || d
         end
    from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) s;
$$;

-- Existing duplicates: the admin (else the oldest account) keeps the number;
-- the others are cleared and will be asked for their own number.
with ranked as (
  select p.id,
         row_number() over (
           partition by public.normalize_iq_phone(p.phone)
           order by p.is_admin desc, u.created_at asc) as rn
    from public.profiles p
    join auth.users u on u.id = p.id
   where public.normalize_iq_phone(p.phone) is not null
)
update public.profiles
   set phone = null, phone_verified = false
 where id in (select id from ranked where rn > 1);

create unique index if not exists profiles_phone_unique
  on public.profiles (public.normalize_iq_phone(phone))
  where public.normalize_iq_phone(phone) is not null;

-- Sign-up / complete-profile check before an account is created or a code
-- is sent (true = nobody else has it).
create or replace function public.is_phone_available(p_phone text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1 from profiles
     where normalize_iq_phone(phone) = normalize_iq_phone(p_phone)
       and id is distinct from auth.uid());
$$;

revoke all on function public.is_phone_available(text) from public;
grant execute on function public.is_phone_available(text) to anon, authenticated;

-- Server-side check for the OTP endpoints (service role only).
create or replace function public.phone_taken_by_other(p_phone text, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles
     where normalize_iq_phone(phone) = normalize_iq_phone(p_phone)
       and id <> p_user);
$$;

revoke all on function public.phone_taken_by_other(text, uuid) from public, anon, authenticated;

-- Check: 3 rows, and no duplicates left.
select 'unique index' as ok
 where exists (select 1 from pg_indexes where indexname = 'profiles_phone_unique')
union all select 'is_phone_available'
 where exists (select 1 from pg_proc where proname = 'is_phone_available')
union all select 'no duplicates'
 where not exists (
   select 1 from profiles where normalize_iq_phone(phone) is not null
    group by normalize_iq_phone(phone) having count(*) > 1);
