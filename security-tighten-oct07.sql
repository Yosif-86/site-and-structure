-- Security tightening from the 2026-10-07 check. Safe to run more than once.
-- Nothing the app or website uses is removed.

-- 1. anon and authenticated had TRUNCATE / REFERENCES / TRIGGER on every
--    public table (Supabase default grants). The API cannot call TRUNCATE
--    today, but TRUNCATE ignores row level security, so take it away.
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;
alter default privileges in schema public revoke truncate, references, trigger on tables from anon, authenticated;

-- 2. Fixed search_path on the helper functions the Security Advisor flags
--    ("Function Search Path Mutable"). Only touches functions with no
--    search_path set yet.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('normalize_iq_phone', 'enforce_discount_code_expiry_future',
                         'generate_public_id', 'set_public_id_on_insert',
                         'learning_points_valid', 'is_allowed_signup_email',
                         'course_price_number', 'trg_guard_course_file',
                         'trg_check_course_file_lecture')
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                        where c like 'search_path=%')
  loop
    execute format('alter function %s set search_path = public, extensions', r.sig);
  end loop;
end $$;

-- 3. Teacher / admin payout numbers were readable without signing in.
--    Checkout only runs for signed-in students, so signed-in only.
revoke execute on function public.get_course_payment_info(text) from anon;

-- Check (read-only): both numbers should be 0.
select
  (select count(*) from information_schema.role_table_grants
    where table_schema = 'public' and grantee in ('anon', 'authenticated')
      and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER')) as risky_grants_left,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_course_payment_info'
      and has_function_privilege('anon', p.oid, 'EXECUTE')) as anon_payment_info;
