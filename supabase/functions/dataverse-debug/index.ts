// DISABLED -- this was a temporary diagnostic-only proxy into the raw
// Dataverse API, used once to look up account GUIDs while building
// dataverse-sync. It had no role check of its own (any authenticated user,
// not just a manager, could call it and read arbitrary Dataverse paths), so
// its body is now stubbed out entirely rather than left live. Safe to
// delete this function altogether via the Supabase Dashboard.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  return new Response(JSON.stringify({ error: "This diagnostic function has been permanently disabled." }), {
    status: 410,
    headers: { "Content-Type": "application/json", ...corsHeaders },
  });
});
