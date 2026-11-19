-- Projects from the rep firms' own CRMs (2026-11-19).
--
-- A rep firm uploads an export of its AUDAC projects (QuickRep, Salesforce,
-- Excel...). Each upload updates the same rows by the firm's own CRM id, so a
-- monthly re-import never duplicates. A project that is also in Dynamics (a
-- registration via AVL) is linked to that deal (matched_crm_id) and shows as
-- "Registered"; the others show "Not registered" with the AVL registration link.
-- Registration itself only ever happens on AVL's website.
--
-- Dynamics side (created 2026-11-19 in solution CustomizationsbyPVS): Origin
-- option "AUDAC Rep App" (921970002), pvs_repfirmid (Lookup -> Account),
-- pvs_repcrmid (text) and alternate key pvs_RepFirmRepCrmIdKey. dynamics_id /
-- written_to_dynamics_at are for the write-back of these projects, which waits
-- for Create/Write privileges on Opportunity in the "Rep Portal Sync" role.

create table if not exists public.rep_projects (
  id uuid primary key default gen_random_uuid(),
  rep_firm_id uuid not null references public.rep_firms(id),
  rep_crm_id text not null,
  project_name text not null,
  location text,
  dealer_name text,
  dealer_account_external_id text,
  stage text,
  status text not null default 'Open' check (status in ('Open', 'Won', 'Lost')),
  value_usd numeric,
  expected_close_date date,
  sales_person text,
  products text,
  notes text,
  matched_crm_id text,
  matched_by text check (matched_by in ('auto', 'rep', 'manager')),
  in_last_import boolean not null default true,
  first_imported_at timestamptz not null default now(),
  last_imported_at timestamptz not null default now(),
  imported_by uuid,
  dynamics_id text,
  written_to_dynamics_at timestamptz,
  unique (rep_firm_id, rep_crm_id)
);
create index if not exists rep_projects_firm_idx on public.rep_projects(rep_firm_id);
alter table public.rep_projects enable row level security;
create policy rep_projects_read on public.rep_projects for select to authenticated
  using (rep_firm_id = public.my_rep_firm_id() or public.current_role_name() in ('manager', 'executive'));

create table if not exists public.rep_project_import_mappings (
  rep_firm_id uuid primary key references public.rep_firms(id),
  mapping jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.rep_project_import_mappings enable row level security;
create policy rep_project_import_mappings_read on public.rep_project_import_mappings for select to authenticated
  using (rep_firm_id = public.my_rep_firm_id() or public.current_role_name() = 'manager');

create or replace function public.rep_project_key(p text)
returns text language sql immutable set search_path to 'public'
as $$ select trim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', ' ', 'g')); $$;

-- Who may import for a firm: its own reps, or a manager.
create or replace function public.can_import_projects_for_firm(p_firm_id uuid)
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select public.current_role_name() = 'manager'
      or (public.current_role_name() = 'rep' and public.my_rep_firm_id() = p_firm_id);
$$;
revoke all on function public.can_import_projects_for_firm(uuid) from public, anon;
grant execute on function public.can_import_projects_for_firm(uuid) to authenticated;

create or replace function public.get_project_import_context(p_firm_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not public.can_import_projects_for_firm(p_firm_id) then raise exception 'Not allowed for this firm'; end if;
  return jsonb_build_object(
    'mapping', (select m.mapping from public.rep_project_import_mappings m where m.rep_firm_id = p_firm_id),
    'existing', (select count(*) from public.rep_projects r where r.rep_firm_id = p_firm_id and r.in_last_import),
    'last_import', (select max(r.last_imported_at) from public.rep_projects r where r.rep_firm_id = p_firm_id));
end;
$$;
revoke all on function public.get_project_import_context(uuid) from public, anon;
grant execute on function public.get_project_import_context(uuid) to authenticated;

-- Link unlinked projects of a firm to its Dynamics deals with the same name
-- (or one name containing the other, 8+ characters), and dealers to accounts.
create or replace function public.match_rep_projects(p_firm_id uuid)
returns integer language plpgsql security definer set search_path to 'public'
as $$
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
     where r.rep_firm_id = p_firm_id and r.matched_crm_id is null
       and length(public.rep_project_key(r.project_name)) >= 4
       and (public.rep_project_key(p.project_name) = public.rep_project_key(r.project_name)
            or (length(public.rep_project_key(r.project_name)) >= 8 and public.rep_project_key(p.project_name) like '%' || public.rep_project_key(r.project_name) || '%')
            or (length(public.rep_project_key(p.project_name)) >= 8 and public.rep_project_key(r.project_name) like '%' || public.rep_project_key(p.project_name) || '%'))
       and not exists (select 1 from public.rep_projects o where o.matched_crm_id = p.crm_id)
     order by r.id, (public.rep_project_key(p.project_name) = public.rep_project_key(r.project_name)) desc, p.created_date desc
  )
  update public.rep_projects r set matched_crm_id = c.crm_id, matched_by = 'auto'
    from c where r.id = c.id;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.match_rep_projects(uuid) from public, anon, authenticated;

-- p_rows: [{rep_crm_id, project_name, location, dealer_name, stage, status,
--           value_usd, expected_close_date, sales_person, products, notes}]
create or replace function public.rep_projects_parse(p_rows jsonb)
returns table(rep_crm_id text, project_name text, location text, dealer_name text, stage text, status text,
              value_usd numeric, expected_close_date date, sales_person text, products text, notes text)
language sql immutable set search_path to 'public'
as $$
  select distinct on (trim(r->>'rep_crm_id'))
         trim(r->>'rep_crm_id') as rep_crm_id,
         left(trim(r->>'project_name'), 300) as project_name,
         nullif(left(trim(r->>'location'), 200), '') as location,
         nullif(left(trim(r->>'dealer_name'), 200), '') as dealer_name,
         nullif(left(trim(r->>'stage'), 100), '') as stage,
         case when r->>'status' in ('Open', 'Won', 'Lost') then r->>'status' else 'Open' end as status,
         case when (r->>'value_usd') ~ '^-?[0-9]+(\.[0-9]+)?$' then (r->>'value_usd')::numeric end as value_usd,
         case when (r->>'expected_close_date') ~ '^\d{4}-\d{2}-\d{2}$' then (r->>'expected_close_date')::date end as expected_close_date,
         nullif(left(trim(r->>'sales_person'), 120), '') as sales_person,
         nullif(left(trim(r->>'products'), 2000), '') as products,
         nullif(left(trim(r->>'notes'), 2000), '') as notes
    from jsonb_array_elements(p_rows) r
   where nullif(trim(r->>'rep_crm_id'), '') is not null and nullif(trim(r->>'project_name'), '') is not null;
$$;
revoke all on function public.rep_projects_parse(jsonb) from public, anon;

create or replace function public.import_rep_projects(p_firm_id uuid, p_rows jsonb, p_mapping jsonb)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  v_in integer; v_new integer; v_upd integer; v_gone integer; v_matched integer; v_now timestamptz := now();
begin
  if not public.can_import_projects_for_firm(p_firm_id) then raise exception 'Not allowed for this firm'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'No projects in the file'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'At most 2,000 projects per import'; end if;

  select count(*) into v_in from public.rep_projects_parse(p_rows);
  if v_in = 0 then raise exception 'No row has both a project name and a CRM id'; end if;
  select count(*) into v_new from public.rep_projects_parse(p_rows) i
   where not exists (select 1 from public.rep_projects p where p.rep_firm_id = p_firm_id and p.rep_crm_id = i.rep_crm_id);

  insert into public.rep_projects (rep_firm_id, rep_crm_id, project_name, location, dealer_name, stage, status, value_usd,
                                   expected_close_date, sales_person, products, notes, in_last_import, first_imported_at, last_imported_at, imported_by)
  select p_firm_id, x.rep_crm_id, x.project_name, x.location, x.dealer_name, x.stage, x.status, x.value_usd,
         x.expected_close_date, x.sales_person, x.products, x.notes, true, v_now, v_now, auth.uid()
    from public.rep_projects_parse(p_rows) x
  on conflict (rep_firm_id, rep_crm_id) do update set
    project_name = excluded.project_name, location = excluded.location,
    dealer_name = excluded.dealer_name,
    dealer_account_external_id = case when excluded.dealer_name is distinct from public.rep_projects.dealer_name then null else public.rep_projects.dealer_account_external_id end,
    stage = excluded.stage, status = excluded.status, value_usd = excluded.value_usd,
    expected_close_date = excluded.expected_close_date, sales_person = excluded.sales_person,
    products = excluded.products, notes = excluded.notes,
    in_last_import = true, last_imported_at = v_now, imported_by = auth.uid();
  v_upd := v_in - v_new;

  -- Not in this export any more: kept, only marked as no longer listed.
  update public.rep_projects p set in_last_import = false
   where p.rep_firm_id = p_firm_id and p.in_last_import
     and not exists (select 1 from public.rep_projects_parse(p_rows) i where i.rep_crm_id = p.rep_crm_id);
  get diagnostics v_gone = row_count;

  v_matched := public.match_rep_projects(p_firm_id);

  if p_mapping is not null and jsonb_typeof(p_mapping) = 'object' then
    insert into public.rep_project_import_mappings (rep_firm_id, mapping, updated_at, updated_by)
    values (p_firm_id, p_mapping, v_now, auth.uid())
    on conflict (rep_firm_id) do update set mapping = excluded.mapping, updated_at = v_now, updated_by = auth.uid();
  end if;

  return jsonb_build_object('new', v_new, 'updated', v_upd, 'no_longer_listed', v_gone, 'newly_linked', v_matched,
    'registered', (select count(*) from public.rep_projects p where p.rep_firm_id = p_firm_id and p.in_last_import and p.matched_crm_id is not null),
    'total', (select count(*) from public.rep_projects p where p.rep_firm_id = p_firm_id and p.in_last_import));
end;
$$;
revoke all on function public.import_rep_projects(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.import_rep_projects(uuid, jsonb, jsonb) to authenticated;

-- Projects of a firm with their Dynamics registration (if linked).
-- p_firm_id null = the caller's own firm (reps); managers/executives may pass any firm or null for all.
create or replace function public.get_rep_projects(p_firm_id uuid default null)
returns table(id uuid, rep_firm_id uuid, rep_crm_id text, project_name text, location text, dealer_name text, stage text, status text,
              value_usd numeric, expected_close_date date, sales_person text, products text, notes text, in_last_import boolean,
              last_imported_at timestamptz, registered boolean, crm_id text, crm_project_name text, crm_stage text, crm_dealer_value_usd numeric)
language sql stable security definer set search_path to 'public'
as $$
  select r.id, r.rep_firm_id, r.rep_crm_id, r.project_name, r.location, r.dealer_name, r.stage, r.status,
         r.value_usd, r.expected_close_date, r.sales_person, r.products, r.notes, r.in_last_import,
         r.last_imported_at, (p.crm_id is not null and p.opportunity_type = 'Registered Project'), p.crm_id, p.project_name, p.stage, p.dealer_value_usd
    from public.rep_projects r
    left join public.pipeline_entries p on p.crm_id = r.matched_crm_id
   where case when public.current_role_name() in ('manager', 'executive')
              then (p_firm_id is null or r.rep_firm_id = p_firm_id)
              else r.rep_firm_id = public.my_rep_firm_id() end
   order by r.in_last_import desc, (r.status = 'Open') desc, r.expected_close_date nulls last, r.project_name;
$$;
revoke all on function public.get_rep_projects(uuid) from public, anon;
grant execute on function public.get_rep_projects(uuid) to authenticated;

-- Link or unlink a project to a Dynamics deal of the same firm by hand.
create or replace function public.link_rep_project(p_project_id uuid, p_crm_id text)
returns void language plpgsql security definer set search_path to 'public'
as $$
declare v_firm uuid;
begin
  select rp.rep_firm_id into v_firm from public.rep_projects rp where rp.id = p_project_id;
  if v_firm is null then raise exception 'Project not found'; end if;
  if not public.can_import_projects_for_firm(v_firm) then raise exception 'Not allowed for this firm'; end if;
  if p_crm_id is not null and not exists (select 1 from public.pipeline_entries pe where pe.crm_id = p_crm_id and pe.rep_firm_id = v_firm) then
    raise exception 'That deal is not one of this firm''s deals';
  end if;
  update public.rep_projects
     set matched_crm_id = p_crm_id,
         matched_by = case when p_crm_id is null then null when public.current_role_name() = 'manager' then 'manager' else 'rep' end
   where id = p_project_id;
end;
$$;
revoke all on function public.link_rep_project(uuid, text) from public, anon;
grant execute on function public.link_rep_project(uuid, text) to authenticated;
