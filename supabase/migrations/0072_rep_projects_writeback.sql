-- Rep projects to Dynamics (2026-11-19). Applied via execute_sql.
--
-- The project-writeback edge function writes every open, unregistered project
-- a rep firm imported to Dynamics as a "Regular Opportunity" with Origin
-- "AUDAC Rep App", Rep Firm and Rep CRM ID (alternate key: upsert, never a
-- duplicate). Owner: the app user. Est. Revenue stays empty (Dynamics only has
-- EUR; the rep's USD value goes in the description). A project that turns out
-- to be registered via AVL, or is won/lost in the rep's CRM, gets its
-- Rep App opportunity closed. The nightly sync ignores Rep App opportunities:
-- they are already in the portal as rep_projects.

alter table public.rep_projects
  add column if not exists crm_push_status text not null default 'waiting'
    check (crm_push_status in ('waiting', 'sent', 'failed', 'skipped')),
  add column if not exists crm_push_attempts integer not null default 0,
  add column if not exists crm_push_error text,
  add column if not exists crm_pushed_at timestamptz,
  add column if not exists dynamics_closed_at timestamptz;

create or replace function public.skip_rep_app_opportunities()
returns trigger language plpgsql set search_path to 'public'
as $$
begin
  if new.origin = 'AUDAC Rep App' then return null; end if;
  return new;
end;
$$;
create or replace trigger pipeline_entries_skip_rep_app
  before insert or update on public.pipeline_entries
  for each row execute function public.skip_rep_app_opportunities();

-- Import: a project goes (back) to "waiting" only when something in it changed.
-- (import_rep_projects re-created with the extra SET lines below; rest as 0071.)
--   crm_push_status = case when <changed> then 'waiting' else rep_projects.crm_push_status end,
--   crm_push_attempts = case when <changed> then 0 else rep_projects.crm_push_attempts end
-- Matching (auto or by hand) a project that is already in Dynamics: waiting, so
-- its Rep App opportunity gets closed.

select cron.schedule('project-writeback', '*/5 * * * *', $cron$
  select net.http_post(
    url := 'https://dhabmvpngjgrepyklius.supabase.co/functions/v1/project-writeback',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRoYWJtdnBuZ2pncmVweWtsaXVzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY2ODgxNzIsImV4cCI6MjEwMjI2NDE3Mn0.GzNEeF-gFrfl0Da3KL0XT7nbRUZX8xerNd67M2icUPc',
      'x-sync-secret', public.crm_sync_secret()),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  ) where coalesce((select value = 'true'::jsonb from public.app_flags where key = 'crm_writeback_enabled'), false)
    and exists (select 1 from public.rep_projects where crm_push_status in ('waiting', 'failed') and crm_push_attempts < 5);
$cron$);

-- get_rep_projects() also returns the Dynamics send status (old version renamed, not dropped).
alter function public.get_rep_projects(uuid) rename to get_rep_projects_superseded_0072;
revoke all on function public.get_rep_projects_superseded_0072(uuid) from public, anon, authenticated;
create function public.get_rep_projects(p_firm_id uuid default null)
returns table(id uuid, rep_firm_id uuid, rep_crm_id text, project_name text, location text, dealer_name text, stage text, status text,
              value_usd numeric, expected_close_date date, sales_person text, products text, notes text, in_last_import boolean,
              last_imported_at timestamptz, registered boolean, crm_id text, crm_project_name text, crm_stage text, crm_dealer_value_usd numeric,
              crm_push_status text, crm_push_error text, dynamics_id text, dynamics_closed_at timestamptz)
language sql stable security definer set search_path to 'public'
as $$
  select r.id, r.rep_firm_id, r.rep_crm_id, r.project_name, r.location, r.dealer_name, r.stage, r.status,
         r.value_usd, r.expected_close_date, r.sales_person, r.products, r.notes, r.in_last_import,
         r.last_imported_at, (p.crm_id is not null and p.opportunity_type = 'Registered Project'), p.crm_id, p.project_name, p.stage, p.dealer_value_usd,
         r.crm_push_status, r.crm_push_error, r.dynamics_id, r.dynamics_closed_at
    from public.rep_projects r
    left join public.pipeline_entries p on p.crm_id = r.matched_crm_id
   where case when public.current_role_name() in ('manager', 'executive')
              then (p_firm_id is null or r.rep_firm_id = p_firm_id)
              else r.rep_firm_id = public.my_rep_firm_id() end
   order by r.in_last_import desc, (r.status = 'Open') desc, r.expected_close_date nulls last, r.project_name;
$$;
revoke all on function public.get_rep_projects(uuid) from public, anon;
grant execute on function public.get_rep_projects(uuid) to authenticated;
