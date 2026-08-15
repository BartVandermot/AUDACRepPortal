// Syncs Accounts and Contacts from Dynamics 365 / Dataverse into crm_accounts /
// crm_contacts. Auth: caller must be a signed-in manager (checked below);
// Dataverse access itself uses the OAuth2 client-credentials (S2S) flow against
// a dedicated Entra ID app registration + Dataverse Application User with a
// read-only security role (Account, Contact, Opportunity, Product, Country
// lookup, Account type). Secrets are read from the function's own environment
// -- never passed through the client.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const DATAVERSE_TENANT_ID = Deno.env.get("DATAVERSE_TENANT_ID")!;
const DATAVERSE_CLIENT_ID = Deno.env.get("DATAVERSE_CLIENT_ID")!;
const DATAVERSE_CLIENT_SECRET = Deno.env.get("DATAVERSE_CLIENT_SECRET")!;
const DATAVERSE_ORG_URL = (Deno.env.get("DATAVERSE_ORG_URL") || "").replace(/\/+$/, "");

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

async function fetchAllPages(url: string, token: string): Promise<any[]> {
  const results: any[] = [];
  let next: string | null = url;
  while (next) {
    const res: Response = await fetch(next, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "OData-MaxVersion": "4.0",
        "OData-Version": "4.0",
        Prefer: 'odata.include-annotations="OData.Community.Display.V1.FormattedValue"',
      },
    });
    if (!res.ok) throw new Error(`Dataverse request failed: ${res.status} ${await res.text()}`);
    const body = await res.json();
    results.push(...(body.value || []));
    next = body["@odata.nextLink"] || null;
  }
  return results;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  try {
    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    if (!jwt) return jsonResponse({ error: "Missing Authorization header" }, 401);

    const svc = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: userData, error: userErr } = await svc.auth.getUser(jwt);
    if (userErr || !userData?.user) return jsonResponse({ error: "Invalid session" }, 401);

    const { data: profile } = await svc.from("profiles").select("role").eq("id", userData.user.id).maybeSingle();
    if (!profile || profile.role !== "manager") return jsonResponse({ error: "Manager role required" }, 403);

    const token = await getDataverseToken();

    const { data: firms } = await svc.from("rep_firms").select("id, states").eq("status", "active");
    const firmsCache = firms || [];

    function resolveFirmIdByState(stateCode: string | null, countryCode: string | null): string | null {
      if (!stateCode || countryCode !== "US") return null;
      const firm = firmsCache.find((f: any) => Array.isArray(f.states) && f.states.includes(stateCode));
      return firm ? firm.id : null;
    }

    // ---------- Accounts ----------
    const accountsUrl = `${DATAVERSE_ORG_URL}/api/data/v9.2/accounts?$select=` + [
      "accountid", "name", "address1_line1", "address1_city",
      "address1_stateorprovince", "address1_postalcode",
      "telephone1", "websiteurl", "customertypecode", "businesstypecode",
      "_scp_countrylookup_value", "modifiedon",
    ].join(",");
    const accountRows = await fetchAllPages(accountsUrl, token);

    const accountFirmByExternalId = new Map<string, string | null>();
    let accountsMatched = 0, accountsOutOfTerritory = 0, accountsNoState = 0;

    const accountUpserts = accountRows
      .filter((r) => r.name)
      .map((r) => {
        const stateCode = normalizeState(r.address1_stateorprovince);
        const countryText = r["_scp_countrylookup_value@OData.Community.Display.V1.FormattedValue"] ?? null;
        const countryCode = normalizeCountry(countryText);
        const repFirmId = resolveFirmIdByState(stateCode, countryCode);
        if (repFirmId) accountsMatched++;
        else if (stateCode && countryCode === "US") accountsOutOfTerritory++;
        else accountsNoState++;
        accountFirmByExternalId.set(r.accountid, repFirmId);

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

    if (accountUpserts.length) {
      const { error } = await svc.from("crm_accounts").upsert(accountUpserts, { onConflict: "external_id" });
      if (error) throw new Error(`crm_accounts upsert failed: ${error.message}`);
    }

    // ---------- Contacts ----------
    const contactsUrl = `${DATAVERSE_ORG_URL}/api/data/v9.2/contacts?$select=` +
      ["contactid", "fullname", "emailaddress1", "_parentcustomerid_value", "modifiedon"].join(",");
    const contactRows = await fetchAllPages(contactsUrl, token);

    let contactsMatched = 0;
    const contactUpserts = contactRows
      .filter((r) => r.fullname || r.emailaddress1)
      .map((r) => {
        const parentId = r._parentcustomerid_value || null;
        const repFirmId = parentId ? accountFirmByExternalId.get(parentId) ?? null : null;
        if (repFirmId) contactsMatched++;
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

    if (contactUpserts.length) {
      const { error } = await svc.from("crm_contacts").upsert(contactUpserts, { onConflict: "external_id" });
      if (error) throw new Error(`crm_contacts upsert failed: ${error.message}`);
    }

    return jsonResponse({
      accounts: { total: accountUpserts.length, matched: accountsMatched, outOfTerritory: accountsOutOfTerritory, noState: accountsNoState },
      contacts: { total: contactUpserts.length, matchedToFirm: contactsMatched },
      syncedAt: new Date().toISOString(),
    });
  } catch (err) {
    return jsonResponse({ error: String((err as Error)?.message || err) }, 500);
  }
});
