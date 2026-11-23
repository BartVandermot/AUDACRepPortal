// project-writeback: writes the projects rep firms import from their own CRM
// (rep_projects, /import-projects) to Dynamics (Bart, 2026-11-19).
//
// Rules:
//   - Only open projects that are NOT registered via AVL (no matched_crm_id).
//     A registration exists in Dynamics already (PVS Portal).
//   - A project that looks like a registration (suggested_crm_id) waits until
//     the rep confirms "same project" or "different project" (0074).
//   - As a "Regular Opportunity", Origin "AUDAC Rep App", with Rep Firm and
//     Rep CRM ID. Upsert on the alternate key (Rep Firm + Rep CRM ID), so a
//     re-import updates the same opportunity and never duplicates.
//   - Owner: the app user itself (no assign). Customer: Intellimix (AVL), like
//     the registrations. Country: Canada for PAG Canada, else United States.
//   - Est. Revenue stays empty: Dynamics only has EUR and the pipeline is AVL's
//     purchase value; the rep's USD value goes in the description.
//   - Only touches opportunities it created itself (dynamics_id / Origin
//     AUDAC Rep App). Never deletes. A project that is registered via AVL
//     afterwards, or won/lost in the rep's CRM, gets its Rep App opportunity
//     closed (Canceled / Won / Lost).
//
// Called by pg_cron every 5 minutes when something waits and the switch
// (app_flags.crm_writeback_enabled) is on, or by a manager.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DATAVERSE_TENANT_ID = Deno.env.get("DATAVERSE_TENANT_ID")!;
const DATAVERSE_CLIENT_ID = Deno.env.get("DATAVERSE_CLIENT_ID")!;
const DATAVERSE_CLIENT_SECRET = Deno.env.get("DATAVERSE_CLIENT_SECRET")!;
const ORG = (Deno.env.get("DATAVERSE_ORG_URL") || "").replace(/\/+$/, "");
const API = `${ORG}/api/data/v9.2`;

const COUNTRY = { US: "45adf5cd-c846-e811-a9c6-000d3a254a9a", CA: "c1abf5cd-c846-e811-a9c6-000d3a254a9a" } as const;
const PAG_CANADA_FIRM_ID = "c1a84e17-3e17-4af0-8f8b-47c229e8fda1";
const CUSTOMER_INTELLIMIX = "18930a0b-52b1-ed11-83ff-000d3aac74f3";   // INTELLIMIX CORP. (DBA AVL MEDIA GROUP)
const TYPE_REGULAR = 921970001;                                       // pvs_opportunitytype: Regular Opportunity
const ORIGIN_REP_APP = 921970002;                                     // pvs_opportunityorigincode: AUDAC Rep App
const STATUS_WON = 3, STATUS_CANCELED = 4, STATUS_LOST = 921970005;
const MAX_ATTEMPTS = 5;
const BATCH = 25;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-secret",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
const lit = (s: string) => `'${s.replace(/'/g, "''")}'`;
const usd = (n: number | null) => n == null ? null : "$" + Number(n).toLocaleString("en-US", { maximumFractionDigits: 0 });

let tokenCache: string | null = null;
async function dvToken(): Promise<string> {
  if (tokenCache) return tokenCache;
  const res = await fetch(`https://login.microsoftonline.com/${DATAVERSE_TENANT_ID}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: DATAVERSE_CLIENT_ID, client_secret: DATAVERSE_CLIENT_SECRET, grant_type: "client_credentials", scope: `${ORG}/.default` }),
  });
  if (!res.ok) throw new Error(`Dynamics sign-in failed: ${res.status} ${await res.text()}`);
  tokenCache = (await res.json()).access_token;
  return tokenCache!;
}
// deno-lint-ignore no-explicit-any
async function dv(method: "GET" | "POST" | "PATCH", path: string, body?: unknown, extra: Record<string, string> = {}): Promise<{ ok: boolean; status: number; data: any; error: string }> {
  const res = await fetch(`${API}/${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${await dvToken()}`,
      Accept: "application/json",
      "Content-Type": "application/json; charset=utf-8",
      "OData-MaxVersion": "4.0",
      "OData-Version": "4.0",
      ...(method !== "GET" ? { Prefer: "return=representation" } : {}),
      ...extra,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  // deno-lint-ignore no-explicit-any
  let data: any = null;
  try { data = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  const error = res.ok ? "" : (data?.error?.message || text || `HTTP ${res.status}`).slice(0, 500);
  return { ok: res.ok, status: res.status, data, error };
}

// deno-lint-ignore no-explicit-any
function description(p: any, firmName: string): string {
  const lines = [
    `Imported from ${firmName}'s own CRM by the AUDAC Rep App (project id ${p.rep_crm_id}). Not registered with AVL.`,
    p.value_usd != null ? `Rep value: ${usd(p.value_usd)} (USD, from the rep's CRM)` : null,
    p.dealer_name ? `Dealer: ${p.dealer_name}` : null,
    p.stage ? `Stage in the rep's CRM: ${p.stage}` : null,
    p.entered_date ? `Entered in the rep's CRM: ${p.entered_date}` : null,
    p.sales_person ? `Sales person: ${p.sales_person}` : null,
    p.products ? `Products: ${p.products}` : null,
    p.notes ? `Notes: ${p.notes}` : null,
  ].filter(Boolean);
  return lines.join("\n").slice(0, 2000);
}

// deno-lint-ignore no-explicit-any
async function setRow(svc: any, id: string, patch: Record<string, unknown>) {
  const { error } = await svc.from("rep_projects").update(patch).eq("id", id);
  if (error) throw new Error(`rep_projects update failed: ${error.message}`);
}

// Close a Rep App opportunity (Won / Lost / Canceled).
async function closeOpportunity(oppId: string, status: number, subject: string) {
  const action = status === STATUS_WON ? "WinOpportunity" : "LoseOpportunity";
  return await dv("POST", action, {
    OpportunityClose: { subject: subject.slice(0, 200), "opportunityid@odata.bind": `/opportunities(${oppId})` },
    Status: status,
  });
}

// deno-lint-ignore no-explicit-any
async function pushOne(svc: any, p: any, firm: { name: string; account: string | null }) {
  // Registered via AVL meanwhile: close our own opportunity, the registration counts.
  if (p.matched_crm_id) {
    if (!p.dynamics_id || p.dynamics_closed_at) {
      await setRow(svc, p.id, { crm_push_status: "skipped", crm_push_error: null });
      return { project: p.project_name, result: "skipped (registered via AVL)" };
    }
    const r = await closeOpportunity(p.dynamics_id, STATUS_CANCELED, `Registered via AVL (${p.project_name})`);
    if (!r.ok) throw new Error(`Closing failed: ${r.error}`);
    await setRow(svc, p.id, { crm_push_status: "sent", crm_push_error: null, dynamics_closed_at: new Date().toISOString() });
    return { project: p.project_name, result: "closed (registered via AVL)" };
  }
  // Won / lost in the rep's CRM.
  if (p.status !== "Open") {
    if (!p.dynamics_id || p.dynamics_closed_at) {
      await setRow(svc, p.id, { crm_push_status: "skipped", crm_push_error: null });
      return { project: p.project_name, result: `skipped (${p.status.toLowerCase()}, never sent)` };
    }
    const r = await closeOpportunity(p.dynamics_id, p.status === "Won" ? STATUS_WON : STATUS_LOST, `${p.status} in ${firm.name}'s CRM`);
    if (!r.ok) throw new Error(`Closing failed: ${r.error}`);
    await setRow(svc, p.id, { crm_push_status: "sent", crm_push_error: null, dynamics_closed_at: new Date().toISOString() });
    return { project: p.project_name, result: `closed (${p.status.toLowerCase()})` };
  }

  const body: Record<string, unknown> = {
    name: String(p.project_name).slice(0, 300),
    pvs_opportunitytype: TYPE_REGULAR,
    pvs_opportunityorigincode: ORIGIN_REP_APP,
    pvs_repcrmid: String(p.rep_crm_id).slice(0, 100),
    pvs_opportunitylocation: p.location ? String(p.location).slice(0, 100) : null,
    estimatedclosedate: p.expected_close_date || null,
    description: description(p, firm.name),
    "pvs_CountryLookup@odata.bind": `/scp_countries(${p.rep_firm_id === PAG_CANADA_FIRM_ID ? COUNTRY.CA : COUNTRY.US})`,
    "customerid_account@odata.bind": `/accounts(${CUSTOMER_INTELLIMIX})`,
  };
  if (firm.account) body["pvs_RepFirmId@odata.bind"] = `/accounts(${firm.account})`;
  if (p.dealer_account_external_id && !String(p.dealer_account_external_id).startsWith("manual:")) {
    body["pvs_involvedinstallerid@odata.bind"] = `/accounts(${p.dealer_account_external_id})`;
  }

  let r;
  if (p.dynamics_id) {
    // Ours already: update it (only this record).
    r = await dv("PATCH", `opportunities(${p.dynamics_id})`, body, { "If-Match": "*" });
  } else if (firm.account) {
    // Find it by Rep Firm + Rep CRM ID with a plain read, then update or create.
    // (An upsert addressed by the alternate key needs metadata privileges the
    // role doesn't have; the key itself still blocks a duplicate on create.)
    const filter = `_pvs_repfirmid_value eq ${firm.account} and pvs_repcrmid eq ${lit(String(p.rep_crm_id))}`;
    const found = await dv("GET", `opportunities?$select=opportunityid&$top=1&$filter=${encodeURIComponent(filter)}`);
    if (!found.ok) throw new Error(`Lookup failed: ${found.error}`);
    const existing = found.data?.value?.[0]?.opportunityid;
    r = existing
      ? await dv("PATCH", `opportunities(${existing})`, body, { "If-Match": "*" })
      : await dv("POST", "opportunities", body);
    if (r.ok && existing && !r.data?.opportunityid) r.data = { ...(r.data || {}), opportunityid: existing };
  } else {
    r = await dv("POST", "opportunities", body);
  }
  if (!r.ok) throw new Error(r.error);
  const oppId = r.data?.opportunityid || p.dynamics_id;
  await setRow(svc, p.id, {
    dynamics_id: oppId, crm_push_status: "sent", crm_push_error: null,
    crm_pushed_at: new Date().toISOString(), written_to_dynamics_at: new Date().toISOString(),
  });
  return { project: p.project_name, result: p.dynamics_id ? "updated" : "written", id: oppId };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const svc = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  try {
    // Scheduler (secret) or a manager.
    const secret = req.headers.get("x-sync-secret") || "";
    if (secret) {
      const { data: expected } = await svc.rpc("crm_sync_secret");
      if (!expected || secret !== expected) return json({ error: "Invalid secret" }, 401);
    } else {
      const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: u, error } = await svc.auth.getUser(jwt);
      if (error || !u?.user) return json({ error: "Sign in first" }, 401);
      const { data: prof } = await svc.from("profiles").select("role").eq("id", u.user.id).maybeSingle();
      if (prof?.role !== "manager") return json({ error: "Managers only" }, 403);
    }

    const { data: flag } = await svc.from("app_flags").select("value").eq("key", "crm_writeback_enabled").maybeSingle();
    if (flag?.value !== true) return json({ skipped: "Sending to Dynamics is switched off." });

    const { data: firms, error: fErr } = await svc.from("rep_firms").select("id, name, crm_account_external_id");
    if (fErr) throw fErr;
    const firmById = new Map((firms || []).map((f: any) => [f.id, { name: f.name, account: f.crm_account_external_id || null }]));

    const { data: rows, error } = await svc.from("rep_projects")
      .select("*")
      .in("crm_push_status", ["waiting", "failed"]).lt("crm_push_attempts", MAX_ATTEMPTS)
      // The rep still has to say whether it's the same project as a registration.
      .is("suggested_crm_id", null)
      .order("last_imported_at").limit(BATCH);
    if (error) throw error;

    const results: any[] = [];
    for (const p of rows || []) {
      const firm = firmById.get(p.rep_firm_id) || { name: "the rep firm", account: null };
      try {
        results.push(await pushOne(svc, p, firm));
      } catch (e) {
        const msg = String((e as Error).message || e).slice(0, 500);
        await setRow(svc, p.id, { crm_push_status: "failed", crm_push_error: msg, crm_push_attempts: (p.crm_push_attempts || 0) + 1 });
        results.push({ project: p.project_name, result: "failed", error: msg });
      }
    }
    return json({ processed: results.length, results });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
