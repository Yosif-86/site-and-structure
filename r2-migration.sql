-- Run in Supabase SQL editor. Adds the column get-video-url.js checks to decide
-- whether a lecture is served from the new R2/HLS pipeline or the existing Bunny one.
alter table lectures add column if not exists r2_path text;

-- After uploading a lecture's HLS folder with scripts/upload-to-r2.sh (which prints
-- the remote prefix, e.g. "videos/<lectureId>"), point that lecture at it:
-- update lectures set r2_path = 'videos/<lectureId>' where id = '<lectureId>';
-- Leave r2_path null for lectures that should keep playing from Bunny.
