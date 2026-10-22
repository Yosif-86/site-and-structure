-- Course ratings (2026-10-22).
--  * A student with an active enrollment rates a course 1 to 5 stars. 1 to 3
--    stars can carry a written comment (4 and 5 never keep one).
--  * The student can change or remove their rating at any time.
--  * Comments are private: only the admins and the teacher who owns the
--    course can read them (course_reviews). A low rating (1 to 3) sends a
--    notification to the teacher and the admins, with the student's name and ID.
--  * The average is public, but only once a course has 5 or more ratings
--    (course_rating_summaries).
-- Clients cannot write the table directly: every change goes through an RPC.

create table if not exists public.course_ratings (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  comment text check (comment is null or length(comment) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (course_id, user_id)
);

create index if not exists course_ratings_course_idx
  on public.course_ratings (course_id);

alter table public.course_ratings enable row level security;

-- A student reads only their own rating (to show it and let them edit it).
drop policy if exists "Users read own rating" on public.course_ratings;
create policy "Users read own rating" on public.course_ratings
  for select to authenticated using (user_id = auth.uid());

revoke all on public.course_ratings from anon, authenticated;
grant select on public.course_ratings to authenticated;

-- ------------------------------------------------------------
-- Rate (or change the rating of) a course.
-- ------------------------------------------------------------
create or replace function public.rate_course(
  p_course uuid, p_rating integer, p_comment text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_course record;
  v_old record;
  v_comment text := nullif(trim(coalesce(p_comment, '')), '');
  v_id uuid;
  v_name text;
  v_pid text;
  v_teacher_is_admin boolean;
  v_body text;
begin
  if v_uid is null then
    raise exception 'Not signed in.';
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'Rating must be 1 to 5.' using errcode = '22023';
  end if;
  if v_comment is not null and length(v_comment) > 1000 then
    raise exception 'Comment is too long.' using errcode = '22023';
  end if;
  -- Only 1 to 3 stars keep a comment.
  if p_rating >= 4 then
    v_comment := null;
  end if;

  select id, slug, title, teacher_id into v_course
    from courses where id = p_course and status = 'published';
  if not found then
    raise exception 'Course not found.';
  end if;
  if v_course.teacher_id is not distinct from v_uid then
    raise exception 'You cannot rate your own course.';
  end if;
  if not exists (select 1 from enrollments e
                  where e.course_slug = v_course.slug
                    and e.user_id = v_uid and e.status = 'active') then
    raise exception 'Enroll in the course first.';
  end if;

  select rating, comment into v_old
    from course_ratings where course_id = p_course and user_id = v_uid;

  insert into course_ratings (course_id, user_id, rating, comment)
  values (p_course, v_uid, p_rating, v_comment)
  on conflict (course_id, user_id) do update
    set rating = excluded.rating,
        comment = excluded.comment,
        updated_at = now()
  returning id into v_id;

  -- A low rating that is new or changed reaches the teacher and the admins.
  if p_rating <= 3
     and (v_old is null
          or v_old.rating is distinct from p_rating::smallint
          or v_old.comment is distinct from v_comment) then
    select coalesce(nullif(full_name, ''), '—'), coalesce(public_id, '')
      into v_name, v_pid from profiles where id = v_uid;
    v_body := coalesce(v_name, '—')
      || case when coalesce(v_pid, '') <> '' then ' · #' || v_pid else '' end
      || ' · ' || p_rating || '/5'
      || case when v_comment is not null then E'\n' || v_comment else '' end;

    select coalesce(is_admin, false) into v_teacher_is_admin
      from profiles where id = v_course.teacher_id;
    if v_course.teacher_id is not null and not coalesce(v_teacher_is_admin, false) then
      perform notify_user(v_course.teacher_id, 'course_rating',
        'تقييم منخفض لدورة «' || v_course.title || '»', v_body,
        jsonb_build_object('course_id', v_course.id, 'course_title', v_course.title,
                           'rating_id', v_id, 'rating', p_rating));
    end if;
    perform notify_admins('course_rating',
      'تقييم منخفض لدورة «' || v_course.title || '»', v_body,
      jsonb_build_object('course_id', v_course.id, 'course_title', v_course.title,
                         'rating_id', v_id, 'rating', p_rating));
  end if;
end;
$$;

revoke all on function public.rate_course(uuid, integer, text) from public, anon;
grant execute on function public.rate_course(uuid, integer, text) to authenticated;

-- ------------------------------------------------------------
-- Remove my rating.
-- ------------------------------------------------------------
create or replace function public.remove_course_rating(p_course uuid)
returns void
language sql
security definer
set search_path = public
as $$
  delete from course_ratings where course_id = p_course and user_id = auth.uid();
$$;

revoke all on function public.remove_course_rating(uuid) from public, anon;
grant execute on function public.remove_course_rating(uuid) to authenticated;

-- ------------------------------------------------------------
-- Every rating of one course with the student's name and ID.
-- Admins and the course's own teacher only.
-- ------------------------------------------------------------
create or replace function public.course_reviews(p_course uuid)
returns table (
  id uuid,
  user_id uuid,
  student_name text,
  public_id text,
  rating smallint,
  comment text,
  updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (public.is_admin() or exists (
            select 1 from courses c
             where c.id = p_course and c.teacher_id = auth.uid())) then
    raise exception 'Not authorized.';
  end if;
  return query
    select r.id, r.user_id, coalesce(nullif(p.full_name, ''), '—'),
           p.public_id, r.rating, r.comment, r.updated_at
      from course_ratings r
      left join profiles p on p.id = r.user_id
     where r.course_id = p_course
     order by r.updated_at desc;
end;
$$;

revoke all on function public.course_reviews(uuid) from public, anon;
grant execute on function public.course_reviews(uuid) to authenticated;

-- ------------------------------------------------------------
-- Public averages: only published courses with 5 or more ratings.
-- ------------------------------------------------------------
create or replace function public.course_rating_summaries()
returns table (course_id uuid, avg_rating numeric, rating_count integer)
language sql
stable
security definer
set search_path = public
as $$
  select r.course_id,
         round(avg(r.rating)::numeric, 1),
         count(*)::integer
    from course_ratings r
    join courses c on c.id = r.course_id and c.status = 'published'
   group by r.course_id
  having count(*) >= 5;
$$;

revoke all on function public.course_rating_summaries() from public;
grant execute on function public.course_rating_summaries() to anon, authenticated;

-- Verify (read-only): every row should say true.
select 'table' as item,
  exists (select 1 from information_schema.tables
           where table_schema = 'public' and table_name = 'course_ratings')::text as ok
union all select 'rls on',
  (select relrowsecurity from pg_class where oid = 'public.course_ratings'::regclass)::text
union all select 'rate_course',
  exists (select 1 from pg_proc where proname = 'rate_course')::text
union all select 'course_reviews',
  exists (select 1 from pg_proc where proname = 'course_reviews')::text
union all select 'summaries',
  exists (select 1 from pg_proc where proname = 'course_rating_summaries')::text
union all select 'anon cannot write table',
  (not has_table_privilege('anon', 'public.course_ratings', 'insert, update, delete, select'))::text
union all select 'anon cannot rate',
  (not has_function_privilege('anon', 'public.rate_course(uuid, integer, text)', 'execute'))::text
union all select 'anon cannot read reviews',
  (not has_function_privilege('anon', 'public.course_reviews(uuid)', 'execute'))::text;
