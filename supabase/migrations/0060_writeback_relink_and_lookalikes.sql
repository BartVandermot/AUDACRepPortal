-- Write-back follow-up (2026-11-07), applied via execute_sql.
--
-- 1. Re-pointing an activity to the real CRM record (merge of a portal-added
--    company/contact by a manager or by crm-writeback) changes no reported
--    content, so it is allowed in a finalized period. The first live run
--    stopped on this for ICB Audio Video (October was finalized).
-- 2. crm_push_force: Bart pressed "Create anyway" on a company the
--    write-back held as a look-alike of an existing Dynamics company.

alter table public.crm_accounts add column if not exists crm_push_force boolean not null default false;

CREATE OR REPLACE FUNCTION public.enforce_activity_entries_period_not_finalized()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_firm uuid;
  v_month text;
begin
  -- Re-pointing an entry to the real CRM record (a merge of a portal-added
  -- company/contact, by a manager or by crm-writeback) changes no reported
  -- content, so it is allowed in a finalized period too.
  if tg_op = 'UPDATE'
     and (public.current_role_name() = 'manager' or coalesce(auth.role(), '') = 'service_role')
     and (to_jsonb(new) - 'account_external_id' - 'contact_external_id' - 'updated_at')
       = (to_jsonb(old) - 'account_external_id' - 'contact_external_id' - 'updated_at') then
    return new;
  end if;

  if tg_op = 'DELETE' then
    v_firm := old.rep_firm_id;
    v_month := old.reporting_month;
  else
    v_firm := new.rep_firm_id;
    v_month := new.reporting_month;
  end if;

  if exists (
    select 1 from public.monthly_reviews
    where rep_firm_id = v_firm and reporting_month = v_month and is_finalized
  ) then
    raise exception 'This reporting period has been finalized and can no longer be changed. Ask a manager to un-finalize it first.';
  end if;

  -- An update can't be used to move an entry OUT of a finalized period either.
  if tg_op = 'UPDATE' and exists (
    select 1 from public.monthly_reviews
    where rep_firm_id = old.rep_firm_id and reporting_month = old.reporting_month and is_finalized
  ) then
    raise exception 'This reporting period has been finalized and can no longer be changed. Ask a manager to un-finalize it first.';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;
