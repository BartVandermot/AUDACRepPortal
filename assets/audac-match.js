// "Is this the same project?" — a project from the rep's own CRM that looks
// like a registration AUDAC already has (0074). The rep decides; we show both
// side by side and why we ask. Used on /import-projects (right after the
// upload) and on My territory.
//
//   AudacMatch.card(project)                 -> HTML for one question
//   AudacMatch.bind(container, client, done) -> wires the Yes / No buttons;
//                                               done() runs after an answer
(function () {
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const date = (iso) => iso ? new Date(String(iso).slice(0, 10) + 'T12:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }) : '';
  const usd = (n) => n == null ? '' : Number(n).toLocaleString('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });

  const css = `
  .match-q { grid-column: 1 / -1; display: grid; gap: var(--space-3); padding: var(--space-4); border-radius: var(--radius-tile);
             border: 1px solid var(--color-gold); background: var(--color-gold-tint); }
  .match-q h3 { margin: 0; font-size: 15px; line-height: 21px; color: var(--color-text-primary); text-wrap: balance; }
  .match-pair { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: var(--space-3); }
  .match-side { padding: var(--space-3); border-radius: var(--radius-input); background: var(--color-surface); border: 1px solid var(--color-border); min-width: 0; }
  .match-side .lbl { display: block; font-size: 11px; letter-spacing: .06em; text-transform: uppercase; color: var(--color-text-muted); margin-bottom: 2px; }
  .match-side b { display: block; overflow-wrap: anywhere; }
  .match-side span.d { display: block; font-size: 13px; line-height: 19px; color: var(--color-text-secondary); overflow-wrap: anywhere; }
  .match-why { margin: 0; padding: 0; list-style: none; display: grid; gap: 4px; font-size: 13px; line-height: 19px; }
  .match-why li { display: flex; gap: 8px; align-items: baseline; color: var(--color-text-secondary); }
  .match-why li::before { flex: none; width: 14px; text-align: center; font-weight: 700; }
  .match-why li.ok::before { content: '✓'; color: var(--color-success); }
  .match-why li.no::before { content: '✗'; color: var(--color-danger); }
  .match-why li.unk::before { content: '?'; color: var(--color-text-muted); }
  .match-q .why-title { margin: 0; font-size: 13px; font-weight: 600; color: var(--color-text-primary); }
  .match-q .hint { margin: 0; }
  .match-actions { display: flex; flex-wrap: wrap; gap: var(--space-2); }
  .match-actions button { width: auto; min-height: 40px; padding: 0 18px; }
  .match-q .form-msg { margin: 0; }
  @media (max-width: 560px) { .match-pair { grid-template-columns: 1fr; } .match-actions button { flex: 1 1 100%; } }`;
  let styled = false;
  function style() {
    if (styled) return;
    styled = true;
    const el = document.createElement('style');
    el.textContent = css;
    document.head.appendChild(el);
  }

  function card(p) {
    style();
    const yours = [p.dealer_name, p.location].filter(Boolean).map(esc).join(' · ') || 'No dealer or location';
    const yoursVal = p.value_usd != null ? `${usd(p.value_usd)}` : '';
    const theirsAcct = p.suggested_account && !/^dealer not specified/i.test(p.suggested_account) ? p.suggested_account : '';
    const theirs = [theirsAcct, p.suggested_location].filter(Boolean).map(esc).join(' · ') || 'No dealer or location';
    const kind = p.suggested_registered ? 'Registered with AVL' : 'In AUDAC’s CRM';
    const signals = Array.isArray(p.match_signals) ? p.match_signals : [];
    return `<div class="match-q" data-match="${esc(p.id)}">
      <h3>Is this the same project as one AUDAC already has?</h3>
      <div class="match-pair">
        <div class="match-side"><span class="lbl">Your CRM</span><b>${esc(p.project_name)}</b>
          <span class="d">${yours}</span>${yoursVal ? `<span class="d">${yoursVal}</span>` : ''}</div>
        <div class="match-side"><span class="lbl">${kind}${p.suggested_created_date ? ' ' + esc(date(p.suggested_created_date)) : ''}</span><b>${esc(p.suggested_name || '')}</b>
          <span class="d">${theirs}</span>${p.suggested_dealer_value_usd != null ? `<span class="d">≈ ${usd(p.suggested_dealer_value_usd)} at dealer price</span>` : ''}</div>
      </div>
      <p class="why-title">Why we ask</p>
      <ul class="match-why">${signals.map(s => `<li class="${s.ok === true ? 'ok' : s.ok === false ? 'no' : 'unk'}">${esc(s.text)}</li>`).join('')}</ul>
      <p class="hint">Same project: we link the two, so it isn’t in AUDAC’s CRM twice. Different project: we add yours as a separate project.</p>
      <p class="form-msg" hidden></p>
      <div class="match-actions">
        <button type="button" class="button-primary" data-match-answer="yes">Yes, same project</button>
        <button type="button" class="button-secondary" data-match-answer="no">No, different project</button>
      </div>
    </div>`;
  }

  function bind(container, client, done) {
    container.addEventListener('click', async (e) => {
      const btn = e.target.closest('[data-match-answer]');
      if (!btn) return;
      const box = btn.closest('[data-match]');
      const same = btn.dataset.matchAnswer === 'yes';
      box.querySelectorAll('button').forEach(b => { b.disabled = true; });
      btn.textContent = 'Saving…';
      const { error } = await client.rpc('confirm_rep_project_match', { p_project_id: box.dataset.match, p_same: same });
      if (error) {
        const msg = box.querySelector('.form-msg');
        msg.hidden = false;
        msg.textContent = 'Could not save your answer: ' + error.message;
        box.querySelectorAll('button').forEach(b => { b.disabled = false; });
        btn.textContent = same ? 'Yes, same project' : 'No, different project';
        return;
      }
      if (done) done(same);
    });
  }

  window.AudacMatch = { card, bind };
})();
