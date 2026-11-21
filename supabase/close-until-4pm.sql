-- Close the Diwali photo wall now and reopen it automatically at 16:00 today (Sat 21 Nov).
-- Run once in the EventSnap SQL Editor (project fllarkkdiklmvxxclmuy).

-- 1. Close it now. Guests see "The photo wall isn't open yet" (no gallery, no uploads).
update public.events set active = false where code = 'diwali2026';

-- Keep within the free 1 GB of photo storage (about 0.5 MB per photo incl. thumbnail).
update public.events set max_photos = 1500 where code = 'diwali2026';

-- 2. Turn on the scheduler (safe to run if it is already on).
create extension if not exists pg_cron with schema pg_catalog;

-- 3. Reopen at 16:00 on 21 Nov. Supabase runs this clock on UTC, and Ireland is on UTC in November.
select cron.schedule(
  'open-diwali2026',
  '0 16 21 11 *',
  $$update public.events set active = true where code = 'diwali2026'$$
);

-- Check: should show active = false and the job below.
select code, active from public.events where code = 'diwali2026';
select jobname, schedule, active from cron.job where jobname = 'open-diwali2026';

-- To open it yourself earlier:  update public.events set active = true where code = 'diwali2026';
-- After the event, remove the job (it would otherwise fire again next 21 Nov):
--   select cron.unschedule('open-diwali2026');
