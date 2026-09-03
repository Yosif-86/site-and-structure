-- Closes two gaps found in the security audit:
--
-- 1. admin.html updates `enrollments.status = 'active'` using the ADMIN'S
--    OWN browser session (not a service-role endpoint), so approval security
--    rests entirely on RLS. If the existing UPDATE policy on `enrollments`
--    is missing or lets a student update their own row's `status`, any
--    authenticated user could self-approve a paid course for free by calling
--    supabase.from('enrollments').update({status:'active'}) directly.
--
-- 2. The free-enroll flow (course_detail_screen.dart's free sheet, and
--    course.html's equivalent) inserts `{status: 'active'}` straight from
--    the client for whatever course_slug it's given. If the INSERT policy
--    doesn't independently re-check that the course is actually free, a
--    user could replay that same insert against a PAID course_slug and grant
--    themselves instant access without paying.
--
-- Run steps 1-2 first to see what's actually in place before applying step 3.

-- ============================================================
-- STEP 1 — diagnose: is RLS even on, and what policies exist now?
-- ============================================================
select relname, relrowsecurity as rls_enabled
from pg_class
where relname = 'enrollments';

select policyname, cmd, roles, qual, with_check
from pg_policies
where tablename = 'enrollments';

-- ============================================================
-- STEP 2 — diagnose: can the `authenticated` role write to this table at all
-- outside of RLS (table-level grants are checked before policies)?
-- ============================================================
select grantee, privilege_type
from information_schema.role_table_grants
where table_name = 'enrollments';

-- ============================================================
-- STEP 3 — fix: replace whatever INSERT/UPDATE policies exist with the
-- correct ones. Review this against what step 1/2 showed before running —
-- if you have other policies doing something intentionally different,
-- adjust names below instead of blindly dropping them.
-- ============================================================

alter table enrollments enable row level security;

-- Students may only ever create their own row, and only ever as 'pending' —
-- UNLESS the course itself is free, in which case 'active' is allowed
-- (mirrors the free-enroll UX: instant access, no approval needed).
drop policy if exists "Users can insert own enrollment" on enrollments;
create policy "Users can insert own enrollment"
  on enrollments for insert
  with check (
    user_id = auth.uid()
    and (
      status = 'pending'
      or (
        status = 'active'
        and exists (
          select 1 from courses
          where courses.slug = enrollments.course_slug
          and courses.is_free = true
        )
      )
    )
  );

-- Students may read only their own enrollments.
drop policy if exists "Users can view own enrollments" on enrollments;
create policy "Users can view own enrollments"
  on enrollments for select
  using (user_id = auth.uid());

-- Only admins may change an enrollment's status (i.e. approve a payment).
-- Students have no UPDATE policy at all, so any update attempt on their own
-- row is rejected outright — approval can only happen through admin.html.
drop policy if exists "Admins can update enrollments" on enrollments;
create policy "Admins can update enrollments"
  on enrollments for update
  using (public.is_admin())
  with check (public.is_admin());

-- Admins can also view every enrollment (for the dashboard) and delete one
-- (to let a student re-submit after a rejected payment).
drop policy if exists "Admins can view all enrollments" on enrollments;
create policy "Admins can view all enrollments"
  on enrollments for select
  using (public.is_admin());

drop policy if exists "Admins can delete enrollments" on enrollments;
create policy "Admins can delete enrollments"
  on enrollments for delete
  using (public.is_admin());

grant select, insert on enrollments to authenticated;
grant select, update, delete on enrollments to authenticated;
