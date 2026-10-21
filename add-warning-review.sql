-- Admin reviews a student's reply to a warning (needs add-user-warnings.sql).
--  Accept: the warning is removed (kept for the admin, marked 'removed', and
--          no longer counted), the student's warning notification is deleted
--          and they get a green "warning removed" notification.
--  Reject: the warning stays ('rejected') and still counts.

alter table public.user_warnings
  add column if not exists status text not null default 'active',
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references auth.users(id) on delete set null;

alter table public.user_warnings drop constraint if exists user_warnings_status_check;
alter table public.user_warnings add constraint user_warnings_status_check
  check (status in ('active', 'rejected', 'removed'));

-- ------------------------------------------------------------
-- Issue: same as before, but a removed warning no longer counts, and the
-- student's notification carries the warning id (so it can be deleted).
-- ------------------------------------------------------------
create or replace function public.admin_issue_warning(
  p_user uuid, p_kind text, p_event_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := gen_random_uuid();
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

  select count(*) + 1 into v_no from user_warnings
   where user_id = p_user and status <> 'removed';
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
    (id, user_id, kind, warning_no, title, message, event_id, event_at, issued_by)
  values
    (v_id, p_user, p_kind, v_no, v_title, v_msg, p_event_id, v_at, auth.uid());

  perform notify_user(p_user, 'warning', v_title, v_msg,
    jsonb_build_object('warning_id', v_id, 'warning_no', v_no, 'kind', p_kind));
  return v_no;
end;
$$;

revoke all on function public.admin_issue_warning(uuid, text, uuid) from public, anon;
grant execute on function public.admin_issue_warning(uuid, text, uuid) to authenticated;

-- ------------------------------------------------------------
-- Review a reply. p_accept true = remove the warning, false = keep it.
-- ------------------------------------------------------------
create or replace function public.admin_review_warning(
  p_warning_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_w record;
begin
  if not public.is_admin() then
    raise exception 'Not authorized.';
  end if;
  select id, user_id, warning_no, title, acknowledged_at, status into v_w
    from user_warnings where id = p_warning_id for update;
  if not found then
    raise exception 'Warning not found.';
  end if;
  if v_w.acknowledged_at is null then
    raise exception 'The student has not replied yet.';
  end if;
  if v_w.status = 'removed' then
    raise exception 'This warning was already removed.';
  end if;

  update user_warnings
     set status = case when p_accept then 'removed' else 'rejected' end,
         reviewed_at = now(),
         reviewed_by = auth.uid()
   where id = p_warning_id;

  if p_accept then
    -- The student's copy of the warning goes; the admin's record stays.
    -- Older notifications have no warning_id: match them by number + title.
    delete from notifications
     where user_id = v_w.user_id
       and type = 'warning'
       and (data->>'warning_id' = v_w.id::text
            or (data->>'warning_id' is null
                and data->>'warning_no' = v_w.warning_no::text
                and title = v_w.title));

    perform notify_user(v_w.user_id, 'warning_cleared',
      'تمت إزالة التحذير',
      'راجعت إدارة منصة آرك ردّك على «' || v_w.title
        || '» وقبلته، وتمت إزالة التحذير من حسابك. نشكرك على تعاونك والتزامك بشروط الاستخدام.',
      jsonb_build_object('warning_id', v_w.id));
  end if;
end;
$$;

revoke all on function public.admin_review_warning(uuid, boolean) from public, anon;
grant execute on function public.admin_review_warning(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- Student's reply: same as before, plus the name in the admins' alert data
-- (the review window opens from that alert).
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
  v_name := coalesce(v_name, '—');
  perform notify_admins('warning_reply',
    'رد على التحذير ' || v_w.warning_no || ' من ' || v_name,
    v_reason,
    jsonb_build_object('user_id', v_w.user_id, 'warning_id', v_w.id,
                       'kind', v_w.kind, 'warning_no', v_w.warning_no,
                       'name', v_name));
end;
$$;

revoke all on function public.submit_warning_reason(uuid, text) from public, anon;
grant execute on function public.submit_warning_reason(uuid, text) to authenticated;

-- Verify (read-only).
select
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'user_warnings'
      and column_name in ('status', 'reviewed_at', 'reviewed_by')) as columns_ok,
  (select count(*) from pg_proc
    where proname = 'admin_review_warning') as function_ok;
