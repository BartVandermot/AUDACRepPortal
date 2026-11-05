// Quick log: turns a rep's typed or dictated note into activity form fields.
// Branch quick-log -- no live page calls this yet.
//
// POST { note, today: "YYYY-MM-DD", firm_id?, model? }  (Authorization: the rep's session)
//   -> { run_id, activities: [...], message, model }
//
// The rep always reviews the result in the normal form; nothing is saved here
// except the run log (quick_log_runs). Accounts and contacts can only be ones
// of the caller's own firm: Claude picks them by short alias from a list we
// send, and every pick is checked against that list again before it's
// returned. Anything not in the list comes back as a new company/contact name
// for the rep to confirm.
//
// Secrets: ANTHROPIC_API_KEY (set by Bart in Supabase). Optional:
// QUICK_LOG_MODEL (default claude-opus-5-5), QUICK_LOG_EFFORT (default low).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import Anthropic from "npm:@anthropic-ai/sdk";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DEFAULT_MODEL = Deno.env.get("QUICK_LOG_MODEL") || "claude-opus-5-5";
const EFFORT = (Deno.env.get("QUICK_LOG_EFFORT") || "low") as "low" | "medium" | "high";
// Managers may pick a model per request, to compare them on the same notes.
const ALLOWED_MODELS = new Set(["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]);
// Server-side fallback on a refusal: supported on Opus 5.5 and Sonnet 5.5, not Haiku 5.5.
const FALLBACK_MODELS = new Set(["claude-opus-5-5", "claude-sonnet-5-5"]);

const NOTE_MAX = 2000;
const RUNS_PER_DAY = 60;
const MAX_ACCOUNTS = 600;
const MAX_CONTACTS = 1200;

const CONTACT_TYPES = ["Dealer", "Consultant", "End User"];
const ACTIVITY_TYPES = ["Brand Introduction", "Demo", "Follow Up", "Lunch & Learn", "Online Demo", "Dealer Training", "Other"];
const UNCERTAIN_FIELDS = ["entry_date", "account", "contact", "contact_type", "activity_type", "demo_gear_used"];

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...corsHeaders } });
}

const PARTY = {
  type: "object",
  additionalProperties: false,
  required: ["match", "ref", "name"],
  properties: {
    match: { type: "string", enum: ["existing", "new", "none"] },
    ref: { anyOf: [{ type: "string" }, { type: "null" }] },
    name: { type: "string" },
  },
};
const SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["activities", "message"],
  properties: {
    activities: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["entry_date", "account", "contact", "contact_type", "activity_type", "demo_gear_used",
          "topic_opportunity", "solution_feedback", "competitive_feedback", "additional_comments", "uncertain"],
        properties: {
          entry_date: { type: "string", format: "date" },
          account: PARTY,
          contact: PARTY,
          contact_type: { type: "string", enum: [...CONTACT_TYPES, "unknown"] },
          activity_type: { type: "string", enum: ACTIVITY_TYPES },
          demo_gear_used: { type: "boolean" },
          topic_opportunity: { type: "string" },
          solution_feedback: { type: "string" },
          competitive_feedback: { type: "string" },
          additional_comments: { type: "string" },
          uncertain: { type: "array", items: { type: "string", enum: UNCERTAIN_FIELDS } },
        },
      },
    },
    message: { type: "string" },
  },
};

// Stable across requests (kept first, so it can be cached).
const SYSTEM = `You turn a sales rep's short note into activity log entries for the AUDAC Rep Portal.

Context: AUDAC makes commercial audio products (loudspeakers, amplifiers, mixers, paging, Dante audio). The writers are independent manufacturer's reps in the US and Canada. They visit dealers (AV integrators, installers, resellers), consultants (designers, specifiers, architects) and end users. Notes are often dictated on a phone, so expect missing punctuation and misheard names.

How to fill an entry:
- One entry per distinct visit, call or meeting. A note can contain several.
- account: pick a company from the account list by its ref (e.g. "A12"). Match loosely on spelling and dictation errors, but only when you are confident it is the same company. If the company is not in the list, use match "new" with the name as the rep said it. Use "none" only when no company is mentioned at all.
- contact: a person at that account. Pick from the contact list by ref only if that contact belongs to the chosen account; otherwise "new" with the name, or "none".
- entry_date: resolve words like "yesterday" or "last Tuesday" against today's date given with the note. Never a date after today. If no date is mentioned, use today.
- contact_type: Dealer, Consultant or End User. The account list shows a type hint where known; use "unknown" when you can't tell.
- activity_type: "Brand Introduction" (first meeting presenting AUDAC), "Demo" (product demo in person), "Online Demo" (demo over Teams/Zoom), "Follow Up" (follow-up on earlier contact, a quote or a project), "Lunch & Learn", "Dealer Training", or "Other".
- demo_gear_used: true only if demo equipment was shown or used.
- Split what was said: topic_opportunity = what was discussed or the opportunity (project, size, products, next step); solution_feedback = what they said about AUDAC products or solutions; competitive_feedback = competitors, competing products or price comparisons; additional_comments = anything else, such as agreed follow-up dates.
- Write in English, short, close to the rep's own words. Leave a text field as "" when nothing was said about it; never invent details.
- uncertain: list the fields you had to guess, so the rep checks them.
- message: one short sentence to the rep if something important was unclear (e.g. two companies with similar names), otherwise "".`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const started = Date.now();
  const svc = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  let runId: string | null = null;
  try {
    // ---- who is asking ----
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: userData, error: userErr } = await svc.auth.getUser(jwt);
    if (userErr || !userData?.user) return json({ error: "Please sign in again." }, 401);
    const userId = userData.user.id;
    const { data: profile } = await svc.from("profiles").select("role, is_active, rep_firm_id").eq("id", userId).maybeSingle();
    if (!profile || profile.is_active === false) return json({ error: "Your account is not active." }, 403);

    const body = await req.json().catch(() => ({}));
    const isManager = profile.role === "manager";
    const firmId: string | null = isManager ? (body.firm_id || null) : profile.rep_firm_id;
    if (profile.role !== "rep" && !isManager) return json({ error: "Quick log is for reps." }, 403);
    if (!firmId) return json({ error: isManager ? "Pick the firm to test with." : "Your account isn't linked to a rep firm yet." }, 400);
    const model = isManager && ALLOWED_MODELS.has(body.model) ? body.model : DEFAULT_MODEL;

    const note = String(body.note || "").trim();
    if (note.length < 3) return json({ error: "Type or dictate what happened first." }, 400);
    if (note.length > NOTE_MAX) return json({ error: `Keep it under ${NOTE_MAX} characters, or split it in two.` }, 400);
    const todayStr = /^\d{4}-\d{2}-\d{2}$/.test(body.today || "") ? body.today : new Date().toISOString().slice(0, 10);

    if (!Deno.env.get("ANTHROPIC_API_KEY")) return json({ error: "Quick log isn't switched on yet (API key not configured)." }, 503);

    // ---- daily limit ----
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    const { count } = await svc.from("quick_log_runs").select("id", { count: "exact", head: true }).eq("user_id", userId).gte("created_at", since);
    if ((count || 0) >= RUNS_PER_DAY) return json({ error: "Daily Quick log limit reached. Use the form below." }, 429);

    // ---- the firm's accounts and contacts, under short refs ----
    const [{ data: accts }, { data: contacts }] = await Promise.all([
      svc.from("crm_accounts").select("external_id, name, city, state_code, business_type, relationship_type")
        .eq("rep_firm_id", firmId).eq("is_active", true).order("name").limit(MAX_ACCOUNTS),
      svc.from("crm_contacts").select("external_id, full_name, parent_account_external_id")
        .eq("rep_firm_id", firmId).eq("is_active", true).order("full_name").limit(MAX_CONTACTS),
    ]);
    const accountByRef = new Map<string, { id: string; name: string }>();
    const refByAccountId = new Map<string, string>();
    const typeHint = (a: { business_type: string | null; relationship_type: string | null }) => {
      const b = a.business_type || "", r = a.relationship_type || "";
      if (/^end user/i.test(b) || r === "End User") return "End User";
      if (["Study/Consultancy Office", "Architect / Interior Designer"].includes(b) || r === "Influencer") return "Consultant";
      if (["A/V Integrator", "Rental company", "Distributor", "Pro Audio Shop", "Electrical Installer", "IT Company", "Home Automation Installer", "Wholesaler"].includes(b) || r === "Reseller") return "Dealer";
      return "";
    };
    const accountLines = (accts || []).map((a, i) => {
      const ref = `A${i + 1}`;
      accountByRef.set(ref, { id: a.external_id, name: a.name });
      refByAccountId.set(a.external_id, ref);
      return [ref, a.name, [a.city, a.state_code].filter(Boolean).join(", "), typeHint(a)].join(" | ");
    });
    const contactByRef = new Map<string, { id: string; name: string; accountRef: string }>();
    const contactLines: string[] = [];
    (contacts || []).forEach((c) => {
      const accRef = refByAccountId.get(c.parent_account_external_id || "");
      if (!accRef || !c.full_name) return;
      const ref = `C${contactLines.length + 1}`;
      contactByRef.set(ref, { id: c.external_id, name: c.full_name, accountRef: accRef });
      contactLines.push(`${ref} | ${c.full_name} | ${accRef}`);
    });

    const weekday = new Date(todayStr + "T12:00:00Z").toLocaleDateString("en-US", { weekday: "long", timeZone: "UTC" });
    const listsText = `Account list (ref | name | place | type hint):\n${accountLines.join("\n") || "(none)"}\n\nContact list (ref | name | account ref):\n${contactLines.join("\n") || "(none)"}`;

    const { data: run } = await svc.from("quick_log_runs").insert({ user_id: userId, rep_firm_id: firmId, model, effort: EFFORT, note }).select("id").single();
    runId = run?.id || null;

    // ---- Claude ----
    const anthropic = new Anthropic();
    const params: Record<string, unknown> = {
      model,
      max_tokens: 8000,
      system: SYSTEM,
      output_config: { effort: EFFORT, format: { type: "json_schema", schema: SCHEMA } },
      messages: [{
        role: "user",
        content: [
          { type: "text", text: listsText, cache_control: { type: "ephemeral" } },
          { type: "text", text: `Today is ${weekday} ${todayStr}.\n\nThe rep's note:\n${note}` },
        ],
      }],
    };
    // deno-lint-ignore no-explicit-any
    const response: any = FALLBACK_MODELS.has(model)
      // deno-lint-ignore no-explicit-any
      ? await anthropic.beta.messages.create({ ...params, betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" } as any)
      // deno-lint-ignore no-explicit-any
      : await anthropic.messages.create(params as any);

    if (response.stop_reason === "refusal") throw new Error("Claude could not process this note. Please use the form.");
    if (response.stop_reason === "max_tokens") throw new Error("The note was too long to process in one go. Split it in two.");
    // deno-lint-ignore no-explicit-any
    const text = (response.content || []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("");
    const parsed = JSON.parse(text);

    // ---- check every pick against the firm's own lists ----
    const minDate = new Date(Date.now() - 365 * 86400000).toISOString().slice(0, 10);
    // deno-lint-ignore no-explicit-any
    const activities = (parsed.activities || []).map((a: any) => {
      const uncertain = new Set<string>(Array.isArray(a.uncertain) ? a.uncertain : []);
      let entry_date = /^\d{4}-\d{2}-\d{2}$/.test(a.entry_date || "") ? a.entry_date : todayStr;
      if (entry_date > todayStr || entry_date < minDate) { entry_date = todayStr; uncertain.add("entry_date"); }

      let account: { external_id: string | null; name: string; is_new: boolean } = { external_id: null, name: "", is_new: false };
      const acc = a.account?.match === "existing" ? accountByRef.get(a.account.ref) : undefined;
      if (acc) account = { external_id: acc.id, name: acc.name, is_new: false };
      else if (a.account?.name) { account = { external_id: null, name: String(a.account.name).trim(), is_new: true }; if (a.account.match === "existing") uncertain.add("account"); }
      else uncertain.add("account");

      let contact: { external_id: string | null; name: string; is_new: boolean } = { external_id: null, name: "", is_new: false };
      const con = a.contact?.match === "existing" ? contactByRef.get(a.contact.ref) : undefined;
      if (con && acc && con.accountRef === a.account.ref) contact = { external_id: con.id, name: con.name, is_new: false };
      else if (a.contact?.name && a.contact.match !== "none") contact = { external_id: null, name: String(a.contact.name).trim(), is_new: true };

      const contact_type = CONTACT_TYPES.includes(a.contact_type) ? a.contact_type : "";
      if (!contact_type) uncertain.add("contact_type");
      const activity_type = ACTIVITY_TYPES.includes(a.activity_type) ? a.activity_type : "Other";
      const clean = (s: unknown) => String(s || "").trim().slice(0, 2000);
      return {
        entry_date, account, contact, contact_type, activity_type,
        demo_gear_used: a.demo_gear_used === true,
        topic_opportunity: clean(a.topic_opportunity),
        solution_feedback: clean(a.solution_feedback),
        competitive_feedback: clean(a.competitive_feedback),
        additional_comments: clean(a.additional_comments),
        uncertain: [...uncertain].filter((f) => UNCERTAIN_FIELDS.includes(f)),
      };
    }).slice(0, 10);
    const message = String(parsed.message || "").trim();

    const usage = response.usage || {};
    if (runId) {
      await svc.from("quick_log_runs").update({
        ok: true, result: { activities, message }, activities: activities.length,
        input_tokens: (usage.input_tokens || 0) + (usage.cache_read_input_tokens || 0) + (usage.cache_creation_input_tokens || 0),
        output_tokens: usage.output_tokens || 0, cache_read_tokens: usage.cache_read_input_tokens || 0,
        duration_ms: Date.now() - started, model: response.model || model,
      }).eq("id", runId);
    }
    if (!activities.length) return json({ run_id: runId, activities: [], message: message || "No activity found in this note. Try saying who you met, where and what about.", model });
    return json({ run_id: runId, activities, message, model: response.model || model });
  } catch (err) {
    const msg = err instanceof Anthropic.APIError
      ? (err.status === 401 ? "Quick log isn't configured correctly (API key)." : err.status === 429 || (err.status ?? 0) >= 500 ? "Quick log is busy right now. Try again in a minute, or use the form." : "Quick log could not process this note.")
      : String((err as Error)?.message || err);
    if (runId) await svc.from("quick_log_runs").update({ ok: false, error: String((err as Error)?.message || err).slice(0, 1000), duration_ms: Date.now() - started }).eq("id", runId);
    return json({ error: msg }, 500);
  }
});
