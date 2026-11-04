-- Make the opportunity sync's decisions visible.
-- 1. Synced deals keep their Dynamics Contact, so "which deals still list
--    person X" can be answered without querying Dynamics.
-- 2. Deals the sync could NOT credit to a rep firm used to vanish silently;
--    they're now kept in crm_skipped_opportunities (rewritten every full sync)
--    with the installer / contact / location that failed to resolve.

alter table public.pipeline_entries add column if not exists contact_external_id text;
alter table public.pipeline_entries add column if not exists contact_name text;
create index if not exists pipeline_entries_contact_idx on public.pipeline_entries(contact_external_id) where contact_external_id is not null;

create table if not exists public.crm_skipped_opportunities (
  crm_id text primary key,
  name text,
  status text,
  value_usd numeric,
  created_date date,
  expected_close_date date,
  contact_external_id text,
  contact_name text,
  installer_external_id text,
  installer_name text,
  location text,
  last_seen_at timestamptz not null default now()
);
alter table public.crm_skipped_opportunities enable row level security;
create policy crm_skipped_opportunities_select on public.crm_skipped_opportunities
  for select using (public.current_role_name() = any (array['manager', 'executive']));
grant select on public.crm_skipped_opportunities to authenticated;
create index if not exists crm_skipped_opportunities_contact_idx on public.crm_skipped_opportunities(contact_external_id);
