-- Teacher role + multi-teacher course workflow, phase 1 (schema + RLS).
-- Matches the plan discussed: is_teacher flag (not a separate account type),
-- courses owned by a teacher and gated behind admin review before going
-- live, single-use/time-limited teacher invite links, per-course discount
-- codes (teacher-defined expiry + use cap, stoppable early, redeemable by
-- up to that many different students), and a public-safe view of teacher
-- profile info that never exposes their private payment details.
--
-- Run this whole file in the Supabase SQL editor. Idempotent (create-or-
-- replace / if-not-exists throughout) — safe to re-run.

-- ============================================================
-- 1. Teacher role + profile fields
-- ============================================================
-- is_teacher mirrors is_admin: a flag on the existing profiles row, not a
-- separate account type — a teacher is still a normal student account with
-- one extra capability. It automatically inherits the same lockdown as
-- is_admin from security-hardening-profiles-column-grants.sql (authenticated
-- can only ever write full_name/phone on their own row), so there's nothing
-- extra to revoke here for it to stay admin/service-role-only.
alter table profiles add column if not exists is_teacher boolean not null default false;

-- Public teacher-facing fields (bio/specialty/photo) vs. a private payment
-- destination that must NEVER be readable by other users — see the view in
-- section 2 for how these are exposed safely.
alter table profiles add column if not exists teacher_bio text;
alter table profiles add column if not exists teacher_specialty text;
alter table profiles add column if not exists teacher_photo_url text;
alter table profiles add column if not exists teacher_payment_method text;
alter table profiles add column if not exists teacher_payment_detail text;

-- Let a teacher edit their own public + payment fields (full_name/phone were
-- already granted in security-hardening-profiles-column-grants.sql; this
-- adds the new ones to that same allowlist, still nowhere near is_admin/
-- is_teacher/active_session_token/id).
grant update (teacher_bio, teacher_specialty, teacher_photo_url, teacher_payment_method, teacher_payment_detail)
  on public.profiles to authenticated;

-- ============================================================
-- 2. Public-safe teacher profile view
-- ============================================================
-- profiles' own RLS only lets you read your own row (or every row, if
-- you're admin) — there is deliberately no "anyone can read anyone's
-- profile" policy, because that would also expose teacher_payment_detail.
-- This view exposes only the fields that are safe to show to any visitor
-- browsing courses, backed by its own grant instead of relying on the base
-- table's policies.
create or replace view public.teacher_public_profiles
  with (security_invoker = false) as
select id, full_name, teacher_bio, teacher_specialty, teacher_photo_url
from public.profiles
where is_teacher = true;

grant select on public.teacher_public_profiles to anon, authenticated;

-- ============================================================
-- 3. Courses: ownership + review workflow
-- ============================================================
alter table courses add column if not exists teacher_id uuid references profiles(id);
-- When true, this course's payments should go to the teacher's own
-- payment_method/detail above instead of your default Zain/Qi numbers.
-- Enforced by app logic at the payment-instructions step, not by RLS.
alter table courses add column if not exists pay_to_teacher boolean not null default false;

-- Free-text status column had no constraint before; pin the three valid
-- values now that there's a third one, so a typo can't silently create an
-- unreachable status.
alter table courses drop constraint if exists courses_status_check;
alter table courses add constraint courses_status_check
  check (status in ('draft', 'pending_review', 'published'));

drop policy if exists "Teachers can insert own courses" on courses;
create policy "Teachers can insert own courses"
  on courses for insert
  with check (
    teacher_id = auth.uid()
    and (select is_teacher from profiles where id = auth.uid()) = true
    -- A teacher can only ever create a course as a draft — pending_review
    -- and published both require a separate, later transition (see the
    -- update policy below), never set directly at creation.
    and status = 'draft'
  );

drop policy if exists "Teachers can view own courses" on courses;
create policy "Teachers can view own courses"
  on courses for select
  using (teacher_id = auth.uid());

drop policy if exists "Teachers can update own courses" on courses;
create policy "Teachers can update own courses"
  on courses for update
  using (teacher_id = auth.uid())
  with check (
    teacher_id = auth.uid()
    -- A teacher can move draft -> pending_review (submit for review) or
    -- edit while still in draft/pending_review, but can never write
    -- 'published' themselves — that transition is admin-only, via the
    -- separate admin policy below which has no such restriction.
    and status in ('draft', 'pending_review')
  );

drop policy if exists "Teachers can delete own courses" on courses;
create policy "Teachers can delete own courses"
  on courses for delete
  using (teacher_id = auth.uid());

drop policy if exists "Admins can view all courses" on courses;
create policy "Admins can view all courses"
  on courses for select
  using (public.is_admin());

-- You creating a course directly (not as a flagged teacher) still needs its
-- own insert path — the teacher policy above requires is_teacher=true and
-- status='draft', neither of which should constrain an admin.
drop policy if exists "Admins can insert any course" on courses;
create policy "Admins can insert any course"
  on courses for insert
  with check (public.is_admin());

drop policy if exists "Admins can update any course" on courses;
create policy "Admins can update any course"
  on courses for update
  using (public.is_admin())
  with check (public.is_admin());

-- Public catalogue browsing (anon + logged-in students) — unchanged in
-- effect from today, just made an explicit policy instead of relying on
-- courses having no RLS at all.
drop policy if exists "Anyone can view published courses" on courses;
create policy "Anyone can view published courses"
  on courses for select
  using (status = 'published');

alter table courses enable row level security;
grant select, insert, update, delete on courses to authenticated;
grant select on courses to anon;

-- ============================================================
-- 4. Lectures: teacher-owned courses need lecture management too
-- ============================================================
alter table lectures add column if not exists thumbnail_url text;

drop policy if exists "Teachers can manage own course lectures" on lectures;
create policy "Teachers can manage own course lectures"
  on lectures for all
  using (exists (select 1 from courses where courses.id = lectures.course_id and courses.teacher_id = auth.uid()))
  with check (exists (select 1 from courses where courses.id = lectures.course_id and courses.teacher_id = auth.uid()));

drop policy if exists "Admins can manage all lectures" on lectures;
create policy "Admins can manage all lectures"
  on lectures for all
  using (public.is_admin())
  with check (public.is_admin());

alter table lectures enable row level security;
grant select, insert, update, delete on lectures to authenticated;
grant select on lectures to anon;

-- ============================================================
-- 5. Teacher invite links: single-use, time-limited
-- ============================================================
-- Redemption must NOT be a plain client-side update (a user could just mark
-- their own invite used, or reuse someone else's) — it has to go through a
-- server path that checks token + expiry + not-already-used and sets
-- is_teacher=true atomically. redeem_teacher_invite() below is that path;
-- application code should call it via .rpc(), never update this table
-- directly except as admin.
create table if not exists teacher_invites (
  id uuid primary key default gen_random_uuid(),
  token text not null unique,
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by uuid references profiles(id)
);

drop policy if exists "Admins manage teacher invites" on teacher_invites;
create policy "Admins manage teacher invites"
  on teacher_invites for all
  using (public.is_admin())
  with check (public.is_admin());

alter table teacher_invites enable row level security;
grant select, insert, update, delete on teacher_invites to authenticated;

-- SECURITY DEFINER so a non-admin caller (the invitee, signing up) can
-- redeem their own invite without needing direct table grants that would
-- otherwise let anyone read/guess other tokens. Single UPDATE with
-- `where used_at is null and expires_at > now()` is itself the atomic
-- single-use check — no advisory lock needed, same reasoning as
-- claim_device_slot but simpler since this is one row, not a count.
create or replace function public.redeem_teacher_invite(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  update teacher_invites
  set used_at = now(), used_by = auth.uid()
  where token = p_token and used_at is null and expires_at > now()
  returning id into v_id;

  if v_id is null then
    return false;
  end if;

  update profiles set is_teacher = true where id = auth.uid();
  return true;
end;
$$;

revoke all on function public.redeem_teacher_invite(text) from public, anon;
grant execute on function public.redeem_teacher_invite(text) to authenticated;

-- ============================================================
-- 6. Discount codes: per-course, teacher-defined expiry + use cap,
--    redeemable by up to max_uses different students, teacher can stop
--    one early regardless of how much of the limit is left.
-- ============================================================
create table if not exists discount_codes (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references courses(id) on delete cascade,
  -- Unique per course, not globally — two different teachers (or the same
  -- teacher on two different courses) should each be free to use a simple
  -- code like "SAVE20" independently.
  code text not null,
  discount_type text not null check (discount_type in ('percent', 'fixed')),
  discount_value numeric not null check (discount_value > 0),
  max_uses integer not null check (max_uses > 0),
  used_count integer not null default 0,
  expires_at timestamptz not null,
  -- Lets the teacher stop a code early even if it still has uses left and
  -- hasn't expired yet — a plain UPDATE via their own "manage own codes"
  -- policy below, no separate mechanism needed since they already trust-
  -- fully own every column on their own row.
  is_active boolean not null default true,
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  unique (course_id, code)
);

-- One row per (code, student) that actually redeemed it — lets the same
-- code be used by up to max_uses different students while still stopping
-- any one student from redeeming the same code twice.
create table if not exists discount_code_redemptions (
  id uuid primary key default gen_random_uuid(),
  discount_code_id uuid not null references discount_codes(id) on delete cascade,
  user_id uuid not null references profiles(id),
  redeemed_at timestamptz not null default now(),
  unique (discount_code_id, user_id)
);

drop policy if exists "Teachers manage own course discount codes" on discount_codes;
create policy "Teachers manage own course discount codes"
  on discount_codes for all
  using (exists (select 1 from courses where courses.id = discount_codes.course_id and courses.teacher_id = auth.uid()))
  with check (exists (select 1 from courses where courses.id = discount_codes.course_id and courses.teacher_id = auth.uid()));

drop policy if exists "Admins manage all discount codes" on discount_codes;
create policy "Admins manage all discount codes"
  on discount_codes for all
  using (public.is_admin())
  with check (public.is_admin());

alter table discount_codes enable row level security;
-- No SELECT/UPDATE grant to plain authenticated users here at all — a
-- student never needs direct table access to use a code, since
-- redeem_discount_code() below (security definer) does the validity check
-- and the discount lookup in one call and returns the result. Keeping the
-- table itself teacher/admin-only means there's no surface for a student
-- to enumerate codes, see how many uses are left, or race the is_active
-- flag some other way.
grant select, insert, update, delete on discount_codes to authenticated;

drop policy if exists "Teachers view own course code redemptions" on discount_code_redemptions;
create policy "Teachers view own course code redemptions"
  on discount_code_redemptions for select
  using (exists (
    select 1 from discount_codes dc
    join courses c on c.id = dc.course_id
    where dc.id = discount_code_redemptions.discount_code_id and c.teacher_id = auth.uid()
  ));

drop policy if exists "Admins view all code redemptions" on discount_code_redemptions;
create policy "Admins view all code redemptions"
  on discount_code_redemptions for select
  using (public.is_admin());

alter table discount_code_redemptions enable row level security;
-- Only SELECT is granted — rows are only ever written by the security-
-- definer function below, never directly by a teacher or student.
grant select on discount_code_redemptions to authenticated;

-- SECURITY DEFINER: validates and applies a code in one call so a student
-- never needs direct table access. Order matters for correctness:
--   1. Insert into discount_code_redemptions first — its unique(discount_
--      code_id, user_id) constraint is what atomically stops the same
--      student redeeming the same code twice (concurrent double-clicks
--      included). If this fails, we're done: already used, nothing else
--      to touch.
--   2. Only then do the atomic conditional UPDATE that increments
--      used_count — its WHERE clause (is_active, not expired, under the
--      cap) is what a concurrent flood of *different* students racing the
--      last remaining use can't both pass, since Postgres evaluates a row's
--      WHERE match and takes its lock together.
--   3. If step 2's WHERE didn't match (code went inactive/expired/hit its
--      cap between the student loading the page and clicking apply), undo
--      the redemption row from step 1 so it isn't left stranded, and
--      report failure.
-- discount_type/discount_value are only ever read here, never part of any
-- SET list, so there's nothing for a caller to smuggle a change into.
create or replace function public.redeem_discount_code(p_code text, p_course_id uuid)
returns table (discount_type text, discount_value numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code_id uuid;
  v_type text;
  v_value numeric;
  v_claimed boolean;
begin
  select id, discount_codes.discount_type, discount_codes.discount_value
    into v_code_id, v_type, v_value
  from discount_codes
  where code = p_code and course_id = p_course_id;

  if v_code_id is null then
    return; -- no such code for this course
  end if;

  begin
    insert into discount_code_redemptions (discount_code_id, user_id) values (v_code_id, auth.uid());
  exception when unique_violation then
    return; -- this student already used this code
  end;

  update discount_codes
  set used_count = used_count + 1
  where id = v_code_id and is_active = true and expires_at > now() and used_count < max_uses
  returning true into v_claimed;

  if v_claimed is not true then
    delete from discount_code_redemptions where discount_code_id = v_code_id and user_id = auth.uid();
    return; -- inactive, expired, or already at its use cap
  end if;

  return query select v_type, v_value;
end;
$$;

revoke all on function public.redeem_discount_code(text, uuid) from public, anon;
grant execute on function public.redeem_discount_code(text, uuid) to authenticated;

-- ============================================================
-- 7. Indexes on the new lookup columns
-- ============================================================
create index if not exists idx_courses_teacher_id on courses (teacher_id);
create index if not exists idx_discount_codes_course_id on discount_codes (course_id);
create index if not exists idx_discount_code_redemptions_code_id on discount_code_redemptions (discount_code_id);
create index if not exists idx_teacher_invites_token on teacher_invites (token);
