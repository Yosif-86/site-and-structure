-- ============================================================
-- Admin announcements: the admin dashboard (app + website) sends a
-- notification to a chosen group. Each row goes into `notifications`, so it
-- shows in the bell and the existing push trigger sends it to phones.
-- Safe to run more than once.
-- ============================================================

create or replace function public.admin_send_announcement(
  p_title text,
  p_body text,
  p_audience text
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text := btrim(coalesce(p_title, ''));
  v_body text := btrim(coalesce(p_body, ''));
  v_count integer;
begin
  if not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_title = '' or length(v_title) > 80 then
    raise exception 'title must be 1-80 characters' using errcode = '22023';
  end if;
  if length(v_body) > 500 then
    raise exception 'body must be at most 500 characters' using errcode = '22023';
  end if;
  if p_audience not in ('me', 'students', 'teachers', 'all') then
    raise exception 'bad audience' using errcode = '22023';
  end if;

  insert into notifications (user_id, type, title, body)
  select p.id, 'announcement', v_title, v_body
  from profiles p
  join auth.users u on u.id = p.id
  where case p_audience
    when 'me' then p.id = auth.uid()
    when 'teachers' then coalesce(p.is_teacher, false)
    when 'students' then not coalesce(p.is_teacher, false) and not coalesce(p.is_admin, false)
    else true
  end;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.admin_send_announcement(text, text, text) from public, anon;
grant execute on function public.admin_send_announcement(text, text, text) to authenticated;

-- Check: should say true.
select 'admin_send_announcement' as item,
  exists (select 1 from pg_proc where proname = 'admin_send_announcement') as ok;
