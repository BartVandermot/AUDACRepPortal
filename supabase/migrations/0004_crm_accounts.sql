-- CRM Accounts reference data (POC for a future live D365/Dataverse sync).
-- Uploaded from a CRM Accounts export -- has real address/state data, so it
-- resolves rep_firm_id by matching state against rep_firms.states, rather
-- than requiring a manual company assignment like rep_firm_aliases does.
-- This is the primary lookup for company -> rep firm resolution in the
-- education/pipeline/sell-out uploads; rep_firm_aliases is the fallback for
-- any company not present in this table.

create table public.crm_accounts (
  id uuid primary key default gen_random_uuid(),
  external_id text unique,
  name text not null,
  name_key text not null unique,
  street text,
  city text,
  state_raw text,
  state_code text,
  zip text,
  country_code text,
  website text,
  relationship_type text,
  business_type text,
  rep_firm_id uuid references public.rep_firms(id),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

comment on column public.crm_accounts.name_key is 'normalized (lowercased, trimmed) account name, used to match this account against company names in education/pipeline/sell-out uploads';
comment on column public.crm_accounts.rep_firm_id is 'resolved from state_code against rep_firms.states; null means US account outside any configured territory, or non-US';

create index idx_crm_accounts_rep_firm on public.crm_accounts (rep_firm_id);

alter table public.crm_accounts enable row level security;

create policy "crm_accounts_select_manager" on public.crm_accounts
  for select using (public.current_role_name() = 'manager');
create policy "crm_accounts_write_manager" on public.crm_accounts
  for all using (public.current_role_name() = 'manager')
  with check (public.current_role_name() = 'manager');
