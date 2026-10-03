-- Platform commission, direct-payment restriction, course edit requests and
-- in-app notifications. Safe to run more than once.

-- ============================================================
-- 1. Direct payment ("pay to teacher") is a per-teacher privilege, granted
--    only to chadeerehsan3@gmail.com for now. Everyone else's students pay
--    the platform, so the platform's 20% is always collected.
-- ============================================================
alter table public.profiles
  add column if not exists direct_payment_allowed boolean not null default false;

update public.profiles p
   set direct_payment_allowed = (lower(u.email) = 'chadeerehsan3@gmail.com')
  from auth.users u
 where u.id = p.id;

-- Turn it off on every course whose teacher isn't allowed.
update public.courses c
   set pay_to_teacher = false
 where pay_to_teacher = true
   and not exists (
     select 1 from public.profiles p
      where p.id = c.teacher_id and p.direct_payment_allowed = true);

create or replace function public.enforce_pay_to_teacher_admin_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    if tg_op = 'INSERT' then
      new.pay_to_teacher := false;
    else
      new.pay_to_teacher := old.pay_to_teacher;
    end if;
  elsif new.pay_to_teacher = true and not exists (
    select 1 from profiles where id = new.teacher_id and direct_payment_allowed = true
  ) then
    if tg_op = 'INSERT' then
      new.pay_to_teacher := false;
    else
      new.pay_to_teacher := false;
    end if;
  end if;
  return new;
end;
$$;

-- ============================================================
-- 2. Discounts come only out of the teacher's 80%: a code can take at most
--    80% off (percent) or 80% of the price (fixed amount).
-- ============================================================
create or replace function public.course_price_number(p_price text)
returns numeric
language sql
immutable
as $$
  select coalesce(nullif(regexp_replace(coalesce(p_price, ''), '[^0-9]', '', 'g'), '')::numeric, 0);
$$;

create or replace function public.enforce_discount_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_price numeric;
begin
  select public.course_price_number(price::text) into v_price
    from courses where id = new.course_id;
  if new.discount_type = 'percent' and new.discount_value > 80 then
    raise exception 'discount_too_large';
  end if;
  if new.discount_type = 'fixed' and v_price > 0 and new.discount_value > v_price * 0.8 then
    raise exception 'discount_too_large';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_discount_cap on public.discount_codes;
create trigger trg_enforce_discount_cap
  before insert or update of discount_type, discount_value on public.discount_codes
  for each row execute function public.enforce_discount_cap();

-- ============================================================
-- 3. Course edit requests (builds on add-course-edit-requests.sql): a
--    reason when rejected, and learning points locked like the other
--    fields on a published course.
-- ============================================================
alter table public.courses add column if not exists pending_edit jsonb;
alter table public.courses add column if not exists edit_status text;
alter table public.courses add column if not exists edit_reject_reason text;

create or replace function public.enforce_course_edit_via_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_admin() then
    return new;
  end if;
  if old.status = 'published' then
    new.title := old.title;
    new.description := old.description;
    new.price := old.price;
    new.is_free := old.is_free;
    new.thumbnail_url := old.thumbnail_url;
    new.teacher_name := old.teacher_name;
    new.stage := old.stage;
    new.level := old.level;
    new.tag_label := old.tag_label;
    new.status := old.status;
    new.learning_points := old.learning_points;
    new.edit_reject_reason := case
      when new.edit_status = 'pending_review' then null
      else old.edit_reject_reason end;
    if new.edit_status is distinct from old.edit_status
       and new.edit_status not in ('pending_review') then
      new.edit_status := old.edit_status;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_course_edit_via_request on public.courses;
create trigger trg_enforce_course_edit_via_request
  before update on public.courses
  for each row execute function public.enforce_course_edit_via_request();

-- ============================================================
-- 4. Notifications (the bell). Rows are written only by the triggers below;
--    each user reads and marks read their own.
-- ============================================================
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  type text not null,
  title text not null,
  body text not null default '',
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;

drop policy if exists "Users read own notifications" on public.notifications;
create policy "Users read own notifications"
  on public.notifications for select using (user_id = auth.uid());

drop policy if exists "Users mark own notifications read" on public.notifications;
create policy "Users mark own notifications read"
  on public.notifications for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke insert, delete, update on public.notifications from anon, authenticated;
grant update (read_at) on public.notifications to authenticated;

-- Live unread badge.
do $$
begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null;
end $$;

create or replace function public.notify_user(
  p_user uuid, p_type text, p_title text, p_body text, p_data jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  insert into notifications (user_id, type, title, body, data)
  select p_user, p_type, p_title, coalesce(p_body, ''), coalesce(p_data, '{}'::jsonb)
  where p_user is not null;
$$;

create or replace function public.notify_admins(
  p_type text, p_title text, p_body text, p_data jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  insert into notifications (user_id, type, title, body, data)
  select id, p_type, p_title, coalesce(p_body, ''), coalesce(p_data, '{}'::jsonb)
    from profiles where is_admin = true;
$$;

revoke all on function public.notify_user(uuid, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.notify_admins(text, text, text, jsonb) from public, anon, authenticated;

-- Payments: new request -> whoever approves it; approved -> the student.
create or replace function public.trg_notify_enrollment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course record;
  v_student text;
  v_data jsonb;
begin
  select title, teacher_id, pay_to_teacher into v_course
    from courses where slug = new.course_slug;
  v_data := jsonb_build_object('course_slug', new.course_slug);

  if tg_op = 'INSERT' and new.status = 'pending' then
    select coalesce(nullif(full_name, ''), 'طالب') into v_student
      from profiles where id = new.user_id;
    if coalesce(v_course.pay_to_teacher, false) and v_course.teacher_id is not null then
      perform notify_user(v_course.teacher_id, 'payment_request', 'طلب دفع جديد',
        coalesce(v_student, 'طالب') || ' أرسل دفعة لدورة ' || coalesce(v_course.title, ''),
        v_data || jsonb_build_object('for', 'teacher'));
    else
      perform notify_admins('payment_request', 'طلب دفع جديد',
        coalesce(v_student, 'طالب') || ' أرسل دفعة لدورة ' || coalesce(v_course.title, ''), v_data);
    end if;
  elsif tg_op = 'UPDATE' and old.status is distinct from 'active' and new.status = 'active' then
    perform notify_user(new.user_id, 'payment_approved', 'تمت الموافقة على الدفع',
      'يمكنك الآن مشاهدة دورة ' || coalesce(v_course.title, ''), v_data);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_enrollment on public.enrollments;
create trigger trg_notify_enrollment
  after insert or update of status on public.enrollments
  for each row execute function public.trg_notify_enrollment();

-- Payment rejected -> the student, with the reason.
create or replace function public.trg_notify_rejection()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text;
begin
  select title into v_title from courses where slug = new.course_slug;
  perform notify_user(new.user_id, 'payment_rejected', 'تم رفض طلب الدفع',
    coalesce(v_title, '') || ': ' || new.reason,
    jsonb_build_object('course_slug', new.course_slug));
  return new;
end;
$$;

drop trigger if exists trg_notify_rejection on public.enrollment_rejections;
create trigger trg_notify_rejection
  after insert on public.enrollment_rejections
  for each row execute function public.trg_notify_rejection();

-- Course review and edit requests.
create or replace function public.trg_notify_course()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_data jsonb := jsonb_build_object('course_slug', new.slug, 'course_id', new.id);
  v_teacher text;
begin
  select coalesce(nullif(full_name, ''), 'مدرّس') into v_teacher
    from profiles where id = new.teacher_id;

  if new.status is distinct from old.status then
    if new.status = 'pending_review' then
      perform notify_admins('course_review', 'دورة بانتظار المراجعة',
        coalesce(v_teacher, 'مدرّس') || ' أرسل دورة ' || new.title || ' للمراجعة', v_data);
    elsif new.status = 'published' and old.status = 'pending_review' then
      perform notify_user(new.teacher_id, 'course_published', 'تم نشر دورتك',
        'أصبحت دورة ' || new.title || ' متاحة للطلاب', v_data);
    elsif new.status = 'draft' and old.status = 'pending_review' then
      perform notify_user(new.teacher_id, 'course_returned', 'أُعيدت دورتك للتعديل',
        'راجع دورة ' || new.title || ' وأرسلها مجددًا', v_data);
    end if;
  end if;

  if new.edit_status is distinct from old.edit_status then
    if new.edit_status = 'pending_review' then
      perform notify_admins('edit_request', 'طلب تعديل دورة',
        coalesce(v_teacher, 'مدرّس') || ' طلب تعديل دورة ' || new.title, v_data);
    elsif new.edit_status = 'approved' then
      perform notify_user(new.teacher_id, 'edit_approved', 'تمت الموافقة على التعديل',
        'تم تطبيق تعديلاتك على دورة ' || new.title, v_data);
    elsif new.edit_status = 'rejected' then
      perform notify_user(new.teacher_id, 'edit_rejected', 'تم رفض طلب التعديل',
        new.title || ': ' || coalesce(new.edit_reject_reason, ''), v_data);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_course on public.courses;
create trigger trg_notify_course
  after update of status, edit_status on public.courses
  for each row execute function public.trg_notify_course();

-- ============================================================
-- 5. Check: should return 5 rows.
-- ============================================================
select 'direct_payment_allowed' as ok
 where exists (select 1 from information_schema.columns
                where table_name = 'profiles' and column_name = 'direct_payment_allowed')
union all select 'chadee allowed'
 where exists (select 1 from profiles p join auth.users u on u.id = p.id
                where lower(u.email) = 'chadeerehsan3@gmail.com' and p.direct_payment_allowed)
union all select 'discount cap'
 where exists (select 1 from pg_trigger where tgname = 'trg_enforce_discount_cap')
union all select 'notifications'
 where to_regclass('public.notifications') is not null
union all select 'edit_reject_reason'
 where exists (select 1 from information_schema.columns
                where table_name = 'courses' and column_name = 'edit_reject_reason');
