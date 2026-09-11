-- Teacher invite links, phase 1d: let a logged-out visitor check an
-- invite's validity BEFORE filling out the signup form.
--
-- Found live: the signup modal auto-opened from ?invite=<token> purely
-- based on the URL parameter existing — no DB check at all. So a revoked
-- or expired link looked exactly like a valid one right up until signup
-- completed, when redeem_teacher_invite() silently failed to grant teacher
-- status (by design — a dead invite must never block account creation).
-- That's correct end-state behavior, but confusing UX: revoking a link
-- looked like it did nothing.
--
-- teacher_invites itself has no anon/authenticated grant at all (admin/
-- service-role only), so a logged-out visitor can't just query it
-- directly. This function is the narrow, safe exception: it answers only
-- "is this exact token still good" (boolean), never anything else about
-- the table (which teachers exist, how many invites, other tokens, etc).

create or replace function public.is_teacher_invite_valid(p_token text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from teacher_invites
    where token = p_token and used_at is null and expires_at > now()
  );
$$;

revoke all on function public.is_teacher_invite_valid(text) from public;
grant execute on function public.is_teacher_invite_valid(text) to anon, authenticated;
