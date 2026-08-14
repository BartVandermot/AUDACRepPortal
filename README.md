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

## CSV uploads

The manager dashboard's upload panels (Education, Pipeline, Sell-out) parse a CSV client-side, let you map its columns to the schema fields (including a required "Rep Firm" column matched against `rep_firms.name`), and save that mapping per source in `csv_column_mappings` so later uploads from the same export auto-apply it. Rows whose firm doesn't match a known rep firm are skipped and counted in the upload summary.

## Deploying

1. Push this repo to `https://github.com/BartVandermot/AUDACRepPortal.git`.
2. Import the repo into Vercel as a static project (no build step needed — `vercel.json` handles routing).
3. Distribute rep-specific form links as `https://<domain>/form?firm=<rep_firm_id>` (get each firm's `id` from the `rep_firms` table).

## Phase 2 (not in this build)

D365 API integration (pipeline data currently comes in via CSV upload only).
