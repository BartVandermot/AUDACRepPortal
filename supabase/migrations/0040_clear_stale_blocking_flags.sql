-- "Blocking pipeline sync" was only ever cleared when a later deal for that
-- contact resolved. A contact who no longer appears on ANY deal (e.g. replaced
-- as Contact in Dynamics after leaving the company) kept the flag forever.
-- After every successful full sync, the flag now follows the truth:
-- a contact blocks only while crm_skipped_opportunities still lists a deal for them.

create or replace function public.clear_stale_blocking_flags()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update public.crm_contacts c
     set blocks_pipeline_sync = false
   where c.blocks_pipeline_sync
     and not exists (select 1 from public.crm_skipped_opportunities s where s.contact_external_id = c.external_id);
  return new;
end;
$function$;

revoke all on function public.clear_stale_blocking_flags() from public, anon, authenticated;

create trigger sync_runs_clear_stale_blocking
  after update of status on public.sync_runs
  for each row
  when (new.status = 'ok' and old.status is distinct from 'ok')
  execute function public.clear_stale_blocking_flags();

-- One-off: apply it to the current state right away.
update public.crm_contacts c
   set blocks_pipeline_sync = false
 where c.blocks_pipeline_sync
   and not exists (select 1 from public.crm_skipped_opportunities s where s.contact_external_id = c.external_id);
