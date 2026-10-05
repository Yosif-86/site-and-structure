-- ============================================================
-- Oct 5 batch: payments record what was actually paid, discount codes are
-- only used on a real payment request, security events (blocked devices,
-- shared devices, screenshots) with notifications, terms acceptance,
-- teachers can't delete published courses, admin helpers.
-- Safe to run more than once.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Enrollments store the price, the code used and the amount paid.
-- ------------------------------------------------------------
alter table public.enrollments
  add column if not exists list_price integer,
  add column if not exists amount_paid integer,
  add column if not exists discount_amount integer,
  add column if not exists discount_code_id uuid
    references public.discount_codes(id) on delete set null;

-- Backfill existing rows from the course price and the student's latest
-- redemption on that course (best available guess for old data).
update public.enrollments e
set list_price = coalesce(nullif(regexp_replace(coalesce(c.price::text, ''), '\D', '', 'g'), ''), '0')::int
from public.courses c
where c.slug = e.course_slug and e.list_price is null;

update public.enrollments e
set discount_code_id = r.code_id,
    discount_amount = least(e.list_price, case when r.discount_type = 'percent'
      then round(e.list_price * r.discount_value / 100.0)
      else round(r.discount_value) end)::int
from public.courses c,
lateral (
  select d.id as code_id, d.discount_type, d.discount_value
  from public.discount_code_redemptions x
  join public.discount_codes d on d.id = x.discount_code_id
  where x.user_id = e.user_id and d.course_id = c.id
  order by x.redeemed_at desc
  limit 1
) r
where c.slug = e.course_slug and e.amount_paid is null and e.discount_code_id is null;

update public.enrollments
set amount_paid = greatest(0, coalesce(list_price, 0) - coalesce(discount_amount, 0))
where amount_paid is null;

-- ------------------------------------------------------------
-- 2. Checking a code no longer uses it up. Same 5-per-day attempt cap.
-- ------------------------------------------------------------
create or replace function public.preview_discount_code(p_code text, p_course_id uuid)
returns table (discount_type text, discount_value numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
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

  return query
  select d.discount_type, d.discount_value
  from discount_codes d
  where d.code = upper(trim(p_code))
    and d.course_id = p_course_id
    and d.is_active = true
    and d.expires_at > now()
    and d.used_count < d.max_uses
    and not exists (
      select 1 from discount_code_redemptions x
      where x.discount_code_id = d.id and x.user_id = auth.uid());
end;
$$;

revoke all on function public.preview_discount_code(text, uuid) from public, anon;
grant execute on function public.preview_discount_code(text, uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. One call creates the payment request: uses the code (if any) and
--    records price, discount and amount paid together.
-- ------------------------------------------------------------
create or replace function public.submit_paid_enrollment(
  p_course_slug text,
  p_method text,
  p_detail text,
  p_proof_path text,
  p_code text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_course record;
  v_price int;
  v_code record;
  v_discount int := 0;
  v_code_id uuid;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'Not signed in.';
  end if;
  if p_method not in ('zain', 'qi') then
    raise exception 'Invalid payment method.';
  end if;
  if coalesce(trim(p_detail), '') = '' or length(p_detail) > 64 then
    raise exception 'Invalid payment detail.';
  end if;
  if p_proof_path is null or p_proof_path not like v_uid::text || '/%' then
    raise exception 'Invalid proof.';
  end if;

  select id, slug, price, is_free, status into v_course
  from courses where slug = p_course_slug;
  if v_course is null or v_course.status <> 'published' then
    raise exception 'Course not available.';
  end if;
  if coalesce(v_course.is_free, false) then
    raise exception 'Course is free.';
  end if;
  v_price := coalesce(nullif(regexp_replace(coalesce(v_course.price::text, ''), '\D', '', 'g'), ''), '0')::int;

  if exists (select 1 from enrollments
             where user_id = v_uid and course_slug = p_course_slug) then
    raise exception 'already_requested' using errcode = '23505';
  end if;

  if coalesce(trim(p_code), '') <> '' then
    select * into v_code from discount_codes
    where code = upper(trim(p_code)) and course_id = v_course.id
    for update;
    if v_code is null or v_code.is_active is not true
       or v_code.expires_at <= now() or v_code.used_count >= v_code.max_uses then
      raise exception 'code_invalid' using errcode = 'P0002';
    end if;
    begin
      insert into discount_code_redemptions (discount_code_id, user_id)
      values (v_code.id, v_uid);
    exception when unique_violation then
      raise exception 'code_invalid' using errcode = 'P0002';
    end;
    update discount_codes set used_count = used_count + 1 where id = v_code.id;
    v_code_id := v_code.id;
    v_discount := least(v_price, case when v_code.discount_type = 'percent'
      then round(v_price * v_code.discount_value / 100.0)
      else round(v_code.discount_value) end)::int;
  end if;

  insert into enrollments (user_id, course_slug, status, payment_method,
    payment_detail, payment_proof_path, list_price, discount_amount,
    amount_paid, discount_code_id)
  values (v_uid, p_course_slug, 'pending', p_method, trim(p_detail),
    p_proof_path, v_price, v_discount, v_price - v_discount, v_code_id)
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.submit_paid_enrollment(text, text, text, text, text) from public, anon;
grant execute on function public.submit_paid_enrollment(text, text, text, text, text) to authenticated;

-- ------------------------------------------------------------
-- 4. A rejected request gives the discount code back, so the student can
--    pay again with it.
-- ------------------------------------------------------------
create or replace function public.reject_enrollment(p_enrollment_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_e record;
  v_teacher_paid boolean;
begin
  select e.id, e.user_id, e.course_slug, e.status, e.discount_code_id,
         c.teacher_id, c.pay_to_teacher
    into v_e
    from enrollments e
    join courses c on c.slug = e.course_slug
    where e.id = p_enrollment_id;

  if v_e is null then
    raise exception 'Request not found.';
  end if;
  if v_e.status = 'active' then
    raise exception 'Already approved.';
  end if;

  v_teacher_paid := coalesce(v_e.pay_to_teacher, false) and v_e.teacher_id is not null;
  if v_teacher_paid and v_e.teacher_id <> auth.uid() then
    raise exception 'Not authorized.';
  end if;
  if not v_teacher_paid and not public.is_admin() then
    raise exception 'Not authorized.';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'A reason is required.';
  end if;

  insert into enrollment_rejections (user_id, course_slug, reason, rejected_by)
  values (v_e.user_id, v_e.course_slug, left(trim(p_reason), 300), auth.uid());

  if v_e.discount_code_id is not null then
    delete from discount_code_redemptions
      where discount_code_id = v_e.discount_code_id and user_id = v_e.user_id;
    update discount_codes set used_count = greatest(used_count - 1, 0)
      where id = v_e.discount_code_id;
  end if;

  delete from enrollments where id = p_enrollment_id;
end;
$$;

revoke all on function public.reject_enrollment(uuid, text) from public, anon;
grant execute on function public.reject_enrollment(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 5. Teacher list now includes what each student actually paid.
-- ------------------------------------------------------------
drop function if exists public.get_teacher_students();
create function public.get_teacher_students()
returns table(
  enrollment_id uuid,
  course_title text,
  course_slug text,
  course_price text,
  pay_to_teacher boolean,
  email text,
  full_name text,
  phone text,
  status text,
  payment_method text,
  payment_detail text,
  payment_proof_path text,
  created_at timestamptz,
  list_price integer,
  amount_paid integer,
  discount_amount integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select
    e.id, c.title, c.slug, c.price::text, c.pay_to_teacher,
    (select le.email from login_events le where le.user_id = e.user_id
      order by le.created_at desc limit 1),
    p.full_name, p.phone, e.status, e.payment_method, e.payment_detail,
    e.payment_proof_path, e.created_at, e.list_price, e.amount_paid,
    e.discount_amount
  from enrollments e
  join courses c on c.slug = e.course_slug
  join profiles p on p.id = e.user_id
  where c.teacher_id = auth.uid()
  order by e.created_at desc;
end;
$$;

revoke all on function public.get_teacher_students() from public, anon;
grant execute on function public.get_teacher_students() to authenticated;

-- ------------------------------------------------------------
-- 6. Teachers can't delete a published course (students paid for it).
-- ------------------------------------------------------------
drop policy if exists "Teachers can delete own courses" on courses;
create policy "Teachers can delete own courses"
  on courses for delete
  using (teacher_id = auth.uid() and status <> 'published');

-- ------------------------------------------------------------
-- 7. Admin: latest email per user (the old query hit the 1000-row cap).
-- ------------------------------------------------------------
create or replace function public.admin_user_emails()
returns table(user_id uuid, email text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized.';
  end if;
  return query
  select u.id, u.email::text from auth.users u;
end;
$$;

revoke all on function public.admin_user_emails() from public, anon;
grant execute on function public.admin_user_emails() to authenticated;

-- ------------------------------------------------------------
-- 8. Security events: blocked device attempts, one device on several
--    accounts, screenshot / screen-recording attempts. Admins are notified;
--    a blocked device attempt also tells the account owner.
-- ------------------------------------------------------------
create table if not exists public.security_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  kind text not null check (kind in
    ('device_blocked', 'shared_device', 'screenshot', 'screen_record')),
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists security_events_created_idx
  on public.security_events (created_at desc);

alter table public.security_events enable row level security;

drop policy if exists "Admins read security events" on public.security_events;
create policy "Admins read security events"
  on public.security_events for select using (public.is_admin());

drop policy if exists "Admins delete security events" on public.security_events;
create policy "Admins delete security events"
  on public.security_events for delete using (public.is_admin());

-- The app reports its own screenshot / recording attempts.
drop policy if exists "Users report own capture attempts" on public.security_events;
create policy "Users report own capture attempts"
  on public.security_events for insert
  with check (user_id = auth.uid() and kind in ('screenshot', 'screen_record'));

create or replace function public.trg_notify_security_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_label text := coalesce(new.detail->>'device_label', '');
begin
  select coalesce(nullif(full_name, ''), '—') into v_name
    from profiles where id = new.user_id;
  v_name := coalesce(v_name, '—');

  if new.kind = 'device_blocked' then
    perform notify_admins('security',
      'حاول جهاز آخر فتح حساب ' || v_name,
      trim(v_label || ' · تم منعه لأن الحساب وصل لحد الأجهزة'),
      jsonb_build_object('user_id', new.user_id, 'event_id', new.id));
    perform notify_user(new.user_id, 'security',
      'محاولة دخول من جهاز آخر',
      'حاول جهاز آخر فتح حسابك وتم منعه. إذا لم تكن أنت، غيّر كلمة المرور.',
      jsonb_build_object('event_id', new.id));
  elsif new.kind = 'shared_device' then
    perform notify_admins('security',
      'جهاز واحد على أكثر من حساب',
      'الجهاز ' || v_label || ' دخل إلى حساب ' || v_name || ' وحسابات أخرى',
      jsonb_build_object('user_id', new.user_id, 'event_id', new.id));
  elsif new.kind in ('screenshot', 'screen_record') then
    perform notify_admins('security',
      case when new.kind = 'screenshot' then 'محاولة لقطة شاشة'
           else 'محاولة تسجيل الشاشة' end,
      v_name || coalesce(' · ' || nullif(new.detail->>'screen', ''), ''),
      jsonb_build_object('user_id', new.user_id, 'event_id', new.id));
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_security_event on public.security_events;
create trigger trg_notify_security_event
  after insert on public.security_events
  for each row execute function public.trg_notify_security_event();

-- Flag reason on suspicious logins (outside Iraq, impossible travel).
alter table public.login_events add column if not exists flag_reason text;

-- Admin quick action: sign an account out of every device.
create or replace function public.admin_force_logout(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized.';
  end if;
  update profiles set active_session_token = gen_random_uuid()::text
    where id = p_user_id;
end;
$$;

revoke all on function public.admin_force_logout(uuid) from public, anon;
grant execute on function public.admin_force_logout(uuid) to authenticated;

-- ------------------------------------------------------------
-- 9. Terms of use acceptance.
-- ------------------------------------------------------------
alter table public.profiles
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists terms_version text;

-- ------------------------------------------------------------
-- 10. Public teacher profile (name, photo, bio, counts). Works for guests.
-- ------------------------------------------------------------
create or replace function public.get_teacher_public(p_teacher_id uuid)
returns table(
  full_name text,
  photo_url text,
  bio text,
  specialty text,
  instagram text,
  telegram text,
  course_count int,
  student_count int
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select p.full_name,
         p.teacher_photo_url,
         p.teacher_bio,
         p.teacher_specialty,
         p.instagram_username,
         p.telegram_username,
         (select count(*)::int from courses c
           where c.teacher_id = p.id and c.status = 'published'),
         (select count(distinct e.user_id)::int from enrollments e
           join courses c on c.slug = e.course_slug
           where c.teacher_id = p.id and c.status = 'published'
             and e.status = 'active')
  from profiles p
  where p.id = p_teacher_id and p.is_teacher = true;
end;
$$;

revoke all on function public.get_teacher_public(uuid) from public;
grant execute on function public.get_teacher_public(uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 11. Course files (PDF, photos, Word/Excel/PowerPoint, CAD), always kept
--     in their original format. Teachers upload to course-files/raw/; PDFs
--     and photos get the Arc logo stamped by a GitHub Actions job, other
--     types are published as-is, at course-files/view/<course>/<id>.<ext>.
--     Students read only the view copy, if enrolled (or the file is free).
--     allow_download: the teacher's choice; files the app can't display
--     (Office, CAD) are always downloadable.
-- ------------------------------------------------------------
create table if not exists public.course_files (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  title text not null check (length(title) between 1 and 200),
  kind text not null check (kind in ('pdf', 'image', 'office', 'cad')),
  original_name text,
  raw_path text,
  view_path text,
  view_type text check (view_type in ('pdf', 'image', 'file')),
  status text not null default 'processing'
    check (status in ('processing', 'published', 'failed')),
  is_free boolean not null default false,
  allow_download boolean not null default false,
  order_index integer not null default 0,
  uploaded_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Files the app can't display must be downloadable.
alter table public.course_files drop constraint if exists course_files_download_check;
alter table public.course_files add constraint course_files_download_check
  check (allow_download or kind in ('pdf', 'image'));

create index if not exists course_files_course_idx
  on public.course_files (course_id, order_index);

alter table public.course_files enable row level security;

create or replace function public.can_edit_course(p_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin() or exists (
    select 1 from courses where id = p_course_id and teacher_id = auth.uid());
$$;

create or replace function public.can_view_course_file(p_file_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from course_files f
    join courses c on c.id = f.course_id
    where f.id = p_file_id
      and f.status = 'published'
      and (
        f.is_free
        or c.teacher_id = auth.uid()
        or public.is_admin()
        or exists (select 1 from enrollments e
                   where e.course_slug = c.slug and e.user_id = auth.uid()
                     and e.status = 'active')));
$$;

drop policy if exists "Course files listed" on public.course_files;
create policy "Course files listed" on public.course_files
  for select using (status = 'published' or public.can_edit_course(course_id));

drop policy if exists "Teachers add course files" on public.course_files;
create policy "Teachers add course files" on public.course_files
  for insert with check (
    public.can_edit_course(course_id)
    and status = 'processing' and view_path is null);

drop policy if exists "Teachers rename course files" on public.course_files;
create policy "Teachers rename course files" on public.course_files
  for update using (public.can_edit_course(course_id))
  with check (public.can_edit_course(course_id));

drop policy if exists "Teachers delete course files" on public.course_files;
create policy "Teachers delete course files" on public.course_files
  for delete using (public.can_edit_course(course_id));

-- Teachers may only change title / free flag / order; the processed copy
-- and its status come from the server job alone.
create or replace function public.trg_guard_course_file()
returns trigger
language plpgsql
as $$
begin
  if current_setting('app.course_file_job', true) = 'on' then
    return new;
  end if;
  new.view_path := old.view_path;
  new.view_type := old.view_type;
  new.status := old.status;
  new.raw_path := old.raw_path;
  new.course_id := old.course_id;
  return new;
end;
$$;

drop trigger if exists trg_guard_course_file on public.course_files;
create trigger trg_guard_course_file
  before update on public.course_files
  for each row execute function public.trg_guard_course_file();

-- Private storage bucket.
insert into storage.buckets (id, name, public)
values ('course-files', 'course-files', false)
on conflict (id) do update set public = false;

drop policy if exists "Course files: teachers upload originals" on storage.objects;
create policy "Course files: teachers upload originals" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'course-files'
    and (storage.foldername(name))[1] = 'raw'
    and public.can_edit_course(((storage.foldername(name))[2])::uuid));

drop policy if exists "Course files: read processed copy" on storage.objects;
create policy "Course files: read processed copy" on storage.objects
  for select to authenticated using (
    bucket_id = 'course-files'
    and (storage.foldername(name))[1] = 'view'
    and exists (
      select 1 from public.course_files f
      where f.view_path = storage.objects.name
        and public.can_view_course_file(f.id)));

drop policy if exists "Course files: teachers remove" on storage.objects;
create policy "Course files: teachers remove" on storage.objects
  for delete to authenticated using (
    bucket_id = 'course-files'
    and public.can_edit_course(((storage.foldername(name))[2])::uuid));

-- Called by api/course-file.js (service role) when the job finishes.
create or replace function public.finish_course_file(
  p_file_id uuid, p_view_path text, p_view_type text, p_ok boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_f record;
begin
  perform set_config('app.course_file_job', 'on', true);
  update course_files
     set view_path = case when p_ok then p_view_path else null end,
         view_type = case when p_ok then p_view_type else null end,
         status = case when p_ok then 'published' else 'failed' end,
         raw_path = case when p_ok then null else raw_path end
   where id = p_file_id
   returning course_id, title, uploaded_by into v_f;
  if v_f.uploaded_by is not null then
    perform notify_user(v_f.uploaded_by, 'course_file',
      case when p_ok then 'الملف جاهز' else 'تعذرت معالجة الملف' end,
      v_f.title,
      jsonb_build_object('course_id', v_f.course_id));
  end if;
end;
$$;

revoke all on function public.finish_course_file(uuid, text, text, boolean) from public, anon, authenticated;
grant execute on function public.finish_course_file(uuid, text, text, boolean) to service_role;

-- ------------------------------------------------------------
-- Checks: each row should say true.
-- ------------------------------------------------------------
select 'enrollments.amount_paid' as item,
  exists (select 1 from information_schema.columns
          where table_name = 'enrollments' and column_name = 'amount_paid') as ok
union all select 'preview_discount_code',
  exists (select 1 from pg_proc where proname = 'preview_discount_code')
union all select 'submit_paid_enrollment',
  exists (select 1 from pg_proc where proname = 'submit_paid_enrollment')
union all select 'security_events',
  exists (select 1 from information_schema.tables where table_name = 'security_events')
union all select 'profiles.terms_accepted_at',
  exists (select 1 from information_schema.columns
          where table_name = 'profiles' and column_name = 'terms_accepted_at')
union all select 'course_files',
  exists (select 1 from information_schema.tables where table_name = 'course_files')
union all select 'course-files bucket',
  exists (select 1 from storage.buckets where id = 'course-files')
union all select 'admin_force_logout',
  exists (select 1 from pg_proc where proname = 'admin_force_logout');
