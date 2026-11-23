-- Rep projects: the rep confirms a match with an AVL registration (2026-11-23).
-- Applied via execute_sql (no DROP: old get_rep_projects renamed).
--
-- Before: match_rep_projects linked a project to a registered deal on its own
-- when the names looked alike (e.g. "Willoughby Hills Community Center" to
-- "Community Center"). Bart can't judge that; the rep can.
-- Now: a look-alike is a suggestion (suggested_crm_id). The rep sees both
-- projects side by side, with why we think they're the same (name, city,
-- dealer, value), and answers "Same project" or "Different project".
--   - Same: linked (matched_crm_id, matched_by 'rep'); not sent to Dynamics
--     as a separate opportunity (the registration counts).
--   - Different: that deal is never suggested again for this project
--     (rejected_crm_ids); the project goes to Dynamics as a Regular Opportunity.
-- While a suggestion is open the project waits: project-writeback skips it.

alter table public.rep_projects
  add column if not exists suggested_crm_id text,
  add column if not exists suggested_at timestamptz,
  add column if not exists rejected_crm_ids text[] not null default '{}',
  add column if not exists match_confirmed_at timestamptz,
  add column if not exists match_confirmed_by uuid;

-- The automatic links so far become suggestions for the rep to confirm.
update public.rep_projects
   set suggested_crm_id = matched_crm_id, suggested_at = now(),
       matched_crm_id = null, matched_by = null,
       crm_push_status = 'waiting', crm_push_attempts = 0, crm_push_error = null
 where matched_by = 'auto';

-- Why we think two projects are the same: one line per signal, ok true (same),
-- false (differs) or null (can't tell).
create or replace function public.rep_project_match_signals(
  r_name text, r_location text, r_dealer text, r_value numeric,
  p_name text, p_location text, p_account text, p_value numeric)
returns jsonb language sql immutable set search_path to 'public' as $function$
  with k as (
    select public.rep_project_key(r_name) rn, public.rep_project_key(p_name) pn,
           nullif(trim(lower(split_part(coalesce(r_location, ''), ',', 1))), '') rc,
           nullif(trim(lower(split_part(coalesce(p_location, ''), ',', 1))), '') pc,
           nullif(public.rep_project_key(r_dealer), '') rd,
           case when p_account is null or p_account ilike 'dealer not specified%' then null
                else nullif(public.rep_project_key(p_account), '') end pd
  )
  select jsonb_agg(s order by o) from (
    select jsonb_build_object('ok', true, 'text',
      case when rn = pn then 'Same project name'
           when pn like '%' || rn || '%' then format('Your project name “%s” is part of the registered name “%s”', r_name, p_name)
           else format('The registered name “%s” is part of your project name “%s”', p_name, r_name) end) s, 1 o from k
    union all
    select case
      when rc is null and pc is null then jsonb_build_object('ok', null, 'text', 'Neither has a location')
      when pc is null then jsonb_build_object('ok', null, 'text', 'The registration has no location')
      when rc is null then jsonb_build_object('ok', null, 'text', format('Your project has no location; the registration is in %s', p_location))
      when rc = pc then jsonb_build_object('ok', true, 'text', format('Same city: %s', initcap(rc)))
      else jsonb_build_object('ok', false, 'text', format('Different location: %s vs %s', r_location, p_location)) end, 2 from k
    union all
    select case
      when pd is null then jsonb_build_object('ok', null, 'text', 'The registration doesn’t name a dealer')
      when rd is null then jsonb_build_object('ok', null, 'text', format('Your project has no dealer; the registration has %s', p_account))
      when rd = pd or rd like '%' || pd || '%' or pd like '%' || rd || '%' then jsonb_build_object('ok', true, 'text', format('Same dealer: %s', p_account))
      else jsonb_build_object('ok', false, 'text', format('Different dealer: %s vs %s', r_dealer, p_account)) end, 3 from k
    union all
    select case
      when r_value is null or p_value is null or r_value <= 0 or p_value <= 0 then null
      when r_value / p_value between 0.67 and 1.5 then jsonb_build_object('ok', true, 'text',
        format('Similar value: $%s vs about $%s at dealer price', to_char(r_value, 'FM999,999,990'), to_char(p_value, 'FM999,999,990')))
      else jsonb_build_object('ok', false, 'text',
        format('Different value: $%s vs about $%s at dealer price', to_char(r_value, 'FM999,999,990'), to_char(p_value, 'FM999,999,990'))) end, 4
  ) x where s is not null;
$function$;

-- Look-alikes become suggestions, never links. A deal the rep rejected for
-- this project, or that is linked or suggested elsewhere, is not suggested.
create or replace function public.match_rep_projects(p_firm_id uuid)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare n integer;
begin
  update public.rep_projects r
     set dealer_account_external_id = a.external_id
    from public.crm_accounts a
   where r.rep_firm_id = p_firm_id and r.dealer_account_external_id is null and r.dealer_name is not null
     and a.is_active and a.name_key = lower(trim(r.dealer_name));

  with c as (
    select distinct on (r.id) r.id, p.crm_id
      from public.rep_projects r
      join public.pipeline_entries p on p.rep_firm_id = r.rep_firm_id and p.crm_id is not null
     where r.rep_firm_id = p_firm_id and r.matched_crm_id is null and r.suggested_crm_id is null
       and length(public.rep_project_key(r.project_name)) >= 4
       and (public.rep_project_key(p.project_name) = public.rep_project_key(r.project_name)
            or (length(public.rep_project_key(r.project_name)) >= 8 and public.rep_project_key(p.project_name) like '%' || public.rep_project_key(r.project_name) || '%')
            or (length(public.rep_project_key(p.project_name)) >= 8 and public.rep_project_key(r.project_name) like '%' || public.rep_project_key(p.project_name) || '%'))
       and not (p.crm_id = any (r.rejected_crm_ids))
       and not exists (select 1 from public.rep_projects o where o.matched_crm_id = p.crm_id or o.suggested_crm_id = p.crm_id)
     order by r.id, (public.rep_project_key(p.project_name) = public.rep_project_key(r.project_name)) desc, p.created_date desc
  )
  update public.rep_projects r
     set suggested_crm_id = c.crm_id, suggested_at = now()
    from c where r.id = c.id;
  get diagnostics n = row_count;
  return n;
end;
$function$;

-- The rep answers a suggestion.
create or replace function public.confirm_rep_project_match(p_project_id uuid, p_same boolean)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare v_firm uuid; v_sugg text;
begin
  select rp.rep_firm_id, rp.suggested_crm_id into v_firm, v_sugg from public.rep_projects rp where rp.id = p_project_id;
  if v_firm is null then raise exception 'Project not found'; end if;
  if not public.can_import_projects_for_firm(v_firm) then raise exception 'Not allowed for this firm'; end if;
  if v_sugg is null then raise exception 'This project has no open question'; end if;
  if p_same then
    update public.rep_projects
       set matched_crm_id = v_sugg, matched_by = case when public.current_role_name() = 'manager' then 'manager' else 'rep' end,
           suggested_crm_id = null, suggested_at = null,
           match_confirmed_at = now(), match_confirmed_by = auth.uid(),
           crm_push_status = 'waiting', crm_push_attempts = 0, crm_push_error = null
     where id = p_project_id;
  else
    update public.rep_projects
       set rejected_crm_ids = array_append(rejected_crm_ids, v_sugg),
           suggested_crm_id = null, suggested_at = null,
           match_confirmed_at = now(), match_confirmed_by = auth.uid(),
           crm_push_status = 'waiting', crm_push_attempts = 0, crm_push_error = null
     where id = p_project_id;
    perform public.match_rep_projects(v_firm);
  end if;
end;
$function$;
grant execute on function public.confirm_rep_project_match(uuid, boolean) to authenticated;

-- import_rep_projects: also returns to_confirm (open suggestions).
create or replace function public.import_rep_projects(p_firm_id uuid, p_rows jsonb, p_mapping jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_in integer; v_new integer; v_upd integer; v_gone integer; v_matched integer; v_kept integer; v_now timestamptz := now();
begin
  if not public.can_import_projects_for_firm(p_firm_id) then raise exception 'Not allowed for this firm'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'No projects in the file'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'At most 2,000 projects per import'; end if;

  select count(*) into v_in from public.rep_projects_parse2(p_rows);
  if v_in = 0 then raise exception 'No row has both a project name and a CRM id'; end if;
  select count(*) into v_new from public.rep_projects_parse2(p_rows) i
   where not exists (select 1 from public.rep_projects p where p.rep_firm_id = p_firm_id and p.rep_crm_id = i.rep_crm_id);
  -- Projects edited in the app whose CRM values did not change since the last import: the app edit stays.
  select count(*) into v_kept from public.rep_projects_parse2(p_rows) x
    join public.rep_projects rp on rp.rep_firm_id = p_firm_id and rp.rep_crm_id = x.rep_crm_id
   where rp.edited_at is not null
     and (x.value_usd, x.expected_close_date, x.stage, x.status, x.notes) is not distinct from
         ((rp.crm_snapshot->>'value_usd')::numeric, (rp.crm_snapshot->>'expected_close_date')::date,
          rp.crm_snapshot->>'stage', rp.crm_snapshot->>'status', rp.crm_snapshot->>'notes')
     and (rp.value_usd, rp.expected_close_date, rp.stage, rp.status, rp.notes) is distinct from
         (x.value_usd, x.expected_close_date, x.stage, x.status, x.notes);

  insert into public.rep_projects as rp (rep_firm_id, rep_crm_id, project_name, location, dealer_name, stage, status, value_usd,
                                   expected_close_date, sales_person, products, notes, entered_date, crm_snapshot,
                                   in_last_import, first_imported_at, last_imported_at, imported_by)
  select p_firm_id, x.rep_crm_id, x.project_name, x.location, x.dealer_name, x.stage, x.status, x.value_usd,
         x.expected_close_date, x.sales_person, x.products, x.notes, x.entered_date,
         jsonb_build_object('value_usd', x.value_usd, 'expected_close_date', x.expected_close_date, 'stage', x.stage, 'status', x.status, 'notes', x.notes),
         true, v_now, v_now, auth.uid()
    from public.rep_projects_parse2(p_rows) x
  on conflict (rep_firm_id, rep_crm_id) do update set
    crm_push_status = case when (excluded.project_name, excluded.location, excluded.dealer_name, excluded.sales_person, excluded.products, excluded.entered_date)
                                  is distinct from (rp.project_name, rp.location, rp.dealer_name, rp.sales_person, rp.products, rp.entered_date)
                             or (excluded.value_usd, excluded.expected_close_date, excluded.stage, excluded.status, excluded.notes) is distinct from
                                ((rp.crm_snapshot->>'value_usd')::numeric, (rp.crm_snapshot->>'expected_close_date')::date,
                                 rp.crm_snapshot->>'stage', rp.crm_snapshot->>'status', rp.crm_snapshot->>'notes')
                           then 'waiting' else rp.crm_push_status end,
    crm_push_attempts = case when (excluded.project_name, excluded.location, excluded.dealer_name, excluded.sales_person, excluded.products, excluded.entered_date)
                                  is distinct from (rp.project_name, rp.location, rp.dealer_name, rp.sales_person, rp.products, rp.entered_date)
                             or (excluded.value_usd, excluded.expected_close_date, excluded.stage, excluded.status, excluded.notes) is distinct from
                                ((rp.crm_snapshot->>'value_usd')::numeric, (rp.crm_snapshot->>'expected_close_date')::date,
                                 rp.crm_snapshot->>'stage', rp.crm_snapshot->>'status', rp.crm_snapshot->>'notes')
                           then 0 else rp.crm_push_attempts end,
    -- Per field: an app edit stays unless the CRM value changed since the last import.
    value_usd = case when rp.edited_at is not null and excluded.value_usd is not distinct from (rp.crm_snapshot->>'value_usd')::numeric
                     then rp.value_usd else excluded.value_usd end,
    expected_close_date = case when rp.edited_at is not null and excluded.expected_close_date is not distinct from (rp.crm_snapshot->>'expected_close_date')::date
                               then rp.expected_close_date else excluded.expected_close_date end,
    stage = case when rp.edited_at is not null and excluded.stage is not distinct from rp.crm_snapshot->>'stage' then rp.stage else excluded.stage end,
    status = case when rp.edited_at is not null and excluded.status is not distinct from rp.crm_snapshot->>'status' then rp.status else excluded.status end,
    notes = case when rp.edited_at is not null and excluded.notes is not distinct from rp.crm_snapshot->>'notes' then rp.notes else excluded.notes end,
    crm_snapshot = excluded.crm_snapshot,
    project_name = excluded.project_name, location = excluded.location,
    dealer_name = excluded.dealer_name,
    dealer_account_external_id = case when excluded.dealer_name is distinct from rp.dealer_name then null else rp.dealer_account_external_id end,
    sales_person = excluded.sales_person, products = excluded.products,
    entered_date = coalesce(excluded.entered_date, rp.entered_date),
    in_last_import = true, last_imported_at = v_now, imported_by = auth.uid();
  v_upd := v_in - v_new;

  update public.rep_projects p set in_last_import = false
   where p.rep_firm_id = p_firm_id and p.in_last_import
     and not exists (select 1 from public.rep_projects_parse2(p_rows) i where i.rep_crm_id = p.rep_crm_id);
  get diagnostics v_gone = row_count;

  v_matched := public.match_rep_projects(p_firm_id);

  if p_mapping is not null and jsonb_typeof(p_mapping) = 'object' then
    insert into public.rep_project_import_mappings (rep_firm_id, mapping, updated_at, updated_by)
    values (p_firm_id, p_mapping, v_now, auth.uid())
    on conflict (rep_firm_id) do update set mapping = excluded.mapping, updated_at = v_now, updated_by = auth.uid();
  end if;

  return jsonb_build_object('new', v_new, 'updated', v_upd, 'no_longer_listed', v_gone, 'newly_linked', v_matched,
    'kept_app_edits', v_kept,
    'to_confirm', (select count(*) from public.rep_projects p where p.rep_firm_id = p_firm_id and p.in_last_import and p.suggested_crm_id is not null),
    'registered', (select count(*) from public.rep_projects p where p.rep_firm_id = p_firm_id and p.in_last_import and p.matched_crm_id is not null),
    'total', (select count(*) from public.rep_projects p where p.rep_firm_id = p_firm_id and p.in_last_import));
end;
$function$;


-- get_rep_projects with the open suggestion and why (new return type: the old
-- one was renamed to get_rep_projects_superseded_0074).
alter function public.get_rep_projects(uuid) rename to get_rep_projects_superseded_0074;
create function public.get_rep_projects(p_firm_id uuid default null)
returns table(id uuid, rep_firm_id uuid, rep_crm_id text, project_name text, location text, dealer_name text, stage text,
              status text, value_usd numeric, expected_close_date date, sales_person text, products text, notes text,
              in_last_import boolean, last_imported_at timestamptz, registered boolean, crm_id text, crm_project_name text,
              crm_stage text, crm_dealer_value_usd numeric, crm_push_status text, crm_push_error text, dynamics_id text,
              dynamics_closed_at timestamptz, entered_date date, first_imported_at timestamptz, edited_at timestamptz,
              matched_by text, suggested_crm_id text, suggested_name text, suggested_account text, suggested_location text,
              suggested_created_date date, suggested_dealer_value_usd numeric, suggested_registered boolean, match_signals jsonb)
language sql stable security definer set search_path to 'public' as $function$
  select r.id, r.rep_firm_id, r.rep_crm_id, r.project_name, r.location, r.dealer_name, r.stage, r.status,
         r.value_usd, r.expected_close_date, r.sales_person, r.products, r.notes, r.in_last_import,
         r.last_imported_at, (p.crm_id is not null and p.opportunity_type = 'Registered Project'), p.crm_id, p.project_name, p.stage, p.dealer_value_usd,
         r.crm_push_status, r.crm_push_error, r.dynamics_id, r.dynamics_closed_at,
         r.entered_date, r.first_imported_at, r.edited_at,
         r.matched_by, s.crm_id, s.project_name, s.account_name, s.location, s.created_date, s.dealer_value_usd,
         (s.opportunity_type = 'Registered Project'),
         case when s.crm_id is not null then public.rep_project_match_signals(r.project_name, r.location, r.dealer_name, r.value_usd,
                                                                               s.project_name, s.location, s.account_name, s.dealer_value_usd) end
    from public.rep_projects r
    left join public.pipeline_entries p on p.crm_id = r.matched_crm_id
    left join public.pipeline_entries s on s.crm_id = r.suggested_crm_id
   where case when public.current_role_name() in ('manager', 'executive')
              then (p_firm_id is null or r.rep_firm_id = p_firm_id)
              else r.rep_firm_id = public.my_rep_firm_id() end
   order by r.in_last_import desc, (r.status = 'Open') desc, r.expected_close_date nulls last, r.project_name;
$function$;
grant execute on function public.get_rep_projects(uuid) to authenticated;

-- The scheduler only fires when something can actually be sent (not waiting
-- on the rep's answer).
select cron.schedule('project-writeback', '*/5 * * * *', $cron$
  select net.http_post(
    url := 'https://dhabmvpngjgrepyklius.supabase.co/functions/v1/project-writeback',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRoYWJtdnBuZ2pncmVweWtsaXVzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY2ODgxNzIsImV4cCI6MjEwMjI2NDE3Mn0.GzNEeF-gFrfl0Da3KL0XT7nbRUZX8xerNd67M2icUPc',
      'x-sync-secret', public.crm_sync_secret()),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  ) where coalesce((select value = 'true'::jsonb from public.app_flags where key = 'crm_writeback_enabled'), false)
    and exists (select 1 from public.rep_projects where crm_push_status in ('waiting', 'failed') and crm_push_attempts < 5 and suggested_crm_id is null);
$cron$);
