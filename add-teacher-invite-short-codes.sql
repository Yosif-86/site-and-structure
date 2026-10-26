-- Teacher invite codes are now 5 characters (e.g. K7QM4). A short code can be
-- guessed by brute force, so both functions below (a) match case-insensitively
-- and (b) refuse to answer once too many wrong codes were tried recently.
-- The limit is global (not per person): the check runs before sign-up, so there
-- is no account to count against. 60 wrong tries per 10 minutes is far above
-- real use and far below what guessing 33 million codes would need.

create table if not exists teacher_invite_attempts (
  at timestamptz not null default now()
);
create index if not exists idx_teacher_invite_attempts_at on teacher_invite_attempts (at);
alter table teacher_invite_attempts enable row level security;
revoke all on teacher_invite_attempts from public, anon, authenticated;

create or replace function public.is_teacher_invite_valid(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ok boolean;
begin
  if (select count(*) from teacher_invite_attempts
       where at > now() - interval '10 minutes') >= 60 then
    raise exception 'too many attempts';
  end if;

  select exists (
    select 1 from teacher_invites
    where lower(token) = lower(btrim(coalesce(p_token, '')))
      and used_at is null and expires_at > now()
  ) into v_ok;

  if not v_ok then
    delete from teacher_invite_attempts where at < now() - interval '1 hour';
    insert into teacher_invite_attempts default values;
  end if;
  return v_ok;
end;
$$;

create or replace function public.redeem_teacher_invite(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if (select count(*) from teacher_invite_attempts
       where at > now() - interval '10 minutes') >= 60 then
    raise exception 'too many attempts';
  end if;

  update teacher_invites
  set used_at = now(), used_by = auth.uid()
  where lower(token) = lower(btrim(coalesce(p_token, '')))
    and used_at is null and expires_at > now()
  returning id into v_id;

  if v_id is null then
    delete from teacher_invite_attempts where at < now() - interval '1 hour';
    insert into teacher_invite_attempts default values;
    return false;
  end if;

  update profiles set is_teacher = true where id = auth.uid();
  return true;
end;
$$;

revoke all on function public.is_teacher_invite_valid(text) from public;
grant execute on function public.is_teacher_invite_valid(text) to anon, authenticated;
revoke all on function public.redeem_teacher_invite(text) from public, anon;
grant execute on function public.redeem_teacher_invite(text) to authenticated;
