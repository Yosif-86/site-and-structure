-- Bunny Stream support has been fully removed from the app (teacher.html,
-- admin.html, api/get-video-url.js, the mobile app, and the CSP now only
-- know about R2/HLS). One real lecture ("Full course video" in "Graduation
-- Project Making") was still on Bunny with no R2 copy -- by Yosif's
-- decision that lecture is left non-playable rather than migrated, so
-- dropping this column is safe to do now.

alter table lectures drop column if exists bunny_video_id;
