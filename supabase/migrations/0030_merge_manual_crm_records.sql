-- Closes the loop the "Manually Added -- Needs CRM Import" KPI opened: once
-- Melissa keys a manually-added account/contact into the real Dataverse (and
-- a sync brings in the real record under its own GUID), the old manual: row
-- and the new synced row sit side by side forever with nothing to reconcile
-- them (see migration 0010's own comment -- reconciliation was deferred to
-- "future work" and never built). These two RPCs are that merge: re-point
-- everything that referenced the manual row onto the real one, then delete
-- the manual row. Restricted to managers, and to merging FROM a manual row
-- INTO a dataverse row only, so this can't be used to delete a real synced
-- record or merge two manual ones together.

create or replace function public.merge_manual_crm_account(p_manual_external_id text, p_target_external_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manual_source text;
  v_target_source text;
begin
  if public.current_role_name() <> 'manager' then
    raise exception 'Manager role required';
  end if;

  select source into v_manual_source from public.crm_accounts where external_id = p_manual_external_id;
  select source into v_target_source from public.crm_accounts where external_id = p_target_external_id;
  if v_manual_source is distinct from 'manual' then
    raise exception 'Source account is not a manually-added account';
  end if;
  if v_target_source is distinct from 'dataverse' then
    raise exception 'Target account is not a CRM-synced account';
  end if;

  update public.activity_entries set account_external_id = p_target_external_id where account_external_id = p_manual_external_id;
  update public.crm_contacts set parent_account_external_id = p_target_external_id where parent_account_external_id = p_manual_external_id;
  delete from public.crm_accounts where external_id = p_manual_external_id;
end;
$$;

revoke all on function public.merge_manual_crm_account(text, text) from public;
grant execute on function public.merge_manual_crm_account(text, text) to authenticated;

create or replace function public.merge_manual_crm_contact(p_manual_external_id text, p_target_external_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manual_source text;
  v_target_source text;
begin
  if public.current_role_name() <> 'manager' then
    raise exception 'Manager role required';
  end if;

  select source into v_manual_source from public.crm_contacts where external_id = p_manual_external_id;
  select source into v_target_source from public.crm_contacts where external_id = p_target_external_id;
  if v_manual_source is distinct from 'manual' then
    raise exception 'Source contact is not a manually-added contact';
  end if;
  if v_target_source is distinct from 'dataverse' then
    raise exception 'Target contact is not a CRM-synced contact';
  end if;

  update public.activity_entries set contact_external_id = p_target_external_id where contact_external_id = p_manual_external_id;
  update public.profiles set crm_contact_external_id = p_target_external_id where crm_contact_external_id = p_manual_external_id;
  delete from public.crm_contacts where external_id = p_manual_external_id;
end;
$$;

revoke all on function public.merge_manual_crm_contact(text, text) from public;
grant execute on function public.merge_manual_crm_contact(text, text) to authenticated;
