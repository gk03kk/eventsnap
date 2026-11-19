# EventSnap — Photo wall for events

Guests scan a QR code, upload photos from the browser (no app), and everyone sees them
live on their phones and on a projector.

## Pages
- `index.html?e=<code>` — guest page (what the QR opens): add photos + live gallery
- `slideshow.html?e=<code>` — projector slideshow with the QR in the corner
- `poster.html?e=<code>` — printable A4 QR poster
- `host.html?e=<code>` — links, download all photos as a zip, hide a photo (PIN)

## Demo mode
With an empty `SUPABASE_URL` in `config.js`, everything runs in this browser only
(localStorage). Good for trying the screens, not for the event.

## Going live (for a real event)
1. Create a NEW free Supabase project (keep it separate from JarJoy).
2. SQL Editor → run `supabase/setup.sql` (change the host PIN first).
3. Put the project URL + anon key in `config.js` (never the service_role key).
4. Publish the folder (e.g. GitHub Pages) so it has a public https link.
5. Open `poster.html` from the public link and print it.

## Security model
- Guests (anon) can only: read active events' name, read visible photos, upload images
  into an active event's folder, and insert a photo row. Max photos per event via trigger.
- Hiding a photo needs the event's host PIN (checked in `hide_photo`, PIN never readable).
- Photos are public to anyone with the link — tell guests that.
- Guest page asks for consent (permission from people shown, parent for any child).
- Create the Supabase project in an EU region (eu-west-1, Ireland) to match the privacy note.
- The guest page promises deletion 30 days after the event. This is NOT automatic yet:
  download the zip, then empty the `photos` bucket and delete the rows (or delete the
  whole Supabase project) by that date.
