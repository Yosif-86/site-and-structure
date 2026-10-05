-- Admin tools (2026-10-05):
--  1. Admins can delete any course (lectures, files and discount codes
--     cascade with it).
--  2. admin_clear_suspicious(): empties the suspicious activity list
--     (deletes security events, un-flags suspicious logins).

drop policy if exists "Admins can delete courses" on public.courses;
create policy "Admins can delete courses"
  on public.courses for delete
  using (public.is_admin());

create or replace function public.admin_clear_suspicious()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  delete from public.security_events where true;
  update public.login_events set flagged = false where flagged;
end;
$$;

revoke all on function public.admin_clear_suspicious() from public, anon;
grant execute on function public.admin_clear_suspicious() to authenticated;

-- Check: both rows should say true.
select 'courses admin delete policy' as item,
  exists (select 1 from pg_policies
          where tablename = 'courses' and policyname = 'Admins can delete courses') as ok
union all select 'admin_clear_suspicious',
  exists (select 1 from pg_proc where proname = 'admin_clear_suspicious');
