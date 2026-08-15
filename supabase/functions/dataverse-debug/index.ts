// TEMPORARY diagnostic-only function for iterating on Dataverse OData filters
// without redeploying dataverse-sync or looping in a manager for every attempt.
// Deliberately unauthenticated (verify_jwt: false) -- but it only ever reads
// Dataverse schema metadata and $count totals, never row data, and never touches
// Supabase tables at all. Reuses the same project-level DATAVERSE_* secrets as
// dataverse-sync (Supabase secrets are shared across all functions in a project).
// Delete this function once the real filter is confirmed and ported over.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const DATAVERSE_TENANT_ID = Deno.env.get("DATAVERSE_TENANT_ID")!;
const DATAVERSE_CLIENT_ID = Deno.env.get("DATAVERSE_CLIENT_ID")!;
const DATAVERSE_CLIENT_SECRET = Deno.env.get("DATAVERSE_CLIENT_SECRET")!;
const DATAVERSE_ORG_URL = (Deno.env.get("DATAVERSE_ORG_URL") || "").replace(/\/+$/, "");

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), { status, headers: { "Content-Type": "application/json", ...corsHeaders } });
}

async function getDataverseToken(): Promise<string> {
  const res = await fetch(`https://login.microsoftonline.com/${DATAVERSE_TENANT_ID}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: DATAVERSE_CLIENT_ID,
      client_secret: DATAVERSE_CLIENT_SECRET,
      scope: `${DATAVERSE_ORG_URL}/.default`,
    }),
  });
  if (!res.ok) throw new Error(`Token request failed: ${res.status} ${await res.text()}`);
  return (await res.json()).access_token as string;
}

async function fetchJson(url: string, token: string): Promise<{ status: number; body: any }> {
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json", "OData-MaxVersion": "4.0", "OData-Version": "4.0" },
  });
  const text = await res.text();
  let body: any;
  try { body = JSON.parse(text); } catch { body = text; }
  return { status: res.status, body };
}

async function fetchCount(url: string, token: string): Promise<{ status: number; body: any }> {
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}`, Accept: "text/plain", "OData-MaxVersion": "4.0", "OData-Version": "4.0" },
  });
  const text = await res.text();
  return { status: res.status, body: text };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    let payload: { mode?: string; entity?: string; filter?: string; select?: string; top?: number } = {};
    try { payload = await req.json(); } catch { /* empty body ok */ }

    const token = await getDataverseToken();
    const base = `${DATAVERSE_ORG_URL}/api/data/v9.2`;

    if (payload.mode === "discover") {
      const accountRels = await fetchJson(
        `${base}/EntityDefinitions(LogicalName='account')/ManyToOneRelationships?$select=ReferencingAttribute,ReferencingEntityNavigationPropertyName,ReferencedEntity,ReferencedAttribute,SchemaName`,
        token,
      );
      const accountCountryRelationship =
        (accountRels.body.value || []).find((r: any) => r.ReferencingAttribute === "scp_countrylookup") || null;

      let countryEntityAttributes = null;
      let countryEntityLogicalName = accountCountryRelationship?.ReferencedEntity || null;
      if (countryEntityLogicalName) {
        const attrs = await fetchJson(`${base}/EntityDefinitions(LogicalName='${countryEntityLogicalName}')/Attributes?$select=LogicalName,SchemaName,AttributeType`, token);
        countryEntityAttributes = (attrs.body.value || []).map((a: any) => ({ logicalName: a.LogicalName, schemaName: a.SchemaName, type: a.AttributeType }));
      }

      const contactRels = await fetchJson(
        `${base}/EntityDefinitions(LogicalName='contact')/ManyToOneRelationships?$select=ReferencingAttribute,ReferencingEntityNavigationPropertyName,ReferencedEntity,SchemaName`,
        token,
      );
      const contactParentAccountRelationship =
        (contactRels.body.value || []).find((r: any) => r.ReferencingAttribute === "parentcustomerid" && r.ReferencedEntity === "account") || null;
      const contactCountryRelationships =
        (contactRels.body.value || []).filter((r: any) => String(r.ReferencingAttribute || "").toLowerCase().includes("country"));

      return jsonResponse({
        accountCountryRelationship, countryEntityLogicalName, countryEntityAttributes,
        contactParentAccountRelationship, contactCountryRelationships,
      });
    }

    if (payload.mode === "raw") {
      // path is anything after /api/data/v9.2/, e.g. "EntityDefinitions(LogicalName='account')/ManyToOneRelationships"
      const url = `${base}/${(payload as any).path}`;
      const result = await fetchJson(url, token);
      return jsonResponse(result);
    }

    if (payload.mode === "sample") {
      // Fetch a couple of raw rows with the country lookup + its formatted value,
      // so we can see real GUID/label pairs directly if metadata-based filtering fails.
      const url = `${base}/accounts?$select=accountid,name,_scp_countrylookup_value&$top=${payload.top || 10}`;
      const res = await fetch(url, {
        headers: {
          Authorization: `Bearer ${token}`, Accept: "application/json", "OData-MaxVersion": "4.0", "OData-Version": "4.0",
          Prefer: 'odata.include-annotations="OData.Community.Display.V1.FormattedValue"',
        },
      });
      const body = await res.json();
      return jsonResponse({ status: res.status, rows: body.value });
    }

    // Default mode: try a filtered count with an arbitrary caller-supplied $filter, so
    // filter strings can be iterated on directly without redeploying anything.
    // Dataverse's bare /$count sub-path doesn't support $filter at all here (fails
    // identically regardless of filter content) -- use ?$count=true on the base
    // collection instead and read @odata.count from the response.
    const entity = payload.entity === "contacts" ? "contacts" : "accounts";
    const idField = entity === "contacts" ? "contactid" : "accountid";
    const url = payload.filter
      ? `${base}/${entity}?$select=${idField}&$count=true&$filter=${encodeURIComponent(payload.filter)}`
      : `${base}/${entity}?$select=${idField}&$count=true`;
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json", "OData-MaxVersion": "4.0", "OData-Version": "4.0", Prefer: "odata.maxpagesize=1" },
    });
    const text = await res.text();
    let body: any;
    try { body = JSON.parse(text); } catch { body = text; }
    return jsonResponse({
      entity, filter: payload.filter || null, status: res.status,
      count: body?.["@odata.count"] ?? null, hasMore: !!body?.["@odata.nextLink"], raw: res.status !== 200 ? body : undefined,
    });
  } catch (err) {
    return jsonResponse({ error: String((err as Error)?.message || err) }, 500);
  }
});
