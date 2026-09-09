-- Every course row was bulk-seeded with the exact same created_at, so
-- ordering the catalogue by created_at (as both the website and the mobile
-- app did) was never actually deterministic — ties fall back to whatever
-- unspecified order Postgres happens to return, which is why "Graduation
-- Project Making" appeared first for a while, then silently moved to last
-- the moment the client's sort direction changed. order_index is the real,
-- explicit display order — grad-project first as the flagship free-course
-- funnel, the rest in whatever order they were previously showing in.
alter table courses add column if not exists order_index integer not null default 0;

update courses set order_index = 0 where slug = 'grad-project';
update courses set order_index = 1 where slug = 'foundation';
update courses set order_index = 2 where slug = 'bridge';
update courses set order_index = 3 where slug = 'rc';
update courses set order_index = 4 where slug = 'autocad';
update courses set order_index = 5 where slug = 'qs';
update courses set order_index = 6 where slug = 'steel';
