-- Admin only: how an account signs in (email, google, apple), from the auth
-- identities. Comma separated when an account has more than one.
create or replace function public.admin_user_sign_in_method(p_user uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v text;
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  select string_agg(provider, ',' order by created_at) into v
    from auth.identities where user_id = p_user;
  return v;
end;
$$;

revoke all on function public.admin_user_sign_in_method(uuid) from public, anon;
grant execute on function public.admin_user_sign_in_method(uuid) to authenticated;
