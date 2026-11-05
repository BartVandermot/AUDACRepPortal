// Full CRM sync (Dynamics -> accounts, contacts, opportunities, leads) run server-side
// by the dataverse-sync edge function as a chained, logged run (sync_runs).
// The same run the nightly pg_cron job starts at 03:00 UTC; these helpers let
// a manager page start one on demand and follow its progress.
(function () {
  const POLL_MS = 2000;
  const MAX_WAIT_MS = 10 * 60 * 1000;
  const PHASE_LABEL = { accounts: 'accounts', contacts: 'contacts', opportunities: 'opportunities', leads: 'leads', done: 'finishing' };

  const esc = (s) => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  function plural(n, one, many) { return `${n} ${n === 1 ? one : (many || one + 's')}`; }

  window.AudacSync = {
    NIGHTLY_LABEL: 'every night at 03:00 UTC',

    async latest(client, limit = 5) {
      const { data } = await client.from('sync_runs').select('*').order('started_at', { ascending: false }).limit(limit);
      return data || [];
    },

    async lastOk(client) {
      const { data } = await client.from('sync_runs').select('*').eq('status', 'ok').order('finished_at', { ascending: false }).limit(1);
      return data?.[0] || null;
    },

    // Starts a run (or joins the one already running). Returns { runId, alreadyRunning }.
    async start(client) {
      const { data, error } = await client.functions.invoke('dataverse-sync', { body: { chain: true } });
      if (error) {
        let msg = error.message;
        try { const body = await error.context?.json?.(); if (body?.error) msg = body.error; } catch { /* keep generic */ }
        throw new Error(msg);
      }
      return data;
    },

    // Polls until the run finishes; calls onUpdate(run) on every poll. Resolves with the final run.
    async watch(client, runId, onUpdate) {
      const t0 = Date.now();
      for (;;) {
        const { data: run } = await client.from('sync_runs').select('*').eq('id', runId).maybeSingle();
        if (run) onUpdate?.(run);
        if (run && run.status !== 'running') return run;
        if (Date.now() - t0 > MAX_WAIT_MS) throw new Error('The sync is taking unusually long. It keeps running in the background; check back later.');
        await new Promise(r => setTimeout(r, POLL_MS));
      }
    },

    // Start + watch in one go.
    async run(client, onUpdate) {
      const { runId } = await this.start(client);
      const run = await this.watch(client, runId, onUpdate);
      this.showAlert(client); // clears (or updates) the red bar
      return run;
    },

    progressText(run) {
      return `Syncing ${PHASE_LABEL[run.phase] || run.phase || ''}… (${plural(run.pages || 0, 'page')} done)`;
    },

    describe(run) {
      if (!run) return 'No full sync has run yet.';
      if (run.status === 'running') return this.progressText(run);
      if (run.status === 'error') return `Sync failed: ${run.error || 'unknown error'}`;
      const s = run.summary || {};
      const secs = run.finished_at ? Math.max(1, Math.round((new Date(run.finished_at) - new Date(run.started_at)) / 1000)) : null;
      const parts = [
        s.accounts && `${s.accounts.processed || 0} accounts (${s.accounts.matched || 0} with a rep firm${s.accounts.deactivated ? `, ${s.accounts.deactivated} deactivated` : ''})`,
        s.contacts && `${s.contacts.processed || 0} contacts${s.contacts.deactivated ? ` (${s.contacts.deactivated} deactivated)` : ''}`,
        s.opportunities && `${s.opportunities.processed || 0} opportunities${s.opportunities.skippedNoMatch ? ` (${s.opportunities.skippedNoMatch} without a firm, skipped)` : ''}`,
        s.leads && `${s.leads.processed || 0} leads`,
      ].filter(Boolean);
      return `Synced ${parts.join(', ')}${secs ? ` in ${secs}s` : ''}.`
        + (s.blockingContacts ? ` ${plural(s.blockingContacts, 'contact')} still ${s.blockingContacts === 1 ? 'blocks' : 'block'} the pipeline.` : '');
    },

    // Red bar at the top of a manager page when the CRM data can't be trusted:
    // the last run failed, or nothing synced successfully for STALE_HOURS
    // (the nightly job itself didn't run). Hidden while a run is in progress.
    STALE_HOURS: 36,
    async showAlert(client) {
      const main = document.querySelector('main.page');
      if (!main) return;
      const [[last], ok] = await Promise.all([this.latest(client, 1), this.lastOk(client)]);
      document.getElementById('sync-alert')?.remove();
      if (!last || last.status === 'running') return;
      const okAt = ok?.finished_at || null;
      const staleHours = okAt ? (Date.now() - new Date(okAt)) / 3600000 : Infinity;
      let msg = null;
      if (last.status === 'error') {
        msg = `<b>The CRM sync failed</b> ${this.ago(last.finished_at || last.started_at)}: ${esc(last.error || 'unknown error')}.`;
      } else if (staleHours > this.STALE_HOURS) {
        msg = `<b>The CRM hasn't synced since ${okAt ? this.ago(okAt) : 'ever'}.</b> The nightly sync didn't run.`;
      }
      if (!msg) return;
      if (!document.getElementById('sync-alert-style')) {
        const st = document.createElement('style');
        st.id = 'sync-alert-style';
        st.textContent = `.sync-alert{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin:0 0 16px;padding:10px 14px;border:1px solid var(--color-danger);border-radius:12px;background:var(--color-danger-tint);color:var(--color-text-primary);font-size:13px}
.sync-alert b{color:var(--color-danger)}.sync-alert span{flex:1 1 320px}.sync-alert a{color:var(--color-text-primary);font-weight:600;white-space:nowrap}`;
        document.head.appendChild(st);
      }
      const bar = document.createElement('div');
      bar.id = 'sync-alert';
      bar.className = 'sync-alert';
      bar.setAttribute('role', 'alert');
      const onDashboard = location.pathname.replace(/\.html$/, '') === '/dashboard';
      bar.innerHTML = `<span>${msg} Data from Dynamics may be out of date until a sync succeeds.</span>`
        + (onDashboard ? '' : '<a href="/dashboard">Retry from the dashboard →</a>');
      main.prepend(bar);
    },

    ago(iso) {
      if (!iso) return 'never';
      const mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
      if (mins < 1) return 'just now';
      if (mins < 60) return `${mins} min ago`;
      const h = Math.floor(mins / 60);
      if (h < 24) return `${h}h ago`;
      const d = Math.floor(h / 24);
      return d === 1 ? 'yesterday' : `${d} days ago`;
    },
  };
})();
