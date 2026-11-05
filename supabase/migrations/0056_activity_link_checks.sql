-- An activity's CRM links must be consistent (asked by Bart, 2026-11-06):
--   * a linked contact belongs to the linked account;
--   * a linked account belongs to the activity's rep firm (managers excepted).
-- Checked on insert and whenever those links change -- existing rows are left
-- as they are. Free-text contacts stay allowed at this level (CRM-export
-- imports keep contacts AUDAC doesn't know); the activity form itself requires
-- picking a contact or adding a new one.
-- Also: a rep can only add a new contact under an account of their own firm.

create or replace function public.check_activity_links()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.account_external_id is not null
     and (tg_op = 'INSERT' or new.account_external_id is distinct from old.account_external_id or new.rep_firm_id is distinct from old.rep_firm_id)
     and public.current_role_name() is distinct from 'manager'
     and not exists (select 1 from public.crm_accounts a where a.external_id = new.account_external_id and a.rep_firm_id = new.rep_firm_id) then
    raise exception 'This company isn''t one of your firm''s accounts. Pick it from the list, or add it as a new company.';
  end if;
  if new.contact_external_id is not null
     and (tg_op = 'INSERT' or new.contact_external_id is distinct from old.contact_external_id or new.account_external_id is distinct from old.account_external_id)
     and not exists (select 1 from public.crm_contacts c where c.external_id = new.contact_external_id and c.parent_account_external_id = new.account_external_id) then
    raise exception 'This contact doesn''t belong to the selected company. Pick a contact from that company''s list, or add them as a new contact.';
  end if;
  return new;
end;
$function$;
revoke all on function public.check_activity_links() from public, anon, authenticated;

create trigger activity_entries_link_check
  before insert or update of account_external_id, contact_external_id, rep_firm_id on public.activity_entries
  for each row execute function public.check_activity_links();

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
begin
  if p_full_name is null or length(trim(p_full_name)) = 0 then
    raise exception 'Contact name is required';
  end if;
  select rep_firm_id into v_rep_firm_id from public.crm_accounts where external_id = p_account_external_id;
  if not found then
    raise exception 'Invalid account';
  end if;
  -- Reps: only under their own firm's accounts. A rep not yet tied to a firm
  -- (first activity) is limited by the account search to the firm they picked.
  if public.current_role_name() is distinct from 'manager' then
    select rep_firm_id into v_my_firm from public.profiles where id = auth.uid();
    if v_my_firm is not null and v_rep_firm_id is distinct from v_my_firm then
      raise exception 'You can only add contacts to your own firm''s accounts';
    end if;
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
$function$;
