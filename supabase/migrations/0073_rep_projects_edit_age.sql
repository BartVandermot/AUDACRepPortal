-- Rep projects: edit in the app, entered date, age (2026-11-23, C. L. Pugh meeting).
-- Applied via execute_sql (no DROP: old get_rep_projects renamed).
--
-- 1. A rep can change a project's expected close date, value, stage, status
--    and note in the app (update_rep_project). The change goes to Dynamics
--    like an import does.
-- 2. A later export from their CRM must not silently undo such an edit:
--    crm_snapshot keeps the values of the last import. Per field, a project
--    edited in the app keeps its app value unless the CRM value changed since
--    the last import (then the CRM wins: it is newer).
-- 3. entered_date: the date the project was created in the rep's CRM
--    (optional import column), for "this project is 8 months old".

alter table public.rep_projects
  add column if not exists entered_date date,
  add column if not exists crm_snapshot jsonb,
  add column if not exists edited_at timestamptz,
  add column if not exists edited_by uuid;

-- Existing rows: the current values are what the last import brought.
update public.rep_projects
   set crm_snapshot = jsonb_build_object('value_usd', value_usd, 'expected_close_date', expected_close_date,
                                         'stage', stage, 'status', status, 'notes', notes)
 where crm_snapshot is null;

-- Parse with the optional entered_date column.
create or replace function public.rep_projects_parse2(p_rows jsonb)
returns table(rep_crm_id text, project_name text, location text, dealer_name text, stage text, status text,
              value_usd numeric, expected_close_date date, sales_person text, products text, notes text, entered_date date)
language sql immutable set search_path to 'public' as $function$
  select distinct on (trim(r->>'rep_crm_id'))
         trim(r->>'rep_crm_id'),
         left(trim(r->>'project_name'), 300),
         nullif(left(trim(r->>'location'), 200), ''),
         nullif(left(trim(r->>'dealer_name'), 200), ''),
         nullif(left(trim(r->>'stage'), 100), ''),
         case when r->>'status' in ('Open', 'Won', 'Lost') then r->>'status' else 'Open' end,
         case when (r->>'value_usd') ~ '^-?[0-9]+(\.[0-9]+)?$' then (r->>'value_usd')::numeric end,
         case when (r->>'expected_close_date') ~ '^\d{4}-\d{2}-\d{2}$' then (r->>'expected_close_date')::date end,
         nullif(left(trim(r->>'sales_person'), 120), ''),
         nullif(left(trim(r->>'products'), 2000), ''),
         nullif(left(trim(r->>'notes'), 2000), ''),
         case when (r->>'entered_date') ~ '^\d{4}-\d{2}-\d{2}$' then (r->>'entered_date')::date end
    from jsonb_array_elements(p_rows) r
   where nullif(trim(r->>'rep_crm_id'), '') is not null and nullif(trim(r->>'project_name'), '') is not null;
$function$;

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
    'registered', (select count(*) from public.rep_projects p where p.rep_firm_id = p_firm_id and p.in_last_import and p.matched_crm_id is not null),
    'total', (select count(*) from public.rep_projects p where p.rep_firm_id = p_firm_id and p.in_last_import));
end;
$function$;

-- A rep changes a project in the app; it goes to Dynamics like an import.
create or replace function public.update_rep_project(p_project_id uuid, p_status text, p_close date, p_value numeric, p_stage text, p_note text)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare v_firm uuid;
begin
  select rp.rep_firm_id into v_firm from public.rep_projects rp where rp.id = p_project_id;
  if v_firm is null then raise exception 'Project not found'; end if;
  if not public.can_import_projects_for_firm(v_firm) then raise exception 'Not allowed for this firm'; end if;
  if p_status not in ('Open', 'Won', 'Lost') then raise exception 'Status must be Open, Won or Lost'; end if;
  if p_value is not null and p_value < 0 then raise exception 'The value cannot be negative'; end if;
  update public.rep_projects
     set status = p_status, expected_close_date = p_close, value_usd = p_value,
         stage = nullif(left(trim(coalesce(p_stage, '')), 100), ''),
         notes = nullif(left(trim(coalesce(p_note, '')), 2000), ''),
         edited_at = now(), edited_by = auth.uid(),
         crm_push_status = 'waiting', crm_push_attempts = 0, crm_push_error = null
   where id = p_project_id;
end;
$function$;
grant execute on function public.update_rep_project(uuid, text, date, numeric, text, text) to authenticated;

-- get_rep_projects with entered_date, first_imported_at, edited_at (new return type:
-- the old one was renamed to get_rep_projects_superseded_0073).
alter function public.get_rep_projects(uuid) rename to get_rep_projects_superseded_0073;
create function public.get_rep_projects(p_firm_id uuid default null)
returns table(id uuid, rep_firm_id uuid, rep_crm_id text, project_name text, location text, dealer_name text, stage text,
              status text, value_usd numeric, expected_close_date date, sales_person text, products text, notes text,
              in_last_import boolean, last_imported_at timestamptz, registered boolean, crm_id text, crm_project_name text,
              crm_stage text, crm_dealer_value_usd numeric, crm_push_status text, crm_push_error text, dynamics_id text,
              dynamics_closed_at timestamptz, entered_date date, first_imported_at timestamptz, edited_at timestamptz)
language sql stable security definer set search_path to 'public' as $function$
  select r.id, r.rep_firm_id, r.rep_crm_id, r.project_name, r.location, r.dealer_name, r.stage, r.status,
         r.value_usd, r.expected_close_date, r.sales_person, r.products, r.notes, r.in_last_import,
         r.last_imported_at, (p.crm_id is not null and p.opportunity_type = 'Registered Project'), p.crm_id, p.project_name, p.stage, p.dealer_value_usd,
         r.crm_push_status, r.crm_push_error, r.dynamics_id, r.dynamics_closed_at,
         r.entered_date, r.first_imported_at, r.edited_at
    from public.rep_projects r
    left join public.pipeline_entries p on p.crm_id = r.matched_crm_id
   where case when public.current_role_name() in ('manager', 'executive')
              then (p_firm_id is null or r.rep_firm_id = p_firm_id)
              else r.rep_firm_id = public.my_rep_firm_id() end
   order by r.in_last_import desc, (r.status = 'Open') desc, r.expected_close_date nulls last, r.project_name;
$function$;
grant execute on function public.get_rep_projects(uuid) to authenticated;
