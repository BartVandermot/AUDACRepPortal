# AUDAC Rep Portal

Rep performance tracking for AUDAC North America. Static HTML/CSS/JS (one self-contained file per view), Supabase for data + auth, deployed on Vercel.

## Structure

- `index.html` — landing page, links to sign-in
- `form.html` — public rep activity submission form (`/form?firm=<rep_firm_id>`)
- `login.html` — manager/executive sign-in
- `dashboard.html` — manager dashboard (RAG scorecard, drill-in, CSV uploads, review agenda generator)
- `executive.html` — executive KPI view (read-only)
- `vercel.json` — clean-URL rewrites (`/form`, `/login`, `/dashboard`, `/executive`)
- `supabase/migrations/` — SQL migrations (schema, RLS, RAG scorecard RPC, seed data)
- `supabase/functions/dataverse-sync/` — Edge Function that syncs Accounts/Contacts from Dynamics 365 (see below)

## Supabase setup

Project: `dhabmvpngjgrepyklius` (`https://dhabmvpngjgrepyklius.supabase.co`).

Migrations in `supabase/migrations/` have already been applied to this project. To replay them elsewhere:

```bash
supabase db push --db-url <connection-string>
```

### Creating the manager/executive accounts

The anon key can't create Auth users. In the Supabase Dashboard → **Authentication → Users → Add User**, create:

- `melissa@pvs.global` (manager)
- `bart@pvs.global` (executive)
- `tom@pvs.global` (executive)

Then link each to a role by inserting into `profiles` (run in the SQL editor or via the Supabase MCP tool):

```sql
insert into public.profiles (id, email, role)
select id, email,
  case email
    when 'melissa@pvs.global' then 'manager'
    when 'bart@pvs.global' then 'executive'
    when 'tom@pvs.global' then 'executive'
  end
from auth.users
where email in ('melissa@pvs.global', 'bart@pvs.global', 'tom@pvs.global')
on conflict (id) do update set role = excluded.role;
```

## CSV / XLSX uploads

The manager dashboard's upload panels (CRM Accounts, Education, Pipeline, Sell-out) accept either `.csv` or `.xlsx`/`.xls` files, parsed entirely client-side (XLSX via SheetJS, no server round-trip). On first upload per source you map its columns to the schema fields; that mapping is saved in `csv_column_mappings` and auto-applied on later uploads from the same export.

Real exports list end-customer/dealer company names (e.g. "AC PROMEDIA"), not rep firm names — there's no direct match against `rep_firms.name`. Company → rep firm resolution happens in three layers, checked in order:

1. **CRM contact email** (`crm_contacts`) — if the upload has an Email column (Education does), and that email matches a synced Dataverse contact, the row inherits that contact's parent account's rep firm. Most precise, since it's keyed on an actual person rather than a free-text company name.
2. **CRM Accounts** (`crm_accounts`) — matches the row's company name against a synced/uploaded account, whose rep firm was resolved by state (see below).
3. **Manual assignment** (`rep_firm_aliases`) — fallback for any company not found in either of the above. The first time a given company name appears in an Education/Pipeline/Sell-out upload, the dashboard prompts you to assign it to one of the 6 rep firms (or skip it as not rep-tracked); that assignment is remembered for every later upload.

Rows unresolved by all three layers, or explicitly skipped, are excluded and counted in the upload summary.

### Live CRM connection (Dynamics 365 / Dataverse)

The **"Sync from CRM"** button in the CRM Accounts panel calls the `dataverse-sync` Edge Function (`supabase/functions/dataverse-sync/`), which pulls Accounts and Contacts live from Dataverse and upserts them into `crm_accounts` / `crm_contacts` — same state-based resolution logic as the manual upload, which stays available as a fallback.

**Authentication**: server-to-server OAuth2 client-credentials flow (Microsoft's recommended pattern for unattended integrations) against a dedicated Entra ID app registration (`AUDAC Rep Portal - Dataverse Sync`, single-tenant), authorized in Dataverse via an Application User assigned a least-privilege security role (`API Read Only - Rep Portal Sync`: read-only on Account, Contact, Opportunity, Product, and the Country/Account-type lookup tables).

**Required Edge Function secrets** (set directly in Supabase — Project Settings → Edge Functions → Secrets, or `supabase secrets set`; never passed through the client or committed here):

| Secret | Value |
|---|---|
| `DATAVERSE_TENANT_ID` | `fb594a94-4558-4794-b174-ed9ae79130d8` |
| `DATAVERSE_CLIENT_ID` | `2a6392b0-7d54-410b-bd05-9bba3fc68766` |
| `DATAVERSE_ORG_URL` | `https://pvs4younv.crm4.dynamics.com` |
| `DATAVERSE_CLIENT_SECRET` | *(the client secret value — not written down anywhere; set it directly)* |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-provided to Edge Functions by Supabase; no need to set those.

Opportunity and Product read access is already granted on the security role for a later phase (pipeline/sell-out sync); the function doesn't use them yet.

## Deploying

1. Push this repo to `https://github.com/BartVandermot/AUDACRepPortal.git`.
2. Import the repo into Vercel as a static project (no build step needed — `vercel.json` handles routing).
3. Distribute rep-specific form links as `https://<domain>/form?firm=<rep_firm_id>` (get each firm's `id` from the `rep_firms` table).

## Phase 2 (not in this build)

Live Dataverse sync currently covers Account + Contact only (see above). Opportunity (pipeline) and Product data still come in via CSV/XLSX upload — the security role already has read access for when that's built.
