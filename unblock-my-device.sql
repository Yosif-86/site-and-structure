-- Immediate unblock: frees up a device slot for one account so you can log in again.
-- Replace the email, run in Supabase SQL editor.
delete from trusted_devices
where user_id = (select id from auth.users where email = 'REPLACE_WITH_YOUR_EMAIL');
