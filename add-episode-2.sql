-- Adds "Episode 2" as a new lecture on the grad-project course, pointing at
-- the HLS folder just uploaded to videos/grad-project-ep2. Assumed title
-- "Episode 2" — edit the title/title_ar below if you want something else.
insert into lectures (course_id, title, title_ar, r2_path, is_free, order_index)
select
  id,
  'Episode 2',
  null,
  'videos/grad-project-ep2',
  false,  -- locked unless the student has an active enrollment; change to true for a free-preview lecture
  (select coalesce(max(order_index), -1) + 1 from lectures where course_id = courses.id)
from courses
where slug = 'grad-project';
