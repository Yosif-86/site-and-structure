-- Lets a teacher edit a course that's already published without the change
-- going live immediately. The RLS policy from add-teacher-role-schema.sql
-- blocks a teacher from updating a published course row at all (with check
-- requires status in draft/pending_review), which is why the Edit button
-- effectively stopped working once a course went live -- that was by design
-- back then, this migration replaces it with a real edit-request flow
-- instead of just opening the row back up.
--
-- Proposed changes are staged in courses.pending_edit (jsonb) with
-- edit_status = 'pending_review'. The live course fields are untouched
-- until an admin approves the request (merges pending_edit onto the row) or
-- rejects it (discards pending_edit). Enforced at the DB level, not just
-- hidden in the UI, same as every other admin-only gate in this schema.

alter table courses add column if not exists pending_edit jsonb;
alter table courses add column if not exists edit_status text;

-- Allow the update to go through when status stays 'published' (previously
-- impossible for a teacher at all) -- the trigger below is what actually
-- restricts what changes, not this policy.
drop policy if exists "Teachers can update own courses" on courses;
create policy "Teachers can update own courses"
  on courses for update
  using (teacher_id = auth.uid())
  with check (
    teacher_id = auth.uid()
    and status in ('draft', 'pending_review', 'published')
  );

-- For a published course being updated by its own (non-admin) teacher, only
-- pending_edit/edit_status may actually change -- every other column snaps
-- back to its old value. Admins are untouched by this (they edit courses
-- directly via the admin dashboard, unstaged).
create or replace function public.enforce_course_edit_via_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_admin() then
    return new;
  end if;
  if old.status = 'published' then
    new.title := old.title;
    new.description := old.description;
    new.price := old.price;
    new.is_free := old.is_free;
    new.thumbnail_url := old.thumbnail_url;
    new.teacher_name := old.teacher_name;
    new.stage := old.stage;
    new.level := old.level;
    new.tag_label := old.tag_label;
    new.status := old.status;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_course_edit_via_request on courses;
create trigger trg_enforce_course_edit_via_request
  before update on courses
  for each row
  execute function public.enforce_course_edit_via_request();
