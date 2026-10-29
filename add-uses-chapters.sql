-- Teacher switch: does this course group its lectures into chapters?
-- Courses that already have chapters are switched on.
alter table public.courses add column if not exists uses_chapters boolean not null default false;
update public.courses c set uses_chapters = true
 where exists (select 1 from public.course_chapters ch where ch.course_id = c.id);
