-- Security/perf hardening pass, part 1: indexes on the columns every RLS
-- policy and every hot query in this repo filters or joins on. Missing
-- indexes here aren't a security hole by themselves, but every RLS check
-- re-runs its `using`/`with check` clause per row, so an un-indexed
-- user_id/lookup column turns "show my enrollments" into a full table scan
-- under RLS as the tables grow — which is also how an attacker gets cheap
-- leverage for a DoS via a normal-looking authenticated request.
--
-- Run in the Supabase SQL editor. All guarded with IF NOT EXISTS, safe to
-- run more than once.

-- trusted_devices: every check-device.js call does
--   .eq('user_id', userId).eq('device_id', deviceId)  and  .eq('user_id', userId)
create index if not exists idx_trusted_devices_user_id
  on trusted_devices (user_id);
create index if not exists idx_trusted_devices_user_device
  on trusted_devices (user_id, device_id);

-- enrollments: RLS policies filter by user_id; get-video-url.js and
-- admin.html both filter/join by user_id + course_slug + status.
create index if not exists idx_enrollments_user_id
  on enrollments (user_id);
create index if not exists idx_enrollments_user_course_status
  on enrollments (user_id, course_slug, status);
create index if not exists idx_enrollments_course_slug
  on enrollments (course_slug);

-- lectures: get-video-url.js looks up by id (already the primary key) and
-- filters by course_id when listing a course's lectures.
create index if not exists idx_lectures_course_id
  on lectures (course_id);

-- courses: looked up by slug everywhere (course.html, get-video-url.js).
create unique index if not exists idx_courses_slug
  on courses (slug);

-- login_events: admin.html's flagged-logins view filters on `flagged` and
-- orders by created_at; logLoginEvent looks up a user's most recent
-- lat/lon row.
create index if not exists idx_login_events_user_created
  on login_events (user_id, created_at desc);
create index if not exists idx_login_events_flagged_created
  on login_events (created_at desc)
  where flagged = true;

-- lesson_progress already gets an index for free from its
-- `unique (user_id, lecture_id)` constraint — nothing to add there.
