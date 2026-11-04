// Shared navigation for the rep-facing pages: a glass sidebar on desktop and
// a floating glass bottom bar on phones. Each page provides the empty
// containers (#app-sidebar, #app-bottom-nav) and calls
// AudacShell.mount('<active key>'); the page's own auth code then fills in
// the profile block via AudacShell.setUser(...).
(function () {
  const ICONS = {
    home: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 10.5 12 4l8 6.5V20h-5.5v-5.5h-5V20H4z"/>',
    plus: '<path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" d="M12 5v14M5 12h14"/>',
    list: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01"/>',
    upload: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M12 15V4m0 0-4 4m4-4 4 4M4 15v4a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-4"/>',
    grid: '<path fill="none" stroke="currentColor" stroke-width="1.8" d="M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z"/>',
    user: '<path fill="none" stroke="currentColor" stroke-width="1.8" d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-7 8c0-3.3 3.1-5.5 7-5.5s7 2.2 7 5.5"/>',
    out: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M15 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4M10 17l5-5-5-5M15 12H3"/>',
    up: '<path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" d="m6 15 6-6 6 6"/>',
    down: '<path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" d="m6 9 6 6 6-6"/>',
    check: '<path fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" d="m5 12.5 4.5 4.5L19 7.5"/>',
    lock: '<path fill="none" stroke="currentColor" stroke-width="1.8" d="M7 11V8a5 5 0 0 1 10 0v3M5.5 11h13v9h-13z"/>',
    spark: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M12 3v4M12 17v4M3 12h4M17 12h4"/>',
  };
  const icon = (name, attrs = '') => `<svg viewBox="0 0 24 24" aria-hidden="true" ${attrs}>${ICONS[name] || ''}</svg>`;

  const NAV = [
    { key: 'home', href: '/home', label: 'Home', short: 'Home', icon: 'home' },
    { key: 'log', href: '/form', label: 'Log activity', short: 'Log', icon: 'plus' },
    { key: 'submissions', href: '/form#my-submissions-section', label: 'My submissions', short: 'Submissions', icon: 'list' },
    { key: 'import', href: '/import', label: 'Import CRM export', short: 'Import', icon: 'upload' },
  ];

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function initials(name) {
    const parts = String(name || '').trim().split(/[\s@._-]+/).filter(Boolean);
    return ((parts[0] || '?')[0] + (parts[1] ? parts[1][0] : '')).toUpperCase();
  }

  let active = 'home';
  let extraItems = [];

  function render() {
    const items = [...NAV, ...extraItems];
    const side = document.getElementById('app-sidebar');
    if (side) {
      side.innerHTML = `
        <a class="brand" href="/home"><b>AUDAC</b><span>Rep Portal</span></a>
        <div class="nav-section" id="app-nav-section"></div>
        ${items.map(n => `<a class="nav-item" href="${n.href}"${n.key === active ? ' aria-current="page"' : ''}>${icon(n.icon)}${esc(n.label)}</a>`).join('')}
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
  }

  window.AudacShell = {
    icon,
    mount(activeKey) { active = activeKey; render(); },
    // Managers using a rep page (e.g. Import) get a way back to their own pages.
    addItem(item) { extraItems.push(item); render(); },
    setSection(text) { const el = document.getElementById('app-nav-section'); if (el) el.textContent = text || ''; },
    setUser({ name, sub }) {
      const p = document.getElementById('app-profile');
      if (!p) return;
      p.hidden = !name;
      document.getElementById('app-avatar').textContent = initials(name);
      document.getElementById('app-user-name').textContent = name || '';
      document.getElementById('app-user-sub').textContent = sub || '';
    },
    onSignOut(fn) {
      document.addEventListener('click', (e) => { if (e.target.closest('#app-signout')) fn(); });
    },
  };
})();
