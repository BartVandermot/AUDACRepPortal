// Full CRM sync (Dynamics -> accounts, contacts, opportunities) run server-side
// by the dataverse-sync edge function as a chained, logged run (sync_runs).
// The same run the nightly pg_cron job starts at 03:00 UTC; these helpers let
// a manager page start one on demand and follow its progress.
(function () {
  const POLL_MS = 2000;
  const MAX_WAIT_MS = 10 * 60 * 1000;
  const PHASE_LABEL = { accounts: 'accounts', contacts: 'contacts', opportunities: 'opportunities', done: 'finishing' };

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
      return this.watch(client, runId, onUpdate);
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
      ].filter(Boolean);
      return `Synced ${parts.join(', ')}${secs ? ` in ${secs}s` : ''}.`
        + (s.blockingContacts ? ` ${plural(s.blockingContacts, 'contact')} still ${s.blockingContacts === 1 ? 'blocks' : 'block'} the pipeline.` : '');
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
