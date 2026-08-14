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

The manager dashboard's upload panels (Education, Pipeline, Sell-out) accept either `.csv` or `.xlsx`/`.xls` files, parsed entirely client-side (XLSX via SheetJS, no server round-trip). On first upload per source you map its columns to the schema fields; that mapping is saved in `csv_column_mappings` and auto-applied on later uploads from the same export.

Real exports list end-customer/dealer company names (e.g. "AC PROMEDIA"), not rep firm names — there's no direct match against `rep_firms.name`. So company → rep firm is resolved through `rep_firm_aliases`: the first time a given company name appears, the dashboard prompts you to assign it to one of the 6 rep firms (or skip it as not rep-tracked); that assignment is remembered for every later upload. Rows for a company you've skipped, or one still unassigned, are excluded and counted in the upload summary.

## Deploying

1. Push this repo to `https://github.com/BartVandermot/AUDACRepPortal.git`.
2. Import the repo into Vercel as a static project (no build step needed — `vercel.json` handles routing).
3. Distribute rep-specific form links as `https://<domain>/form?firm=<rep_firm_id>` (get each firm's `id` from the `rep_firms` table).

## Phase 2 (not in this build)

D365 API integration (pipeline data currently comes in via CSV upload only).
