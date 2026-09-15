-- Replaces the single method+detail pair teachers used to fill in for their
-- own payout with three explicit fields: a ZainCash phone number, a Qi Card
-- account number, and an uploaded QR code image. A teacher must have at
-- least one of (ZainCash phone) or (Qi account number / Qi QR) filled in
-- before admin can flip their "manage own payments" switch on -- enforced
-- inside set_teacher_payment_enabled itself, not just the UI.
--
-- The old teacher_payment_method/teacher_payment_detail columns are left
-- alone and keep working exactly as before for the ADMIN's own payout
-- number (admin.html "My payment number") -- unrelated to this change.

alter table profiles add column if not exists teacher_zaincash_phone text;
alter table profiles add column if not exists teacher_qi_account_number text;
alter table profiles add column if not exists teacher_qi_qr_url text;

-- ============================================================
-- Public bucket for the QR code image, same shape as course-thumbnails:
-- publicly readable (shown to students at checkout), writable only by the
-- owning teacher's own folder.
-- ============================================================
insert into storage.buckets (id, name, public)
values ('payment-qr', 'payment-qr', true)
on conflict (id) do nothing;

drop policy if exists "Anyone can view payment QR codes" on storage.objects;
create policy "Anyone can view payment QR codes"
  on storage.objects for select
  using (bucket_id = 'payment-qr');

drop policy if exists "Teachers can upload own payment QR" on storage.objects;
create policy "Teachers can upload own payment QR"
  on storage.objects for insert
  with check (
    bucket_id = 'payment-qr'
    and (storage.foldername(name))[1] = auth.uid()::text
    and lower(storage.extension(name)) in ('png', 'jpg', 'jpeg', 'webp')
  );

drop policy if exists "Teachers can replace own payment QR" on storage.objects;
create policy "Teachers can replace own payment QR"
  on storage.objects for update
  using (bucket_id = 'payment-qr' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'payment-qr' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Teachers can delete own payment QR" on storage.objects;
create policy "Teachers can delete own payment QR"
  on storage.objects for delete
  using (bucket_id = 'payment-qr' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Admins manage all payment QR" on storage.objects;
create policy "Admins manage all payment QR"
  on storage.objects for all
  using (bucket_id = 'payment-qr' and public.is_admin())
  with check (bucket_id = 'payment-qr' and public.is_admin());

-- ============================================================
-- Admin can only unlock a teacher once they've actually filled in payment
-- info -- ZainCash phone, or a Qi account number/QR (or both).
-- ============================================================
create or replace function public.set_teacher_payment_enabled(p_teacher_id uuid, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_zaincash boolean;
  v_has_qi boolean;
begin
  if not public.is_admin() then
    raise exception 'Only admins can change this.';
  end if;

  if p_enabled then
    select
      coalesce(trim(teacher_zaincash_phone), '') <> '',
      coalesce(trim(teacher_qi_account_number), '') <> '' or coalesce(trim(teacher_qi_qr_url), '') <> ''
    into v_has_zaincash, v_has_qi
    from profiles where id = p_teacher_id;

    if not (coalesce(v_has_zaincash, false) or coalesce(v_has_qi, false)) then
      raise exception 'This teacher has not added payment info yet (ZainCash number, or a Qi account number/QR code).';
    end if;
  end if;

  update profiles set teacher_payment_enabled = p_enabled where id = p_teacher_id and is_teacher = true;
  if not p_enabled then
    update courses set pay_to_teacher = false where teacher_id = p_teacher_id;
  end if;
end;
$$;

revoke all on function public.set_teacher_payment_enabled(uuid, boolean) from public, anon;
grant execute on function public.set_teacher_payment_enabled(uuid, boolean) to authenticated;

-- ============================================================
-- Checkout screen now reads the three new fields instead of the old single
-- method/detail pair. Return type changed, so the old function must be
-- dropped first (Postgres refuses create-or-replace across a signature
-- change). The admin fallback path (pay_to_teacher = false) still reads the
-- OLD teacher_payment_method/teacher_payment_detail columns off the admin's
-- own row, mapped into the same three-field shape so course.html only has
-- to understand one response format.
-- ============================================================
drop function if exists public.get_course_payment_info(text);

create function public.get_course_payment_info(p_course_slug text)
returns table(zaincash_phone text, qi_account_number text, qi_qr_url text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course record;
begin
  select id, teacher_id, pay_to_teacher, status, is_free
    into v_course
    from courses
    where slug = p_course_slug;

  if v_course is null or v_course.status <> 'published' or v_course.is_free then
    return;
  end if;

  if v_course.pay_to_teacher and v_course.teacher_id is not null then
    return query
      select p.teacher_zaincash_phone, p.teacher_qi_account_number, p.teacher_qi_qr_url
      from profiles p
      where p.id = v_course.teacher_id;
  else
    return query
      select
        case when p.teacher_payment_method = 'zain' then p.teacher_payment_detail else null end,
        case when p.teacher_payment_method = 'qi' then p.teacher_payment_detail else null end,
        null::text
      from profiles p
      where p.is_admin = true
      order by p.created_at asc
      limit 1;
  end if;
end;
$$;

revoke all on function public.get_course_payment_info(text) from public, anon;
grant execute on function public.get_course_payment_info(text) to anon, authenticated;
