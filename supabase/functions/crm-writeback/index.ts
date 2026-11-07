// crm-writeback: creates the companies and contacts reps add in the portal in
// Dynamics (Bart, 2026-11-07), then merges the portal's temporary "manual:"
// record into the real Dynamics record so the nightly sync never duplicates it.
//
// Rules (agreed with Bart):
//   - Account first, then its contacts: a contact is only sent once its
//     company exists in Dynamics, and is always linked to it.
//   - Owner of every record: Bart.
//   - Only creates. Never updates, deletes, assigns or merges in Dynamics.
//     (One exception, approved per record by Bart: the address clean-up in
//     crm_address_fixes -- City / State / ZIP only, with undo.)
//   - Before creating, look for the same record in Dynamics (company: same
//     name in the same country; contact: same e-mail). Found -> link to it,
//     don't create. Dynamics' own duplicate detection is switched on as well.
//     Look-alikes are held as "needs_info" for Bart ("Create anyway" sets
//     crm_push_force): one of its contacts' e-mails or e-mail domains is
//     already in Dynamics, or crm_lookalike_accounts() finds the same name
//     without Inc/LLC/Audio/Video/... in the state (or the same first word in
//     the same city), or Dynamics has such a name in that city right now, or
//     an account with the same phone number (last 10 digits). A refusal by
//     Dynamics' own duplicate rules also becomes needs_info, not a retry.
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

// Free mail providers: a shared domain there says nothing about the company.
const GENERIC_DOMAINS = new Set([
  "gmail.com", "googlemail.com", "yahoo.com", "ymail.com", "hotmail.com", "outlook.com", "live.com", "msn.com",
  "aol.com", "icloud.com", "me.com", "mac.com", "comcast.net", "att.net", "sbcglobal.net", "bellsouth.net",
  "verizon.net", "cox.net", "charter.net", "earthlink.net", "protonmail.com", "proton.me", "gmx.com", "mail.com",
  "rogers.com", "shaw.ca", "sympatico.ca", "bell.net", "telus.net", "videotron.ca",
]);

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
async function dv(method: "GET" | "POST" | "PATCH", path: string, body?: unknown, suppressDuplicateCheck = false): Promise<{ ok: boolean; status: number; data: any; error: string }> {
  const res = await fetch(`${API}/${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${await dvToken()}`,
      Accept: "application/json",
      "Content-Type": "application/json; charset=utf-8",
      "OData-MaxVersion": "4.0",
      "OData-Version": "4.0",
      Prefer: method !== "GET" ? "return=representation" : 'odata.include-annotations="OData.Community.Display.V1.FormattedValue"',
      // Let Dynamics' own duplicate detection rules refuse a duplicate too,
      // unless Bart pressed "Create anyway".
      ...(method === "POST" ? { "MSCRM.SuppressDuplicateDetection": suppressDuplicateCheck ? "true" : "false" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data: any = null;
  try { data = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  const error = res.ok ? "" : (data?.error?.message || text || `HTTP ${res.status}`).slice(0, 500);
  return { ok: res.ok, status: res.status, data, error };
}
// Dynamics refused the create because one of its duplicate detection rules
// matched (error 0x80040333): not worth retrying, Bart decides.
const isDuplicateRefusal = (r: { data: any; error: string }) =>
  String(r.data?.error?.code || "").toLowerCase() === "0x80040333" || /duplicate/i.test(r.error);

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

  // Maybe Dynamics has it under another name (e.g. "ICB" for "ICB Audio
  // Video"). Any sign of that goes to Bart instead of creating a duplicate.
  // Skipped when Bart pressed "Create anyway" on a held look-alike (crm_push_force).
  if (!m.crm_push_force) {
    const holdFor = async (msg: string, candidates: string[]) => {
      await setStatus(svc, "crm_accounts", m, "needs_info", msg, false);
      await log(svc, "account", m, "needs_info", null, { reason: msg, candidates }, by);
      return { name: m.name, result: "needs_info" };
    };
    const { data: myContacts } = await svc.from("crm_contacts").select("full_name, email").eq("parent_account_external_id", m.external_id).eq("source", "manual");
    for (const c of myContacts || []) {
      if (!validEmail(c.email)) continue;
      const r = await dv("GET", `contacts?$select=contactid,_parentcustomerid_value&$filter=${encodeURIComponent(`statecode eq 0 and emailaddress1 eq ${lit(String(c.email).trim())}`)}&$top=5`);
      if (!r.ok) throw new Error(`Dynamics lookup: ${r.error}`);
      const hit = (r.data?.value || []).find((h: any) => h._parentcustomerid_value);
      if (hit) {
        const where = hit["_parentcustomerid_value@OData.Community.Display.V1.FormattedValue"] || "another company";
        return holdFor(`${c.full_name} is already in Dynamics under ${where}: probably the same company. Merge it by hand on Accounts & Contacts.`, [hit._parentcustomerid_value]);
      }
    }
    // Same e-mail domain (not gmail & co.) on a contact or company in Dynamics.
    const domains = [...new Set((myContacts || []).map((c: any) => String(c.email || "").trim().toLowerCase().split("@")[1]).filter((d: string) => d && d.includes(".") && !GENERIC_DOMAINS.has(d)))];
    for (const d of domains) {
      const rc = await dv("GET", `contacts?$select=contactid,_parentcustomerid_value&$filter=${encodeURIComponent(`statecode eq 0 and endswith(emailaddress1, ${lit("@" + d)})`)}&$top=5`);
      if (!rc.ok) throw new Error(`Dynamics lookup: ${rc.error}`);
      const hit = (rc.data?.value || []).find((h: any) => h._parentcustomerid_value);
      if (hit) {
        const where = hit["_parentcustomerid_value@OData.Community.Display.V1.FormattedValue"] || "another company";
        return holdFor(`Dynamics already has contacts with @${d} addresses at ${where}: probably the same company. Merge it by hand on Accounts & Contacts, or press "Create anyway".`, [hit._parentcustomerid_value]);
      }
      const ra = await dv("GET", `accounts?$select=accountid,name&$filter=${encodeURIComponent(`statecode eq 0 and (endswith(emailaddress1, ${lit("@" + d)}) or contains(websiteurl, ${lit(d)}))`)}&$top=5`);
      if (!ra.ok) throw new Error(`Dynamics lookup: ${ra.error}`);
      if ((ra.data?.value || []).length) {
        const h = ra.data.value[0];
        return holdFor(`Dynamics has "${h.name}" with the ${d} website or e-mail: probably the same company. Merge it by hand on Accounts & Contacts, or press "Create anyway".`, ra.data.value.map((x: any) => x.accountid));
      }
    }

    // Same name without Inc/LLC/Audio/Video/AV/Systems/..., or the same first
    // word in the same city: on the portal's copy of Dynamics (all firms) ...
    const { data: alike, error: alikeErr } = await svc.rpc("crm_lookalike_accounts", {
      p_name: m.name, p_city: m.city, p_state: m.state_code, p_firm_id: null, p_exclude: m.external_id, p_limit: 5,
    });
    if (alikeErr) throw new Error(`look-alike check: ${alikeErr.message}`);
    if ((alike || []).length) {
      return holdFor(`Already in CRM: ${alike.map((a: any) => `"${a.name}"${a.city ? ` (${a.city})` : ""}`).join(", ")}. Is it the same company? Merge it by hand on Accounts & Contacts, or press "Create anyway".`, alike.map((a: any) => a.external_id));
    }
    // Same phone number, compared on the last 10 digits (Dynamics' own rule
    // compares the text exactly, so "(513) 555-1234" vs "513-555-1234" slips by).
    const digits = String(m.phone || "").replace(/\D/g, "");
    if (digits.length >= 10) {
      const last10 = digits.slice(-10);
      const r = await dv("GET", `accounts?$select=accountid,name,address1_city,telephone1&$filter=${encodeURIComponent(`statecode eq 0 and endswith(telephone1, ${lit(last10.slice(-4))})`)}&$top=50`);
      if (!r.ok) throw new Error(`Dynamics lookup: ${r.error}`);
      const same = (r.data?.value || []).filter((h: any) => String(h.telephone1 || "").replace(/\D/g, "").slice(-10) === last10);
      if (same.length) {
        return holdFor(`Dynamics has ${same.map((h: any) => `"${h.name}"${h.address1_city ? ` (${h.address1_city})` : ""}`).join(", ")} with the same phone number: probably the same company. Merge it by hand on Accounts & Contacts, or press "Create anyway".`, same.map((h: any) => h.accountid));
      }
    }
    // ... and live, for companies added to Dynamics since the last nightly sync.
    const { data: core } = await svc.rpc("crm_name_core", { p: m.name });
    const firstWord = String(core || "").split(" ")[0];
    if (firstWord.length >= 2) {
      const r = await dv("GET", `accounts?$select=accountid,name&$filter=${encodeURIComponent(`statecode eq 0 and contains(name, ${lit(firstWord)}) and address1_city eq ${lit(String(m.city).trim())} and _scp_countrylookup_value eq ${COUNTRY[country]}`)}&$top=5`);
      if (!r.ok) throw new Error(`Dynamics lookup: ${r.error}`);
      const near: any[] = r.data?.value || [];
      if (near.length) {
        return holdFor(`Dynamics has ${near.map((h) => `"${h.name}"`).join(", ")} in ${m.city}: is it the same company? Merge it by hand on Accounts & Contacts, or press "Create anyway".`, near.map((h) => h.accountid));
      }
    }
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
  const res = await dv("POST", "accounts", payload, !!m.crm_push_force);
  if (!res.ok && isDuplicateRefusal(res)) {
    const msg = "Dynamics' own duplicate rules say this company already exists (same name, phone number, e-mail or website). Merge it by hand on Accounts & Contacts.";
    await setStatus(svc, "crm_accounts", m, "needs_info", msg, false);
    await log(svc, "account", m, "needs_info", null, { reason: msg, status: res.status, error: res.error }, by);
    return { name: m.name, result: "needs_info" };
  }
  if (!res.ok) {
    await setStatus(svc, "crm_accounts", m, "failed", res.error, true);
    await log(svc, "account", m, "failed", null, { status: res.status, error: res.error }, by);
    return { name: m.name, result: "failed", error: res.error };
  }
  const id = res.data?.accountid;
  // Logged before the local merge, so the Dynamics id is never lost; if the
  // merge fails, the next run finds the company by name and links to it.
  await log(svc, "account", m, "created", id, { customertypecode: type.customertypecode }, by);
  await linkAccountLocally(svc, m, id, country);
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
  if (!res.ok && isDuplicateRefusal(res)) {
    const msg = "Dynamics' own duplicate rules say this contact already exists. Check it by hand on Accounts & Contacts.";
    await setStatus(svc, "crm_contacts", m, "needs_info", msg, false);
    await log(svc, "contact", m, "needs_info", null, { reason: msg, status: res.status, error: res.error }, by);
    return { name: m.full_name, result: "needs_info" };
  }
  if (!res.ok) {
    await setStatus(svc, "crm_contacts", m, "failed", res.error, true);
    await log(svc, "contact", m, "failed", null, { status: res.status, error: res.error }, by);
    return { name: m.full_name, result: "failed", error: res.error };
  }
  const id = res.data?.contactid;
  await log(svc, "contact", m, "created", id, {}, by);
  await linkContactLocally(svc, m, id);
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

    // {"inspect": true}: read-only look at Dynamics' duplicate detection rules
    // (and optionally some accounts by id), to tune the duplicate check.
    if (reqBody?.inspect) {
      const rules = await dv("GET", "duplicaterules?$select=duplicateruleid,name,baseentityname,matchingentityname,statecode,statuscode,excludeinactiverecords,iscasesensitive&$top=50");
      const conditions = await dv("GET", "duplicateruleconditions?$select=baseattributename,matchingattributename,operatorcode,operatorparam,ignoreblankvalues,_regardingobjectid_value&$top=200");
      const accounts: any[] = [];
      for (const id of (Array.isArray(reqBody.accounts) ? reqBody.accounts : []).slice(0, 10)) {
        if (!/^[0-9a-f-]{36}$/i.test(String(id))) continue;
        const a = await dv("GET", `accounts(${id})?$select=name,address1_city,address1_stateorprovince,customertypecode,businesstypecode,statecode,createdon,description,_ownerid_value,_scp_countrylookup_value,_createdby_value`);
        accounts.push(a.ok ? a.data : { id, error: a.error });
      }
      return json({
        rules: rules.ok ? rules.data.value : { error: rules.error },
        conditions: conditions.ok ? conditions.data.value : { error: conditions.error },
        accounts,
      });
    }

    // {"applyAddressFixes": true} / {"undoAddressFixes": true}: the one-off
    // address clean-up Bart approved (crm_address_fixes, migration 0064). Only
    // City / State / ZIP of the listed accounts are written, and only when
    // Dynamics still holds the values the proposal was made from; the old
    // values stay in the table so undo puts them back.
    if (reqBody?.applyAddressFixes || reqBody?.undoAddressFixes) {
      const undo = !!reqBody.undoAddressFixes;
      const { data: fixes, error: fErr } = await svc.from("crm_address_fixes").select("*").eq("status", undo ? "applied" : "approved").limit(200);
      if (fErr) throw fErr;
      const same = (a: unknown, b: unknown) => String(a ?? "").trim() === String(b ?? "").trim();
      const out: any[] = [];
      for (const f of fixes || []) {
        const from = undo ? { city: f.new_city, state: f.new_state, zip: f.new_zip } : { city: f.old_city, state: f.old_state, zip: f.old_zip };
        const to = undo ? { city: f.old_city, state: f.old_state, zip: f.old_zip } : { city: f.new_city, state: f.new_state, zip: f.new_zip };
        const cur = await dv("GET", `accounts(${f.external_id})?$select=address1_city,address1_stateorprovince,address1_postalcode,statecode`);
        let status = undo ? "proposed" : "applied", error: string | null = null;
        if (!cur.ok) { status = undo ? "applied" : "failed"; error = cur.error; }
        else if (!same(cur.data.address1_city, from.city) || !same(cur.data.address1_stateorprovince, from.state) || !same(cur.data.address1_postalcode, from.zip)) {
          status = undo ? "applied" : "skipped";
          error = `Changed in Dynamics since the proposal (now: ${[cur.data.address1_city, cur.data.address1_stateorprovince, cur.data.address1_postalcode].map((v) => v ?? "–").join(" | ")}); left alone.`;
        } else {
          const patch: Record<string, unknown> = {};
          if (!same(to.city, from.city)) patch.address1_city = to.city ?? null;
          if (!same(to.state, from.state)) patch.address1_stateorprovince = to.state ?? null;
          if (!same(to.zip, from.zip)) patch.address1_postalcode = to.zip ?? null;
          const res = await dv("PATCH", `accounts(${f.external_id})`, patch);
          if (!res.ok) { status = undo ? "applied" : "failed"; error = res.error; }
        }
        await svc.from("crm_address_fixes").update({ status, error, applied_at: status === "applied" ? new Date().toISOString() : null }).eq("external_id", f.external_id);
        out.push({ name: f.name, status, error });
      }
      return json({ processed: out.length, results: out });
    }

    const { data: flag } = await svc.from("app_flags").select("value").eq("key", "crm_writeback_enabled").maybeSingle();
    if (flag?.value !== true) return json({ skipped: "Sending to Dynamics is switched off." });

    const results: any[] = [];
    const accountCols = "external_id, name, name_key, street, city, state_code, zip, country_code, phone, rep_firm_id, created_by, crm_push_attempts, crm_push_force";
    const { data: accounts, error: aErr } = await svc.from("crm_accounts").select(accountCols)
      .eq("source", "manual").eq("is_active", true).in("crm_push_status", ["waiting", "failed"]).lt("crm_push_attempts", MAX_ATTEMPTS).order("updated_at").limit(BATCH);
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
      .eq("source", "manual").eq("is_active", true).in("crm_push_status", ["waiting", "failed"]).lt("crm_push_attempts", MAX_ATTEMPTS)
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
