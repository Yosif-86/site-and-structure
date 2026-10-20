-- User warnings: the admin sends a formal warning from a security alert
-- (screen capture, or account sharing / sign-in from another device).
-- The student sees it in a window when they open the app and must type a
-- reason, which reaches the admins. Three warnings: the account may be
-- deleted with no refund (terms). Deletion itself stays a manual admin step.
-- New table: grants are explicit (Supabase stops auto-granting on 2026-10-30).

create table if not exists public.user_warnings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('screen_capture', 'account_sharing')),
  warning_no integer not null,
  title text not null,
  message text not null,
  event_id uuid,
  event_at timestamptz,
  issued_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  user_reason text,
  acknowledged_at timestamptz
);

create index if not exists user_warnings_user_idx
  on public.user_warnings (user_id, created_at);
-- One warning per security event.
create unique index if not exists user_warnings_event_key
  on public.user_warnings (event_id) where event_id is not null;

alter table public.user_warnings enable row level security;

drop policy if exists "Users read own warnings" on public.user_warnings;
create policy "Users read own warnings"
  on public.user_warnings for select
  using (user_id = auth.uid() or public.is_admin());

-- No insert/update/delete policies: only the functions below write.
revoke all on public.user_warnings from anon, authenticated;
grant select on public.user_warnings to authenticated;
grant select, insert, update, delete on public.user_warnings to service_role;

-- ------------------------------------------------------------
-- Security alerts now carry the event kind, so the app can show
-- a distinct icon (screen recording = red camera) and offer a warning.
-- ------------------------------------------------------------
create or replace function public.trg_notify_security_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_label text := coalesce(new.detail->>'device_label', '');
  v_data jsonb := jsonb_build_object(
    'user_id', new.user_id, 'event_id', new.id, 'kind', new.kind);
begin
  select coalesce(nullif(full_name, ''), '—') into v_name
    from profiles where id = new.user_id;
  v_name := coalesce(v_name, '—');

  if new.kind = 'device_blocked' then
    perform notify_admins('security',
      'حاول جهاز آخر فتح حساب ' || v_name,
      trim(v_label || ' · تم منعه لأن الحساب وصل لحد الأجهزة'),
      v_data);
    perform notify_user(new.user_id, 'security',
      'محاولة دخول من جهاز آخر',
      'حاول جهاز آخر فتح حسابك وتم منعه. إذا لم تكن أنت، غيّر كلمة المرور.',
      jsonb_build_object('event_id', new.id, 'kind', new.kind, 'own', true));
  elsif new.kind = 'shared_device' then
    perform notify_admins('security',
      'جهاز واحد على أكثر من حساب',
      'الجهاز ' || v_label || ' دخل إلى حساب ' || v_name || ' وحسابات أخرى',
      v_data);
  elsif new.kind in ('screenshot', 'screen_record') then
    perform notify_admins('security',
      case when new.kind = 'screenshot' then 'محاولة لقطة شاشة'
           else 'محاولة تسجيل الشاشة' end,
      v_name || coalesce(' · ' || nullif(new.detail->>'screen', ''), ''),
      v_data);
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------
-- Admin issues a warning. p_kind: 'screen_capture' or 'account_sharing'.
-- p_event_id (optional) ties it to one security event. Returns the number.
-- ------------------------------------------------------------
create or replace function public.admin_issue_warning(
  p_user uuid, p_kind text, p_event_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_no integer;
  v_at timestamptz := now();
  v_ord text;
  v_title text;
  v_msg text;
  v_ev record;
begin
  if not public.is_admin() then
    raise exception 'Not authorized.';
  end if;
  if p_kind not in ('screen_capture', 'account_sharing') then
    raise exception 'Bad warning kind.';
  end if;
  if not exists (select 1 from profiles where id = p_user) then
    raise exception 'User not found.';
  end if;

  if p_event_id is not null then
    select user_id, created_at into v_ev
      from security_events where id = p_event_id;
    if found then
      if v_ev.user_id is distinct from p_user then
        raise exception 'Event belongs to another user.';
      end if;
      v_at := v_ev.created_at;
    end if;
    if exists (select 1 from user_warnings where event_id = p_event_id) then
      raise exception 'A warning was already sent for this event.';
    end if;
  end if;

  select count(*) + 1 into v_no from user_warnings where user_id = p_user;
  v_ord := case v_no when 1 then 'الأول' when 2 then 'الثاني'
                     when 3 then 'الثالث' else '(' || v_no || ')' end;
  v_title := 'تحذير رسمي ' || v_ord;

  v_msg := case p_kind
    when 'screen_capture' then
      'رصد نظام الحماية في منصة آرك محاولة لتصوير الشاشة أو تسجيلها بتاريخ '
    else
      'رصد نظام الحماية في منصة آرك محاولة لمشاركة الحساب أو تسجيل الدخول من جهاز آخر بتاريخ '
    end
    || to_char(v_at at time zone 'Asia/Baghdad', 'YYYY-MM-DD HH24:MI')
    || '، وهذا مخالفة صريحة لشروط استخدام التطبيق. '
    || case
         when v_no = 1 then
           'يُعدّ هذا التحذير الأول، وعند الوصول إلى التحذير الثالث سيُحذف الحساب نهائيًا دون استرجاع أي مبالغ أو دورات مشتراة.'
         when v_no = 2 then
           'يُعدّ هذا التحذير الثاني، والتحذير القادم هو الثالث والأخير، وبعده سيُحذف الحساب نهائيًا دون استرجاع أي مبالغ أو دورات مشتراة.'
         else
           'يُعدّ هذا التحذير الثالث والأخير، وسيُحذف الحساب نهائيًا دون استرجاع أي مبالغ أو دورات مشتراة.'
       end;

  insert into user_warnings
    (user_id, kind, warning_no, title, message, event_id, event_at, issued_by)
  values
    (p_user, p_kind, v_no, v_title, v_msg, p_event_id, v_at, auth.uid());

  perform notify_user(p_user, 'warning', v_title, v_msg,
    jsonb_build_object('warning_no', v_no, 'kind', p_kind));
  return v_no;
end;
$$;

revoke all on function public.admin_issue_warning(uuid, text, uuid) from public, anon;
grant execute on function public.admin_issue_warning(uuid, text, uuid) to authenticated;

-- ------------------------------------------------------------
-- Student answers a warning with the reason; the admins are notified.
-- ------------------------------------------------------------
create or replace function public.submit_warning_reason(
  p_warning_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_w record;
  v_reason text := trim(coalesce(p_reason, ''));
  v_name text;
begin
  select id, user_id, warning_no, kind, acknowledged_at into v_w
    from user_warnings where id = p_warning_id;
  if not found or v_w.user_id <> auth.uid() then
    raise exception 'Warning not found.';
  end if;
  if v_w.acknowledged_at is not null then
    raise exception 'Already answered.';
  end if;
  if length(v_reason) < 3 or length(v_reason) > 500 then
    raise exception 'Reason must be 3-500 characters.' using errcode = '22023';
  end if;

  update user_warnings
     set user_reason = v_reason, acknowledged_at = now()
   where id = p_warning_id;

  select coalesce(nullif(full_name, ''), '—') into v_name
    from profiles where id = v_w.user_id;
  perform notify_admins('warning_reply',
    'رد على التحذير ' || v_w.warning_no || ' من ' || coalesce(v_name, '—'),
    v_reason,
    jsonb_build_object('user_id', v_w.user_id, 'warning_id', v_w.id,
                       'kind', v_w.kind, 'warning_no', v_w.warning_no));
end;
$$;

revoke all on function public.submit_warning_reason(uuid, text) from public, anon;
grant execute on function public.submit_warning_reason(uuid, text) to authenticated;

-- Verify (read-only).
select
  (select count(*) from information_schema.tables
    where table_schema = 'public' and table_name = 'user_warnings') as table_ok,
  (select count(*) from pg_proc
    where proname in ('admin_issue_warning', 'submit_warning_reason')) as functions_ok;
