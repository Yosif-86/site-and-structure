-- Read-only. Run this in the Supabase SQL editor and save the output
-- (e.g. paste it into a new SCHEMA_SNAPSHOT.md) as the first committed
-- record of what RLS actually looks like today. This repo has never had
-- a schema/migrations folder — trusted_devices (device-admin-policy.sql)
-- and now enrollments (enrollments-rls-policy.sql) are the only tables
-- with their policies committed anywhere; everything else (courses,
-- lectures, profiles, login_events, ...) was applied ad hoc in the SQL
-- editor with no reproducible source. This doesn't fix that on its own —
-- it just gives you (and future sessions) a real starting point instead
-- of guessing.

-- 1. Every table: does it have RLS on at all?
select relname as table_name, relrowsecurity as rls_enabled
from pg_class
join pg_namespace on pg_namespace.oid = pg_class.relnamespace
where pg_namespace.nspname = 'public'
  and relkind = 'r'
order by relname;

-- 2. Every policy on every table, in full.
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
order by tablename, cmd;

-- 3. Table-level grants per role (checked BEFORE policies — a missing grant
-- here silently blocks access even with a correct policy).
select table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
order by table_name, grantee;

-- 4. Storage: is the payment-proofs bucket actually private, and what
-- policies gate access to it (storage policies are just RLS policies on
-- storage.objects in current Supabase, not a separate policies table)?
select id, name, public from storage.buckets where id = 'payment-proofs';

select policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'storage' and tablename = 'objects';

-- 5. is_admin() itself — confirm it checks profiles.is_admin and nothing looser.
select prosrc from pg_proc where proname = 'is_admin';
