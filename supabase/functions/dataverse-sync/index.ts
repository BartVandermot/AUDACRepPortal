// Syncs Accounts, Contacts, and Opportunities from Dynamics 365 / Dataverse
// into crm_accounts / crm_contacts / pipeline_entries. Auth: caller must be a
// signed-in manager (checked below); Dataverse access itself uses the OAuth2
// client-credentials (S2S) flow against a dedicated Entra ID app registration
// + Dataverse Application User with a read-only security role (Account,
// Contact, Opportunity, Product, Country lookup, Account type). Secrets are
// read from the function's own environment -- never passed through the client.
//
// Processes one small page per invocation (Edge Functions have a per-call CPU
// budget; pulling a whole org's worth of records in one call blew through
// it). The caller drives the pagination loop: POST { phase, cursor } and keep
// calling with the returned nextCursor until done=true. Phase order matters:
// "accounts" first -- "contacts" resolves rep firm via its parent account in
// crm_accounts; "opportunities" resolves rep firm via (in priority order) its
// Involved Installer account, a manager-maintained rep-name mapping keyed off
// the Contact field, or the free-typed Location field, since almost every
// opportunity is filed under Intellimix as the customer account.
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

const CA_PROVINCE_NAMES: Record<string, string> = {
  alberta: "AB", "british columbia": "BC", manitoba: "MB", "new brunswick": "NB",
  "newfoundland and labrador": "NL", "nova scotia": "NS", ontario: "ON",
  "prince edward island": "PE", quebec: "QC", saskatchewan: "SK",
  "northwest territories": "NT", nunavut: "NU", yukon: "YT",
};
const CA_PROVINCE_CODES = new Set(Object.values(CA_PROVINCE_NAMES));

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

function normalizePersonName(raw: unknown): string {
  return String(raw || "").trim().toLowerCase();
}

function normalizeEmail(raw: unknown): string | null {
  const v = String(raw || "").trim().toLowerCase();
  return v || null;
}

// Location is a free-typed project address/city, not a structured field, so
// this is necessarily best-effort: try the whole string as a state/province
// first (e.g. "PA"), then each comma-separated segment from the end (e.g.
// "Toronto, Ontario" -> "Ontario", "Orlando, Florida" -> "Florida"), then any
// individual token. A city-only value ("Montreal", "Ottawa") or something
// non-geographic ("Unknown", "Carter County") intentionally returns no match
// rather than guessing -- ambiguous free text should fall through to being
// reported as unresolved, not silently assigned to the wrong firm.
function extractLocationTerritory(raw: unknown): { code: string; country: "US" | "CA" } | null {
  const text = String(raw || "").trim();
  if (!text) return null;

  function tryMatch(segment: string): { code: string; country: "US" | "CA" } | null {
    const s = segment.trim();
    if (!s) return null;
    if (s.length === 2) {
      const up = s.toUpperCase();
      if (US_STATE_CODES.has(up)) return { code: up, country: "US" };
      if (CA_PROVINCE_CODES.has(up)) return { code: up, country: "CA" };
    }
    const low = s.toLowerCase();
    if (US_STATE_NAMES[low]) return { code: US_STATE_NAMES[low], country: "US" };
    if (CA_PROVINCE_NAMES[low]) return { code: CA_PROVINCE_NAMES[low], country: "CA" };
    return null;
  }

  const whole = tryMatch(text);
  if (whole) return whole;

  const parts = text.split(",").map((p) => p.trim()).filter(Boolean).reverse();
  for (const part of parts) {
    const m = tryMatch(part);
    if (m) return m;
  }

  const tokens = text.split(/[\s,]+/).filter(Boolean);
  for (const tok of tokens) {
    const m = tryMatch(tok);
    if (m) return m;
  }
  return null;
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
  "pvs_audacpartnertype", "accountclassificationcode",
  "_scp_countrylookup_value", "_parentaccountid_value", "modifiedon",
].join(",");

const CONTACTS_SELECT = ["contactid", "fullname", "emailaddress1", "_parentcustomerid_value", "modifiedon"].join(",");

const OPPORTUNITIES_SELECT = [
  "opportunityid", "name", "estimatedvalue", "actualvalue", "estimatedclosedate",
  "actualclosedate", "createdon", "statuscode", "statecode",
  "_pvs_involvedinstallerid_value", "_parentcontactid_value",
  "pvs_opportunitylocation", "_pvs_countrylookup_value",
].join(",");

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

// Opportunities carry their own Country Lookup field (a separate custom field
// from the one on Account -- _pvs_countrylookup_value here vs.
// _scp_countrylookup_value on accounts/contacts -- but pointing at the same
// underlying Country records, so the same two GUIDs apply). This is more
// accurate than deriving country from the customer account anyway: almost
// every opportunity is filed under Intellimix as the customer, which reflects
// the billing entity, not where the actual project is located.
// No status filter -- Won and Lost opportunities are pulled too (see the
// per-row status handling below), not just Open, since losing that outcome
// the moment a deal closes would throw away real information (win rate,
// actual vs. estimated value, which reps are actually closing).
const OPPORTUNITIES_URL_BASE = `${DATAVERSE_ORG_URL}/api/data/v9.2/opportunities?$select=${OPPORTUNITIES_SELECT}`;
const OPPORTUNITIES_URL_LEVELS = [
  { level: "full", url: `${OPPORTUNITIES_URL_BASE}&$filter=_pvs_countrylookup_value eq ${COUNTRY_GUID_US} or _pvs_countrylookup_value eq ${COUNTRY_GUID_CA}` },
  { level: "none", url: OPPORTUNITIES_URL_BASE },
];

// Diagnostic-only counts, so the actual expected record counts can be checked before
// running a real sync. Dataverse's bare /$count sub-path doesn't support $filter at
// all in this org (confirmed: fails identically regardless of filter content) --
// uses ?$count=true on the base collection instead and reads @odata.count.
async function fetchFilteredCount(entity: "accounts" | "contacts" | "opportunities", filter: string | null, token: string): Promise<number | null> {
  const idField = entity === "contacts" ? "contactid" : entity === "opportunities" ? "opportunityid" : "accountid";
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
  const oppFilter = `_pvs_countrylookup_value eq ${COUNTRY_GUID_US} or _pvs_countrylookup_value eq ${COUNTRY_GUID_CA}`;
  const [accFull, accActive, accNone, conFull, conActive, conNone, oppUsCanada, oppNone] = await Promise.all([
    fetchFilteredCount("accounts", accFilter, token),
    fetchFilteredCount("accounts", "statecode eq 0", token),
    fetchFilteredCount("accounts", null, token),
    fetchFilteredCount("contacts", conFilter, token),
    fetchFilteredCount("contacts", "statecode eq 0", token),
    fetchFilteredCount("contacts", null, token),
    fetchFilteredCount("opportunities", oppFilter, token),
    fetchFilteredCount("opportunities", null, token),
  ]);
  return {
    accounts: { activeUsCanada: accFull, activeOnly: accActive, total: accNone },
    contacts: { activeUsCanada: conFull, activeOnly: conActive, total: conNone },
    opportunities: { usCanada: oppUsCanada, total: oppNone },
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

    const phase = payload.phase === "contacts" ? "contacts" : payload.phase === "opportunities" ? "opportunities" : "accounts";
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
            audac_partner_type: r["pvs_audacpartnertype@OData.Community.Display.V1.FormattedValue"] ?? null,
            classification: r["accountclassificationcode@OData.Community.Display.V1.FormattedValue"] ?? null,
            parent_account_external_id: parentId,
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
    } else if (phase === "contacts") {
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
    } else {
      let rows: any[], nextLink: string | null, filterLevel: string | null;
      if (cursor) {
        const page = await fetchOnePage(cursor, token);
        if (page.status !== 200) throw new Error(`Dataverse request failed: ${page.status} ${page.bodyText}`);
        rows = page.rows; nextLink = page.nextLink; filterLevel = null;
      } else {
        const first = await fetchFirstPageLadder(OPPORTUNITIES_URL_LEVELS, token);
        rows = first.rows; nextLink = first.nextLink; filterLevel = first.filterLevel;
      }

      // Almost every opportunity is filed under Intellimix as the customer
      // account, which doesn't identify a rep firm -- rep firm is resolved
      // in priority order instead: (1) Involved Installer, the actual dealer
      // account, looked up in crm_accounts; (2) the Contact field, which
      // Melissa already uses to record which rep person is handling the
      // deal, matched against a manager-maintained name->firm mapping; (3)
      // the free-typed Location field, parsed for a state/province. An
      // opportunity that resolves none of these has nowhere to go (unlike
      // crm_contacts, pipeline_entries.rep_firm_id is not-null) and is
      // skipped, with its contact name surfaced so a manager can assign it.
      const installerIds = [...new Set(rows.map((r: any) => r._pvs_involvedinstallerid_value).filter(Boolean))];
      let installerById = new Map<string, { name: string; repFirmId: string | null }>();
      if (installerIds.length) {
        const { data: accts } = await svc.from("crm_accounts").select("external_id, name, rep_firm_id").in("external_id", installerIds);
        installerById = new Map((accts || []).map((a: any) => [a.external_id, { name: a.name, repFirmId: a.rep_firm_id }]));
      }

      const { data: aliases } = await svc.from("rep_person_aliases").select("person_name_key, rep_firm_id");
      const personAliasByKey = new Map<string, string | null>((aliases || []).map((a: any) => [a.person_name_key, a.rep_firm_id]));

      const { data: firms } = await svc.from("rep_firms").select("id, states").eq("status", "active");
      const firmsCache = firms || [];

      // Dataverse's standard Opportunity statecode option set: 0 Open, 1 Won, 2 Lost.
      const STATUS_BY_STATECODE: Record<number, "Open" | "Won" | "Lost"> = { 0: "Open", 1: "Won", 2: "Lost" };
      const syncMonth = new Date().toISOString().slice(0, 7);
      let matchedByInstaller = 0, matchedByRepName = 0, matchedByLocation = 0, excludedByRepName = 0, skippedNoMatch = 0;
      let openCount = 0, wonCount = 0, lostCount = 0;
      const unmatchedContactNames = new Map<string, number>();
      const upserts: any[] = [];

      for (const r of rows) {
        const installerId = r._pvs_involvedinstallerid_value || null;
        const installer = installerId ? installerById.get(installerId) : undefined;
        const contactName = r["_parentcontactid_value@OData.Community.Display.V1.FormattedValue"] || null;
        const contactNameKey = contactName ? normalizePersonName(contactName) : null;

        let repFirmId: string | null = null;
        if (installer?.repFirmId) {
          repFirmId = installer.repFirmId;
          matchedByInstaller++;
        } else if (contactNameKey && personAliasByKey.has(contactNameKey)) {
          const aliasFirmId = personAliasByKey.get(contactNameKey) || null;
          if (aliasFirmId) { repFirmId = aliasFirmId; matchedByRepName++; }
          else { excludedByRepName++; }
        } else {
          const territory = extractLocationTerritory(r.pvs_opportunitylocation);
          const firm = territory ? firmsCache.find((f: any) => Array.isArray(f.states) && f.states.includes(territory.code)) : null;
          if (firm) { repFirmId = firm.id; matchedByLocation++; }
          else {
            skippedNoMatch++;
            if (contactName) unmatchedContactNames.set(contactName, (unmatchedContactNames.get(contactName) || 0) + 1);
          }
        }

        if (!repFirmId) continue;

        const status = STATUS_BY_STATECODE[r.statecode] ?? null;
        if (status === "Won") wonCount++;
        else if (status === "Lost") lostCount++;
        else openCount++;

        // Open deals are tagged with the current sync month -- each monthly
        // sync is a fresh snapshot of "still open as of now", same as every
        // other reporting_month in this app. A closed deal instead gets the
        // month it actually closed in, so a win/loss lands on the scorecard
        // for the month it really happened, not whichever month someone
        // happened to run the sync -- otherwise running the first sync in
        // September would misattribute a June win to September.
        const reportingMonth = status === "Open"
          ? syncMonth
          : (r.actualclosedate ? String(r.actualclosedate).slice(0, 7) : syncMonth);

        upserts.push({
          rep_firm_id: repFirmId,
          reporting_month: reportingMonth,
          account_name: installer?.name || contactName || r.name || "Unknown",
          account_external_id: installerId,
          project_name: r.name || null,
          stage: r["statuscode@OData.Community.Display.V1.FormattedValue"] ?? null,
          status,
          value_usd: r.estimatedvalue ?? null,
          actual_value_usd: r.actualvalue ?? null,
          created_date: r.createdon ? String(r.createdon).slice(0, 10) : null,
          expected_close_date: r.estimatedclosedate ? String(r.estimatedclosedate).slice(0, 10) : null,
          actual_close_date: r.actualclosedate ? String(r.actualclosedate).slice(0, 10) : null,
          crm_id: r.opportunityid,
        });
      }

      if (upserts.length) {
        const { error } = await svc.from("pipeline_entries").upsert(upserts, { onConflict: "crm_id,reporting_month" });
        if (error) throw new Error(`pipeline_entries upsert failed: ${error.message}`);
      }

      return jsonResponse({
        phase: "opportunities",
        done: !nextLink,
        nextCursor: nextLink,
        processed: upserts.length,
        matchedByInstaller,
        matchedByRepName,
        matchedByLocation,
        excludedByRepName,
        skippedNoMatch,
        openCount,
        wonCount,
        lostCount,
        unmatchedContactNames: [...unmatchedContactNames.entries()].map(([name, count]) => ({ name, count })),
        filterLevel,
      });
    }
  } catch (err) {
    return jsonResponse({ error: String((err as Error)?.message || err) }, 500);
  }
});
