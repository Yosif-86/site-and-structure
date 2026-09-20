-- The app-level limiter in api/redeem-discount-code.js is in-memory per
-- serverless instance -- a cheap first gate, but not a real guarantee, and
-- it can't stop someone from calling redeem_discount_code() directly via
-- PostgREST with a valid JWT, skipping that endpoint entirely. This adds
-- the actual enforcement inside the function itself: at most 5 redemption
-- attempts per user per rolling 24 hours, no matter how it's called.

create table if not exists public.discount_code_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default now()
);

create index if not exists discount_code_attempts_user_time_idx
  on public.discount_code_attempts (user_id, attempted_at);

alter table public.discount_code_attempts enable row level security;
-- No policies granted to anon/authenticated on purpose -- only the
-- security-definer function below ever reads or writes this table.

create or replace function public.redeem_discount_code(p_code text, p_course_id uuid)
returns table (discount_type text, discount_value numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code_id uuid;
  v_type text;
  v_value numeric;
  v_claimed boolean;
  v_attempts int;
begin
  select count(*) into v_attempts
  from discount_code_attempts
  where user_id = auth.uid() and attempted_at > now() - interval '24 hours';

  if v_attempts >= 5 then
    raise exception 'Too many discount code attempts today. Try again tomorrow.'
      using errcode = 'P0001';
  end if;

  insert into discount_code_attempts (user_id) values (auth.uid());

  select id, discount_codes.discount_type, discount_codes.discount_value
    into v_code_id, v_type, v_value
  from discount_codes
  where code = p_code and course_id = p_course_id;

  if v_code_id is null then
    return; -- no such code for this course
  end if;

  begin
    insert into discount_code_redemptions (discount_code_id, user_id) values (v_code_id, auth.uid());
  exception when unique_violation then
    return; -- this student already used this code
  end;

  update discount_codes
  set used_count = used_count + 1
  where id = v_code_id and is_active = true and expires_at > now() and used_count < max_uses
  returning true into v_claimed;

  if v_claimed is not true then
    delete from discount_code_redemptions where discount_code_id = v_code_id and user_id = auth.uid();
    return; -- inactive, expired, or already at its use cap
  end if;

  return query select v_type, v_value;
end;
$$;

revoke all on function public.redeem_discount_code(text, uuid) from public, anon;
grant execute on function public.redeem_discount_code(text, uuid) to authenticated;
