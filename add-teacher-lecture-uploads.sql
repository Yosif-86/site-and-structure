-- Teacher role schema, phase 1b: lecture video uploads.
--
-- Video playback only works for two sources today (get-video-url.js):
-- Bunny Stream (bunny_video_id) or Cloudflare R2 + HLS (r2_path), both of
-- which need Yosif to run the transcode-to-hls script and upload-to-r2
-- script by hand — there's no automated pipeline a browser upload can
-- trigger. Rather than build that now, a teacher's uploaded video sits as
-- "pending" (this column set, bunny_video_id/r2_path both still null) until
-- Yosif processes it manually and fills in one of those two columns himself
-- — at which point the lecture is live exactly like any other.

alter table lectures add column if not exists pending_upload_path text;

-- Private bucket (public: false — no bucket-URL access, only via a signed
-- URL or these RLS-gated policies below).
insert into storage.buckets (id, name, public)
values ('lecture-uploads', 'lecture-uploads', false)
on conflict (id) do nothing;

-- Path convention: `${teacherId}/${courseId}/${timestamp}-${filename}` —
-- same shape as payment-proofs, so the same foldername()[1]=auth.uid()
-- check scopes a teacher to their own uploads.
drop policy if exists "Teachers can upload own pending lecture videos" on storage.objects;
create policy "Teachers can upload own pending lecture videos"
  on storage.objects for insert
  with check (
    bucket_id = 'lecture-uploads'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Teachers can view own pending lecture videos" on storage.objects;
create policy "Teachers can view own pending lecture videos"
  on storage.objects for select
  using (
    bucket_id = 'lecture-uploads'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- You need to fetch these to actually process them.
drop policy if exists "Admins can view all pending lecture videos" on storage.objects;
create policy "Admins can view all pending lecture videos"
  on storage.objects for select
  using (
    bucket_id = 'lecture-uploads'
    and public.is_admin()
  );

-- Once you've pulled a file down and processed it, delete the raw upload —
-- no reason to keep a second copy of the source video sitting in Supabase
-- storage on top of what's now in R2/Bunny.
drop policy if exists "Admins can delete processed lecture videos" on storage.objects;
create policy "Admins can delete processed lecture videos"
  on storage.objects for delete
  using (
    bucket_id = 'lecture-uploads'
    and public.is_admin()
  );
