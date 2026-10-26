-- Admin: clear one group of security events (login attempts, or screen
-- capture) without touching the other. The old admin_clear_suspicious() stays.
create or replace function public.admin_clear_security_events(p_kinds text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  delete from public.security_events where kind = any (p_kinds);
end;
$$;

revoke all on function public.admin_clear_security_events(text[]) from public, anon;
grant execute on function public.admin_clear_security_events(text[]) to authenticated;
