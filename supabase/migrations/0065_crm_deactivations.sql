-- Spam accounts and their contacts Bart picked one by one to set Inactive in
-- Dynamics (2026-11-07): 16 accounts, 20 contacts. crm-writeback
-- {"applyDeactivations": true} sets them Inactive (contacts first),
-- {"undoDeactivations": true} sets them Active again. Nothing is deleted.
-- Applied via execute_sql (rows filled there by name).

create table if not exists public.crm_deactivations (
  external_id text primary key,
  kind text not null check (kind in ('account', 'contact')),
  name text,
  parent_name text,
  reason text,
  status text not null default 'approved' check (status in ('approved', 'done', 'failed', 'undone')),
  error text,
  created_at timestamptz not null default now(),
  done_at timestamptz
);
alter table public.crm_deactivations enable row level security;
create policy crm_deactivations_manager on public.crm_deactivations for select to authenticated using (public.current_role_name() = 'manager');
revoke all on public.crm_deactivations from anon;
grant select on public.crm_deactivations to authenticated;
