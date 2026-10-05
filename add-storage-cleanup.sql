-- Daily storage cleanup (2026-10-05), used by the Cloudflare Worker's cron
-- job (worker/src/index.js). Deleting a lecture, course or account removes
-- database rows only; these two read-only helpers tell the worker which
-- stored files no longer belong to anything. Only the service role (the
-- worker) can call them.

-- Of the given lecture ids (R2 folders videos/<id>/), the ones with no
-- lecture row any more.
create or replace function public.missing_lecture_ids(p_ids uuid[])
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select i from unnest(p_ids) as i
  where not exists (select 1 from lectures l where l.id = i);
$$;

-- course-files objects older than two days that no course_files row points
-- to (deleted courses, deleted teachers, abandoned uploads).
create or replace function public.orphan_course_file_paths(p_limit integer default 200)
returns setof text
language sql
stable
security definer
set search_path = public, storage
as $$
  select o.name
    from storage.objects o
   where o.bucket_id = 'course-files'
     and o.created_at < now() - interval '2 days'
     and not exists (
       select 1 from public.course_files f
        where f.view_path = o.name or f.raw_path = o.name)
   order by o.created_at
   limit greatest(1, least(p_limit, 1000));
$$;

revoke all on function public.missing_lecture_ids(uuid[]) from public, anon, authenticated;
revoke all on function public.orphan_course_file_paths(integer) from public, anon, authenticated;
grant execute on function public.missing_lecture_ids(uuid[]) to service_role;
grant execute on function public.orphan_course_file_paths(integer) to service_role;

-- Check: both true, then how many course files are leftovers right now.
select 'missing_lecture_ids' as item,
  exists (select 1 from pg_proc where proname = 'missing_lecture_ids')::text as ok
union all select 'orphan_course_file_paths',
  exists (select 1 from pg_proc where proname = 'orphan_course_file_paths')::text
union all select 'course-files leftovers now',
  (select count(*) from public.orphan_course_file_paths(1000))::text;
