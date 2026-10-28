-- Chapters: a course groups its lectures under named chapters.
-- A lecture without a chapter (all existing ones) stays in a general group.
create table if not exists public.course_chapters (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  order_index int not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists course_chapters_course_idx
  on public.course_chapters (course_id, order_index);

alter table public.lectures
  add column if not exists chapter_id uuid
  references public.course_chapters(id) on delete set null;

create index if not exists lectures_chapter_idx on public.lectures (chapter_id);

alter table public.course_chapters enable row level security;

drop policy if exists "Anyone can view chapters of published courses" on public.course_chapters;
create policy "Anyone can view chapters of published courses"
  on public.course_chapters for select
  using (exists (select 1 from public.courses c
                 where c.id = course_chapters.course_id and c.status = 'published'));

drop policy if exists "Teachers can manage own course chapters" on public.course_chapters;
create policy "Teachers can manage own course chapters"
  on public.course_chapters for all
  using (exists (select 1 from public.courses c
                 where c.id = course_chapters.course_id and c.teacher_id = auth.uid()))
  with check (exists (select 1 from public.courses c
                      where c.id = course_chapters.course_id and c.teacher_id = auth.uid()));

drop policy if exists "Admins can manage all chapters" on public.course_chapters;
create policy "Admins can manage all chapters"
  on public.course_chapters for all
  using (public.is_admin())
  with check (public.is_admin());

-- A lecture can only point at a chapter of its own course.
create or replace function public.check_lecture_chapter()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.chapter_id is not null and not exists (
    select 1 from public.course_chapters ch
    where ch.id = new.chapter_id and ch.course_id = new.course_id
  ) then
    new.chapter_id := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_check_lecture_chapter on public.lectures;
create trigger trg_check_lecture_chapter
  before insert or update of chapter_id, course_id on public.lectures
  for each row execute function public.check_lecture_chapter();

revoke all on function public.check_lecture_chapter() from public, anon, authenticated;

grant select on public.course_chapters to anon, authenticated;
grant insert, update, delete on public.course_chapters to authenticated;
