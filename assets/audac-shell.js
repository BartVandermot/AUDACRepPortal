// Shared navigation: a glass sidebar on desktop and a floating glass bottom
// bar on phones. Pages provide the empty containers (#app-sidebar,
// #app-bottom-nav) and either call AudacShell.mount(activeKey, {nav}) or
// declare <body data-nav="manager" data-active="crm"> to mount automatically.
//
// Manager/executive pages keep their own auth code: the shell mirrors the
// page's existing #user-email text into the sidebar profile and routes the
// sidebar's Sign out to the page's existing #signout-btn.
(function () {
  const ICONS = {
    home: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 10.5 12 4l8 6.5V20h-5.5v-5.5h-5V20H4z"/>',
    plus: '<path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" d="M12 5v14M5 12h14"/>',
    list: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01"/>',
    upload: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M12 15V4m0 0-4 4m4-4 4 4M4 15v4a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-4"/>',
    grid: '<path fill="none" stroke="currentColor" stroke-width="1.8" d="M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z"/>',
    building: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 20V5l8-2v17M12 9l8 2v9M3 20h18M7.5 8h1M7.5 12h1M7.5 16h1M15.5 14h1M15.5 17h1"/>',
    users: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Zm-6 9c0-3 2.7-5 6-5s6 2 6 5M16 4.3a3.5 3.5 0 0 1 0 6.4M18 15c2 .6 3 2.4 3 5"/>',
    map: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="m3 6 6-2 6 2 6-2v14l-6 2-6-2-6 2zM9 4v14M15 6v14"/>',
    db: '<path fill="none" stroke="currentColor" stroke-width="1.8" d="M4 6c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3Zm0 0v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    chart: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M4 20V4M4 20h16M8 16v-4M12 16V8M16 16v-6"/>',
    user: '<path fill="none" stroke="currentColor" stroke-width="1.8" d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-7 8c0-3.3 3.1-5.5 7-5.5s7 2.2 7 5.5"/>',
    out: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M15 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4M10 17l5-5-5-5M15 12H3"/>',
    up: '<path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" d="m6 15 6-6 6 6"/>',
    down: '<path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" d="m6 9 6 6 6-6"/>',
    check: '<path fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" d="m5 12.5 4.5 4.5L19 7.5"/>',
    lock: '<path fill="none" stroke="currentColor" stroke-width="1.8" d="M7 11V8a5 5 0 0 1 10 0v3M5.5 11h13v9h-13z"/>',
    collapse: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 4h16v16H4zM9 4v16M15.5 9.5 13 12l2.5 2.5"/>',
    expand: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 4h16v16H4zM9 4v16M13 9.5l2.5 2.5-2.5 2.5"/>',
    spark: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M12 3v4M12 17v4M3 12h4M17 12h4"/>',
    left: '<path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" d="m14.5 6-6 6 6 6"/>',
    right: '<path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" d="m9.5 6 6 6-6 6"/>',
    book: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M5 4.5A1.5 1.5 0 0 1 6.5 3H19v15H6.5A1.5 1.5 0 0 0 5 19.5zM5 19.5A1.5 1.5 0 0 0 6.5 21H19v-3M9 7h6"/>',
  };
  const icon = (name, attrs = '') => `<svg viewBox="0 0 24 24" aria-hidden="true" ${attrs}>${ICONS[name] || ''}</svg>`;

  const NAVS = {
    rep: {
      home: '/home', label: 'Rep Portal',
      items: [
        { key: 'home', href: '/home', label: 'Home', short: 'Home', icon: 'home' },
        { key: 'log', href: '/form', label: 'Log activity', short: 'Log', icon: 'plus' },
        { key: 'territory', href: '/territory', label: 'My territory', short: 'Territory', icon: 'map' },
        { key: 'submissions', href: '/form#my-submissions-section', label: 'My submissions', short: 'Submissions', icon: 'list' },
        { key: 'resources', href: '/resources', label: 'Resources', short: 'Resources', icon: 'book' },
        // Importing a CRM export is a desktop job; keeps the phone bar at five items.
        { key: 'import', href: '/import', label: 'Import CRM export', short: 'Import', icon: 'upload', desktopOnly: true },
      ],
    },
    manager: {
      home: '/dashboard', label: 'Manager',
      items: [
        { key: 'dashboard', href: '/dashboard', label: 'Dashboard', short: 'Dashboard', icon: 'grid' },
        { key: 'crm', href: '/crm', label: 'Accounts & Contacts', short: 'Accounts', icon: 'building' },
        { key: 'reps', href: '/reps', label: 'Reps', short: 'Reps', icon: 'users' },
        { key: 'territories', href: '/territories', label: 'Territories', short: 'Territories', icon: 'map', desktopOnly: true },
        { key: 'admin', href: '/admin', label: 'Data Admin', short: 'Admin', icon: 'db' },
        { key: 'import', href: '/import', label: 'Activity import', short: 'Import', icon: 'upload', desktopOnly: true },
      ],
    },
    executive: {
      home: '/executive', label: 'Executive',
      items: [{ key: 'executive', href: '/executive', label: 'Executive overview', short: 'Overview', icon: 'chart' }],
    },
  };

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function initials(name) {
    const parts = String(name || '').trim().split(/[\s@._-]+/).filter(Boolean);
    return ((parts[0] || '?')[0] + (parts[1] ? parts[1][0] : '')).toUpperCase();
  }

  let active = 'home';
  let navKey = 'rep';
  let extraItems = [];
  let user = null;
  let section = '';

  // Collapsible sidebar (icon rail), like the AUDAC Touch 2 menu. The choice
  // is remembered per browser; with no choice yet, narrower laptop screens
  // start collapsed so the working area gets the room.
  const COLLAPSE_KEY = 'audac_nav_collapsed';
  let collapsed = (() => {
    try { const v = localStorage.getItem(COLLAPSE_KEY); if (v !== null) return v === '1'; } catch { /* storage blocked */ }
    return window.innerWidth < 1440;
  })();
  function applyCollapsed() { document.documentElement.classList.toggle('nav-collapsed', collapsed); }
  applyCollapsed();
  document.addEventListener('click', (e) => {
    if (!e.target.closest('#app-nav-toggle')) return;
    collapsed = !collapsed;
    try { localStorage.setItem(COLLAPSE_KEY, collapsed ? '1' : '0'); } catch { /* ignore */ }
    applyCollapsed();
    render();
  });

  function render() {
    const nav = NAVS[navKey] || NAVS.rep;
    const items = [...nav.items, ...extraItems];
    const side = document.getElementById('app-sidebar');
    if (side) {
      side.innerHTML = `
        <div class="sidebar-head">
          <a class="brand" href="${nav.home}" title="AUDAC ${esc(nav.label)}"><img class="brand-logo" src="/assets/audac-logo.webp" alt="AUDAC" width="37" height="40"><span>${esc(nav.label)}</span></a>
          <button type="button" class="nav-toggle" id="app-nav-toggle" aria-label="${collapsed ? 'Expand menu' : 'Collapse menu'}" title="${collapsed ? 'Expand menu' : 'Collapse menu'}" aria-expanded="${!collapsed}">${icon(collapsed ? 'expand' : 'collapse')}</button>
        </div>
        <div class="nav-section" id="app-nav-section"></div>
        ${items.map(n => `<a class="nav-item" href="${n.href}" title="${esc(n.label)}"${n.key === active ? ' aria-current="page"' : ''}>${icon(n.icon)}<span class="label">${esc(n.label)}</span></a>`).join('')}
        <div class="grow"></div>
        <div class="profile" id="app-profile" hidden>
          <span class="avatar" id="app-avatar"></span>
          <div class="who"><b id="app-user-name"></b><span id="app-user-sub"></span></div>
          <button type="button" class="icon-btn" id="app-signout" aria-label="Sign out" title="Sign out">${icon('out')}</button>
        </div>`;
    }
    const bottom = document.getElementById('app-bottom-nav');
    if (bottom) {
      bottom.innerHTML = items.filter(n => !n.desktopOnly).map(n =>
        `<a href="${n.href}"${n.key === active ? ' aria-current="page"' : ''}>${icon(n.icon)}${esc(n.short)}</a>`).join('');
    }
    applyUser();
    const sec = document.getElementById('app-nav-section');
    if (sec) sec.textContent = section;
  }

  function applyUser() {
    const p = document.getElementById('app-profile');
    if (!p) return;
    p.hidden = !user?.name;
    if (!user?.name) return;
    document.getElementById('app-avatar').textContent = initials(user.name);
    document.getElementById('app-user-name').textContent = user.name;
    document.getElementById('app-user-sub').textContent = user.sub || '';
  }

  // Dark-theme defaults for Chart.js on pages that draw charts in-page.
  function themeCharts() {
    if (!window.Chart?.defaults) return;
    Chart.defaults.color = '#b8b8b5';
    Chart.defaults.borderColor = 'rgba(255,255,255,0.08)';
    Chart.defaults.font.family = "'Montserrat', system-ui, sans-serif";
  }

  // Legacy manager pages: mirror their #user-email and #signout-btn.
  function bridgeLegacyAuth() {
    const emailEl = document.getElementById('user-email');
    if (emailEl) {
      const sync = () => { const t = emailEl.textContent.trim(); if (t) AudacShell.setUser({ name: t, sub: NAVS[navKey]?.label === 'Executive' ? 'AUDAC executive' : 'AUDAC manager' }); };
      new MutationObserver(sync).observe(emailEl, { childList: true, characterData: true, subtree: true });
      sync();
    }
    const legacyBtn = document.getElementById('signout-btn');
    if (legacyBtn) {
      legacyBtn.innerHTML = icon('out');
      AudacShell.onSignOut(() => legacyBtn.click());
    }
  }

  // The service worker (/sw.js) only handles push notifications -- it never
  // caches pages. Registered on every page so the portal installs as an app
  // from any page (Chrome/Edge on Android) and notifications keep working.
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => { navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch(() => {}); });
  }

  window.AudacShell = {
    icon,
    // A lead asks for follow-up only while it is fresh: older ones are history
    // (shown, but no follow-up asked, no reminders, not in the rates).
    // Used by My territory, Home, Reps and the dashboard.
    LEAD_FOLLOW_UP_DAYS: 60,
    mount(activeKey, opts = {}) { active = activeKey; if (opts.nav) navKey = opts.nav; render(); },
    useNav(key) { navKey = key; render(); },
    addItem(item) { if (!extraItems.some(i => i.key === item.key)) extraItems.push(item); render(); },
    setSection(text) { section = text || ''; const el = document.getElementById('app-nav-section'); if (el) el.textContent = section; },
    setUser(u) { user = u && u.name ? u : null; applyUser(); },
    onSignOut(fn) {
      document.addEventListener('click', (e) => { if (e.target.closest('#app-signout')) fn(); });
    },
  };

  // ---------- Background sound waves ----------
  // A few thin gold lines that weave through each other like an audio
  // waveform across the middle of the page, drifting very slowly. Fixed
  // behind everything (glass tiles blur them), ~30 fps, paused by the browser
  // in background tabs, and drawn once without motion for prefers-reduced-motion.
  const WAVES = [
    // amplitude (x viewport height), two frequencies (cycles across the width), drift speeds, phase, alpha, width
    { amp: 0.11, f1: 1.15, f2: 2.6, s1: 0.16, s2: -0.11, p: 0.0, alpha: 0.55, w: 1.6 },
    { amp: 0.085, f1: 0.85, f2: 3.1, s1: -0.12, s2: 0.09, p: 1.7, alpha: 0.38, w: 1.3 },
    { amp: 0.13, f1: 1.45, f2: 1.9, s1: 0.09, s2: 0.14, p: 3.1, alpha: 0.30, w: 1.2 },
    { amp: 0.07, f1: 2.05, f2: 0.7, s1: -0.07, s2: -0.13, p: 4.4, alpha: 0.24, w: 1.1 },
    { amp: 0.05, f1: 0.55, f2: 4.2, s1: 0.05, s2: 0.08, p: 5.6, alpha: 0.32, w: 1.0 },
  ];
  function mountWaves() {
    if (document.getElementById('audac-waves') || !document.body) return;
    const cv = document.createElement('canvas');
    cv.id = 'audac-waves';
    cv.setAttribute('aria-hidden', 'true');
    document.body.prepend(cv);
    const ctx = cv.getContext('2d');
    if (!ctx) return;
    const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    let W = 0, H = 0, dpr = 1;
    function size() {
      dpr = Math.min(window.devicePixelRatio || 1, 1.5); // soft glow: full retina resolution not needed
      W = window.innerWidth; H = window.innerHeight;
      cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    function draw(t) {
      ctx.clearRect(0, 0, W, H);
      const baseY = H * 0.5;
      const steps = Math.max(60, Math.round(W / 12));
      for (const wv of WAVES) {
        ctx.beginPath();
        for (let i = 0; i <= steps; i++) {
          const u = i / steps; // 0..1 across the width
          // Envelope: quiet at both edges, fuller in the middle, slowly breathing.
          const env = Math.pow(Math.sin(Math.PI * u), 1.4) * (0.75 + 0.25 * Math.sin(t * 0.05 + wv.p));
          const y = baseY + wv.amp * H * env * (
            0.72 * Math.sin(2 * Math.PI * wv.f1 * u + t * wv.s1 + wv.p) +
            0.28 * Math.sin(2 * Math.PI * wv.f2 * u + t * wv.s2 + wv.p * 0.6));
          if (i === 0) ctx.moveTo(u * W, y); else ctx.lineTo(u * W, y);
        }
        // Glow: a wide soft halo, a tighter inner glow, then the bright core.
        // Additive blending makes crossings flare up a little, like light.
        ctx.globalCompositeOperation = 'lighter';
        for (const [widthMul, alphaMul] of GLOW_PASSES) {
          ctx.strokeStyle = waveGradient(wv.alpha * alphaMul);
          ctx.lineWidth = wv.w * widthMul;
          ctx.stroke();
        }
        ctx.globalCompositeOperation = 'source-over';
      }
    }
    // [line width multiplier, alpha multiplier]: wide faint strokes under a
    // thin bright core. (canvas shadowBlur looks similar but costs ~10x more.)
    const GLOW_PASSES = [[22, 0.045], [10, 0.09], [4, 0.2], [1, 1]];
    function waveGradient(alpha) {
      const g = ctx.createLinearGradient(0, 0, W, 0);
      g.addColorStop(0, 'rgba(217,166,83,0)');
      g.addColorStop(0.18, `rgba(217,166,83,${alpha})`);
      g.addColorStop(0.5, `rgba(238,200,134,${Math.min(1, alpha * 1.15)})`);
      g.addColorStop(0.82, `rgba(217,166,83,${alpha})`);
      g.addColorStop(1, 'rgba(217,166,83,0)');
      return g;
    }
    size();
    window.addEventListener('resize', () => { size(); if (reduce) draw(12); });
    if (reduce) { draw(12); return; }
    let last = 0;
    const start = performance.now();
    function frame(now) {
      if (now - last >= 33) { last = now; draw((now - start) / 1000); }
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  // ---------- Month picker ----------
  // Replaces the browser's own month popup (light, in the OS language) with
  // one in the portal's style: ‹ November 2026 › to step, a dark 12-month grid
  // to jump. The real <input type="month"> stays (hidden) as the source of
  // truth, so page code keeps reading .value and listening for 'change'; a
  // value set from code re-renders the control too.
  const MONTHS_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const valueDesc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
  let openPicker = null;
  function closeOpenPicker() { if (openPicker) { openPicker(); openPicker = null; } }
  document.addEventListener('click', (e) => { if (!e.target.closest('.mp')) closeOpenPicker(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeOpenPicker(); });

  function enhanceMonthInput(input) {
    if (input.dataset.mpReady) return;
    input.dataset.mpReady = '1';
    const id = input.id || ('mp-' + Math.random().toString(36).slice(2));
    const wrap = document.createElement('div');
    wrap.className = 'mp';
    wrap.innerHTML =
      `<button type="button" class="mp-step" data-step="-1" aria-label="Previous month">${icon('left')}</button>` +
      `<button type="button" class="mp-label" id="${id}-mp" aria-haspopup="dialog" aria-expanded="false"></button>` +
      `<button type="button" class="mp-step" data-step="1" aria-label="Next month">${icon('right')}</button>` +
      `<div class="mp-pop" role="dialog" aria-label="Choose a month" hidden>` +
        `<div class="mp-year"><button type="button" class="mp-ystep" data-y="-1" aria-label="Previous year">${icon('left')}</button><span class="mp-y"></span><button type="button" class="mp-ystep" data-y="1" aria-label="Next year">${icon('right')}</button></div>` +
        `<div class="mp-grid"></div>` +
        `<div class="mp-foot"><button type="button" class="mp-now">This month</button>${input.hasAttribute('data-clearable') ? '<button type="button" class="mp-clear">Any month</button>' : ''}</div>` +
      `</div>`;
    input.classList.add('mp-native');
    input.tabIndex = -1;
    input.setAttribute('aria-hidden', 'true');
    input.insertAdjacentElement('afterend', wrap);
    const label = document.querySelector(`label[for="${CSS.escape(input.id)}"]`);
    if (label) label.htmlFor = id + '-mp';

    const pop = wrap.querySelector('.mp-pop');
    const btn = wrap.querySelector('.mp-label');
    const now = new Date();
    const thisYm = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    let viewYear = now.getFullYear();
    const get = () => valueDesc.get.call(input);
    const parse = (v) => /^\d{4}-\d{2}$/.test(v || '') ? { y: +v.slice(0, 4), m: +v.slice(5, 7) } : null;
    const fmt = (y, m) => `${y}-${String(m).padStart(2, '0')}`;
    const inRange = (v) => (!input.min || v >= input.min) && (!input.max || v <= input.max);

    function render() {
      const p = parse(get());
      btn.textContent = p ? new Date(p.y, p.m - 1, 1).toLocaleString('en-US', { month: 'long', year: 'numeric' }) : 'Any month';
      wrap.querySelectorAll('.mp-step').forEach(b => { b.disabled = !p; });
    }
    function renderGrid() {
      const p = parse(get());
      wrap.querySelector('.mp-y').textContent = viewYear;
      wrap.querySelector('.mp-grid').innerHTML = MONTHS_SHORT.map((name, i) => {
        const v = fmt(viewYear, i + 1);
        const sel = p && p.y === viewYear && p.m === i + 1;
        return `<button type="button" data-v="${v}"${sel ? ' aria-selected="true"' : ''}${v === thisYm ? ' aria-current="date"' : ''}${inRange(v) ? '' : ' disabled'}>${name}</button>`;
      }).join('');
    }
    function choose(v) {
      if (v && !inRange(v)) return;
      valueDesc.set.call(input, v || '');
      render();
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
    }
    function close() { pop.hidden = true; btn.setAttribute('aria-expanded', 'false'); }
    function open() {
      closeOpenPicker();
      const p = parse(get());
      viewYear = p ? p.y : now.getFullYear();
      renderGrid();
      pop.hidden = false;
      btn.setAttribute('aria-expanded', 'true');
      openPicker = close;
      (pop.querySelector('[aria-selected="true"]') || pop.querySelector('.mp-grid button')).focus();
    }

    btn.addEventListener('click', () => (pop.hidden ? open() : closeOpenPicker()));
    wrap.querySelectorAll('.mp-step').forEach(b => b.addEventListener('click', () => {
      const p = parse(get());
      if (!p) return;
      const d = new Date(p.y, p.m - 1 + Number(b.dataset.step), 1);
      choose(fmt(d.getFullYear(), d.getMonth() + 1));
    }));
    wrap.querySelectorAll('.mp-ystep').forEach(b => b.addEventListener('click', () => { viewYear += Number(b.dataset.y); renderGrid(); }));
    wrap.querySelector('.mp-grid').addEventListener('click', (e) => {
      const b = e.target.closest('button[data-v]');
      if (!b) return;
      choose(b.dataset.v);
      closeOpenPicker();
      btn.focus();
    });
    wrap.querySelector('.mp-now').addEventListener('click', () => { choose(thisYm); closeOpenPicker(); btn.focus(); });
    const clr = wrap.querySelector('.mp-clear');
    if (clr) clr.addEventListener('click', () => { choose(''); closeOpenPicker(); btn.focus(); });

    // Keep the control in sync when page code sets input.value directly.
    Object.defineProperty(input, 'value', {
      configurable: true,
      get() { return valueDesc.get.call(input); },
      set(v) { valueDesc.set.call(input, v); render(); },
    });
    render();
  }
  function enhanceMonthInputs(root) {
    (root || document).querySelectorAll('input[type="month"]').forEach(enhanceMonthInput);
  }
  window.AudacShell.enhanceMonthInputs = enhanceMonthInputs;

  themeCharts();
  function autoMount() {
    const b = document.body;
    if (!b || !b.dataset.nav) return;
    AudacShell.mount(b.dataset.active || '', { nav: b.dataset.nav });
    bridgeLegacyAuth();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { autoMount(); enhanceMonthInputs(); mountWaves(); });
  else { autoMount(); enhanceMonthInputs(); mountWaves(); }
})();
