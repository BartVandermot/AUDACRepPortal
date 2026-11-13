-- Write-back race (2026-11-13), applied via execute_sql.
--
-- A rep added "EDC Solutions" on the Log form and, while still typing the
-- contact, the 5-minute crm-writeback run created the company in Dynamics and
-- merged the portal's temporary "manual:" record away. The form still held
-- the manual id, so "Add contact" failed with "Invalid account" (and saving
-- the activity would have failed the same way; an offline-queued activity
-- could hit it hours later).
--
-- Fix, two layers:
-- 1. crm_current_id(): a "manual:" id that the write-back has replaced is
--    translated to the Dynamics id via crm_writeback_log. Used by
--    create_manual_crm_contact and by a BEFORE trigger on activity_entries
--    that runs before the link check (trigger names fire alphabetically).
-- 2. crm-writeback waits until a manual record is 15 minutes untouched
--    (edge function change), so the window is normally never hit.

create or replace function public.crm_current_id(p_kind text, p_id text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when p_id like 'manual:%' then coalesce(
      (select l.dynamics_id from public.crm_writeback_log l
        where l.kind = p_kind and l.manual_external_id = p_id and l.dynamics_id is not null
        order by l.at desc limit 1),
      p_id)
    else p_id end;
$$;
revoke all on function public.crm_current_id(text, text) from public, anon;
grant execute on function public.crm_current_id(text, text) to authenticated;

create or replace function public.remap_activity_crm_ids()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.account_external_id like 'manual:%'
     and not exists (select 1 from public.crm_accounts a where a.external_id = new.account_external_id) then
    new.account_external_id := public.crm_current_id('account', new.account_external_id);
  end if;
  if new.contact_external_id like 'manual:%'
     and not exists (select 1 from public.crm_contacts c where c.external_id = new.contact_external_id) then
    new.contact_external_id := public.crm_current_id('contact', new.contact_external_id);
  end if;
  return new;
end;
$$;
revoke all on function public.remap_activity_crm_ids() from public, anon, authenticated;

create or replace trigger activity_entries_a_remap_crm_ids
  before insert or update of account_external_id, contact_external_id on public.activity_entries
  for each row execute function public.remap_activity_crm_ids();

create or replace function public.create_manual_crm_contact(p_account_external_id text, p_full_name text, p_email text, p_phone text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_external_id text;
  v_rep_firm_id uuid;
  v_my_firm uuid;
  v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_account text := p_account_external_id;
begin
  if p_full_name is null or length(trim(p_full_name)) = 0 then raise exception 'Contact name is required'; end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'An e-mail address is required for a new contact'; end if;
  -- The company may have been sent to Dynamics while the form was open.
  if not exists (select 1 from public.crm_accounts where external_id = v_account) then
    v_account := public.crm_current_id('account', v_account);
  end if;
  select rep_firm_id into v_rep_firm_id from public.crm_accounts where external_id = v_account;
  if not found then raise exception 'Invalid account'; end if;
  if public.current_role_name() is distinct from 'manager' then
    select rep_firm_id into v_my_firm from public.profiles where id = auth.uid();
    if v_my_firm is not null and v_rep_firm_id is distinct from v_my_firm then
      raise exception 'You can only add contacts to your own firm''s accounts';
    end if;
  end if;
  v_external_id := 'manual:' || gen_random_uuid();
  insert into public.crm_contacts (external_id, full_name, email, email_key, phone, parent_account_external_id, rep_firm_id, source, created_by, updated_at)
  values (v_external_id, trim(p_full_name), trim(p_email), v_email, nullif(trim(coalesce(p_phone, '')), ''), v_account, v_rep_firm_id, 'manual', auth.uid(), now());
  return v_external_id;
end; $function$;
