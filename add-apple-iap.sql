-- ============================================================
-- Apple In-App Purchase for courses (iPhone).
-- Apple requires paid courses that open in the iPhone app to be buyable
-- there with In-App Purchase (guideline 3.1.1 / 3.1.3(b)). The app sells
-- one consumable "price level" product per course price (see
-- api/wayl-checkout.js, provider "apple"); the server checks Apple's
-- signed transaction and then this function turns the course on, the
-- same way wayl_complete_payment does for website payments.
-- Safe to run more than once.
-- ============================================================

create table if not exists public.apple_iap_transactions (
  id uuid primary key default gen_random_uuid(),
  transaction_id text not null unique,
  original_transaction_id text,
  user_id uuid not null references auth.users(id) on delete cascade,
  course_slug text not null,
  product_id text not null,
  environment text not null check (environment in ('Sandbox', 'Production', 'Xcode', 'LocalTesting')),
  storefront text,
  price_milli bigint,
  currency text,
  list_price int,
  purchased_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists apple_iap_user_idx on public.apple_iap_transactions (user_id, course_slug);

alter table public.apple_iap_transactions enable row level security;
drop policy if exists "Users see own apple purchases" on public.apple_iap_transactions;
create policy "Users see own apple purchases" on public.apple_iap_transactions
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
revoke all on public.apple_iap_transactions from anon, authenticated;
grant select on public.apple_iap_transactions to authenticated;

-- Course facts the server needs to pick the right Apple product: the
-- list price in IQD. Raises like wayl_prepare_payment.
create or replace function public.apple_prepare_purchase(p_user uuid, p_course_slug text)
returns table (course_title text, list_price int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course record;
begin
  select c.slug, c.title, c.price, c.is_free, c.status into v_course
    from courses c where c.slug = p_course_slug;
  if v_course is null or v_course.status <> 'published' then
    raise exception 'course_unavailable';
  end if;
  if coalesce(v_course.is_free, false) then
    raise exception 'course_free';
  end if;
  return query select v_course.title::text,
    coalesce(nullif(regexp_replace(coalesce(v_course.price::text, ''), '\D', '', 'g'), ''), '0')::int;
end;
$$;

-- Records one verified Apple transaction and turns the course on.
-- A transaction id is used once: a second call returns 'already_recorded'.
create or replace function public.apple_complete_purchase(
  p_user uuid, p_course_slug text, p_transaction_id text,
  p_original_transaction_id text, p_product_id text, p_environment text,
  p_storefront text, p_price_milli bigint, p_currency text,
  p_purchased_at timestamptz)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_list int;
  v_existing record;
  v_title text;
begin
  select coalesce(nullif(regexp_replace(coalesce(c.price::text, ''), '\D', '', 'g'), ''), '0')::int, c.title
    into v_list, v_title
    from courses c where c.slug = p_course_slug;
  if v_title is null and v_list is null then
    raise exception 'course_unavailable';
  end if;

  begin
    insert into apple_iap_transactions (transaction_id, original_transaction_id,
      user_id, course_slug, product_id, environment, storefront, price_milli,
      currency, list_price, purchased_at)
    values (p_transaction_id, p_original_transaction_id, p_user, p_course_slug,
      p_product_id, p_environment, left(p_storefront, 8), p_price_milli,
      left(p_currency, 8), v_list, p_purchased_at);
  exception when unique_violation then
    return 'already_recorded';
  end;

  select id, status into v_existing from enrollments
   where user_id = p_user and course_slug = p_course_slug
   order by (status = 'active') desc limit 1;

  if v_existing is not null and v_existing.status = 'active' then
    return 'already_enrolled';
  elsif v_existing is not null then
    update enrollments
       set status = 'active', payment_method = 'apple',
           payment_detail = left(p_transaction_id, 64), payment_proof_path = null,
           list_price = v_list, discount_amount = 0, amount_paid = v_list,
           discount_code_id = null, approved_at = now()
     where id = v_existing.id;
  else
    insert into enrollments (user_id, course_slug, status, payment_method,
      payment_detail, list_price, discount_amount, amount_paid, approved_at)
    values (p_user, p_course_slug, 'active', 'apple', left(p_transaction_id, 64),
      v_list, 0, v_list, now());
  end if;

  perform notify_user(p_user, 'payment_approved', 'تم الشراء بنجاح',
    'يمكنك الآن مشاهدة دورة ' || coalesce(v_title, ''),
    jsonb_build_object('course_slug', p_course_slug));
  perform notify_admins('payment_request', 'شراء جديد عبر Apple',
    coalesce(v_title, '') || ' · ' || coalesce(p_environment, ''),
    jsonb_build_object('course_slug', p_course_slug));
  return 'enrolled';
end;
$$;

revoke all on function public.apple_prepare_purchase(uuid, text) from public, anon, authenticated;
revoke all on function public.apple_complete_purchase(uuid, text, text, text, text, text, text, bigint, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apple_prepare_purchase(uuid, text) to service_role;
grant execute on function public.apple_complete_purchase(uuid, text, text, text, text, text, text, bigint, text, timestamptz) to service_role;

select 'apple_iap_transactions table' as item,
  exists (select 1 from information_schema.tables
          where table_schema = 'public' and table_name = 'apple_iap_transactions') as ok
union all select 'apple_prepare_purchase',
  exists (select 1 from pg_proc where proname = 'apple_prepare_purchase')
union all select 'apple_complete_purchase',
  exists (select 1 from pg_proc where proname = 'apple_complete_purchase')
union all select 'not callable by app users',
  not has_function_privilege('authenticated',
    'public.apple_complete_purchase(uuid, text, text, text, text, text, text, bigint, text, timestamptz)', 'EXECUTE');
