// crm-writeback: creates the companies and contacts reps add in the portal in
// Dynamics (Bart, 2026-11-07), then merges the portal's temporary "manual:"
// record into the real Dynamics record so the nightly sync never duplicates it.
//
// Rules (agreed with Bart):
//   - Account first, then its contacts: a contact is only sent once its
//     company exists in Dynamics, and is always linked to it.
//   - Owner of every record: Bart.
//   - Only creates. Never updates, deletes, assigns or merges in Dynamics.
//   - Before creating, look for the same record in Dynamics (company: same
//     name in the same country; contact: same e-mail). Found -> link to it,
//     don't create. Dynamics' own duplicate detection is switched on as well.
//   - The rep firm follows the portal's logic (state / ZIP), so the address
//     goes in as the rep typed it; nothing else decides the firm.
//   - Required in Dynamics: account name, relationship type, country; contact
//     last name, e-mail, language, country.
//
// Called by pg_cron every 5 minutes when something waits and the switch
// (app_flags.crm_writeback_enabled) is on, or by a manager ("Send now").

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DATAVERSE_TENANT_ID = Deno.env.get("DATAVERSE_TENANT_ID")!;
const DATAVERSE_CLIENT_ID = Deno.env.get("DATAVERSE_CLIENT_ID")!;
const DATAVERSE_CLIENT_SECRET = Deno.env.get("DATAVERSE_CLIENT_SECRET")!;
const ORG = (Deno.env.get("DATAVERSE_ORG_URL") || "").replace(/\/+$/, "");
const API = `${ORG}/api/data/v9.2`;

const OWNER_BART = "83f0f646-cff9-e711-a954-000d3a254a9a";           // systemuser Bart Vandermot
const COUNTRY = { US: "45adf5cd-c846-e811-a9c6-000d3a254a9a", CA: "c1abf5cd-c846-e811-a9c6-000d3a254a9a" } as const;
const COUNTRY_NAME = { US: "United States", CA: "Canada" } as const;
const PAG_CANADA_FIRM_ID = "c1a84e17-3e17-4af0-8f8b-47c229e8fda1";
const LANGUAGE_EN = 921970001;                                        // pvs_contactlanguage
const MAX_ATTEMPTS = 5;
const BATCH = 15;

// Relationship type (customertypecode) and business type from how the rep
// described the company on its first activity.
const TYPE_BY_CONTACT_TYPE: Record<string, { customertypecode: number; businesstypecode?: number }> = {
  "Dealer": { customertypecode: 9, businesstypecode: 921970000 },          // Reseller, A/V Integrator
  "Consultant": { customertypecode: 6, businesstypecode: 921970008 },      // Influencer, Study/Consultancy Office
  "End User": { customertypecode: 921970002 },                             // End User
};
const DEFAULT_TYPE = { customertypecode: 8 };                              // Prospect

const STATE_NAME: Record<string, string> = {
  AL: "Alabama", AK: "Alaska", AZ: "Arizona", AR: "Arkansas", CA: "California", CO: "Colorado", CT: "Connecticut",
  DE: "Delaware", DC: "District of Columbia", FL: "Florida", GA: "Georgia", HI: "Hawaii", ID: "Idaho", IL: "Illinois",
  IN: "Indiana", IA: "Iowa", KS: "Kansas", KY: "Kentucky", LA: "Louisiana", ME: "Maine", MD: "Maryland",
  MA: "Massachusetts", MI: "Michigan", MN: "Minnesota", MS: "Mississippi", MO: "Missouri", MT: "Montana",
  NE: "Nebraska", NV: "Nevada", NH: "New Hampshire", NJ: "New Jersey", NM: "New Mexico", NY: "New York",
  NC: "North Carolina", ND: "North Dakota", OH: "Ohio", OK: "Oklahoma", OR: "Oregon", PA: "Pennsylvania",
  RI: "Rhode Island", SC: "South Carolina", SD: "South Dakota", TN: "Tennessee", TX: "Texas", UT: "Utah",
  VT: "Vermont", VA: "Virginia", WA: "Washington", WV: "West Virginia", WI: "Wisconsin", WY: "Wyoming",
  PR: "Puerto Rico", GU: "Guam",
};
const PROVINCE_NAME: Record<string, string> = {
  AB: "Alberta", BC: "British Columbia", MB: "Manitoba", NB: "New Brunswick", NL: "Newfoundland and Labrador",
  NS: "Nova Scotia", ON: "Ontario", PE: "Prince Edward Island", QC: "Quebec", SK: "Saskatchewan",
  NT: "Northwest Territories", NU: "Nunavut", YT: "Yukon",
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-secret",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
const lit = (s: string) => `'${s.replace(/'/g, "''")}'`;   // OData string literal
const cleanPhone = (p: string | null) => (p && p.replace(/\D/g, "").length >= 10 ? p.trim() : undefined);
const validEmail = (e: string | null) => !!e && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e.trim());

// ---------- Dataverse ----------
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
async function dv(method: "GET" | "POST", path: string, body?: unknown): Promise<{ ok: boolean; status: number; data: any; error: string }> {
  const res = await fetch(`${API}/${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${await dvToken()}`,
      Accept: "application/json",
      "Content-Type": "application/json; charset=utf-8",
      "OData-MaxVersion": "4.0",
      "OData-Version": "4.0",
      Prefer: method === "POST" ? "return=representation" : 'odata.include-annotations="OData.Community.Display.V1.FormattedValue"',
      // Let Dynamics' own duplicate detection rules refuse a duplicate too.
      ...(method === "POST" ? { "MSCRM.SuppressDuplicateDetection": "false" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data: any = null;
  try { data = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  const error = res.ok ? "" : (data?.error?.message || text || `HTTP ${res.status}`).slice(0, 500);
  return { ok: res.ok, status: res.status, data, error };
}

// ---------- local merge: same steps as merge_manual_crm_account / _contact ----------
async function linkAccountLocally(svc: any, m: any, targetId: string, country: string) {
  const { data: exists } = await svc.from("crm_accounts").select("external_id").eq("external_id", targetId).maybeSingle();
  if (!exists) {
    const { error } = await svc.from("crm_accounts").insert({
      external_id: targetId, name: m.name, name_key: m.name_key, street: m.street, city: m.city,
      state_raw: m.state_code, state_code: m.state_code, zip: m.zip, country_code: country, phone: m.phone,
      rep_firm_id: m.rep_firm_id, source: "dataverse", is_active: true, last_synced_at: new Date().toISOString(), updated_at: new Date().toISOString(),
    });
    if (error) throw new Error(`local insert: ${error.message}`);
  }
  // Contacts first, so no activity points at a contact of another company.
  for (const [table, col, filter] of [
    ["crm_contacts", "parent_account_external_id", { source: "manual" }],
    ["activity_entries", "account_external_id", {}],
    ["pipeline_entries", "account_external_id", {}],
  ] as const) {
    let q = svc.from(table).update({ [col]: targetId }).eq(col, m.external_id);
    for (const [k, v] of Object.entries(filter)) q = q.eq(k, v);
    const { error } = await q;
    if (error) throw new Error(`local ${table}: ${error.message}`);
  }
  const { error: delErr } = await svc.from("crm_accounts").delete().eq("external_id", m.external_id).eq("source", "manual");
  if (delErr) throw new Error(`local cleanup: ${delErr.message}`);
}

async function linkContactLocally(svc: any, m: any, targetId: string) {
  const { data: exists } = await svc.from("crm_contacts").select("external_id").eq("external_id", targetId).maybeSingle();
  if (!exists) {
    const { error } = await svc.from("crm_contacts").insert({
      external_id: targetId, full_name: m.full_name, email: m.email, email_key: m.email_key, phone: m.phone,
      parent_account_external_id: m.parent_account_external_id, rep_firm_id: m.rep_firm_id,
      source: "dataverse", is_active: true, last_synced_at: new Date().toISOString(), updated_at: new Date().toISOString(),
    });
    if (error) throw new Error(`local insert: ${error.message}`);
  }
  for (const [table, col] of [["activity_entries", "contact_external_id"], ["profiles", "crm_contact_external_id"]] as const) {
    const { error } = await svc.from(table).update({ [col]: targetId }).eq(col, m.external_id);
    if (error) throw new Error(`local ${table}: ${error.message}`);
  }
  const { error: delErr } = await svc.from("crm_contacts").delete().eq("external_id", m.external_id).eq("source", "manual");
  if (delErr) throw new Error(`local cleanup: ${delErr.message}`);
}

// ---------- bookkeeping ----------
async function log(svc: any, kind: string, m: any, action: string, dynamicsId: string | null, detail: Record<string, unknown>, by: string | null) {
  await svc.from("crm_writeback_log").insert({ kind, manual_external_id: m.external_id, dynamics_id: dynamicsId, action, name: m.name || m.full_name, detail, requested_by: by });
}
async function setStatus(svc: any, table: string, m: any, status: string, error: string | null, countAttempt: boolean) {
  await svc.from(table).update({
    crm_push_status: status, crm_push_error: error, crm_push_last_at: new Date().toISOString(),
    crm_push_attempts: (m.crm_push_attempts || 0) + (countAttempt ? 1 : 0),
  }).eq("external_id", m.external_id);
}
async function whoAdded(svc: any, m: any): Promise<string> {
  const [{ data: p }, { data: f }] = await Promise.all([
    m.created_by ? svc.from("profiles").select("full_name, email").eq("id", m.created_by).maybeSingle() : Promise.resolve({ data: null }),
    m.rep_firm_id ? svc.from("rep_firms").select("name").eq("id", m.rep_firm_id).maybeSingle() : Promise.resolve({ data: null }),
  ]);
  const who = p?.full_name || p?.email || "a rep";
  return `Added via the AUDAC Rep Portal by ${who}${f?.name ? ` (${f.name})` : ""} on ${new Date().toISOString().slice(0, 10)}.`;
}

// ---------- accounts ----------
function countryOf(m: any): "US" | "CA" | null {
  if (m.state_code && PROVINCE_NAME[m.state_code]) return "CA";
  if (m.state_code && STATE_NAME[m.state_code]) return "US";
  if (m.rep_firm_id === PAG_CANADA_FIRM_ID) return null;   // Canadian but no province: can't place it
  return null;
}

async function pushAccount(svc: any, m: any, by: string | null) {
  const country = countryOf(m);
  if (!country || !m.city) {
    const msg = !country ? "Needs a US state or Canadian province (2-letter code) before it can go to Dynamics." : "Needs a city before it can go to Dynamics.";
    await setStatus(svc, "crm_accounts", m, "needs_info", msg, false);
    await log(svc, "account", m, "needs_info", null, { reason: msg }, by);
    return { name: m.name, result: "needs_info" };
  }

  // Already in Dynamics? Same name, same country, active.
  const found = await dv("GET", `accounts?$select=accountid,name,address1_city&$filter=${encodeURIComponent(`statecode eq 0 and name eq ${lit(m.name)} and _scp_countrylookup_value eq ${COUNTRY[country]}`)}&$top=5`);
  if (!found.ok) throw new Error(`Dynamics lookup: ${found.error}`);
  const hits: any[] = found.data?.value || [];
  let target: string | null = null;
  if (hits.length === 1) target = hits[0].accountid;
  else if (hits.length > 1) {
    const sameCity = hits.filter((h) => (h.address1_city || "").trim().toLowerCase() === String(m.city).trim().toLowerCase());
    if (sameCity.length === 1) target = sameCity[0].accountid;
    else {
      const msg = `Dynamics has ${hits.length} active companies named "${m.name}". Merge it by hand on Accounts & Contacts.`;
      await setStatus(svc, "crm_accounts", m, "needs_info", msg, false);
      await log(svc, "account", m, "needs_info", null, { reason: msg, candidates: hits.map((h) => h.accountid) }, by);
      return { name: m.name, result: "needs_info" };
    }
  }
  if (target) {
    await linkAccountLocally(svc, m, target, country);
    await log(svc, "account", m, "linked_existing", target, {}, by);
    return { name: m.name, result: "linked_existing", id: target };
  }

  // First activity on the company tells what kind it is.
  const { data: firstAct } = await svc.from("activity_entries").select("contact_type").eq("account_external_id", m.external_id).order("entry_date").limit(1).maybeSingle();
  const type = TYPE_BY_CONTACT_TYPE[firstAct?.contact_type || ""] || DEFAULT_TYPE;
  const payload: Record<string, unknown> = {
    name: m.name.trim(),
    ...type,
    accountclassificationcode: 1,
    address1_line1: m.street || undefined,
    address1_city: m.city,
    address1_stateorprovince: country === "CA" ? PROVINCE_NAME[m.state_code] : STATE_NAME[m.state_code],
    address1_postalcode: m.zip || undefined,
    address1_country: COUNTRY_NAME[country],
    telephone1: cleanPhone(m.phone),
    description: await whoAdded(svc, m),
    "scp_CountryLookup@odata.bind": `/scp_countries(${COUNTRY[country]})`,
    "ownerid@odata.bind": `/systemusers(${OWNER_BART})`,
  };
  const res = await dv("POST", "accounts", payload);
  if (!res.ok) {
    await setStatus(svc, "crm_accounts", m, "failed", res.error, true);
    await log(svc, "account", m, "failed", null, { status: res.status, error: res.error }, by);
    return { name: m.name, result: "failed", error: res.error };
  }
  const id = res.data?.accountid;
  await linkAccountLocally(svc, m, id, country);
  await log(svc, "account", m, "created", id, { customertypecode: type.customertypecode }, by);
  return { name: m.name, result: "created", id };
}

// ---------- contacts ----------
async function pushContact(svc: any, m: any, by: string | null) {
  if (!validEmail(m.email)) {
    const msg = "Dynamics needs an e-mail address for a contact.";
    await setStatus(svc, "crm_contacts", m, "needs_info", msg, false);
    await log(svc, "contact", m, "needs_info", null, { reason: msg }, by);
    return { name: m.full_name, result: "needs_info" };
  }
  const { data: parent } = await svc.from("crm_accounts").select("external_id, country_code, source").eq("external_id", m.parent_account_external_id).maybeSingle();
  if (!parent || parent.source !== "dataverse") return { name: m.full_name, result: "waiting_for_company" };
  const country: "US" | "CA" = parent.country_code === "CA" ? "CA" : "US";
  const email = String(m.email).trim();

  // Already in Dynamics? Same e-mail, active.
  const found = await dv("GET", `contacts?$select=contactid,fullname,_parentcustomerid_value&$filter=${encodeURIComponent(`statecode eq 0 and emailaddress1 eq ${lit(email)}`)}&$top=5`);
  if (!found.ok) throw new Error(`Dynamics lookup: ${found.error}`);
  const hits: any[] = found.data?.value || [];
  const sameCompany = hits.find((h) => h._parentcustomerid_value === parent.external_id);
  if (sameCompany) {
    await linkContactLocally(svc, m, sameCompany.contactid);
    await log(svc, "contact", m, "linked_existing", sameCompany.contactid, {}, by);
    return { name: m.full_name, result: "linked_existing", id: sameCompany.contactid };
  }
  if (hits.length) {
    const elsewhere = hits[0]["_parentcustomerid_value@OData.Community.Display.V1.FormattedValue"] || "another company";
    const msg = `This e-mail already exists in Dynamics under ${elsewhere}. Check it by hand.`;
    await setStatus(svc, "crm_contacts", m, "needs_info", msg, false);
    await log(svc, "contact", m, "needs_info", null, { reason: msg, candidates: hits.map((h) => h.contactid) }, by);
    return { name: m.full_name, result: "needs_info" };
  }

  const parts = String(m.full_name || "").trim().split(/\s+/);
  const lastname = parts.length > 1 ? parts.pop()! : parts[0];
  const firstname = parts.length ? parts.join(" ") : undefined;
  const payload: Record<string, unknown> = {
    firstname: firstname && firstname !== lastname ? firstname : undefined,
    lastname,
    emailaddress1: email,
    telephone1: cleanPhone(m.phone),
    pvs_contactlanguage: LANGUAGE_EN,
    description: await whoAdded(svc, m),
    "scp_CountryLookup@odata.bind": `/scp_countries(${COUNTRY[country]})`,
    "parentcustomerid_account@odata.bind": `/accounts(${parent.external_id})`,
    "ownerid@odata.bind": `/systemusers(${OWNER_BART})`,
  };
  const res = await dv("POST", "contacts", payload);
  if (!res.ok) {
    await setStatus(svc, "crm_contacts", m, "failed", res.error, true);
    await log(svc, "contact", m, "failed", null, { status: res.status, error: res.error }, by);
    return { name: m.full_name, result: "failed", error: res.error };
  }
  const id = res.data?.contactid;
  await linkContactLocally(svc, m, id);
  await log(svc, "contact", m, "created", id, {}, by);
  return { name: m.full_name, result: "created", id };
}

// ---------- entry ----------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const svc = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  try {
    // Scheduler (secret) or a manager.
    let by: string | null = null;
    const secret = req.headers.get("x-sync-secret") || "";
    if (secret) {
      const { data: expected } = await svc.rpc("crm_sync_secret");
      if (!expected || secret !== expected) return json({ error: "Invalid secret" }, 401);
    } else {
      const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: u, error } = await svc.auth.getUser(jwt);
      if (error || !u?.user) return json({ error: "Sign in first" }, 401);
      const { data: p } = await svc.from("profiles").select("role").eq("id", u.user.id).maybeSingle();
      if (p?.role !== "manager") return json({ error: "Managers only" }, 403);
      by = u.user.id;
    }

    // {"check": true}: ask Dynamics which of the needed privileges this app
    // user has. Reads only; works with the switch off.
    const reqBody = await req.json().catch(() => ({}));
    if (reqBody?.check) {
      const who = await dv("GET", "WhoAmI");
      if (!who.ok) return json({ error: who.error }, 502);
      const uid = who.data.UserId;
      const needed = [
        "prvReadscp_country", "prvAppendToscp_country",
        "prvCreateAccount", "prvReadAccount", "prvAppendAccount", "prvAppendToAccount", "prvAssignAccount",
        "prvCreateContact", "prvReadContact", "prvAppendContact", "prvAssignContact",
        "prvReadAsyncOperation", "prvReadUser", "prvReadBusinessUnit", "prvReadTeam", "prvReadWorkflow",
        "prvWriteAccount", "prvWriteContact", "prvDeleteAccount", "prvDeleteContact",
      ];
      const privileges: Record<string, string> = {};
      for (const name of needed) {
        const r = await dv("GET", `systemusers(${uid})/Microsoft.Dynamics.CRM.RetrieveUserPrivilegeByPrivilegeName(PrivilegeName='${name}')`);
        privileges[name] = !r.ok ? `error: ${r.error}` : (r.data?.RolePrivileges || []).map((p: any) => p.Depth).join(",") || "missing";
      }
      return json({ app_user: uid, privileges });
    }

    const { data: flag } = await svc.from("app_flags").select("value").eq("key", "crm_writeback_enabled").maybeSingle();
    if (flag?.value !== true) return json({ skipped: "Sending to Dynamics is switched off." });

    const results: any[] = [];
    const accountCols = "external_id, name, name_key, street, city, state_code, zip, country_code, phone, rep_firm_id, created_by, crm_push_attempts";
    const { data: accounts, error: aErr } = await svc.from("crm_accounts").select(accountCols)
      .eq("source", "manual").in("crm_push_status", ["waiting", "failed"]).lt("crm_push_attempts", MAX_ATTEMPTS).order("updated_at").limit(BATCH);
    if (aErr) throw aErr;
    for (const m of accounts || []) {
      try { results.push({ kind: "account", ...(await pushAccount(svc, m, by)) }); }
      catch (e) {
        const msg = String((e as Error).message || e).slice(0, 500);
        await setStatus(svc, "crm_accounts", m, "failed", msg, true);
        await log(svc, "account", m, "failed", null, { error: msg }, by);
        results.push({ kind: "account", name: m.name, result: "failed", error: msg });
      }
    }

    // Then contacts whose company is in Dynamics by now (incl. the ones just sent).
    const contactCols = "external_id, full_name, email, email_key, phone, parent_account_external_id, rep_firm_id, created_by, crm_push_attempts";
    const { data: contacts, error: cErr } = await svc.from("crm_contacts").select(contactCols)
      .eq("source", "manual").in("crm_push_status", ["waiting", "failed"]).lt("crm_push_attempts", MAX_ATTEMPTS)
      .not("parent_account_external_id", "like", "manual:%").order("updated_at").limit(BATCH);
    if (cErr) throw cErr;
    for (const m of contacts || []) {
      try { results.push({ kind: "contact", ...(await pushContact(svc, m, by)) }); }
      catch (e) {
        const msg = String((e as Error).message || e).slice(0, 500);
        await setStatus(svc, "crm_contacts", m, "failed", msg, true);
        await log(svc, "contact", m, "failed", null, { error: msg }, by);
        results.push({ kind: "contact", name: m.full_name, result: "failed", error: msg });
      }
    }
    return json({ processed: results.length, results });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
