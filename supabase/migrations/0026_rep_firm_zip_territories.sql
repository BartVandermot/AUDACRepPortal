-- Some states are split between two rep firms by sub-region (e.g. Western vs
-- Eastern PA), not just assigned whole to one firm. rep_firms.states already
-- lists the state for BOTH firms in that case (so whole-state lookups
-- elsewhere -- e.g. the territories.html conflict warning -- still see it),
-- but that leaves plain `states @> array[code]` matching unable to pick a
-- side. This table disambiguates those specific state+firm pairs by zip3
-- (first 3 digits of the US zip code), and is only consulted for states that
-- actually need it -- everywhere else, the existing states-array match is
-- still authoritative and unambiguous on its own.
create table public.rep_firm_zip_ranges (
  id uuid primary key default gen_random_uuid(),
  rep_firm_id uuid not null references public.rep_firms(id),
  state_code text not null,
  zip3_start int not null check (zip3_start between 0 and 999),
  zip3_end int not null check (zip3_end between zip3_start and 999),
  created_at timestamptz not null default now()
);

create index idx_rep_firm_zip_ranges_state on public.rep_firm_zip_ranges (state_code);

alter table public.rep_firm_zip_ranges enable row level security;

create policy "rep_firm_zip_ranges_select_all" on public.rep_firm_zip_ranges
  for select using (true);
create policy "rep_firm_zip_ranges_write_manager" on public.rep_firm_zip_ranges
  for all using (public.current_role_name() = 'manager')
  with check (public.current_role_name() = 'manager');

-- Boundaries confirmed against Melissa's account of how each split is
-- actually divided (2026-09-15): Western/Eastern PA, Metro/Upstate NY,
-- Southern/Northern CA and NV.
insert into public.rep_firm_zip_ranges (rep_firm_id, state_code, zip3_start, zip3_end) values
  ('9592267c-1279-4a49-8eae-b9fbc8f53b5a', 'PA', 150, 169), -- C. L. Pugh & Associates: Western PA
  ('fd8d8c2c-75df-4044-a29f-d680543536c7', 'PA', 170, 196), -- Lienau AV: Eastern PA
  ('fd8d8c2c-75df-4044-a29f-d680543536c7', 'NY', 100, 119), -- Lienau AV: Metro NY
  ('9cafb34e-d3e0-4a2f-b08e-3e4721b1db06', 'NY', 120, 149), -- Eaton Sales Associates: Upstate NY
  ('af70f9e4-eda8-4cab-b472-efdb0aadcaa4', 'CA', 900, 935), -- MC Marketing Pro: Southern CA
  ('b6e17e57-8def-4a6b-b8c6-201b3c96f682', 'CA', 936, 961), -- LVX: Northern CA
  ('af70f9e4-eda8-4cab-b472-efdb0aadcaa4', 'NV', 889, 891), -- MC Marketing Pro: Southern NV
  ('af70f9e4-eda8-4cab-b472-efdb0aadcaa4', 'NV', 893, 893), -- MC Marketing Pro: Southern NV
  ('b6e17e57-8def-4a6b-b8c6-201b3c96f682', 'NV', 894, 898); -- LVX: Northern NV

-- One-time correction of existing crm_accounts rows that were resolved
-- before this table existed (so plain `states @> array[code]` matching --
-- non-deterministic across two firms sharing a state -- decided them,
-- sometimes wrong: several Southern CA/NV dealers had landed under LVX
-- instead of MC Marketing Pro). Only touches rows that are (a) not manually
-- overridden and (b) either unassigned or currently assigned to one of the
-- two firms actually contesting that state, so an unrelated CRM-hierarchy
-- resolution (e.g. an Industry Tech Sales account) is never clobbered.
update public.crm_accounts a
set rep_firm_id = z.rep_firm_id,
    updated_at = now()
from public.rep_firm_zip_ranges z
where a.state_code = z.state_code
  and a.zip is not null
  and a.zip ~ '^\d{3}'
  and (substring(a.zip from '^\d{3}'))::int between z.zip3_start and z.zip3_end
  and a.rep_firm_overridden = false
  and a.rep_firm_id is distinct from z.rep_firm_id
  and (
    a.rep_firm_id is null
    or a.rep_firm_id in (select rfz.rep_firm_id from public.rep_firm_zip_ranges rfz where rfz.state_code = z.state_code)
  );
