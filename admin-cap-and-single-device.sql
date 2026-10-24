-- 1) At most 2 admins. Any change that would make a third is rejected.
create or replace function public.enforce_admin_cap()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.is_admin is true
     and (tg_op = 'INSERT' or old.is_admin is distinct from true) then
    if (select count(*) from profiles
        where is_admin = true and id <> new.id) >= 2 then
      raise exception 'Admin limit reached (max 2)';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_admin_cap on public.profiles;
create trigger profiles_admin_cap
  before insert or update of is_admin on public.profiles
  for each row execute function public.enforce_admin_cap();

-- 2) One device per account; admins get 2. The store-review account stays as is.
update profiles
set max_devices = case when is_admin then 2 else 1 end
where coalesce(is_reviewer, false) = false
  and max_devices <> case when is_admin then 2 else 1 end;

-- Keep each account's most recently used devices, up to its limit.
delete from trusted_devices
where id in (
  select r.id from (
    select t.id, p.max_devices,
           row_number() over (partition by t.user_id
                              order by t.last_seen desc nulls last) rn
    from trusted_devices t
    join profiles p on p.id = t.user_id
    where coalesce(p.is_reviewer, false) = false
  ) r
  where r.rn > r.max_devices
);
