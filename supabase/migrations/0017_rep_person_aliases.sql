-- Most Opportunities are filed under Intellimix itself as the customer
-- account, so customer-account lookup can't resolve a rep firm for them.
-- Melissa already records which rep is handling each deal in the
-- Opportunity's Contact field (a person's name, e.g. "Brad Horbal") -- this
-- table lets a manager assign each distinct rep name to a rep firm once,
-- reused on every later sync. Same shape/purpose as rep_firm_aliases, just
-- keyed on a person's name instead of a company's.

create table public.rep_person_aliases (
  id uuid primary key default gen_random_uuid(),
  person_name_key text not null unique,
  display_name text not null,
  rep_firm_id uuid references public.rep_firms(id),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

comment on column public.rep_person_aliases.person_name_key is 'normalized (lowercased, trimmed) rep person name as it appears in the Opportunity Contact field';
comment on column public.rep_person_aliases.rep_firm_id is 'null means the manager explicitly chose to exclude this person (not a rep whose deals should count toward a firm)';

alter table public.rep_person_aliases enable row level security;

create policy "rep_person_aliases_select_manager" on public.rep_person_aliases
  for select using (public.current_role_name() = 'manager');
create policy "rep_person_aliases_write_manager" on public.rep_person_aliases
  for all using (public.current_role_name() = 'manager')
  with check (public.current_role_name() = 'manager');
