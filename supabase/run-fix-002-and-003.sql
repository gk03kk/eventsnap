-- EventSnap: fix-002 + fix-003 together. Run in the EventSnap project (fllarkkdiklmvxxclmuy) only.

-- Fix 2 (2026-11-20): guests can remove their own photos.
-- When a photo is shared, the guest's phone makes a secret "delete token" and keeps it.
-- The token is saved with the photo but guests can never read it back (no select grant),
-- so only the phone that shared a photo can remove it. Run once in the EventSnap SQL Editor.

alter table public.photos add column if not exists delete_token uuid;

-- The phone chooses the photo id (it is also the file name) and the delete token.
grant insert (id, delete_token) on public.photos to anon;

create or replace function public.delete_my_photo(p_photo_id uuid, p_token uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed integer;
begin
  update public.photos
     set hidden = true
   where id = p_photo_id
     and delete_token is not null
     and delete_token = p_token
     and not hidden;
  get diagnostics changed = row_count;
  return changed > 0;
end;
$$;
revoke execute on function public.delete_my_photo(uuid, uuid) from public;
grant execute on function public.delete_my_photo(uuid, uuid) to anon;

-- Fix 3 (2026-11-20): the host can delete a photo for good (row + both files) with the PIN.
-- Supabase only allows files to be deleted through its Storage service, so it works in two steps:
--   1. host_delete_photo(id, PIN) checks the PIN, deletes the photo's row and allows just
--      that photo's two files to be deleted for the next 5 minutes;
--   2. the host page then deletes those two files through Storage.
-- Run once in the EventSnap SQL Editor.

-- Files the host has just allowed to be deleted (guests cannot read or change this table).
create table if not exists public.photo_deletions (
  path       text primary key,
  expires_at timestamptz not null
);
alter table public.photo_deletions enable row level security;
revoke all on public.photo_deletions from anon, authenticated;

-- Used by the storage policies below (they run as the guest, who cannot read the table).
create or replace function public.photo_delete_allowed(p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.photo_deletions d
    where d.path = p_path and d.expires_at > now()
  );
$$;
revoke execute on function public.photo_delete_allowed(text) from public;
grant execute on function public.photo_delete_allowed(text) to anon;

create or replace function public.host_delete_photo(p_photo_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_path  text;
  v_thumb text;
begin
  delete from public.photos p
   using public.events e
   where p.id = p_photo_id
     and e.code = p.event_code
     and e.host_pin = p_pin
  returning p.path, p.thumb_path into v_path, v_thumb;

  if v_path is null then
    return null;  -- wrong PIN or no such photo
  end if;

  delete from public.photo_deletions where expires_at < now();
  insert into public.photo_deletions (path, expires_at)
  select x, now() + interval '5 minutes'
    from unnest(array[v_path, v_thumb]) as x
   where x is not null
  on conflict (path) do update set expires_at = excluded.expires_at;

  return jsonb_build_object('path', v_path, 'thumb_path', v_thumb);
end;
$$;
revoke execute on function public.host_delete_photo(uuid, text) from public;
grant execute on function public.host_delete_photo(uuid, text) to anon;

-- Storage needs to find a file (select) before deleting it; both only for allowed files.
drop policy if exists photos_select_for_delete on storage.objects;
create policy photos_select_for_delete on storage.objects
  for select to anon
  using (bucket_id = 'photos' and public.photo_delete_allowed(objects.name));

drop policy if exists photos_delete_allowed on storage.objects;
create policy photos_delete_allowed on storage.objects
  for delete to anon
  using (bucket_id = 'photos' and public.photo_delete_allowed(objects.name));

notify pgrst, 'reload schema';

-- Check: should list delete_my_photo, host_delete_photo, delete_token
select proname as found from pg_proc where proname in ('delete_my_photo','host_delete_photo') union all select column_name from information_schema.columns where table_name = 'photos' and column_name = 'delete_token';
