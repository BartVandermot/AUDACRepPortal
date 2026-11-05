-- Quick log (branch quick-log, not live yet): a rep's typed or dictated note
-- is turned into activity form fields by Claude in the quick-log edge
-- function. Additive only -- nothing live reads or writes these yet.
--   * quick_log_runs: every run (original note, result, model, tokens, time).
--     Written by the edge function with the service role; readable by managers
--     (quality checks, model comparison, cost). Also the per-rep daily limit.
--   * activity_entries.quick_log_run_id: which run an activity came from, so
--     the original note stays next to what the rep finally saved.

create table if not exists public.quick_log_runs (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid references auth.users(id),
  rep_firm_id uuid references public.rep_firms(id),
  model text,
  effort text,
  note text,
  result jsonb,
  activities integer,
  input_tokens integer,
  output_tokens integer,
  cache_read_tokens integer,
  duration_ms integer,
  ok boolean not null default false,
  error text
);
alter table public.quick_log_runs enable row level security;
create policy quick_log_runs_manager_read on public.quick_log_runs
  for select using (public.current_role_name() = 'manager');
grant select on public.quick_log_runs to authenticated;
create index if not exists quick_log_runs_user_idx on public.quick_log_runs(user_id, created_at desc);

alter table public.activity_entries add column if not exists quick_log_run_id uuid references public.quick_log_runs(id);
