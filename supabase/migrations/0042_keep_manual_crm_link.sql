-- The auto-link trigger (0028) recomputed crm_contact_external_id from the
-- rep's email on EVERY update that touched rep_firm_id -- even re-saving the
-- same firm -- which wiped a link a manager had just set by hand on the Reps
-- page (seen 2026-11-04: Salesforce FL login linked, then lost).
-- Now: nothing happens unless the firm really changes, and a link that already
-- points at a contact of the (new) firm is kept; only otherwise does it fall
-- back to matching by email.

create or replace function public.auto_link_rep_crm_contact()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_crm_account_external_id text;
begin
  if tg_op = 'UPDATE' and new.rep_firm_id is not distinct from old.rep_firm_id then
    return new;
  end if;

  if new.rep_firm_id is null or new.email is null then
    new.crm_contact_external_id := null;
    return new;
  end if;

  select crm_account_external_id into v_crm_account_external_id
    from public.rep_firms where id = new.rep_firm_id;

  if v_crm_account_external_id is null then
    new.crm_contact_external_id := null;
    return new;
  end if;

  if new.crm_contact_external_id is not null and exists (
    select 1 from public.crm_contacts
     where external_id = new.crm_contact_external_id
       and parent_account_external_id = v_crm_account_external_id
  ) then
    return new;
  end if;

  select external_id into new.crm_contact_external_id
    from public.crm_contacts
    where parent_account_external_id = v_crm_account_external_id
      and email_key = lower(trim(new.email))
    limit 1;

  return new;
end;
$function$;
