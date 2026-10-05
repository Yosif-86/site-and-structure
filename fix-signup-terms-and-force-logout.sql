-- ============================================================
-- 1. Terms acceptance is saved through a function. Users aren't allowed to
--    write profiles.terms_accepted_at / terms_version themselves (they can
--    only write a short list of columns), which is what made registration
--    fail when the app tried to.
-- 2. admin_force_logout: profiles.active_session_token is a uuid, the
--    function was writing text ("column active_session_token is of type
--    uuid but expression is of type text").
-- Safe to run more than once.
-- ============================================================

create or replace function public.record_terms_acceptance(p_version text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return;
  end if;
  update profiles
     set terms_accepted_at = now(),
         terms_version = left(coalesce(p_version, ''), 40)
   where id = auth.uid();
end;
$$;

revoke all on function public.record_terms_acceptance(text) from public, anon;
grant execute on function public.record_terms_acceptance(text) to authenticated;

create or replace function public.admin_force_logout(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized.';
  end if;
  update profiles set active_session_token = gen_random_uuid()
    where id = p_user_id;
end;
$$;

revoke all on function public.admin_force_logout(uuid) from public, anon;
grant execute on function public.admin_force_logout(uuid) to authenticated;

-- Check: both rows should say true.
select 'record_terms_acceptance' as item,
  exists (select 1 from pg_proc where proname = 'record_terms_acceptance') as ok
union all select 'admin_force_logout',
  exists (select 1 from pg_proc where proname = 'admin_force_logout');
