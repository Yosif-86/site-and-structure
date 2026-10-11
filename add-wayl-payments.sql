-- Wayl online payments (2026-10-11).
-- The app or website asks /api/wayl-checkout for a payment link; the price
-- and discount are worked out here, on the server, never sent by the phone.
-- When Wayl reports the payment, /api/wayl-webhook asks Wayl itself whether
-- the link is really paid, and only then calls wayl_complete_payment, which
-- turns on the course exactly like an approved manual payment (same
-- enrollments columns, so revenue and teacher earnings keep working).
-- Both functions are for the server (service role) only.
-- Safe to run more than once.

create table if not exists public.wayl_payments (
  id uuid primary key default gen_random_uuid(),
  reference_id text not null unique,
  user_id uuid not null references auth.users(id) on delete cascade,
  course_slug text not null,
  list_price int not null,
  discount_amount int not null default 0,
  amount int not null,
  discount_code_id uuid references public.discount_codes(id) on delete set null,
  env text not null default 'test' check (env in ('test', 'live')),
  status text not null default 'created'
    check (status in ('created', 'complete', 'failed')),
  wayl_link_id text,
  wayl_url text,
  payment_method text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists wayl_payments_user_idx on public.wayl_payments (user_id, course_slug);

alter table public.wayl_payments enable row level security;
drop policy if exists "Users see own wayl payments" on public.wayl_payments;
create policy "Users see own wayl payments" on public.wayl_payments
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
-- Rows are written only by the server functions below.
revoke all on public.wayl_payments from anon, authenticated;
grant select on public.wayl_payments to authenticated;

-- ------------------------------------------------------------
-- Price for one student and one course, with an optional discount code.
-- Checks the same rules as submit_paid_enrollment; the code is only used
-- up when the payment completes.
-- ------------------------------------------------------------
create or replace function public.wayl_prepare_payment(
  p_user uuid, p_course_slug text, p_code text default null)
returns table (course_title text, list_price int, discount_amount int,
               amount int, discount_code_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course record;
  v_price int;
  v_code record;
  v_discount int := 0;
  v_code_id uuid;
begin
  select id, slug, title, price, is_free, status into v_course
    from courses where slug = p_course_slug;
  if v_course is null or v_course.status <> 'published' then
    raise exception 'course_unavailable';
  end if;
  if coalesce(v_course.is_free, false) then
    raise exception 'course_free';
  end if;
  if exists (select 1 from enrollments
             where user_id = p_user and course_slug = p_course_slug
               and status = 'active') then
    raise exception 'already_enrolled';
  end if;
  v_price := coalesce(nullif(regexp_replace(coalesce(v_course.price::text, ''), '\D', '', 'g'), ''), '0')::int;

  if coalesce(trim(p_code), '') <> '' then
    select * into v_code from discount_codes
      where code = upper(trim(p_code)) and course_id = v_course.id;
    if v_code is null or v_code.is_active is not true
       or v_code.expires_at <= now() or v_code.used_count >= v_code.max_uses
       or exists (select 1 from discount_code_redemptions
                  where discount_code_id = v_code.id and user_id = p_user) then
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
$$;

-- ------------------------------------------------------------
-- Called once Wayl has confirmed the payment. Idempotent: a second call
-- for the same reference does nothing.
-- ------------------------------------------------------------
create or replace function public.wayl_complete_payment(
  p_reference text, p_method text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p record;
  v_existing record;
  v_title text;
begin
  select * into v_p from wayl_payments where reference_id = p_reference for update;
  if v_p is null then
    raise exception 'payment_not_found';
  end if;
  if v_p.status = 'complete' then
    return 'already_complete';
  end if;

  update wayl_payments
     set status = 'complete', completed_at = now(),
         payment_method = left(coalesce(p_method, payment_method), 40)
   where id = v_p.id;

  -- The discount code is used up now, not when the link was made.
  if v_p.discount_code_id is not null then
    begin
      insert into discount_code_redemptions (discount_code_id, user_id)
      values (v_p.discount_code_id, v_p.user_id);
      update discount_codes set used_count = used_count + 1
       where id = v_p.discount_code_id;
    exception when unique_violation then
      null;
    end;
  end if;

  select id, status into v_existing from enrollments
   where user_id = v_p.user_id and course_slug = v_p.course_slug
   order by (status = 'active') desc limit 1;

  if v_existing is not null and v_existing.status = 'active' then
    return 'already_enrolled';
  elsif v_existing is not null then
    update enrollments
       set status = 'active', payment_method = 'wayl',
           payment_detail = left(p_reference, 64), payment_proof_path = null,
           list_price = v_p.list_price, discount_amount = v_p.discount_amount,
           amount_paid = v_p.amount, discount_code_id = v_p.discount_code_id,
           approved_at = now()
     where id = v_existing.id;
  else
    insert into enrollments (user_id, course_slug, status, payment_method,
      payment_detail, list_price, discount_amount, amount_paid,
      discount_code_id, approved_at)
    values (v_p.user_id, v_p.course_slug, 'active', 'wayl', left(p_reference, 64),
      v_p.list_price, v_p.discount_amount, v_p.amount, v_p.discount_code_id, now());
    -- The enrollment trigger only announces approvals of pending requests.
    select title into v_title from courses where slug = v_p.course_slug;
    perform notify_user(v_p.user_id, 'payment_approved', 'تم الدفع بنجاح',
      'يمكنك الآن مشاهدة دورة ' || coalesce(v_title, ''),
      jsonb_build_object('course_slug', v_p.course_slug));
  end if;

  select title into v_title from courses where slug = v_p.course_slug;
  perform notify_admins('payment_request', 'دفعة جديدة عبر Wayl',
    coalesce(v_title, '') || ' · ' || v_p.amount || ' IQD',
    jsonb_build_object('course_slug', v_p.course_slug));
  return 'enrolled';
end;
$$;

revoke all on function public.wayl_prepare_payment(uuid, text, text) from public, anon, authenticated;
revoke all on function public.wayl_complete_payment(text, text) from public, anon, authenticated;
grant execute on function public.wayl_prepare_payment(uuid, text, text) to service_role;
grant execute on function public.wayl_complete_payment(text, text) to service_role;

-- Check: every row should say true.
select 'wayl_payments table' as item,
  exists (select 1 from information_schema.tables
          where table_schema = 'public' and table_name = 'wayl_payments') as ok
union all select 'wayl_prepare_payment',
  exists (select 1 from pg_proc where proname = 'wayl_prepare_payment')
union all select 'wayl_complete_payment',
  exists (select 1 from pg_proc where proname = 'wayl_complete_payment')
union all select 'not callable by app users',
  not has_function_privilege('authenticated',
    'public.wayl_complete_payment(text, text)', 'EXECUTE');
