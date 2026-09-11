-- Teacher role schema, phase 1c: public bucket for course thumbnail uploads.
-- courses.thumbnail_url is a plain text URL today (set by hand for Yosif's
-- own courses) — teachers need somewhere to actually upload an image to get
-- one. Unlike payment-proofs/lecture-uploads, this bucket is PUBLIC read
-- (thumbnails must be visible to anyone browsing the catalogue, logged in
-- or not) but still scoped so only the owning teacher can write to their
-- own folder.

insert into storage.buckets (id, name, public)
values ('course-thumbnails', 'course-thumbnails', true)
on conflict (id) do nothing;

drop policy if exists "Anyone can view course thumbnails" on storage.objects;
create policy "Anyone can view course thumbnails"
  on storage.objects for select
  using (bucket_id = 'course-thumbnails');

-- Path convention: `${teacherId}/${courseId or timestamp}-${filename}`.
drop policy if exists "Teachers can upload own course thumbnails" on storage.objects;
create policy "Teachers can upload own course thumbnails"
  on storage.objects for insert
  with check (
    bucket_id = 'course-thumbnails'
    and (storage.foldername(name))[1] = auth.uid()::text
    and lower(storage.extension(name)) in ('png', 'jpg', 'jpeg', 'webp')
  );

drop policy if exists "Teachers can replace own course thumbnails" on storage.objects;
create policy "Teachers can replace own course thumbnails"
  on storage.objects for update
  using (bucket_id = 'course-thumbnails' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'course-thumbnails' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Teachers can delete own course thumbnails" on storage.objects;
create policy "Teachers can delete own course thumbnails"
  on storage.objects for delete
  using (bucket_id = 'course-thumbnails' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Admins manage all course thumbnails" on storage.objects;
create policy "Admins manage all course thumbnails"
  on storage.objects for all
  using (bucket_id = 'course-thumbnails' and public.is_admin())
  with check (bucket_id = 'course-thumbnails' and public.is_admin());
