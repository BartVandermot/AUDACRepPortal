-- A rep is auto-linked to their CRM contact by email only when the profile is
-- created or changes firm (auto_link_rep_crm_contact). A contact that appears
-- in Dynamics LATER (e.g. created for an existing login like
-- sales@salesforcerep.com) was never picked up. After every successful full
-- sync, unlinked reps now get linked to the active contact under their firm's
-- CRM account with the same email.

create or replace function public.link_reps_after_sync()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update public.profiles p
     set crm_contact_external_id = m.external_id
    from (
      select distinct on (p2.id) p2.id as profile_id, c.external_id
        from public.profiles p2
        join public.rep_firms f on f.id = p2.rep_firm_id
        join public.crm_contacts c on c.parent_account_external_id = f.crm_account_external_id
       where p2.role = 'rep'
         and p2.crm_contact_external_id is null
         and p2.email is not null
         and c.is_active
         and c.email_key = lower(trim(p2.email))
       order by p2.id, c.updated_at desc nulls last
    ) m
   where p.id = m.profile_id;
  return new;
end;
$function$;

revoke all on function public.link_reps_after_sync() from public, anon, authenticated;

create trigger sync_runs_link_reps
  after update of status on public.sync_runs
  for each row
  when (new.status = 'ok' and old.status is distinct from 'ok')
  execute function public.link_reps_after_sync();
