// Activities saved without a connection (Bart, 2026-11-09).
// When Save on the Log page can't reach the server, the activity (and its
// photos) is kept on the phone in IndexedDB and sent automatically once the
// connection is back: on page load, when the phone comes online, when the app
// comes to the front, and every 30 s while something is waiting.
//
// Safe to retry: every activity and photo has an id made on the phone, so a
// send that did reach the server before the connection dropped is recognised
// (duplicate key) instead of saved twice.
(function () {
  const DB = 'audac-outbox', STORE = 'items';
  let client = null, userId = null, listeners = [], timer = null, flushing = null;

  function db() {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(DB, 1);
      req.onupgradeneeded = () => req.result.createObjectStore(STORE, { keyPath: 'id' });
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }
  async function tx(mode, fn) {
    const d = await db();
    return new Promise((resolve, reject) => {
      const t = d.transaction(STORE, mode);
      const out = fn(t.objectStore(STORE));
      t.oncomplete = () => resolve(out && 'result' in out ? out.result : undefined);
      t.onerror = () => reject(t.error);
    });
  }
  const all = async () => ((await tx('readonly', s => s.getAll())) || []).filter(i => i.userId === userId)
    .sort((a, b) => a.createdAt - b.createdAt);

  // A failure of the connection (as opposed to the server saying no).
  function isNetworkError(err, status) {
    if (status === 0) return true;
    const m = String((err && (err.message || err.error || err)) || '');
    return /failed to fetch|networkerror|network request failed|load failed|internet connection|abort|timed? ?out|offline/i.test(m);
  }
  const isDuplicate = (err) => err && (err.code === '23505' || /duplicate|already exists/i.test(String(err.message || err.error || '')) || String(err.statusCode) === '409');

  async function notify() {
    const items = userId ? await all() : [];
    listeners.forEach(fn => { try { fn(items); } catch { /* listener errors stay local */ } });
    clearInterval(timer); timer = null;
    if (items.some(i => !i.error)) timer = setInterval(() => flush(), 30000);
  }

  async function sendOne(item) {
    const signal = () => (window.AbortSignal && AbortSignal.timeout ? AbortSignal.timeout(20000) : undefined);
    if (!item.rowsSent) {
      let q = client.from('activity_entries').insert(item.rows);
      const sig = signal(); if (sig) q = q.abortSignal(sig);
      const { error, status } = await q;
      if (error && !isDuplicate(error)) {
        if (isNetworkError(error, status)) return 'offline';
        item.error = error.message || 'The server refused this activity.';
        await tx('readwrite', s => s.put(item));
        return 'refused';
      }
      item.rowsSent = true;
      await tx('readwrite', s => s.put(item));
    }
    for (const f of item.files || []) {
      if (f.done) continue;
      const up = await client.storage.from('activity-attachments').upload(f.path, f.blob, { contentType: f.type });
      if (up.error && !isDuplicate(up.error)) {
        if (isNetworkError(up.error)) return 'offline';
        f.done = true; f.failed = up.error.message; // a refused photo doesn't hold the rest back
      } else {
        const meta = await client.from('activity_attachments').insert({
          id: f.metaId, activity_entry_id: f.entryId, storage_path: f.path, file_name: f.name, content_type: f.type, uploaded_by: item.userId,
        });
        if (meta.error && !isDuplicate(meta.error)) {
          if (isNetworkError(meta.error, meta.status)) return 'offline';
          f.failed = meta.error.message;
        }
        f.done = true;
      }
      await tx('readwrite', s => s.put(item));
    }
    await tx('readwrite', s => s.delete(item.id));
    return 'sent';
  }

  async function flush() {
    if (!client || !userId) return { sent: 0 };
    if (flushing) return flushing;
    flushing = (async () => {
      let sent = 0;
      try {
        const { data: { session } } = await client.auth.getSession();
        if (!session || session.user.id !== userId) return { sent };
        for (const item of await all()) {
          if (item.error) continue;
          const r = await sendOne(item);
          if (r === 'offline') break;
          if (r === 'sent') sent++;
        }
      } catch { /* try again on the next trigger */ }
      return { sent };
    })();
    const res = await flushing;
    flushing = null;
    await notify();
    if (res.sent) window.dispatchEvent(new CustomEvent('audac-outbox-sent', { detail: res }));
    return res;
  }

  window.AudacOutbox = {
    isNetworkError,
    /** Starts sending for this user; call once the session is known. */
    init(supabaseClient, uid) {
      if (!('indexedDB' in window)) return;
      client = supabaseClient; userId = uid;
      window.addEventListener('online', () => flush());
      document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') flush(); });
      flush();
    },
    /** Keeps activities on the phone. rows: activity_entries rows (with ids);
     *  files: [{ entryId, file }]; opts.rowsSent: only the photos still have to go. */
    async add(rows, files, opts = {}) {
      const item = {
        id: (crypto.randomUUID && crypto.randomUUID()) || String(Date.now()),
        userId, createdAt: Date.now(), rows, rowsSent: !!opts.rowsSent,
        files: (files || []).map(({ entryId, file }) => ({
          entryId, metaId: crypto.randomUUID(), path: `${entryId}/${Date.now()}-${file.name}`,
          name: file.name, type: file.type, blob: file, done: false,
        })),
      };
      await tx('readwrite', s => s.put(item));
      await notify();
      return item;
    },
    async items() { return userId ? all() : []; },
    async remove(id) { await tx('readwrite', s => s.delete(id)); await notify(); },
    flush,
    /** fn(items) runs now and after every change. */
    onChange(fn) { listeners.push(fn); if (userId) all().then(fn).catch(() => {}); },
    /** Shows what's waiting in el (a .notice); hidden when nothing is. */
    mountNotice(el) {
      const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
      const label = (i) => esc((i.rows[0] && i.rows[0].account_name) || 'Photos') + (i.rows.length > 1 ? ` + ${i.rows.length - 1} more` : '');
      el.addEventListener('click', async (e) => {
        const b = e.target.closest('button');
        if (!b) return;
        if (b.dataset.outboxSend !== undefined) {
          b.disabled = true; b.textContent = 'Sending…';
          const { sent } = await flush();
          if (!sent && !el.hidden) { b.disabled = false; b.textContent = 'Still no connection. Try again'; }
        }
        if (b.dataset.outboxRemove && confirm('Remove this activity from your phone? It was not saved at AUDAC.')) AudacOutbox.remove(b.dataset.outboxRemove);
      });
      this.onChange((items) => {
        const waiting = items.filter(i => !i.error), refused = items.filter(i => i.error);
        const acts = waiting.reduce((n, i) => n + (i.rows.length || 0), 0);
        const parts = [];
        if (waiting.length) parts.push(`<div class="outbox-row"><span><b>${acts ? `${acts} ${acts === 1 ? 'activity' : 'activities'}` : 'Photos'} waiting to be sent</b> (${waiting.map(label).join(', ')}). They go automatically as soon as you’re online.</span><button type="button" class="button-secondary" data-outbox-send>Send now</button></div>`);
        for (const i of refused) parts.push(`<div class="outbox-row"><span><b>Couldn’t save ${label(i)}:</b> ${esc(i.error)}</span><button type="button" class="button-secondary" data-outbox-remove="${esc(i.id)}">Remove</button></div>`);
        el.innerHTML = parts.join('');
        el.hidden = !parts.length;
      });
    },
  };
})();
