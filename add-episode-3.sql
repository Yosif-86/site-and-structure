-- Adds "Episode 3" as a new lecture on the grad-project course, pointing at
-- the HLS folder just uploaded to videos/grad-project-ep3. Assumed title
-- "Episode 3" — edit it below if you want something else.
insert into lectures (course_id, title, r2_path, is_free, order_index)
select id, 'Episode 3', 'videos/grad-project-ep3', false,
  (select coalesce(max(order_index), -1) + 1 from lectures where course_id = courses.id)
from courses
where slug = 'grad-project';
