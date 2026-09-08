-- The existing lecture row still points at the old, unencrypted upload
-- (videos/test-lecture-1). Today's AES-128 re-encrypted video was uploaded
-- to videos/grad-project instead — this was my mistake, I assumed the path
-- without checking the database first. This repoints the row at the actual
-- encrypted content.
update lectures
set r2_path = 'videos/grad-project'
where r2_path = 'videos/test-lecture-1';
