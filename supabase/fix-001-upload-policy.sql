-- Fix 1 (2026-11-19): the upload rule compared the folder with events.name instead of
-- the uploaded file's path, so every upload was refused. Run once in the EventSnap SQL Editor.
drop policy if exists photos_upload_active_event on storage.objects;
create policy photos_upload_active_event on storage.objects
  for insert to anon
  with check (
    bucket_id = 'photos'
    and exists (
      select 1 from public.events e
      where e.active and now() <= e.uploads_until
        and e.code = (storage.foldername(objects.name))[1]
    )
  );
