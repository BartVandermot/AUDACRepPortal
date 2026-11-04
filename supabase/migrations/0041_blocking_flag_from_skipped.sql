-- The sync sets/clears "Blocking pipeline sync" page by page, so a later page
-- where all of a contact's deals resolved cleared the flag even though an
-- earlier page still had a skipped deal for them (seen with Jay Perry after
-- dataverse-sync v31). After every successful full sync the flag is now fully
-- re-derived: a contact blocks exactly while crm_skipped_opportunities lists a
-- deal for them. Replaces the clear-only version from 0040.

create or replace function public.clear_stale_blocking_flags()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update public.crm_contacts c
     set blocks_pipeline_sync = x.should_block
    from (
      select c2.external_id,
             exists (select 1 from public.crm_skipped_opportunities s where s.contact_external_id = c2.external_id) as should_block
        from public.crm_contacts c2
    ) x
   where x.external_id = c.external_id
     and c.blocks_pipeline_sync is distinct from x.should_block;
  return new;
end;
$function$;

-- Apply to the current state right away.
update public.crm_contacts c
   set blocks_pipeline_sync = true
 where not c.blocks_pipeline_sync
   and exists (select 1 from public.crm_skipped_opportunities s where s.contact_external_id = c.external_id);
