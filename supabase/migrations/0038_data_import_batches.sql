-- Import history + undo for the manager's file imports in Data Admin
-- (Education, Pipeline CSV, Sell-out) -- the same safety net rep activity
-- imports already have (activity_import_batches, 0032). Before this, a wrong
-- file could only be cleaned up row by row.

create table if not exists public.data_import_batches (
  id uuid primary key default gen_random_uuid(),
  source text not null check (source in ('education', 'pipeline', 'sellout')),
  file_name text,
  reporting_month text,
  row_count integer not null default 0,
  imported_by uuid not null default auth.uid() references auth.users(id),
  imported_by_email text,
  created_at timestamptz not null default now(),
  undone_at timestamptz,
  undone_by uuid references auth.users(id)
);
alter table public.data_import_batches enable row level security;

drop policy if exists data_import_batches_select on public.data_import_batches;
create policy data_import_batches_select on public.data_import_batches
  for select using (public.current_role_name() = any (array['manager', 'executive']));

drop policy if exists data_import_batches_insert on public.data_import_batches;
create policy data_import_batches_insert on public.data_import_batches
  for insert with check (public.current_role_name() = 'manager' and imported_by = (select auth.uid()) and undone_at is null);

-- Only the row count is updated after the insert; undo goes through the RPC.
drop policy if exists data_import_batches_update on public.data_import_batches;
create policy data_import_batches_update on public.data_import_batches
  for update using (public.current_role_name() = 'manager' and undone_at is null)
  with check (public.current_role_name() = 'manager');

-- A failed insert removes its own empty batch again.
drop policy if exists data_import_batches_delete on public.data_import_batches;
create policy data_import_batches_delete on public.data_import_batches
  for delete using (public.current_role_name() = 'manager' and undone_at is null);

grant select, insert, update, delete on public.data_import_batches to authenticated;

alter table public.education_records add column if not exists import_batch_id uuid references public.data_import_batches(id) on delete set null;
alter table public.pipeline_entries  add column if not exists import_batch_id uuid references public.data_import_batches(id) on delete set null;
alter table public.sellout_records   add column if not exists import_batch_id uuid references public.data_import_batches(id) on delete set null;
create index if not exists education_records_import_batch_idx on public.education_records(import_batch_id) where import_batch_id is not null;
create index if not exists pipeline_entries_import_batch_idx  on public.pipeline_entries(import_batch_id)  where import_batch_id is not null;
create index if not exists sellout_records_import_batch_idx   on public.sellout_records(import_batch_id)   where import_batch_id is not null;

-- Undo removes exactly the rows that import added. Details it backfilled onto
-- already-existing rows stay (they were missing, not wrong).
create or replace function public.undo_data_import(p_batch_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_batch public.data_import_batches;
  v_deleted integer;
begin
  if public.current_role_name() is distinct from 'manager' then
    raise exception 'Only a manager can undo an import';
  end if;
  select * into v_batch from public.data_import_batches where id = p_batch_id for update;
  if v_batch.id is null then
    raise exception 'Import not found';
  end if;
  if v_batch.undone_at is not null then
    raise exception 'This import was already undone';
  end if;
  if v_batch.source = 'education' then
    delete from public.education_records where import_batch_id = p_batch_id;
  elsif v_batch.source = 'pipeline' then
    delete from public.pipeline_entries where import_batch_id = p_batch_id;
  else
    delete from public.sellout_records where import_batch_id = p_batch_id;
  end if;
  get diagnostics v_deleted = row_count;
  update public.data_import_batches set undone_at = now(), undone_by = auth.uid() where id = p_batch_id;
  return v_deleted;
end;
$function$;

revoke all on function public.undo_data_import(uuid) from public, anon;
grant execute on function public.undo_data_import(uuid) to authenticated;
