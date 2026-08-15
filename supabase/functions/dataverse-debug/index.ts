// TEMPORARY diagnostic-only function, re-enabled briefly to look up the Intellimix
// parent account + rep firm child accounts. Deliberately unauthenticated
// (verify_jwt: false) -- read-only, no row data pulled beyond a handful of account
// records, never touches Supabase tables. Reuses the same project-level
// DATAVERSE_* secrets as dataverse-sync. Disable again (verify_jwt: true, body
// stubbed) once done.
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    let payload: { path?: string } = {};
    try { payload = await req.json(); } catch { /* empty body ok */ }

    const token = await getDataverseToken();
    const base = `${DATAVERSE_ORG_URL}/api/data/v9.2`;
    const url = `${base}/${payload.path || ""}`;
    const res = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`, Accept: "application/json", "OData-MaxVersion": "4.0", "OData-Version": "4.0",
        Prefer: 'odata.include-annotations="OData.Community.Display.V1.FormattedValue"',
      },
    });
    const text = await res.text();
    let body: any;
    try { body = JSON.parse(text); } catch { body = text; }
    return jsonResponse({ status: res.status, body });
  } catch (err) {
    return jsonResponse({ error: String((err as Error)?.message || err) }, 500);
  }
});
