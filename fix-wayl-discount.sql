-- ============================================================
-- Fix: Wayl checkout failed whenever a discount code was used.
-- wayl_prepare_payment returns a column named discount_code_id, and the
-- code check also read discount_code_redemptions.discount_code_id without a
-- table name, so Postgres stopped with "column reference is ambiguous".
-- Same function, with the table columns named through an alias.
-- Safe to run more than once.
-- ============================================================

create or replace function public.wayl_prepare_payment(
  p_user uuid,
  p_course_slug text,
  p_code text default null
)
returns table(course_title text, list_price integer, discount_amount integer, amount integer, discount_code_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_course record;
  v_price int;
  v_code record;
  v_discount int := 0;
  v_code_id uuid;
begin
  select c.id, c.slug, c.title, c.price, c.is_free, c.status into v_course
    from courses c where c.slug = p_course_slug;
  if v_course is null or v_course.status <> 'published' then
    raise exception 'course_unavailable';
  end if;
  if coalesce(v_course.is_free, false) then
    raise exception 'course_free';
  end if;
  if exists (select 1 from enrollments e
             where e.user_id = p_user and e.course_slug = p_course_slug
               and e.status = 'active') then
    raise exception 'already_enrolled';
  end if;
  v_price := coalesce(nullif(regexp_replace(coalesce(v_course.price::text, ''), '\D', '', 'g'), ''), '0')::int;

  if coalesce(trim(p_code), '') <> '' then
    select d.* into v_code from discount_codes d
      where d.code = upper(trim(p_code)) and d.course_id = v_course.id;
    if v_code is null or v_code.is_active is not true
       or v_code.expires_at <= now() or v_code.used_count >= v_code.max_uses
       or exists (select 1 from discount_code_redemptions r
                  where r.discount_code_id = v_code.id and r.user_id = p_user) then
      raise exception 'code_invalid';
    end if;
    v_code_id := v_code.id;
    v_discount := least(v_price, case when v_code.discount_type = 'percent'
      then round(v_price * v_code.discount_value / 100.0)
      else round(v_code.discount_value) end)::int;
  end if;

  return query select v_course.title::text, v_price, v_discount,
    v_price - v_discount, v_code_id;
end;
$function$;

-- Same access as before: only the server (service role) may call it.
revoke all on function public.wayl_prepare_payment(uuid, text, text) from public, anon, authenticated;

-- Check: should print the course with list_price 10000, discount 2000, amount 8000
-- for a student who has not bought it (replace the user id to test):
-- select * from wayl_prepare_payment('00000000-0000-0000-0000-000000000000'::uuid, 'payment-test-aefede', 'TEST20');
