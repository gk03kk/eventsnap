// Diwali fireworks drawn on a see-through canvas behind the page content.
// Fireworks.start({ rate }) launches rockets now and then; Fireworks.burst() fires a few at once.
// Turns itself off for people who ask their phone for reduced motion, and pauses in hidden tabs.
(function () {
  const COLORS = ['#f5b942', '#ff7a1a', '#e0457b', '#b57bff', '#4ade80', '#ffe08a', '#ff5e5e'];
  const reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  let canvas, ctx, w, h, dpr;
  let rockets = [], sparks = [];
  let running = false, rate = 0.5, lastLaunch = 0, lastFrame = 0;

  function setup() {
    canvas = document.createElement('canvas');
    canvas.className = 'fireworks';
    canvas.setAttribute('aria-hidden', 'true');
    Object.assign(canvas.style, { position: 'fixed', inset: '0', width: '100%', height: '100%', pointerEvents: 'none', zIndex: '0' });
    document.body.prepend(canvas);
    ctx = canvas.getContext('2d');
    resize();
    window.addEventListener('resize', resize);
    document.addEventListener('visibilitychange', () => { if (!document.hidden && running) loop(performance.now()); });
  }

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    w = window.innerWidth;
    h = window.innerHeight;
    canvas.width = w * dpr;
    canvas.height = h * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function launch(x) {
    const color = COLORS[(Math.random() * COLORS.length) | 0];
    rockets.push({
      x: x != null ? x : w * (0.15 + Math.random() * 0.7),
      y: h + 10,
      vx: (Math.random() - 0.5) * 1.2,
      vy: -(h / 95 + Math.random() * h / 220),
      targetY: h * (0.12 + Math.random() * 0.35),
      color,
    });
  }

  function explode(r) {
    const count = 50 + ((Math.random() * 30) | 0);
    const second = Math.random() < 0.4 ? COLORS[(Math.random() * COLORS.length) | 0] : r.color;
    const ring = Math.random() < 0.3;
    for (let i = 0; i < count; i++) {
      const a = (Math.PI * 2 * i) / count;
      const speed = ring ? 3.2 : 1 + Math.random() * 3.4;
      sparks.push({
        x: r.x, y: r.y,
        vx: Math.cos(a) * speed, vy: Math.sin(a) * speed,
        life: 1, decay: 0.012 + Math.random() * 0.012,
        color: i % 2 ? r.color : second,
        size: 1.4 + Math.random() * 1.4,
        twinkle: Math.random() < 0.3,
      });
    }
  }

  function loop(t) {
    if (!running || document.hidden) return;
    const dt = Math.min(3, (t - (lastFrame || t)) / 16.7 || 1);
    lastFrame = t;

    // Fade the previous frame (keeps the canvas see-through, leaves soft trails).
    ctx.globalCompositeOperation = 'destination-out';
    ctx.fillStyle = 'rgba(0,0,0,0.22)';
    ctx.fillRect(0, 0, w, h);
    ctx.globalCompositeOperation = 'lighter';

    if (rate > 0 && t - lastLaunch > (1000 / rate) * (0.6 + Math.random() * 0.8)) {
      launch();
      lastLaunch = t;
    }

    for (let i = rockets.length - 1; i >= 0; i--) {
      const r = rockets[i];
      r.x += r.vx * dt;
      r.y += r.vy * dt;
      r.vy += 0.05 * dt;
      ctx.fillStyle = '#ffe9b0';
      ctx.beginPath();
      ctx.arc(r.x, r.y, 2, 0, Math.PI * 2);
      ctx.fill();
      if (r.y <= r.targetY || r.vy >= 0) { explode(r); rockets.splice(i, 1); }
    }

    for (let i = sparks.length - 1; i >= 0; i--) {
      const s = sparks[i];
      s.x += s.vx * dt;
      s.y += s.vy * dt;
      s.vx *= 0.985;
      s.vy = s.vy * 0.985 + 0.045 * dt;
      s.life -= s.decay * dt;
      if (s.life <= 0) { sparks.splice(i, 1); continue; }
      ctx.globalAlpha = s.twinkle ? s.life * (0.5 + Math.random() * 0.5) : s.life;
      ctx.fillStyle = s.color;
      ctx.beginPath();
      ctx.arc(s.x, s.y, s.size, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
    requestAnimationFrame(loop);
  }

  window.Fireworks = {
    start(opts) {
      if (reduced) return;
      if (!canvas) setup();
      rate = opts && opts.rate != null ? opts.rate : 0.5;
      if (!running) { running = true; requestAnimationFrame(loop); }
    },
    burst(n) {
      if (reduced) return;
      if (!canvas) this.start({ rate: 0 });
      const count = n || 4;
      for (let i = 0; i < count; i++) setTimeout(() => launch(w * (0.15 + Math.random() * 0.7)), i * 220);
    },
  };
})();
