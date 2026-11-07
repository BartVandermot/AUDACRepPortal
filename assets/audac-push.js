// Push notifications for the AUDAC Rep Portal (Web Push, opt-in per device).
//   AudacPush.state()          -> 'unsupported' | 'install-first' | 'denied' | 'on' | 'off'
//   AudacPush.enable(client)   -> asks permission, subscribes, saves it
//   AudacPush.disable(client)  -> unsubscribes this device
//   AudacPush.test(client)     -> sends a test notification to this user now
//   AudacPush.mountCard(el, client, { audience: 'rep' | 'manager' })
// iPhone/iPad only allow web push from the portal added to the Home Screen
// (iOS 16.4+), so there it first explains how to do that.
(function () {
  const css = document.createElement('style');
  css.textContent = `
    .push-card { padding: var(--space-5) var(--space-6); }
    .push-head { display: flex; align-items: center; gap: var(--space-2); }
    .push-head .card-title { margin: 0; }
    .push-text { margin: var(--space-2) 0 0; font-size: 14px; line-height: 21px; color: var(--color-text-secondary); max-width: 70ch; }
    .push-actions { display: flex; align-items: center; gap: var(--space-3); flex-wrap: wrap; margin-top: var(--space-3); }
    .push-actions:empty { display: none; }
    .push-btn { width: auto; min-height: 40px; padding: 0 16px; }
    .push-msg { margin: var(--space-2) 0 0; font-size: 13.5px; line-height: 20px; }
    .push-msg.ok { color: var(--color-success); }
    .push-msg.err { color: var(--color-danger); }`;
  document.head.appendChild(css);
  const isIOS =() => /iPhone|iPad|iPod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const standalone = () => window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
  const supported = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  const keyBytes = (b64u) => {
    const s = atob(b64u.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((b64u.length + 3) % 4));
    return Uint8Array.from(s, (c) => c.charCodeAt(0));
  };

  async function registration() {
    return (await navigator.serviceWorker.getRegistration('/')) || navigator.serviceWorker.register('/sw.js', { scope: '/' });
  }

  async function state() {
    if (isIOS() && !standalone()) return 'install-first';
    if (!supported()) return 'unsupported';
    if (Notification.permission === 'denied') return 'denied';
    const reg = await navigator.serviceWorker.getRegistration('/');
    const sub = reg && (await reg.pushManager.getSubscription());
    return sub && Notification.permission === 'granted' ? 'on' : 'off';
  }

  async function enable(client) {
    if (Notification.permission !== 'granted') {
      const perm = await Notification.requestPermission();
      if (perm !== 'granted') throw new Error(perm === 'denied' ? 'Notifications are blocked for this site in your browser settings.' : 'Notifications were not allowed.');
    }
    const { data: key, error } = await client.rpc('push_public_key');
    if (error) throw error;
    if (!key) {
      // First use ever: the server creates its keys on its first run.
      await client.functions.invoke('push-send', { body: {} });
      const again = await client.rpc('push_public_key');
      if (!again.data) throw new Error('Notifications are not ready yet. Try again in a minute.');
      return enableWithKey(client, again.data);
    }
    return enableWithKey(client, key);
  }
  async function enableWithKey(client, key) {
    const reg = await registration();
    await navigator.serviceWorker.ready;
    let sub = await reg.pushManager.getSubscription();
    if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(key) });
    const j = sub.toJSON();
    const { error } = await client.rpc('save_push_subscription', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_user_agent: navigator.userAgent });
    if (error) throw error;
  }

  async function disable(client) {
    const reg = await navigator.serviceWorker.getRegistration('/');
    const sub = reg && (await reg.pushManager.getSubscription());
    if (!sub) return;
    await client.rpc('remove_push_subscription', { p_endpoint: sub.endpoint });
    await sub.unsubscribe();
  }

  async function test(client) {
    const { error } = await client.rpc('queue_test_push');
    if (error) throw error;
    const res = await client.functions.invoke('push-send', { body: {} });
    if (res.error) throw res.error;
    return res.data;
  }

  // A small self-contained card: explains, toggles, offers a test.
  function mountCard(el, client, { audience = 'rep' } = {}) {
    const what = audience === 'manager'
      ? 'Get a notification on this device when a rep asks a question.'
      : 'Get a notification on this device when AUDAC forwards you a new lead (and one reminder if it’s still open after 10 days), leaves you a note, or answers your question.';
    const say = (msg, cls) => {
      let p = el.querySelector('.push-msg');
      if (!p) { p = document.createElement('p'); el.appendChild(p); }
      p.className = 'push-msg ' + (cls || '');
      p.textContent = msg;
    };
    const render = async (msg, cls) => {
      let s;
      try { s = await state(); } catch { s = 'off'; }
      const body = {
        'install-first': 'On iPhone and iPad, notifications only work from the app on your Home Screen: tap Share, then “Add to Home Screen”, open the portal from there and turn notifications on.',
        unsupported: 'This browser doesn’t support notifications. Try Chrome, Edge or Safari.',
        denied: 'Notifications are blocked for this site. Allow them via the icon in the address bar (or the site settings), then come back here.',
        on: 'Notifications are on for this device.',
        off: what,
      }[s];
      el.innerHTML = `
        <div class="push-head"><h3 class="card-title">Notifications</h3>${s === 'on' ? '<span class="chip ok">On</span>' : ''}</div>
        <p class="push-text">${body}</p>
        <div class="push-actions">
          ${s === 'off' ? '<button type="button" class="button-primary push-btn" data-push="on">Turn on notifications</button>' : ''}
          ${s === 'on' ? '<button type="button" class="button-secondary push-btn" data-push="test">Send a test</button><button type="button" class="link-btn" data-push="off">Turn off</button>' : ''}
        </div>
        ${msg ? `<p class="push-msg ${cls || ''}">${msg}</p>` : ''}`;
      el.hidden = false;
    };
    el.addEventListener('click', async (e) => {
      const b = e.target.closest('[data-push]');
      if (!b) return;
      b.disabled = true;
      // Edge and Chrome often ask "quietly": no pop-up, only an icon in the
      // address bar -- and the permission request just waits until it's used.
      const ASK = 'Your browser is asking for permission. No pop-up? Click the bell or lock icon in the address bar and choose Allow.';
      let nudge = null;
      if (b.dataset.push === 'on' && Notification.permission === 'default') {
        say(ASK);
        nudge = setTimeout(() => say(ASK + ' Still nothing? Check that this browser may show notifications in Windows or macOS settings.'), 8000);
      }
      try {
        if (b.dataset.push === 'on') { await enable(client); clearTimeout(nudge); await render('Done. You’ll get a test notification in a moment.', 'ok'); await test(client); }
        else if (b.dataset.push === 'off') { await disable(client); await render('Notifications are off for this device.'); }
        else { await test(client); await render('Test sent. It should appear within a few seconds.', 'ok'); }
      } catch (err) { clearTimeout(nudge); await render(String(err.message || err), 'err'); }
    });
    render().catch((err) => { el.hidden = false; say('Notifications could not be loaded: ' + (err.message || err), 'err'); });
  }

  window.AudacPush = { state, enable, disable, test, mountCard, supported };
})();
