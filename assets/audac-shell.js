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
  };
  const icon = (name, attrs = '') => `<svg viewBox="0 0 24 24" aria-hidden="true" ${attrs}>${ICONS[name] || ''}</svg>`;

  const NAVS = {
    rep: {
      home: '/home', label: 'Rep Portal',
      items: [
        { key: 'home', href: '/home', label: 'Home', short: 'Home', icon: 'home' },
        { key: 'log', href: '/form', label: 'Log activity', short: 'Log', icon: 'plus' },
        { key: 'submissions', href: '/form#my-submissions-section', label: 'My submissions', short: 'Submissions', icon: 'list' },
        { key: 'import', href: '/import', label: 'Import CRM export', short: 'Import', icon: 'upload' },
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
          <a class="brand" href="${nav.home}"><b>AUDAC</b><span>${esc(nav.label)}</span></a>
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

  window.AudacShell = {
    icon,
    mount(activeKey, opts = {}) { active = activeKey; if (opts.nav) navKey = opts.nav; render(); },
    useNav(key) { navKey = key; render(); },
    addItem(item) { if (!extraItems.some(i => i.key === item.key)) extraItems.push(item); render(); },
    setSection(text) { section = text || ''; const el = document.getElementById('app-nav-section'); if (el) el.textContent = section; },
    setUser(u) { user = u && u.name ? u : null; applyUser(); },
    onSignOut(fn) {
      document.addEventListener('click', (e) => { if (e.target.closest('#app-signout')) fn(); });
    },
  };

  themeCharts();
  function autoMount() {
    const b = document.body;
    if (!b || !b.dataset.nav) return;
    AudacShell.mount(b.dataset.active || '', { nav: b.dataset.nav });
    bridgeLegacyAuth();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', autoMount);
  else autoMount();
})();
