-- Per-teacher platform share (default 15%, 0 to 30%), set only by the admin,
-- and the discount cap that follows it (100 minus the platform share).
-- Safe to run more than once.

alter table public.profiles
  add column if not exists platform_rate numeric(5,2) not null default 15;

alter table public.profiles drop constraint if exists profiles_platform_rate_check;
alter table public.profiles
  add constraint profiles_platform_rate_check
  check (platform_rate >= 0 and platform_rate <= 30);

-- Teachers can read their own row but never write this column: profiles
-- updates are limited to the column grants in
-- security-hardening-profiles-column-grants.sql, which do not include it.

create or replace function public.admin_set_platform_rate(p_teacher uuid, p_rate numeric)
returns numeric
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_cap numeric;
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  if p_rate is null or p_rate < 0 or p_rate > 30 then
    raise exception 'rate must be between 0 and 30';
  end if;
  update profiles set platform_rate = p_rate where id = p_teacher;
  if not found then
    raise exception 'teacher not found';
  end if;

  -- Existing codes above the new cap are lowered to it, so no code ever
  -- takes more than the teacher's own share.
  v_cap := 100 - p_rate;
  update discount_codes d
     set discount_value = case
           when d.discount_type = 'percent' then least(d.discount_value, v_cap)
           else least(d.discount_value,
                      floor(public.course_price_number(c.price::text) * v_cap / 100))
         end
    from courses c
   where c.id = d.course_id
     and c.teacher_id = p_teacher
     and ((d.discount_type = 'percent' and d.discount_value > v_cap)
       or (d.discount_type = 'fixed'
           and d.discount_value > public.course_price_number(c.price::text) * v_cap / 100));
  return p_rate;
end;
$$;

revoke all on function public.admin_set_platform_rate(uuid, numeric) from public, anon;
grant execute on function public.admin_set_platform_rate(uuid, numeric) to authenticated;

create or replace function public.enforce_discount_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_price numeric;
  v_rate numeric;
  v_cap numeric;
begin
  select public.course_price_number(c.price::text), coalesce(p.platform_rate, 15)
    into v_price, v_rate
    from courses c
    left join profiles p on p.id = c.teacher_id
   where c.id = new.course_id;
  v_cap := 100 - coalesce(v_rate, 15);
  if new.discount_type = 'percent' and new.discount_value > v_cap then
    raise exception 'discount_too_large';
  end if;
  if new.discount_type = 'fixed' and v_price > 0
     and new.discount_value > v_price * v_cap / 100 then
    raise exception 'discount_too_large';
  end if;
  return new;
end;
$$;

select 'platform_rate' as ok
 where exists (select 1 from information_schema.columns
               where table_name = 'profiles' and column_name = 'platform_rate');
