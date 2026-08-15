-- Links activity_entries to a real crm_accounts/crm_contacts row (when the rep
-- picked or created one via the new form.html autocomplete) instead of only ever
-- storing a free-text account_name. account_name/contact_name stay as-is for
-- display so nothing breaks for existing rows or if a rep skips linking.
alter table public.activity_entries
  add column account_external_id text references public.crm_accounts(external_id),
  add column contact_external_id text references public.crm_contacts(external_id),
  add column contact_name text;

create index idx_activity_entries_account_external_id on public.activity_entries(account_external_id);

-- Distinguishes CRM accounts/contacts that came from the real Dataverse sync (or
-- a CSV export of it) from ones a rep created on the fly through the submission
-- form for a company/contact not yet in CRM. Lets the CRM admin page and any
-- future reconciliation flag them distinctly instead of looking identical.
alter table public.crm_accounts add column source text not null default 'dataverse' check (source in ('dataverse', 'manual'));
alter table public.crm_contacts add column source text not null default 'dataverse' check (source in ('dataverse', 'manual'));

-- ---------------------------------------------------------------------------
-- Public-form access to CRM accounts/contacts, without opening the tables
-- themselves to anon (they stay manager-only per existing RLS). These four
-- functions are the only surface anon gets: narrow read-only search, and
-- narrow, validated inserts for reps creating a company/contact CRM doesn't
-- have yet. Same security-definer pattern as current_role_name()/get_rag_scorecard.
-- ---------------------------------------------------------------------------

create or replace function public.search_crm_accounts(p_query text, p_limit int default 8)
returns table (external_id text, name text, city text, state_code text)
language sql
security definer
set search_path = public
stable
as $$
  select external_id, name, city, state_code
  from public.crm_accounts
  where p_query is not null and length(trim(p_query)) >= 2
    and name ilike '%' || trim(p_query) || '%'
  order by name
  limit greatest(1, least(coalesce(p_limit, 8), 25));
$$;

revoke all on function public.search_crm_accounts(text, int) from public;
grant execute on function public.search_crm_accounts(text, int) to anon, authenticated;

create or replace function public.search_crm_contacts(p_account_external_id text)
returns table (external_id text, full_name text, email text)
language sql
security definer
set search_path = public
stable
as $$
  select external_id, full_name, email
  from public.crm_contacts
  where p_account_external_id is not null
    and parent_account_external_id = p_account_external_id
  order by full_name
  limit 25;
$$;

revoke all on function public.search_crm_contacts(text) from public;
grant execute on function public.search_crm_contacts(text) to anon, authenticated;

create or replace function public.create_manual_crm_account(p_name text, p_city text, p_state_code text, p_rep_firm_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_external_id text;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Account name is required';
  end if;
  if p_rep_firm_id is not null and not exists (select 1 from public.rep_firms where id = p_rep_firm_id and status = 'active') then
    raise exception 'Invalid rep firm';
  end if;

  v_external_id := 'manual:' || gen_random_uuid();
  insert into public.crm_accounts (external_id, name, name_key, city, state_code, rep_firm_id, source, updated_at)
  values (v_external_id, trim(p_name), lower(trim(p_name)), nullif(trim(coalesce(p_city, '')), ''), nullif(upper(trim(coalesce(p_state_code, ''))), ''), p_rep_firm_id, 'manual', now());

  return v_external_id;
end;
$$;

revoke all on function public.create_manual_crm_account(text, text, text, uuid) from public;
grant execute on function public.create_manual_crm_account(text, text, text, uuid) to anon, authenticated;

create or replace function public.create_manual_crm_contact(p_account_external_id text, p_full_name text, p_email text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_external_id text;
  v_rep_firm_id uuid;
begin
  if p_full_name is null or length(trim(p_full_name)) = 0 then
    raise exception 'Contact name is required';
  end if;
  select rep_firm_id into v_rep_firm_id from public.crm_accounts where external_id = p_account_external_id;
  if not found then
    raise exception 'Invalid account';
  end if;

  v_external_id := 'manual:' || gen_random_uuid();
  insert into public.crm_contacts (external_id, full_name, email, email_key, parent_account_external_id, rep_firm_id, source, updated_at)
  values (v_external_id, trim(p_full_name), nullif(trim(coalesce(p_email, '')), ''), nullif(lower(trim(coalesce(p_email, ''))), ''), p_account_external_id, v_rep_firm_id, 'manual', now());

  return v_external_id;
end;
$$;

revoke all on function public.create_manual_crm_contact(text, text, text) from public;
grant execute on function public.create_manual_crm_contact(text, text, text) to anon, authenticated;
