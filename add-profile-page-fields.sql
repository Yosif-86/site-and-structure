-- Adds the fields the new mobile-app Profile page needs: a short public_id
-- for admin to search by, avatar/bio/social-username fields shared by every
-- user (teacher or student -- the existing teacher_bio/teacher_photo_url
-- stay separate, unrelated to this and still used by the teacher-facing
-- course card), and a public avatars storage bucket.

alter table profiles add column if not exists public_id text;
alter table profiles add column if not exists avatar_url text;
alter table profiles add column if not exists bio text;
alter table profiles add column if not exists instagram_username text;
alter table profiles add column if not exists telegram_username text;

create unique index if not exists profiles_public_id_key on profiles(public_id) where public_id is not null;

-- 4-digit id, e.g. "0421". Only 10,000 possible values, which is fine at
-- this app's scale -- the retry loop just re-rolls on a collision.
create or replace function public.generate_public_id()
returns text
language plpgsql
as $body$
declare
  candidate text;
  already_taken boolean;
begin
  loop
    candidate := lpad(floor(random() * 10000)::int::text, 4, '0');
    select exists(select 1 from profiles where public_id = candidate) into already_taken;
    exit when not already_taken;
  end loop;
  return candidate;
end;
$body$;

create or replace function public.set_public_id_on_insert()
returns trigger
language plpgsql
as $body$
begin
  if new.public_id is null then
    new.public_id := public.generate_public_id();
  end if;
  return new;
end;
$body$;

drop trigger if exists trg_set_public_id on profiles;
create trigger trg_set_public_id
before insert on profiles
for each row execute function public.set_public_id_on_insert();

-- Backfill every existing account so admin can search by id immediately,
-- not just for new signups going forward.
update profiles set public_id = public.generate_public_id() where public_id is null;

-- public_id is system-generated only (not in this grant, same reasoning as
-- id/is_admin/active_session_token in the earlier column-grants migration).
grant update (avatar_url, bio, instagram_username, telegram_username) on public.profiles to authenticated;

-- ============================================================
-- Public bucket for profile photos, same shape as payment-qr: readable by
-- anyone, writable only in the owning user's own folder.
-- ============================================================
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

drop policy if exists "Anyone can view avatars" on storage.objects;
create policy "Anyone can view avatars"
  on storage.objects for select
  using (bucket_id = 'avatars');

drop policy if exists "Users can upload own avatar" on storage.objects;
create policy "Users can upload own avatar"
  on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
    and lower(storage.extension(name)) in ('png', 'jpg', 'jpeg', 'webp')
  );

drop policy if exists "Users can replace own avatar" on storage.objects;
create policy "Users can replace own avatar"
  on storage.objects for update
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Users can delete own avatar" on storage.objects;
create policy "Users can delete own avatar"
  on storage.objects for delete
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Admins manage all avatars" on storage.objects;
create policy "Admins manage all avatars"
  on storage.objects for all
  using (bucket_id = 'avatars' and public.is_admin())
  with check (bucket_id = 'avatars' and public.is_admin());

-- Verify: every profile should now have a 4-char public_id.
select count(*) as total, count(public_id) as with_public_id from profiles;
