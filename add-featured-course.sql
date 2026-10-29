-- Featured course on Home: one course at a time, chosen by an admin, with an
-- optional end date. Clients treat a course as featured while is_featured is
-- true and featured_until is null or in the future.

alter table public.courses add column if not exists is_featured boolean not null default false;
alter table public.courses add column if not exists featured_until timestamptz;

-- At most one featured course.
create unique index if not exists courses_one_featured
  on public.courses ((true)) where is_featured;

-- Only admins can change the flag (teachers can update their own courses).
create or replace function public.guard_course_featured()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if tg_op = 'INSERT' then
      new.is_featured := false;
      new.featured_until := null;
    else
      new.is_featured := old.is_featured;
      new.featured_until := old.featured_until;
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.guard_course_featured() from public, anon, authenticated;

drop trigger if exists trg_guard_course_featured on public.courses;
create trigger trg_guard_course_featured
  before insert or update on public.courses
  for each row execute function public.guard_course_featured();

-- Make one published course the featured one (p_until null = no end date).
create or replace function public.admin_set_featured(p_course uuid, p_until timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  if not exists (select 1 from public.courses where id = p_course and status = 'published') then
    raise exception 'course not published';
  end if;
  update public.courses set is_featured = false, featured_until = null
   where is_featured and id <> p_course;
  update public.courses set is_featured = true, featured_until = p_until
   where id = p_course;
end;
$$;

create or replace function public.admin_clear_featured()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  update public.courses set is_featured = false, featured_until = null where is_featured;
end;
$$;

revoke all on function public.admin_set_featured(uuid, timestamptz) from public, anon;
revoke all on function public.admin_clear_featured() from public, anon;
grant execute on function public.admin_set_featured(uuid, timestamptz) to authenticated;
grant execute on function public.admin_clear_featured() to authenticated;
