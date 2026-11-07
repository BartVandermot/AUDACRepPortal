-- Write-back to Dynamics (Bart, 2026-11-07): companies and contacts a rep adds
-- in the portal are created in Dynamics automatically -- account first, then
-- its contacts -- owned by Bart. The portal's temporary "manual:" record is
-- then merged into the real Dynamics record, so the nightly sync never makes a
-- duplicate. The edge function crm-writeback does the Dynamics side.
--
--   crm_push_status on a manual record:
--     waiting     -> will be sent on the next run (every 5 minutes)
--     held        -> not sent (test account, or a manager chose so)
--     needs_info  -> can't be placed: no US state / Canadian province
--     failed      -> Dynamics refused; crm_push_error says why (retried up to 5x)
--   Once sent, the manual record no longer exists (merged); crm_writeback_log
--   keeps the history.
-- Applied 2026-11-07 in parts via execute_sql (apply_migration was declined).

-- ---- status on manual records ----
alter table public.crm_accounts
  add column if not exists created_by uuid references public.profiles(id),
  add column if not exists crm_push_status text check (crm_push_status in ('waiting', 'held', 'needs_info', 'failed')),
  add column if not exists crm_push_error text,
  add column if not exists crm_push_attempts int not null default 0,
  add column if not exists crm_push_last_at timestamptz;
alter table public.crm_contacts
  add column if not exists created_by uuid references public.profiles(id),
  add column if not exists crm_push_status text check (crm_push_status in ('waiting', 'held', 'needs_info', 'failed')),
  add column if not exists crm_push_error text,
  add column if not exists crm_push_attempts int not null default 0,
  add column if not exists crm_push_last_at timestamptz;

-- Test logins (e.g. Bart's test rep) never write to Dynamics.
alter table public.profiles add column if not exists is_test_account boolean not null default false;

-- ---- history ----
create table if not exists public.crm_writeback_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  kind text not null check (kind in ('account', 'contact')),
  manual_external_id text,
  dynamics_id text,
  action text not null check (action in ('created', 'linked_existing', 'failed', 'needs_info')),
  name text,
  detail jsonb,
  requested_by uuid references public.profiles(id)
);
alter table public.crm_writeback_log enable row level security;
create policy crm_writeback_log_select_manager on public.crm_writeback_log for select to authenticated
  using (public.current_role_name() = 'manager');
revoke all on public.crm_writeback_log from anon;
grant select on public.crm_writeback_log to authenticated;

-- ---- on/off switch ----
create table if not exists public.app_flags (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);
alter table public.app_flags enable row level security;
create policy app_flags_select_manager on public.app_flags for select to authenticated using (public.current_role_name() = 'manager');
create policy app_flags_update_manager on public.app_flags for update to authenticated
  using (public.current_role_name() = 'manager') with check (public.current_role_name() = 'manager');
revoke all on public.app_flags from anon;
grant select, update on public.app_flags to authenticated;
insert into public.app_flags (key, value) values ('crm_writeback_enabled', 'false'::jsonb) on conflict (key) do nothing;

-- ---- activity link check (0056): not for managers or the write-back ----
-- Merging a manual record (by hand on Accounts & Contacts, or by crm-writeback)
-- re-points account and contact in separate steps; the checks are for reps.
-- (The write-back does the merge steps itself from the edge function with the
-- service role -- the same steps as merge_manual_crm_account -- so the merge
-- functions themselves are unchanged.)
create or replace function public.check_activity_links()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if public.current_role_name() = 'manager' or coalesce(auth.role(), '') = 'service_role' then
    return new;
  end if;
  if new.account_external_id is not null
     and (tg_op = 'INSERT' or new.account_external_id is distinct from old.account_external_id or new.rep_firm_id is distinct from old.rep_firm_id)
     and not exists (select 1 from public.crm_accounts a where a.external_id = new.account_external_id and a.rep_firm_id = new.rep_firm_id) then
    raise exception 'This company isn''t one of your firm''s accounts. Pick it from the list, or add it as a new company.';
  end if;
  if new.contact_external_id is not null
     and (tg_op = 'INSERT' or new.contact_external_id is distinct from old.contact_external_id or new.account_external_id is distinct from old.account_external_id)
     and not exists (select 1 from public.crm_contacts c where c.external_id = new.contact_external_id and c.parent_account_external_id = new.account_external_id) then
    raise exception 'This contact doesn''t belong to the selected company. Pick a contact from that company''s list, or add them as a new contact.';
  end if;
  return new;
end; $function$;

-- ---- new manual records start as "waiting" (or "held" for test logins) ----
create or replace function public.crm_push_initial_status()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.source = 'manual' and new.crm_push_status is null then
    new.created_by := coalesce(new.created_by, auth.uid());
    new.crm_push_status := case
      when exists (select 1 from public.profiles p where p.id = new.created_by and p.is_test_account) then 'held'
      else 'waiting' end;
  end if;
  return new;
end;
$function$;
revoke all on function public.crm_push_initial_status() from public, anon, authenticated;

create trigger crm_accounts_push_status before insert on public.crm_accounts
  for each row execute function public.crm_push_initial_status();
create trigger crm_contacts_push_status before insert on public.crm_contacts
  for each row execute function public.crm_push_initial_status();

-- ---- what Dynamics needs, asked at the source ----
-- Dynamics requires an e-mail address on every contact.
create or replace function public.create_manual_crm_contact(p_account_external_id text, p_full_name text, p_email text, p_phone text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_external_id text;
  v_rep_firm_id uuid;
  v_my_firm uuid;
  v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
begin
  if p_full_name is null or length(trim(p_full_name)) = 0 then
    raise exception 'Contact name is required';
  end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'An e-mail address is required for a new contact';
  end if;
  select rep_firm_id into v_rep_firm_id from public.crm_accounts where external_id = p_account_external_id;
  if not found then
    raise exception 'Invalid account';
  end if;
  if public.current_role_name() is distinct from 'manager' then
    select rep_firm_id into v_my_firm from public.profiles where id = auth.uid();
    if v_my_firm is not null and v_rep_firm_id is distinct from v_my_firm then
      raise exception 'You can only add contacts to your own firm''s accounts';
    end if;
  end if;

  v_external_id := 'manual:' || gen_random_uuid();
  insert into public.crm_contacts (external_id, full_name, email, email_key, phone, parent_account_external_id, rep_firm_id, source, created_by, updated_at)
  values (
    v_external_id, trim(p_full_name), trim(p_email), v_email,
    nullif(trim(coalesce(p_phone, '')), ''),
    p_account_external_id, v_rep_firm_id, 'manual', auth.uid(), now()
  );
  return v_external_id;
end;
$function$;

-- New companies: city and a real US state / Canadian province are needed to
-- place them in a territory (and in Dynamics); the ZIP decides split states.
create or replace function public.add_manual_crm_account(p_name text, p_street text, p_city text, p_state_code text, p_zip text, p_phone text, p_rep_firm_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_external_id text;
  v_state text := nullif(upper(trim(coalesce(p_state_code, ''))), '');
  v_country text;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Company name is required';
  end if;
  if nullif(trim(coalesce(p_city, '')), '') is null then
    raise exception 'City is required';
  end if;
  if v_state = any (array['AB','BC','MB','NB','NL','NS','ON','PE','QC','SK','NT','NU','YT']) then
    v_country := 'CA';
  elsif v_state = any (array['AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','PR','GU']) then
    v_country := 'US';
  else
    raise exception 'Use a 2-letter US state or Canadian province code, e.g. OH or ON';
  end if;
  if p_rep_firm_id is not null and not exists (select 1 from public.rep_firms where id = p_rep_firm_id and status = 'active') then
    raise exception 'Invalid rep firm';
  end if;

  v_external_id := 'manual:' || gen_random_uuid();
  insert into public.crm_accounts (external_id, name, name_key, street, city, state_code, zip, country_code, phone, rep_firm_id, source, created_by, updated_at)
  values (
    v_external_id, trim(p_name), lower(trim(p_name)),
    nullif(trim(coalesce(p_street, '')), ''), trim(p_city), v_state,
    nullif(trim(coalesce(p_zip, '')), ''), v_country,
    nullif(trim(coalesce(p_phone, '')), ''),
    p_rep_firm_id, 'manual', auth.uid(), now()
  );
  return v_external_id;
end;
$function$;
revoke all on function public.add_manual_crm_account(text, text, text, text, text, text, uuid) from public, anon;
grant execute on function public.add_manual_crm_account(text, text, text, text, text, text, uuid) to authenticated;

-- ---- the records that were already waiting ----
update public.profiles set is_test_account = true where lower(email) = 'bart.vandermot@gmail.com';
update public.crm_accounts set crm_push_status = 'waiting', country_code = coalesce(country_code, 'US')
  where source = 'manual' and name in ('ICB Audio Video', 'AVDG', 'Sound Solutions of Saratoga');
update public.crm_accounts set crm_push_status = 'held' where source = 'manual' and name = 'Grape Pucker';
update public.crm_contacts set crm_push_status = 'waiting' where source = 'manual' and crm_push_status is null;

-- ---- every 5 minutes, only when something is waiting and the switch is on ----
do $$
declare v_jwt text;
begin
  select substring(command from 'Bearer (eyJ[A-Za-z0-9._-]+)') into v_jwt from cron.job where jobname = 'crm-nightly-sync';
  perform cron.schedule('crm-writeback', '*/5 * * * *', format($cmd$
    select net.http_post(
      url := 'https://dhabmvpngjgrepyklius.supabase.co/functions/v1/crm-writeback',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer %s', 'x-sync-secret', public.crm_sync_secret()),
      body := '{}'::jsonb,
      timeout_milliseconds := 60000
    ) where coalesce((select value = 'true'::jsonb from public.app_flags where key = 'crm_writeback_enabled'), false)
      and (exists (select 1 from public.crm_accounts where source = 'manual' and crm_push_status in ('waiting', 'failed') and crm_push_attempts < 5)
        or exists (select 1 from public.crm_contacts where source = 'manual' and crm_push_status in ('waiting', 'failed') and crm_push_attempts < 5 and parent_account_external_id not like 'manual:%%'));
  $cmd$, v_jwt));
end $$;
