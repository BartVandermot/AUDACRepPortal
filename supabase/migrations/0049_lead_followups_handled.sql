-- A follow-up saying "quoted" or "won" means the lead became real business:
-- the manager turns it into an opportunity in Dynamics and marks it processed,
-- like deal updates (0045).
alter table public.lead_followups add column if not exists handled_at timestamptz;
alter table public.lead_followups add column if not exists handled_by uuid references auth.users(id);
create index if not exists lead_followups_open_idx on public.lead_followups(created_at) where handled_at is null;
create policy lead_followups_handle on public.lead_followups
  for update using (public.current_role_name() = 'manager') with check (public.current_role_name() = 'manager');
grant update (handled_at, handled_by) on public.lead_followups to authenticated;
