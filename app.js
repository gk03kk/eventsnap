// Shared data layer for all EventSnap pages.
// Two backends: Supabase (real event) and demo (this browser only, for testing).
(function () {
  const cfg = window.EVENTSNAP_CONFIG || {};
  const params = new URLSearchParams(location.search);
  const eventCode = (params.get('e') || cfg.DEFAULT_EVENT || 'demo').toLowerCase().replace(/[^a-z0-9-]/g, '');
  const demo = !cfg.SUPABASE_URL || !cfg.SUPABASE_ANON_KEY;
  const sb = demo ? null : window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: false },
  });

  // ---------- image shrinking (done on the phone before upload) ----------
  function shrinkImage(file, maxSide, quality) {
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(file);
      const img = new Image();
      img.onload = () => {
        const scale = Math.min(1, maxSide / Math.max(img.naturalWidth, img.naturalHeight));
        const w = Math.round(img.naturalWidth * scale);
        const h = Math.round(img.naturalHeight * scale);
        const canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        canvas.getContext('2d').drawImage(img, 0, 0, w, h);
        URL.revokeObjectURL(url);
        canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Could not read this photo'))), 'image/jpeg', quality);
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('This file is not a photo we can read')); };
      img.src = url;
    });
  }

  function uuid() {
    return ([1e7] + -1e3 + -4e3 + -8e3 + -1e11).replace(/[018]/g, (c) =>
      (c ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16));
  }

  // ---------- demo backend (localStorage) ----------
  const demoKey = 'eventsnap.demo.' + eventCode;
  function demoRead() {
    try { return JSON.parse(localStorage.getItem(demoKey) || '[]'); } catch (e) { return []; }
  }
  function demoWrite(list) {
    try { localStorage.setItem(demoKey, JSON.stringify(list)); }
    catch (e) { throw new Error('Demo storage is full. Clear it from the host page.'); }
  }
  function blobToDataUrl(blob) {
    return new Promise((res) => { const r = new FileReader(); r.onload = () => res(r.result); r.readAsDataURL(blob); });
  }

  // ---------- public API ----------
  async function getEvent() {
    if (demo) {
      // ?demo=closed or ?demo=ended lets you preview the later states.
      const day = 86400000;
      const mode = params.get('demo');
      const now = Date.now();
      const uploadsUntil = mode === 'closed' || mode === 'ended' ? now - day : now + 2 * day;
      const viewUntil = mode === 'ended' ? now - 1000 : now + 30 * day;
      return {
        code: eventCode, name: 'Diwali Night (demo)', active: true,
        uploads_until: new Date(uploadsUntil).toISOString(), view_until: new Date(viewUntil).toISOString(),
      };
    }
    const { data, error } = await sb.from('events').select('code,name,active,uploads_until,view_until').eq('code', eventCode).maybeSingle();
    if (error) throw new Error('Could not reach the photo wall. Check your internet and try again.');
    return data; // null when the event code doesn't exist
  }

  async function listPhotos() {
    if (demo) return demoRead().filter((p) => !p.hidden).sort((a, b) => b.created_at.localeCompare(a.created_at));
    const { data, error } = await sb.from('photos')
      .select('id,path,thumb_path,uploader,created_at')
      .eq('event_code', eventCode)
      .order('created_at', { ascending: false })
      .limit(1000);
    if (error) throw new Error('Could not load photos.');
    const publicUrl = (path) => sb.storage.from(cfg.BUCKET).getPublicUrl(path).data.publicUrl;
    return data.map((p) => ({
      ...p,
      url: publicUrl(p.path),
      thumb: p.thumb_path ? publicUrl(p.thumb_path) : publicUrl(p.path),
    }));
  }

  async function uploadPhoto(file, uploader) {
    const name = (uploader || '').trim().slice(0, 40) || null;
    if (demo) {
      const blob = await shrinkImage(file, 900, 0.7);
      const list = demoRead();
      const dataUrl = await blobToDataUrl(blob);
      list.push({ id: uuid(), url: dataUrl, thumb: dataUrl, uploader: name, created_at: new Date().toISOString(), hidden: false });
      demoWrite(list);
      return;
    }
    // Full photo (2048 px, sharp on any TV) + small thumbnail for the gallery grid.
    const blob = await shrinkImage(file, 2048, 0.85);
    const thumb = await shrinkImage(blob, 400, 0.72);
    const id = uuid();
    const path = eventCode + '/' + id + '.jpg';
    const thumbPath = eventCode + '/thumbs/' + id + '.jpg';
    const up = await sb.storage.from(cfg.BUCKET).upload(path, blob, { contentType: 'image/jpeg', upsert: false });
    if (up.error) throw new Error('Upload failed. Uploads may be closed.');
    const upThumb = await sb.storage.from(cfg.BUCKET).upload(thumbPath, thumb, { contentType: 'image/jpeg', upsert: false });
    const ins = await sb.from('photos').insert({
      event_code: eventCode, path, thumb_path: upThumb.error ? null : thumbPath, uploader: name,
    });
    if (ins.error) throw new Error(/limit/i.test(ins.error.message) ? 'This event has reached its photo limit.' : 'Upload failed. Uploads may be closed.');
  }

  // 'open' (upload + view), 'viewOnly' (uploads closed), 'ended' (nothing), or 'missing'.
  function eventState(ev) {
    if (!ev || !ev.active) return 'missing';
    const now = Date.now();
    if (now > new Date(ev.view_until).getTime()) return 'ended';
    if (now > new Date(ev.uploads_until).getTime()) return 'viewOnly';
    return 'open';
  }

  function formatWhen(iso, withTime) {
    const opts = { weekday: 'short', day: 'numeric', month: 'short' };
    if (withTime) { opts.hour = '2-digit'; opts.minute = '2-digit'; }
    return new Date(iso).toLocaleString(undefined, opts);
  }

  // Saves one photo to the phone: share sheet on phones that support it, else a download.
  async function savePhoto(p) {
    const blob = await (await fetch(p.url)).blob();
    const fileName = eventCode + '-' + (p.uploader || 'photo').replace(/[^a-z0-9]+/gi, '-').slice(0, 20) + '-' + p.id.slice(0, 6) + '.jpg';
    const file = new File([blob], fileName, { type: blob.type || 'image/jpeg' });
    if (navigator.canShare && navigator.canShare({ files: [file] }) && /Mobi|Android|iPhone|iPad/i.test(navigator.userAgent)) {
      try { await navigator.share({ files: [file] }); return; }
      catch (e) { if (e.name === 'AbortError') return; }
    }
    const a = document.createElement('a');
    a.href = URL.createObjectURL(file);
    a.download = fileName;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  }

  async function hidePhoto(id, pin) {
    if (demo) {
      const list = demoRead();
      const p = list.find((x) => x.id === id);
      if (p) p.hidden = true;
      demoWrite(list);
      return true;
    }
    const { data, error } = await sb.rpc('hide_photo', { p_photo_id: id, p_pin: pin });
    if (error) throw new Error('Could not hide the photo.');
    return data === true;
  }

  function clearDemo() { localStorage.removeItem(demoKey); }

  // Number of visible photos, without downloading the list (a tiny HEAD request).
  async function countPhotos() {
    const { count, error } = await sb.from('photos')
      .select('id', { count: 'exact', head: true })
      .eq('event_code', eventCode);
    if (error) throw new Error('Could not load photos.');
    return count;
  }

  // Calls cb(photos) now, then checks every `ms` milliseconds.
  // To stay light with 100+ phones watching, each check only asks "how many photos?"
  // and downloads the list again only when that number changes (or every 2 minutes,
  // to catch a hidden photo swapped for a new one). Paused while the page is in the background.
  function watchPhotos(cb, ms, onError) {
    let stopped = false, timer = null, lastCount = -1, lastFull = 0;
    async function tick() {
      if (stopped) return;
      clearTimeout(timer);
      if (!document.hidden) {
        try {
          if (demo) cb(await listPhotos());
          else {
            const n = await countPhotos();
            if (n !== lastCount || Date.now() - lastFull > 120000) {
              cb(await listPhotos());
              lastCount = n;
              lastFull = Date.now();
            }
          }
        } catch (e) { if (onError) onError(e); }
      }
      if (!stopped) timer = setTimeout(tick, ms);
    }
    tick();
    document.addEventListener('visibilitychange', () => { if (!document.hidden) tick(); });
    if (demo) window.addEventListener('storage', (e) => { if (e.key === demoKey) listPhotos().then(cb); });
    return () => { stopped = true; clearTimeout(timer); };
  }

  function pageUrl(page) {
    const u = new URL(page, location.href);
    u.search = '?e=' + encodeURIComponent(eventCode);
    return u.toString();
  }

  function timeAgo(iso) {
    const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
    if (s < 60) return 'just now';
    if (s < 3600) return Math.floor(s / 60) + ' min ago';
    if (s < 86400) return Math.floor(s / 3600) + ' h ago';
    return new Date(iso).toLocaleDateString();
  }

  window.EventSnap = {
    eventCode, demo, getEvent, eventState, formatWhen, listPhotos, uploadPhoto, savePhoto,
    hidePhoto, clearDemo, watchPhotos, pageUrl, timeAgo,
  };
})();
