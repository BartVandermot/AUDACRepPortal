-- Synced Dataverse contacts (companion to crm_accounts). Primarily used so the
-- Education upload can match a person by email (from the education platform
-- export) to their CRM contact record, and inherit that contact's parent
-- account's already-resolved rep_firm_id -- a more precise alternative to
-- matching by company-name text.

create table public.crm_contacts (
  id uuid primary key default gen_random_uuid(),
  external_id text unique,
  full_name text,
  email text,
  email_key text,
  parent_account_external_id text,
  rep_firm_id uuid references public.rep_firms(id),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

comment on column public.crm_contacts.email_key is 'normalized (lowercased, trimmed) email, used to match this contact against the Email column in education uploads -- not unique, since real contacts can share an inbox';
comment on column public.crm_contacts.rep_firm_id is 'inherited from the parent account''s resolved rep_firm_id at sync time';

create index idx_crm_contacts_rep_firm on public.crm_contacts (rep_firm_id);
create index idx_crm_contacts_email_key on public.crm_contacts (email_key);

alter table public.crm_contacts enable row level security;

create policy "crm_contacts_select_manager" on public.crm_contacts
  for select using (public.current_role_name() = 'manager');
create policy "crm_contacts_write_manager" on public.crm_contacts
  for all using (public.current_role_name() = 'manager')
  with check (public.current_role_name() = 'manager');
