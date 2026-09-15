-- Lets teachers set a course's stage/level/tag from teacher.html (level and
-- tag_label columns already existed but had no UI anywhere; stage is new).
-- Also adds duration_seconds on lectures so course cards can show total
-- runtime and lecture count automatically instead of requiring hand-typed
-- meta JSON for those two numbers.

alter table courses add column if not exists stage text;
alter table lectures add column if not exists duration_seconds integer;
