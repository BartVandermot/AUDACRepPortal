// Sends queued push notifications (notification_outbox) to every opted-in
// browser/device of each user (push_subscriptions). Standard Web Push:
// payload encrypted per RFC 8291 (aes128gcm) and signed with VAPID (RFC 8292),
// all with Web Crypto -- no third-party push service or library.
//
// Called by pg_cron every minute when something is waiting (x-sync-secret,
// the same internal key as the nightly CRM sync), or by a signed-in user to
// send their own test notification right away.
//
// VAPID keys live in Vault; created here on the first run.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_SUBJECT = "https://audac-rep-portal.vercel.app";
const BATCH = 200;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...corsHeaders } });

// ---------- encoding helpers ----------
const enc = new TextEncoder();
function b64u(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function fromB64u(s: string): Uint8Array {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}
function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, length: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, length * 8));
}

// ---------- VAPID ----------
type Vapid = { publicKey: string; privateKey: CryptoKey };
// deno-lint-ignore no-explicit-any
async function loadVapid(svc: any): Promise<Vapid> {
  let { data } = await svc.rpc("push_vapid_get");
  let row = Array.isArray(data) ? data[0] : data;
  if (!row?.public_key || !row?.private_jwk) {
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const pub = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
    const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
    await svc.rpc("push_vapid_put", { p_public: b64u(pub), p_private_jwk: JSON.stringify(jwk) });
    ({ data } = await svc.rpc("push_vapid_get")); // another run may have won the race
    row = Array.isArray(data) ? data[0] : data;
  }
  const privateKey = await crypto.subtle.importKey("jwk", JSON.parse(row.private_jwk), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return { publicKey: row.public_key, privateKey };
}
const jwtCache = new Map<string, { token: string; exp: number }>();
async function vapidAuth(vapid: Vapid, endpoint: string): Promise<string> {
  const aud = new URL(endpoint).origin;
  const now = Math.floor(Date.now() / 1000);
  const cached = jwtCache.get(aud);
  if (cached && cached.exp - now > 600) return `vapid t=${cached.token}, k=${vapid.publicKey}`;
  const exp = now + 12 * 3600;
  const head = b64u(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const claims = b64u(enc.encode(JSON.stringify({ aud, exp, sub: VAPID_SUBJECT })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, vapid.privateKey, enc.encode(`${head}.${claims}`)));
  const token = `${head}.${claims}.${b64u(sig)}`;
  jwtCache.set(aud, { token, exp });
  return `vapid t=${token}, k=${vapid.publicKey}`;
}

// ---------- RFC 8291 payload encryption (aes128gcm, one record) ----------
async function encryptPayload(payload: Uint8Array, p256dh: string, authSecret: string): Promise<Uint8Array> {
  const uaPublic = fromB64u(p256dh);
  const auth = fromB64u(authSecret);
  const local = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", local.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, local.privateKey, 256));
  const ikm = await hkdf(auth, shared, concat(enc.encode("WebPush: info\0"), uaPublic, asPublic), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, enc.encode("Content-Encoding: nonce\0"), 12);
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, concat(payload, new Uint8Array([2]))));
  const rs = new Uint8Array([0, 0, 16, 0]); // record size 4096
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, cipher);
}

async function sendOne(vapid: Vapid, sub: { endpoint: string; p256dh: string; auth: string }, payload: Uint8Array): Promise<number> {
  const body = await encryptPayload(payload, sub.p256dh, sub.auth);
  const res = await fetch(sub.endpoint, {
    method: "POST",
    headers: {
      Authorization: await vapidAuth(vapid, sub.endpoint),
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      TTL: String(2 * 24 * 3600),
      Urgency: "normal",
    },
    body,
  });
  await res.body?.cancel();
  return res.status;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const svc = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  try {
    // Who is calling: the scheduler (secret) processes everything; a user only their own queue.
    let onlyUser: string | null = null;
    const secret = req.headers.get("x-sync-secret") || "";
    if (secret) {
      const { data: expected } = await svc.rpc("crm_sync_secret");
      if (!expected || secret !== expected) return json({ error: "Invalid secret" }, 401);
    } else {
      const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: u, error } = await svc.auth.getUser(jwt);
      if (error || !u?.user) return json({ error: "Sign in first" }, 401);
      onlyUser = u.user.id;
    }

    let q = svc.from("notification_outbox").select("id, user_id, kind, title, body, url").is("sent_at", null).order("created_at").limit(BATCH);
    if (onlyUser) q = q.eq("user_id", onlyUser);
    const { data: queue, error: qErr } = await q;
    if (qErr) throw qErr;
    if (!queue?.length) return json({ processed: 0 });

    const userIds = [...new Set(queue.map((n) => n.user_id))];
    const { data: subs } = await svc.from("push_subscriptions").select("id, user_id, endpoint, p256dh, auth").in("user_id", userIds).is("disabled_at", null);
    const subsByUser = new Map<string, typeof subs>();
    (subs || []).forEach((s) => { const l = subsByUser.get(s.user_id) || []; l.push(s); subsByUser.set(s.user_id, l); });

    const vapid = await loadVapid(svc);
    let delivered = 0;
    for (const n of queue) {
      const targets = subsByUser.get(n.user_id) || [];
      const payload = enc.encode(JSON.stringify({ title: n.title, body: n.body || "", url: n.url || "/home", tag: `${n.kind}` }));
      let ok = 0;
      const errors: string[] = [];
      for (const s of targets) {
        try {
          const status = await sendOne(vapid, s, payload);
          if (status >= 200 && status < 300) {
            ok++;
            await svc.from("push_subscriptions").update({ last_success_at: new Date().toISOString() }).eq("id", s.id);
          } else if (status === 404 || status === 410) {
            // The browser unsubscribed or the subscription expired.
            await svc.from("push_subscriptions").update({ disabled_at: new Date().toISOString() }).eq("id", s.id);
            errors.push(`gone (${status})`);
          } else errors.push(`status ${status}`);
        } catch (e) { errors.push(String((e as Error)?.message || e).slice(0, 120)); }
      }
      delivered += ok;
      await svc.from("notification_outbox").update({
        sent_at: new Date().toISOString(), delivered: ok,
        error: targets.length ? (errors.length ? errors.join("; ").slice(0, 500) : null) : "no subscription",
      }).eq("id", n.id);
    }
    return json({ processed: queue.length, delivered });
  } catch (err) {
    return json({ error: String((err as Error)?.message || err) }, 500);
  }
});
