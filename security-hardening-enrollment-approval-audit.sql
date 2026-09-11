-- Security hardening pass, part 5: audit trail on enrollment approvals.
--
-- Payment verification here is a human looking at a screenshot and clicking
-- Approve — there's no payment processor to fall back on for a record of
-- what happened. Right now approve() just flips `status` to 'active' with
-- no record of which admin did it or when, so a disputed/mistaken approval
-- has nothing to point to.
--
-- enrollments.updated_at already exists in the codebase, but nothing writes
-- it on approval and it wouldn't say *who* approved it anyway. Two dedicated
-- columns are simpler than trying to repurpose that one.

alter table enrollments add column if not exists approved_by uuid references auth.users(id);
alter table enrollments add column if not exists approved_at timestamptz;

-- No RLS change needed: enrollments-rls-policy.sql already restricts UPDATE
-- to public.is_admin() with no column restriction, so only an admin session
-- can set these anyway (same trust boundary as status itself).
