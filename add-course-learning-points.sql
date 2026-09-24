-- 1) "What you'll learn" bullets for the course page (edited from the
--    teacher dashboard's course form). Limits are enforced here, not just in
--    the app, so a modified client can't store an arbitrarily large array:
--    at most 12 points, each at most 200 characters.
--    Teachers already write courses through "Teachers can update own
--    courses" (draft/pending_review only) -- no new policy is needed.

create or replace function public.learning_points_valid(p text[])
returns boolean
language sql
immutable
as $$
  select coalesce(bool_and(char_length(x) <= 200), true) from unnest(p) as x
$$;

alter table public.courses
  add column if not exists learning_points text[] not null default '{}';

alter table public.courses drop constraint if exists courses_learning_points_check;
alter table public.courses add constraint courses_learning_points_check
  check (cardinality(learning_points) <= 12 and public.learning_points_valid(learning_points));

-- 2) lectures.duration_seconds already exists (add-course-stage-and-lecture-
--    duration.sql) but was mostly empty. The app now reads the runtime off
--    the file when a teacher uploads; this backfills existing lectures from
--    the durations students' players have already reported.

update public.lectures l
set duration_seconds = sub.d
from (
  select lecture_id, max(duration_seconds) as d
  from public.lesson_progress
  where duration_seconds between 1 and 21600
  group by lecture_id
) sub
where l.id = sub.lecture_id
  and l.duration_seconds is null;

-- 3) Going forward: the first time anyone's player reports a lecture's
--    length, fill it in if it's still unknown (e.g. a lecture uploaded from
--    the website, which doesn't read durations). Only ever fills a NULL --
--    never overwrites a teacher-recorded value -- and only within a sane
--    1s..6h range, so a tampered progress row can't set anything absurd.

create or replace function public.fill_lecture_duration_from_progress()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.duration_seconds between 1 and 21600 then
    update public.lectures
    set duration_seconds = new.duration_seconds
    where id = new.lecture_id
      and duration_seconds is null;
  end if;
  return new;
end;
$$;

revoke all on function public.fill_lecture_duration_from_progress() from public, anon, authenticated;

drop trigger if exists trg_fill_lecture_duration on public.lesson_progress;
create trigger trg_fill_lecture_duration
  after insert or update of duration_seconds on public.lesson_progress
  for each row execute function public.fill_lecture_duration_from_progress();
