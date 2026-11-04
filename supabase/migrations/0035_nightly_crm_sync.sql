-- Nightly CRM sync (Dataverse -> crm_accounts / crm_contacts / pipeline_entries)
-- plus a log of every full run.
--
-- The dataverse-sync edge function runs a full sync as a chain of one-page
-- steps (see its header). pg_cron starts that chain every night; the "Sync
-- now" buttons start the same chain on demand. Every run is recorded in
-- sync_runs so the dashboard can show the real last-sync time and result.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- 1. Run log
create table if not exists public.sync_runs (
  id uuid primary key default gen_random_uuid(),
  trigger text not null check (trigger in ('scheduled', 'manual')),
  started_by uuid references auth.users(id),
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running', 'ok', 'error')),
  phase text,
  pages integer not null default 0,
  summary jsonb not null default '{}'::jsonb,
  error text
);
create index if not exists sync_runs_started_at_idx on public.sync_runs (started_at desc);
alter table public.sync_runs enable row level security;
create policy sync_runs_select_staff on public.sync_runs
  for select using (public.current_role_name() = any (array['manager', 'executive']));
grant select on public.sync_runs to authenticated;
-- Writes happen only from the edge function (service role).

-- 2. Shared secret between pg_cron and the edge function's chained steps.
-- Generated here, stored only in Vault; never in code or function env.
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'crm_sync_cron_secret',
                           'Shared secret: pg_cron / chained steps -> dataverse-sync edge function')
where not exists (select 1 from vault.secrets where name = 'crm_sync_cron_secret');

create or replace function public.crm_sync_secret()
returns text
language sql
stable
security definer
set search_path to ''
as $function$
  select decrypted_secret from vault.decrypted_secrets where name = 'crm_sync_cron_secret';
$function$;
revoke execute on function public.crm_sync_secret() from public, anon, authenticated;
grant execute on function public.crm_sync_secret() to service_role;

-- 3. Every night at 03:00 UTC (evening in the US, before the European workday).
select cron.schedule(
  'crm-nightly-sync',
  '0 3 * * *',
  $job$
    select net.http_post(
      url := 'https://dhabmvpngjgrepyklius.supabase.co/functions/v1/dataverse-sync',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-secret', public.crm_sync_secret()),
      body := '{"chain": true}'::jsonb,
      timeout_milliseconds := 15000
    );
  $job$
);
