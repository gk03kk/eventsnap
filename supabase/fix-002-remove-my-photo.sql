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
