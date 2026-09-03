-- New table backing resume-position and lesson-completion, used by
-- mobile_app/lib/screens/video_player_screen.dart. A student can only ever
-- read/write their own rows (own progress data, nothing about other users).

create table if not exists lesson_progress (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  lecture_id uuid not null references lectures(id) on delete cascade,
  position_seconds integer not null default 0,
  duration_seconds integer,
  completed boolean not null default false,
  updated_at timestamptz not null default now(),
  unique (user_id, lecture_id)
);

alter table lesson_progress enable row level security;

drop policy if exists "Users can view own progress" on lesson_progress;
create policy "Users can view own progress"
  on lesson_progress for select
  using (user_id = auth.uid());

drop policy if exists "Users can upsert own progress" on lesson_progress;
create policy "Users can insert own progress"
  on lesson_progress for insert
  with check (user_id = auth.uid());

drop policy if exists "Users can update own progress" on lesson_progress;
create policy "Users can update own progress"
  on lesson_progress for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select, insert, update on lesson_progress to authenticated;
