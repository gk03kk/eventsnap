-- EventSnap database setup.
-- Run ONCE in a NEW, separate Supabase project (never in jarjoy-kids-prod):
-- Supabase dashboard -> SQL Editor -> paste all of this -> Run.
-- Before running, change the host PIN on the last lines.

-- 1. Events ----------------------------------------------------------------
create table public.events (
  code        text primary key check (code ~ '^[a-z0-9-]{3,40}$'),
  name        text not null check (char_length(name) between 1 and 80),
  active      boolean not null default true,
  max_photos  integer not null default 3000,
  host_pin    text not null check (char_length(host_pin) >= 6),
  -- Guests can upload until uploads_until and see the gallery until view_until.
  uploads_until timestamptz not null,
  view_until    timestamptz not null,
  created_at  timestamptz not null default now(),
  check (view_until >= uploads_until)
);
alter table public.events enable row level security;

-- Guests may read only the public columns of active events (never host_pin).
revoke all on public.events from anon, authenticated;
grant select (code, name, active, uploads_until, view_until) on public.events to anon;
create policy events_read_active on public.events
  for select to anon using (active);

-- 2. Photos ----------------------------------------------------------------
create table public.photos (
  id          uuid primary key default gen_random_uuid(),
  event_code  text not null references public.events(code) on delete cascade,
  path        text not null unique,
  thumb_path  text,
  uploader    text check (uploader is null or char_length(uploader) <= 40),
  hidden      boolean not null default false,
  created_at  timestamptz not null default now()
);
create index photos_event_newest on public.photos (event_code, created_at desc);
alter table public.photos enable row level security;

revoke all on public.photos from anon, authenticated;
grant select (id, event_code, path, thumb_path, uploader, created_at) on public.photos to anon;
grant insert (event_code, path, thumb_path, uploader) on public.photos to anon;

create policy photos_read_visible on public.photos
  for select to anon
  using (not hidden and exists (
    select 1 from public.events e
    where e.code = event_code and e.active and now() <= e.view_until
  ));

create policy photos_insert_active_event on public.photos
  for insert to anon
  with check (
    not hidden
    and path like event_code || '/%'
    and (thumb_path is null or thumb_path like event_code || '/thumbs/%')
    and exists (
      select 1 from public.events e
      where e.code = event_code and e.active and now() <= e.uploads_until
    )
  );

-- Photo limit per event (stops someone filling the storage).
create or replace function public.enforce_photo_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  lim integer;
  cnt integer;
begin
  select max_photos into lim from public.events where code = new.event_code;
  select count(*) into cnt from public.photos where event_code = new.event_code;
  if cnt >= lim then
    raise exception 'photo limit reached for this event';
  end if;
  new.created_at := now();
  new.hidden := false;
  return new;
end;
$$;
revoke execute on function public.enforce_photo_limit() from public, anon, authenticated;
create trigger photos_limit before insert on public.photos
  for each row execute function public.enforce_photo_limit();

-- 3. Host can hide a photo with the event's PIN -----------------------------
create or replace function public.hide_photo(p_photo_id uuid, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed integer;
begin
  update public.photos p
     set hidden = true
    from public.events e
   where p.id = p_photo_id
     and e.code = p.event_code
     and e.host_pin = p_pin;
  get diagnostics changed = row_count;
  return changed > 0;
end;
$$;
revoke execute on function public.hide_photo(uuid, text) from public;
grant execute on function public.hide_photo(uuid, text) to anon;

-- 4. Storage bucket for the photos -----------------------------------------
-- Public read (photos open by link), max 10 MB, images only.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- Guests may only upload into the folder of an active event: photos/<code>/<file>
create policy photos_upload_active_event on storage.objects
  for insert to anon
  with check (
    bucket_id = 'photos'
    and exists (
      select 1 from public.events e
      where e.active and now() <= e.uploads_until
        and e.code = (storage.foldername(objects.name))[1]  -- objects.name: the file path, not events.name
    )
  );

-- 5. The Diwali event ------------------------------------------------------
-- CHANGE the PIN below to your own (at least 6 characters) before running.
-- Uploads open until Sunday 22 Nov 23:59 (Irish time); gallery viewable until 21 Dec 23:59.
insert into public.events (code, name, host_pin, uploads_until, view_until)
values (
  'diwali2026', 'Diwali Night 2026', 'CHANGE-ME-123',
  timestamptz '2026-11-22 23:59:59 Europe/Dublin',
  timestamptz '2026-12-21 23:59:59 Europe/Dublin'
);

-- The windows close by themselves. To change them later:
--   update public.events set uploads_until = timestamptz '2026-11-23 23:59:59 Europe/Dublin'
--   where code = 'diwali2026';
-- Emergency stop (closes uploads AND gallery at once):
--   update public.events set active = false where code = 'diwali2026';
-- After view_until: download the zip first, then delete the photos (see README).

-- 6. Guests can remove their own photos (same as fix-002-remove-my-photo.sql)
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

-- 7. Host can delete a photo for good (same as fix-003-host-delete-photo.sql)
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
