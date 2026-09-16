-- Merging a manual account onto its real counterpart used to just re-parent
-- any manual contacts under it onto the real account -- leaving a same-named
-- duplicate person sitting next to the real contact record whenever one
-- already existed there (e.g. a rep added "Cody Spitale" by hand before the
-- real Dataverse contact of the same name was synced in). Matching by full
-- name is too weak globally (two unrelated people commonly share a name),
-- but scoped to "the two accounts we just confirmed are the same company"
-- it's a solid signal, so this reconciles contacts the same way as part of
-- the account merge: same name under the target account -> merge into it
-- (via merge_manual_crm_contact, so activity history moves too and nothing
-- is duplicated); no match -> just re-parent, same as before.
create or replace function public.merge_manual_crm_account(p_manual_external_id text, p_target_external_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manual_source text;
  v_target_source text;
  v_contact record;
  v_match_external_id text;
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

  for v_contact in
    select external_id, full_name from public.crm_contacts
    where parent_account_external_id = p_manual_external_id and source = 'manual'
  loop
    select external_id into v_match_external_id
      from public.crm_contacts
      where parent_account_external_id = p_target_external_id
        and source = 'dataverse'
        and full_name is not null and v_contact.full_name is not null
        and lower(trim(full_name)) = lower(trim(v_contact.full_name))
      limit 1;

    if v_match_external_id is not null then
      perform public.merge_manual_crm_contact(v_contact.external_id, v_match_external_id);
    else
      update public.crm_contacts set parent_account_external_id = p_target_external_id where external_id = v_contact.external_id;
    end if;
  end loop;

  delete from public.crm_accounts where external_id = p_manual_external_id;
end;
$$;
