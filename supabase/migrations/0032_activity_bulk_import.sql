-- Bulk import of activity entries from a rep firm's own CRM export (/import).
--
-- Everything goes through security-definer RPCs rather than direct table
-- access, because an import needs things the normal insert policy can't
-- express: attributing rows to other reps of the same firm (rep admins and
-- managers only), skipping the per-firm rate limit for one vetted batch, and
-- undoing a whole batch at once.

-- 1. Batches -- one row per import, so a bad upload can be undone as a unit.
create table if not exists public.activity_import_batches (
  id uuid primary key default gen_random_uuid(),
  rep_firm_id uuid not null references public.rep_firms(id),
  imported_by uuid not null references auth.users(id),
  imported_by_email text,
  file_name text,
  row_count integer not null,
  created_at timestamptz not null default now(),
  undone_at timestamptz,
  undone_by uuid references auth.users(id)
);
alter table public.activity_import_batches enable row level security;

drop policy if exists activity_import_batches_select on public.activity_import_batches;
create policy activity_import_batches_select on public.activity_import_batches
  for select using (
    imported_by = (select auth.uid())
    or public.current_role_name() = any (array['manager', 'executive'])
    or exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.is_rep_admin and p.rep_firm_id = activity_import_batches.rep_firm_id
    )
  );

alter table public.activity_entries
  add column if not exists import_batch_id uuid references public.activity_import_batches(id) on delete set null;
create index if not exists activity_entries_import_batch_idx on public.activity_entries(import_batch_id) where import_batch_id is not null;

-- 2. Saved column/value mapping per firm, so the second upload is one click.
create table if not exists public.activity_import_mappings (
  rep_firm_id uuid primary key references public.rep_firms(id) on delete cascade,
  mapping jsonb not null,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
alter table public.activity_import_mappings enable row level security;
-- No policies: read/written only through the RPCs below.

-- 3. Rate limit: a vetted bulk import (flag set transaction-locally by
-- import_activity_entries) is exempt. A client can't set this flag itself --
-- set_config isn't exposed through PostgREST and each request is its own
-- transaction.
create or replace function public.enforce_activity_entries_rate_limit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_recent_count integer;
begin
  if current_setting('app.bulk_import', true) = 'on' then
    return new;
  end if;
  select count(*) into v_recent_count
  from public.activity_entries
  where rep_firm_id = new.rep_firm_id
    and submitted_at > now() - interval '5 minutes';
  if v_recent_count >= 100 then
    raise exception 'Too many activity submissions for this firm in a short period. Please wait a few minutes and try again.';
  end if;
  return new;
end;
$function$;

-- 4. Who may import for a firm: a signed-in member of that firm, or a manager.
create or replace function public.can_import_activities_for_firm(p_firm_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select auth.uid() is not null and exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and (p.role = 'manager' or (p.rep_firm_id = p_firm_id and p.rep_firm_id is not null))
  );
$function$;

-- Can the caller attribute imported rows to other reps of the firm?
create or replace function public.can_attribute_activities_for_firm(p_firm_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select auth.uid() is not null and exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and (p.role = 'manager' or (p.is_rep_admin and p.rep_firm_id = p_firm_id))
  );
$function$;

-- 5. Context for the import page: saved mapping + the reps rows can be
-- attributed to (just the caller unless they're a rep admin / manager).
create or replace function public.get_activity_import_context(p_firm_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_can_attr boolean;
begin
  if not public.can_import_activities_for_firm(p_firm_id) then
    raise exception 'Not allowed to import activities for this firm';
  end if;
  v_can_attr := public.can_attribute_activities_for_firm(p_firm_id);
  return jsonb_build_object(
    'mapping', (select mapping from public.activity_import_mappings where rep_firm_id = p_firm_id),
    'can_attribute', v_can_attr,
    'reps', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'email', p.email) order by coalesce(p.full_name, p.email))
      from public.profiles p
      where (v_can_attr and p.rep_firm_id = p_firm_id and p.role = 'rep') or p.id = auth.uid()
    ), '[]'::jsonb)
  );
end;
$function$;

create or replace function public.save_activity_import_mapping(p_firm_id uuid, p_mapping jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not public.can_import_activities_for_firm(p_firm_id) then
    raise exception 'Not allowed to import activities for this firm';
  end if;
  insert into public.activity_import_mappings (rep_firm_id, mapping, updated_by, updated_at)
  values (p_firm_id, p_mapping, auth.uid(), now())
  on conflict (rep_firm_id) do update
    set mapping = excluded.mapping, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
end;
$function$;

-- 6. Match account (and contact) names from the file against this firm's CRM
-- accounts -- exact, case/whitespace-insensitive. p_pairs: [{"a": account, "c": contact}]
create or replace function public.match_crm_for_import(p_firm_id uuid, p_pairs jsonb)
returns table(input_account text, input_contact text, account_external_id text, account_name text, contact_external_id text, contact_name text)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
begin
  if not public.can_import_activities_for_firm(p_firm_id) then
    raise exception 'Not allowed to import activities for this firm';
  end if;
  return query
  with pairs as (
    select distinct x->>'a' as a, x->>'c' as c
    from jsonb_array_elements(coalesce(p_pairs, '[]'::jsonb)) x
  )
  select pr.a, pr.c, acc.external_id, acc.name, con.external_id, con.full_name
  from pairs pr
  left join lateral (
    select ca.external_id, ca.name
    from public.crm_accounts ca
    where ca.rep_firm_id = p_firm_id
      and lower(trim(ca.name)) = lower(trim(pr.a))
    order by ca.is_active desc nulls last, ca.updated_at desc nulls last
    limit 1
  ) acc on true
  left join lateral (
    select cc.external_id, cc.full_name
    from public.crm_contacts cc
    where acc.external_id is not null
      and pr.c is not null and length(trim(pr.c)) > 0
      and cc.parent_account_external_id = acc.external_id
      and lower(trim(cc.full_name)) = lower(trim(pr.c))
    order by cc.is_active desc nulls last
    limit 1
  ) con on true;
end;
$function$;

-- 7. Which of the given rows already exist (same firm/account/date/type as
-- check_duplicate_activity). p_rows: [{"i": n, "account_name", "entry_date", "activity_type"}]
create or replace function public.find_duplicate_activities(p_firm_id uuid, p_rows jsonb)
returns setof integer
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
begin
  if not public.can_import_activities_for_firm(p_firm_id) then
    raise exception 'Not allowed to import activities for this firm';
  end if;
  return query
  select (x->>'i')::int
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
  where exists (
    select 1 from public.activity_entries ae
    where ae.rep_firm_id = p_firm_id
      and lower(trim(ae.account_name)) = lower(trim(x->>'account_name'))
      and ae.entry_date = (x->>'entry_date')::date
      and ae.activity_type = x->>'activity_type'
  );
end;
$function$;

-- 8. The import itself: all-or-nothing, one batch.
create or replace function public.import_activity_entries(p_firm_id uuid, p_file_name text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_can_attr boolean;
  v_count integer;
  v_batch uuid;
  v_bad_owner text;
begin
  if not public.can_import_activities_for_firm(p_firm_id) then
    raise exception 'Not allowed to import activities for this firm';
  end if;
  if not exists (select 1 from public.rep_firms where id = p_firm_id and status = 'active') then
    raise exception 'Invalid rep firm';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Rows must be an array';
  end if;
  v_count := jsonb_array_length(p_rows);
  if v_count = 0 then
    raise exception 'Nothing to import';
  end if;
  if v_count > 2000 then
    raise exception 'Too many rows in one import (max 2000) -- split the file';
  end if;

  v_can_attr := public.can_attribute_activities_for_firm(p_firm_id);

  -- Rows attributed to someone else: only rep admins/managers, and only to a rep of this firm.
  select x->>'created_by' into v_bad_owner
  from jsonb_array_elements(p_rows) x
  where nullif(x->>'created_by', '') is not null
    and (x->>'created_by')::uuid <> v_uid
    and (not v_can_attr or not exists (
      select 1 from public.profiles p where p.id = (x->>'created_by')::uuid and p.rep_firm_id = p_firm_id
    ))
  limit 1;
  if v_bad_owner is not null then
    raise exception 'Can''t attribute activities to that sales person (not a rep of this firm, or you''re not the firm''s admin)';
  end if;

  insert into public.activity_import_batches (rep_firm_id, imported_by, imported_by_email, file_name, row_count)
  values (p_firm_id, v_uid, (select email from auth.users where id = v_uid), left(p_file_name, 255), v_count)
  returning id into v_batch;

  perform set_config('app.bulk_import', 'on', true);

  insert into public.activity_entries (
    rep_firm_id, reporting_month, entry_date, account_name, account_external_id,
    contact_name, contact_external_id, contact_type, activity_type, demo_gear_used,
    topic_opportunity, solution_feedback, competitive_feedback, additional_comments,
    created_by, created_by_email, import_batch_id
  )
  select
    p_firm_id,
    to_char((x->>'entry_date')::date, 'YYYY-MM'),
    (x->>'entry_date')::date,
    left(trim(x->>'account_name'), 500),
    case when exists (select 1 from public.crm_accounts ca where ca.external_id = x->>'account_external_id' and ca.rep_firm_id = p_firm_id)
         then x->>'account_external_id' end,
    nullif(left(trim(x->>'contact_name'), 300), ''),
    case when exists (select 1 from public.crm_contacts cc where cc.external_id = x->>'contact_external_id')
         then x->>'contact_external_id' end,
    x->>'contact_type',
    x->>'activity_type',
    coalesce((x->>'demo_gear_used')::boolean, false),
    nullif(trim(x->>'topic_opportunity'), ''),
    nullif(trim(x->>'solution_feedback'), ''),
    nullif(trim(x->>'competitive_feedback'), ''),
    nullif(trim(x->>'additional_comments'), ''),
    coalesce(nullif(x->>'created_by', '')::uuid, v_uid),
    (select p.email from public.profiles p where p.id = coalesce(nullif(x->>'created_by', '')::uuid, v_uid)),
    v_batch
  from jsonb_array_elements(p_rows) x;

  perform set_config('app.bulk_import', 'off', true);

  return jsonb_build_object('batch_id', v_batch, 'inserted', v_count);
end;
$function$;

-- 9. Undo a whole import (blocked by the period-lock trigger if any of its
-- months has been finalized since).
create or replace function public.undo_activity_import(p_batch_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_batch public.activity_import_batches;
  v_deleted integer;
begin
  select * into v_batch from public.activity_import_batches where id = p_batch_id;
  if v_batch.id is null then
    raise exception 'Import not found';
  end if;
  if v_batch.undone_at is not null then
    raise exception 'This import was already undone';
  end if;
  if not (v_batch.imported_by = auth.uid() or public.current_role_name() = 'manager') then
    raise exception 'Only the person who ran this import (or a manager) can undo it';
  end if;
  delete from public.activity_entries where import_batch_id = p_batch_id;
  get diagnostics v_deleted = row_count;
  update public.activity_import_batches set undone_at = now(), undone_by = auth.uid() where id = p_batch_id;
  return v_deleted;
end;
$function$;

revoke all on function public.can_import_activities_for_firm(uuid) from public, anon;
revoke all on function public.can_attribute_activities_for_firm(uuid) from public, anon;
revoke all on function public.get_activity_import_context(uuid) from public, anon;
revoke all on function public.save_activity_import_mapping(uuid, jsonb) from public, anon;
revoke all on function public.match_crm_for_import(uuid, jsonb) from public, anon;
revoke all on function public.find_duplicate_activities(uuid, jsonb) from public, anon;
revoke all on function public.import_activity_entries(uuid, text, jsonb) from public, anon;
revoke all on function public.undo_activity_import(uuid) from public, anon;
grant execute on function public.can_import_activities_for_firm(uuid) to authenticated;
grant execute on function public.can_attribute_activities_for_firm(uuid) to authenticated;
grant execute on function public.get_activity_import_context(uuid) to authenticated;
grant execute on function public.save_activity_import_mapping(uuid, jsonb) to authenticated;
grant execute on function public.match_crm_for_import(uuid, jsonb) to authenticated;
grant execute on function public.find_duplicate_activities(uuid, jsonb) to authenticated;
grant execute on function public.import_activity_entries(uuid, text, jsonb) to authenticated;
grant execute on function public.undo_activity_import(uuid) to authenticated;
grant select on public.activity_import_batches to authenticated;
