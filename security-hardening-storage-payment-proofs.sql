-- Security/perf hardening pass, part 2: RLS policies for the `payment-proofs`
-- storage bucket.
--
-- schema-rls-audit.sql (step 4) only *checks* whether this bucket is private
-- and what policies exist on storage.objects — it doesn't create anything.
-- Nothing else in this repo does either. That means this was an open
-- question, not a confirmed-safe state: if the bucket has RLS enabled on
-- storage.objects (Supabase's default) with no policy for this bucket, every
-- request is denied (uploads/admin review silently break); if a broad grant
-- exists instead, any authenticated user could read or overwrite anyone
-- else's payment screenshot by guessing/enumerating another user's storage
-- path. Run STEP 1 first to see which of those you're actually in before
-- applying STEP 2.
--
-- Upload path shape used by course.html's submitPay(): `${user.id}/${Date.now()}-${filename}`
-- so the top-level "folder" of every object is the uploading user's own uid.

-- ============================================================
-- STEP 1 — diagnose current state (same queries as schema-rls-audit.sql #4)
-- ============================================================
select id, name, public from storage.buckets where id = 'payment-proofs';

select policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'storage' and tablename = 'objects' and qual ilike '%payment-proofs%';

-- ============================================================
-- STEP 2 — fix: a user can only upload/read their own proof screenshots;
-- admins can read every proof (admin.html's "view proof" button, which signs
-- a URL via sb.storage.from('payment-proofs').createSignedUrl).
-- Nobody gets update/delete — a submitted proof is evidence and shouldn't be
-- silently replaceable after submission.
-- ============================================================

-- course.html's <input type="file" accept="image/*"> is a client-side hint
-- only — nothing stops a direct API call from uploading an .html/.svg/.exe
-- under a legitimate-looking name straight into storage. Restrict by file
-- extension here since that's what a `with check` can see cheaply; it's not
-- as strong as a real content-type/magic-byte check but blocks the obvious
-- abuse (uploading an executable or an HTML file an admin might later open
-- directly from a signed URL).
drop policy if exists "Users can upload own payment proof" on storage.objects;
create policy "Users can upload own payment proof"
  on storage.objects for insert
  with check (
    bucket_id = 'payment-proofs'
    and (storage.foldername(name))[1] = auth.uid()::text
    and lower(storage.extension(name)) in ('png', 'jpg', 'jpeg', 'webp', 'heic', 'pdf')
  );

drop policy if exists "Users can view own payment proof" on storage.objects;
create policy "Users can view own payment proof"
  on storage.objects for select
  using (
    bucket_id = 'payment-proofs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Admins can view all payment proofs" on storage.objects;
create policy "Admins can view all payment proofs"
  on storage.objects for select
  using (
    bucket_id = 'payment-proofs'
    and public.is_admin()
  );

-- Confirm the bucket itself is private (not publicly readable by URL alone).
-- If this returns public = true, flip it in the Supabase dashboard
-- (Storage -> payment-proofs -> ... -> Make private), since a public bucket
-- would let anyone with a guessed/leaked path view a payment screenshot
-- regardless of the policies above.
select id, public from storage.buckets where id = 'payment-proofs';
