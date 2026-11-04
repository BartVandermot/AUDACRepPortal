-- Anonymous activity submission is retired: every activity must belong to a
-- signed-in rep (attribution, "My Submissions", Sales Person columns all
-- depend on created_by). Uses ALTER POLICY rather than drop/create.

alter policy activity_entries_insert_public on public.activity_entries
  to authenticated
  with check (created_by = (select auth.uid()));
alter policy activity_entries_insert_public on public.activity_entries
  rename to activity_entries_insert_own;

alter policy activity_attachments_insert_public on public.activity_attachments
  to authenticated
  with check (uploaded_by = (select auth.uid()));
alter policy activity_attachments_insert_public on public.activity_attachments
  rename to activity_attachments_insert_own;

alter policy activity_attachments_storage_insert on storage.objects
  to authenticated
  with check (bucket_id = 'activity-attachments');

-- RPCs that only existed for the anonymous form (or never should have been
-- public): signed-in only. get_rag_scorecard in particular exposed every
-- firm's activity/pipeline/sell-out figures to anyone with the public key.
revoke execute on function public.check_duplicate_activity(uuid, text, date, text) from public, anon;
revoke execute on function public.search_crm_accounts(text, uuid, integer) from public, anon;
revoke execute on function public.search_crm_contacts(text, uuid) from public, anon;
revoke execute on function public.create_manual_crm_account(text, text, text, text, text, uuid) from public, anon;
revoke execute on function public.create_manual_crm_contact(text, text, text, text) from public, anon;
revoke execute on function public.merge_manual_crm_account(text, text) from public, anon;
revoke execute on function public.merge_manual_crm_contact(text, text) from public, anon;
revoke execute on function public.get_rag_scorecard(text) from public, anon;
grant execute on function public.check_duplicate_activity(uuid, text, date, text) to authenticated;
grant execute on function public.search_crm_accounts(text, uuid, integer) to authenticated;
grant execute on function public.search_crm_contacts(text, uuid) to authenticated;
grant execute on function public.create_manual_crm_account(text, text, text, text, text, uuid) to authenticated;
grant execute on function public.create_manual_crm_contact(text, text, text, text) to authenticated;
grant execute on function public.merge_manual_crm_account(text, text) to authenticated;
grant execute on function public.merge_manual_crm_contact(text, text) to authenticated;
grant execute on function public.get_rag_scorecard(text) to authenticated;

-- Pre-fills the form's Contact Type from what the AUDAC CRM already knows
-- about the picked account (business_type / relationship_type). NULL when
-- the CRM doesn't say -- the rep then picks it as before.
create or replace function public.suggest_contact_type(p_account_external_id text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case
    when a.business_type ilike 'end user%' or a.relationship_type = 'End User' then 'End User'
    when a.business_type in ('Study/Consultancy Office', 'Architect / Interior Designer')
      or a.relationship_type = 'Influencer' then 'Consultant'
    when a.business_type in ('A/V Integrator', 'Rental company', 'Distributor', 'Pro Audio Shop',
                             'Electrical Installer', 'IT Company', 'Home Automation Installer', 'Wholesaler')
      or a.relationship_type = 'Reseller' then 'Dealer'
  end
  from public.crm_accounts a
  where a.external_id = p_account_external_id;
$function$;
revoke execute on function public.suggest_contact_type(text) from public, anon;
grant execute on function public.suggest_contact_type(text) to authenticated;
