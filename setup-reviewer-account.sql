-- Turns an existing account into the store-review account.
-- 1. First create the account normally in the app (sign up), e.g.
--    arc.iq6+review@gmail.com (sign-up accepts only well-known email providers),
--    with a strong password.
-- 2. Put that email below, then run this in the Supabase SQL editor.
-- Needs add-reviewer-and-reports.sql.

update public.profiles p
   set is_reviewer = true,
       max_devices = 5,          -- reviewers test on several devices
       phone_verified = true     -- no SMS code needed
  from auth.users u
 where u.id = p.id
   and u.email = 'arc.iq6+review@gmail.com';   -- <-- the review account's email

-- Check: should show the account with is_reviewer = true.
select u.email, p.is_reviewer, p.max_devices, p.phone_verified
  from public.profiles p join auth.users u on u.id = p.id
 where p.is_reviewer;
