-- Dealer/distributor company names in real CSV/XLSX exports (education, D365, AVL)
-- don't match rep_firms.name directly -- they're end-customer accounts, not rep firm
-- names. This table lets the manager assign each distinct company name to a rep firm
-- once, and reuse that assignment on every later upload.

create table public.rep_firm_aliases (
  id uuid primary key default gen_random_uuid(),
  alias_key text not null unique,
  display_name text not null,
  rep_firm_id uuid references public.rep_firms(id),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

comment on column public.rep_firm_aliases.alias_key is 'normalized (lowercased, trimmed) dealer/distributor company name as it appears in CSV/XLSX exports';
comment on column public.rep_firm_aliases.rep_firm_id is 'null means the manager explicitly chose to exclude this company from import (not a rep-tracked account)';

alter table public.rep_firm_aliases enable row level security;

create policy "rep_firm_aliases_select_manager" on public.rep_firm_aliases
  for select using (public.current_role_name() = 'manager');
create policy "rep_firm_aliases_write_manager" on public.rep_firm_aliases
  for all using (public.current_role_name() = 'manager')
  with check (public.current_role_name() = 'manager');
