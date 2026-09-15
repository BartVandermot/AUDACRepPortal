-- Melissa's feedback: adding a company/contact CRM doesn't have yet only
-- captured a name -- no address or phone for the company, no phone for the
-- contact -- even though this is often the best opportunity to actually
-- capture that data (a rep is standing in front of the dealer). Neither
-- table had anywhere to put a phone number at all until now.
alter table public.crm_accounts add column if not exists phone text;
alter table public.crm_contacts add column if not exists phone text;

drop function if exists public.create_manual_crm_account(text, text, text, uuid);
create function public.create_manual_crm_account(p_name text, p_street text, p_city text, p_state_code text, p_phone text, p_rep_firm_id uuid)
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
  insert into public.crm_accounts (external_id, name, name_key, street, city, state_code, phone, rep_firm_id, source, updated_at)
  values (
    v_external_id, trim(p_name), lower(trim(p_name)),
    nullif(trim(coalesce(p_street, '')), ''),
    nullif(trim(coalesce(p_city, '')), ''),
    nullif(upper(trim(coalesce(p_state_code, ''))), ''),
    nullif(trim(coalesce(p_phone, '')), ''),
    p_rep_firm_id, 'manual', now()
  );

  return v_external_id;
end;
$$;

revoke all on function public.create_manual_crm_account(text, text, text, text, text, uuid) from public;
grant execute on function public.create_manual_crm_account(text, text, text, text, text, uuid) to anon, authenticated;

drop function if exists public.create_manual_crm_contact(text, text, text);
create function public.create_manual_crm_contact(p_account_external_id text, p_full_name text, p_email text, p_phone text)
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
  insert into public.crm_contacts (external_id, full_name, email, email_key, phone, parent_account_external_id, rep_firm_id, source, updated_at)
  values (
    v_external_id, trim(p_full_name),
    nullif(trim(coalesce(p_email, '')), ''),
    nullif(lower(trim(coalesce(p_email, ''))), ''),
    nullif(trim(coalesce(p_phone, '')), ''),
    p_account_external_id, v_rep_firm_id, 'manual', now()
  );

  return v_external_id;
end;
$$;

revoke all on function public.create_manual_crm_contact(text, text, text, text) from public;
grant execute on function public.create_manual_crm_contact(text, text, text, text) to anon, authenticated;
