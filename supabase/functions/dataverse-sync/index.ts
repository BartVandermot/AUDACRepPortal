// Syncs Accounts and Contacts from Dynamics 365 / Dataverse into crm_accounts /
// crm_contacts. Auth: caller must be a signed-in manager (checked below);
// Dataverse access itself uses the OAuth2 client-credentials (S2S) flow against
// a dedicated Entra ID app registration + Dataverse Application User with a
// read-only security role (Account, Contact, Opportunity, Product, Country
// lookup, Account type). Secrets are read from the function's own environment
// -- never passed through the client.
//
// Processes one small page per invocation (Edge Functions have a per-call CPU
// budget; pulling a whole org's worth of Accounts/Contacts in one call blew
// through it). The caller drives the pagination loop: POST { phase, cursor }
// and keep calling with the returned nextCursor until done=true, first for
// phase "accounts" then phase "contacts" (contacts resolve their rep firm by
// looking up their already-synced parent account in crm_accounts).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const DATAVERSE_TENANT_ID = Deno.env.get("DATAVERSE_TENANT_ID")!;
const DATAVERSE_CLIENT_ID = Deno.env.get("DATAVERSE_CLIENT_ID")!;
const DATAVERSE_CLIENT_SECRET = Deno.env.get("DATAVERSE_CLIENT_SECRET")!;
const DATAVERSE_ORG_URL = (Deno.env.get("DATAVERSE_ORG_URL") || "").replace(/\/+$/, "");

const PAGE_SIZE = 100;

const US_STATE_NAMES: Record<string, string> = {
  alabama: "AL", alaska: "AK", arizona: "AZ", arkansas: "AR", california: "CA", colorado: "CO",
  connecticut: "CT", delaware: "DE", "district of columbia": "DC", florida: "FL", georgia: "GA",
  hawaii: "HI", idaho: "ID", illinois: "IL", indiana: "IN", iowa: "IA", kansas: "KS", kentucky: "KY",
  louisiana: "LA", maine: "ME", maryland: "MD", massachusetts: "MA", michigan: "MI", minnesota: "MN",
  mississippi: "MS", missouri: "MO", montana: "MT", nebraska: "NE", nevada: "NV", "new hampshire": "NH",
  "new jersey": "NJ", "new mexico": "NM", "new york": "NY", "north carolina": "NC", "north dakota": "ND",
  ohio: "OH", oklahoma: "OK", oregon: "OR", pennsylvania: "PA", "rhode island": "RI",
  "south carolina": "SC", "south dakota": "SD", tennessee: "TN", texas: "TX", utah: "UT", vermont: "VT",
  virginia: "VA", washington: "WA", "west virginia": "WV", wisconsin: "WI", wyoming: "WY",
  "puerto rico": "PR", guam: "GU",
};
const US_STATE_CODES = new Set(Object.values(US_STATE_NAMES));

function normalizeState(raw: unknown): string | null {
  if (!raw) return null;
  const s = String(raw).trim();
  if (!s) return null;
  if (s.length === 2 && US_STATE_CODES.has(s.toUpperCase())) return s.toUpperCase();
  return US_STATE_NAMES[s.toLowerCase()] || null;
}

function normalizeCountry(raw: unknown): string | null {
  if (!raw) return null;
  const s = String(raw).trim();
  if (!s) return null;
  if (s.length === 2) return s.toUpperCase();
  const nl = s.toLowerCase();
  if (nl.includes("united states")) return "US";
  if (nl === "canada") return "CA";
  return null;
}

function normalizeCompany(raw: unknown): string {
  return String(raw || "").trim().toLowerCase();
}

function normalizeEmail(raw: unknown): string | null {
  const v = String(raw || "").trim().toLowerCase();
  return v || null;
}

async function getDataverseToken(): Promise<string> {
  const tokenUrl = `https://login.microsoftonline.com/${DATAVERSE_TENANT_ID}/oauth2/v2.0/token`;
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: DATAVERSE_CLIENT_ID,
    client_secret: DATAVERSE_CLIENT_SECRET,
    scope: `${DATAVERSE_ORG_URL}/.default`,
  });
  const res = await fetch(tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) throw new Error(`Dataverse token request failed: ${res.status} ${await res.text()}`);
  const json = await res.json();
  return json.access_token as string;
}

async function fetchOnePage(url: string, token: string): Promise<{ rows: any[]; nextLink: string | null; status: number; bodyText?: string }> {
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      "OData-MaxVersion": "4.0",
      "OData-Version": "4.0",
      Prefer: `odata.include-annotations="OData.Community.Display.V1.FormattedValue",odata.maxpagesize=${PAGE_SIZE}`,
    },
  });
  if (!res.ok) return { rows: [], nextLink: null, status: res.status, bodyText: await res.text() };
  const body = await res.json();
  return { rows: body.value || [], nextLink: body["@odata.nextLink"] || null, status: 200 };
}

// Only the first page of a fresh sync (no cursor yet) carries a $filter, since a
// nextLink already has whatever filter was used baked into it. Tries each URL in
// order (most restrictive first) and uses the first one Dataverse accepts -- e.g.
// if the guessed relationship/field names for the country filter are wrong, this
// falls back to "active records only" rather than silently pulling the entire
// (possibly huge) unfiltered table, which is the actual failure mode we hit.
async function fetchFirstPageLadder(
  levels: { level: string; url: string }[],
  token: string,
): Promise<{ rows: any[]; nextLink: string | null; filterLevel: string }> {
  let lastError: { status: number; bodyText?: string } | null = null;
  for (const { level, url } of levels) {
    const page = await fetchOnePage(url, token);
    if (page.status === 200) return { rows: page.rows, nextLink: page.nextLink, filterLevel: level };
    lastError = page;
  }
  throw new Error(`Dataverse request failed: ${lastError?.status} ${lastError?.bodyText}`);
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders },
  });
}

const ACCOUNTS_SELECT = [
  "accountid", "name", "address1_line1", "address1_city",
  "address1_stateorprovince", "address1_postalcode",
  "telephone1", "websiteurl", "customertypecode", "businesstypecode",
  "_scp_countrylookup_value", "_parentaccountid_value", "modifiedon",
].join(",");

const CONTACTS_SELECT = ["contactid", "fullname", "emailaddress1", "_parentcustomerid_value", "modifiedon"].join(",");

// We only care about active US/Canada accounts (rep territories are US states).
// The Country entity's Web API relationship/attribute names aren't readable by this
// Application User (its security role lacks the metadata-read privilege, confirmed
// via a 403 on EntityDefinitions), so filtering by relationship path isn't available.
// Instead this filters directly on the raw lookup GUID (_scp_countrylookup_value),
// which needs no relationship traversal at all. The two GUIDs below were read
// directly off real account records (address1_stateorprovince eq 'CA' / 'Ontario')
// via a throwaway diagnostic function and confirmed against a live filtered query
// (582 accounts, 676 contacts) before being hardcoded here.
const COUNTRY_GUID_US = "45adf5cd-c846-e811-a9c6-000d3a254a9a";
const COUNTRY_GUID_CA = "c1abf5cd-c846-e811-a9c6-000d3a254a9a";

const ACCOUNTS_URL_BASE = `${DATAVERSE_ORG_URL}/api/data/v9.2/accounts?$select=${ACCOUNTS_SELECT}`;
const ACCOUNTS_URL_LEVELS = [
  { level: "full", url: `${ACCOUNTS_URL_BASE}&$filter=statecode eq 0 and (_scp_countrylookup_value eq ${COUNTRY_GUID_US} or _scp_countrylookup_value eq ${COUNTRY_GUID_CA})` },
  { level: "active_only", url: `${ACCOUNTS_URL_BASE}&$filter=statecode eq 0` },
  { level: "none", url: ACCOUNTS_URL_BASE },
];

const CONTACTS_URL_BASE = `${DATAVERSE_ORG_URL}/api/data/v9.2/contacts?$select=${CONTACTS_SELECT}`;
const CONTACTS_URL_LEVELS = [
  { level: "full", url: `${CONTACTS_URL_BASE}&$filter=statecode eq 0 and (parentcustomerid_account/_scp_countrylookup_value eq ${COUNTRY_GUID_US} or parentcustomerid_account/_scp_countrylookup_value eq ${COUNTRY_GUID_CA})` },
  { level: "active_only", url: `${CONTACTS_URL_BASE}&$filter=statecode eq 0` },
  { level: "none", url: CONTACTS_URL_BASE },
];

// Diagnostic-only counts, so the actual expected record counts can be checked before
// running a real sync. Dataverse's bare /$count sub-path doesn't support $filter at
// all in this org (confirmed: fails identically regardless of filter content) --
// uses ?$count=true on the base collection instead and reads @odata.count.
async function fetchFilteredCount(entity: "accounts" | "contacts", filter: string | null, token: string): Promise<number | null> {
  const idField = entity === "contacts" ? "contactid" : "accountid";
  const url = filter
    ? `${DATAVERSE_ORG_URL}/api/data/v9.2/${entity}?$select=${idField}&$count=true&$filter=${encodeURIComponent(filter)}`
    : `${DATAVERSE_ORG_URL}/api/data/v9.2/${entity}?$select=${idField}&$count=true`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json", "OData-MaxVersion": "4.0", "OData-Version": "4.0", Prefer: "odata.maxpagesize=1" },
  });
  if (!res.ok) return null;
  const body = await res.json();
  return body?.["@odata.count"] ?? null;
}

async function getCounts(): Promise<Record<string, any>> {
  const token = await getDataverseToken();
  const accFilter = `statecode eq 0 and (_scp_countrylookup_value eq ${COUNTRY_GUID_US} or _scp_countrylookup_value eq ${COUNTRY_GUID_CA})`;
  const conFilter = `statecode eq 0 and (parentcustomerid_account/_scp_countrylookup_value eq ${COUNTRY_GUID_US} or parentcustomerid_account/_scp_countrylookup_value eq ${COUNTRY_GUID_CA})`;
  const [accFull, accActive, accNone, conFull, conActive, conNone] = await Promise.all([
    fetchFilteredCount("accounts", accFilter, token),
    fetchFilteredCount("accounts", "statecode eq 0", token),
    fetchFilteredCount("accounts", null, token),
    fetchFilteredCount("contacts", conFilter, token),
    fetchFilteredCount("contacts", "statecode eq 0", token),
    fetchFilteredCount("contacts", null, token),
  ]);
  return {
    accounts: { activeUsCanada: accFull, activeOnly: accActive, total: accNone },
    contacts: { activeUsCanada: conFull, activeOnly: conActive, total: conNone },
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    if (!jwt) return jsonResponse({ error: "Missing Authorization header" }, 401);

    const svc = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: userData, error: userErr } = await svc.auth.getUser(jwt);
    if (userErr || !userData?.user) return jsonResponse({ error: "Invalid session" }, 401);

    const { data: profile } = await svc.from("profiles").select("role").eq("id", userData.user.id).maybeSingle();
    if (!profile || profile.role !== "manager") return jsonResponse({ error: "Manager role required" }, 403);

    let payload: { phase?: string; cursor?: string | null } = {};
    try {
      payload = await req.json();
    } catch {
      // no body -> start accounts phase from the beginning
    }

    if (payload.phase === "count") {
      return jsonResponse(await getCounts());
    }

    const phase = payload.phase === "contacts" ? "contacts" : "accounts";
    const cursor = payload.cursor || null;

    const token = await getDataverseToken();

    if (phase === "accounts") {
      let rows: any[], nextLink: string | null, filterLevel: string | null;
      if (cursor) {
        const page = await fetchOnePage(cursor, token);
        if (page.status !== 200) throw new Error(`Dataverse request failed: ${page.status} ${page.bodyText}`);
        rows = page.rows; nextLink = page.nextLink; filterLevel = null;
      } else {
        const first = await fetchFirstPageLadder(ACCOUNTS_URL_LEVELS, token);
        rows = first.rows; nextLink = first.nextLink; filterLevel = first.filterLevel;
      }

      const { data: firms } = await svc.from("rep_firms").select("id, states, crm_account_external_id").eq("status", "active");
      const firmsCache = firms || [];
      const firmIdByCrmAccountId = new Map<string, string>(
        firmsCache.filter((f: any) => f.crm_account_external_id).map((f: any) => [f.crm_account_external_id, f.id]),
      );
      function resolveFirmIdByState(stateCode: string | null, countryCode: string | null): string | null {
        if (!stateCode || countryCode !== "US") return null;
        const firm = firmsCache.find((f: any) => Array.isArray(f.states) && f.states.includes(stateCode));
        return firm ? firm.id : null;
      }

      // Rep firms are themselves Accounts under Intellimix -- an account whose
      // parentaccountid IS one of those rep-firm accounts is authoritatively that
      // firm's, no state-guessing needed. State matching is only a fallback for
      // accounts not under a rep firm parent (or whose parent isn't one we know).
      let matchedByParent = 0, matchedByState = 0, outOfTerritory = 0, noState = 0;
      const upserts = rows
        .filter((r: any) => r.name)
        .map((r: any) => {
          const stateCode = normalizeState(r.address1_stateorprovince);
          const countryText = r["_scp_countrylookup_value@OData.Community.Display.V1.FormattedValue"] ?? null;
          const countryCode = normalizeCountry(countryText);

          const parentId = r._parentaccountid_value || null;
          let repFirmId = parentId ? firmIdByCrmAccountId.get(parentId) ?? null : null;
          if (repFirmId) matchedByParent++;
          else {
            repFirmId = resolveFirmIdByState(stateCode, countryCode);
            if (repFirmId) matchedByState++;
            else if (stateCode && countryCode === "US") outOfTerritory++;
            else noState++;
          }

          return {
            external_id: r.accountid,
            name: r.name,
            name_key: normalizeCompany(r.name),
            street: r.address1_line1 || null,
            city: r.address1_city || null,
            state_raw: r.address1_stateorprovince || null,
            state_code: stateCode,
            zip: r.address1_postalcode || null,
            country_code: countryCode,
            website: r.websiteurl || null,
            relationship_type: r["customertypecode@OData.Community.Display.V1.FormattedValue"] ?? null,
            business_type: r["businesstypecode@OData.Community.Display.V1.FormattedValue"] ?? null,
            rep_firm_id: repFirmId,
            updated_by: userData.user.id,
            updated_at: new Date().toISOString(),
          };
        });

      if (upserts.length) {
        const { error } = await svc.from("crm_accounts").upsert(upserts, { onConflict: "external_id" });
        if (error) throw new Error(`crm_accounts upsert failed: ${error.message}`);
      }

      return jsonResponse({
        phase: "accounts",
        done: !nextLink,
        nextCursor: nextLink,
        processed: upserts.length,
        matched: matchedByParent + matchedByState,
        matchedByParent,
        matchedByState,
        outOfTerritory,
        noState,
        filterLevel,
      });
    } else {
      let rows: any[], nextLink: string | null, filterLevel: string | null;
      if (cursor) {
        const page = await fetchOnePage(cursor, token);
        if (page.status !== 200) throw new Error(`Dataverse request failed: ${page.status} ${page.bodyText}`);
        rows = page.rows; nextLink = page.nextLink; filterLevel = null;
      } else {
        const first = await fetchFirstPageLadder(CONTACTS_URL_LEVELS, token);
        rows = first.rows; nextLink = first.nextLink; filterLevel = first.filterLevel;
      }

      const parentIds = [...new Set(rows.map((r: any) => r._parentcustomerid_value).filter(Boolean))];
      let parentFirmById = new Map<string, string | null>();
      if (parentIds.length) {
        const { data: parents } = await svc.from("crm_accounts").select("external_id, rep_firm_id").in("external_id", parentIds);
        parentFirmById = new Map((parents || []).map((p: any) => [p.external_id, p.rep_firm_id]));
      }

      let matchedToFirm = 0;
      const upserts = rows
        .filter((r: any) => r.fullname || r.emailaddress1)
        .map((r: any) => {
          const parentId = r._parentcustomerid_value || null;
          const repFirmId = parentId ? parentFirmById.get(parentId) ?? null : null;
          if (repFirmId) matchedToFirm++;
          return {
            external_id: r.contactid,
            full_name: r.fullname || null,
            email: r.emailaddress1 || null,
            email_key: normalizeEmail(r.emailaddress1),
            parent_account_external_id: parentId,
            rep_firm_id: repFirmId,
            updated_by: userData.user.id,
            updated_at: new Date().toISOString(),
          };
        });

      if (upserts.length) {
        const { error } = await svc.from("crm_contacts").upsert(upserts, { onConflict: "external_id" });
        if (error) throw new Error(`crm_contacts upsert failed: ${error.message}`);
      }

      return jsonResponse({
        phase: "contacts",
        done: !nextLink,
        nextCursor: nextLink,
        processed: upserts.length,
        matchedToFirm,
        filterLevel,
      });
    }
  } catch (err) {
    return jsonResponse({ error: String((err as Error)?.message || err) }, 500);
  }
});
