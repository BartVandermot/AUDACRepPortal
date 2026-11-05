-- Rep round 2: give reps something back for logging.
-- 1. Review feedback: a separate "feedback for the rep" on monthly_reviews
--    (notes stay internal), visible to the firm once the review is finalized.
-- 2. Their firm's deals (synced from Dynamics) + a way to report a status
--    change; the manager processes it in Dynamics and marks it handled.
-- 3. Their key accounts (TOP AUDAC LEAD / AUDAC partner) with last contact.
-- Reps never read these tables directly: everything goes through
-- security-definer RPCs scoped to the caller's own firm.

alter table public.monthly_reviews add column if not exists rep_feedback text;

create table if not exists public.deal_status_updates (
  id uuid primary key default gen_random_uuid(),
  crm_id text not null,
  rep_firm_id uuid not null references public.rep_firms(id),
  project_name text,
  submitted_by uuid not null default auth.uid() references auth.users(id),
  submitted_by_email text,
  proposed_status text not null check (proposed_status in ('Open', 'Won', 'Lost')),
  proposed_close_date date,
  note text,
  created_at timestamptz not null default now(),
  handled_at timestamptz,
  handled_by uuid references auth.users(id)
);
alter table public.deal_status_updates enable row level security;
create index if not exists deal_status_updates_open_idx on public.deal_status_updates(crm_id) where handled_at is null;

create policy deal_status_updates_select on public.deal_status_updates
  for select using (public.current_role_name() = any (array['manager', 'executive']) or submitted_by = (select auth.uid()));
create policy deal_status_updates_handle on public.deal_status_updates
  for update using (public.current_role_name() = 'manager') with check (public.current_role_name() = 'manager');
grant select, update on public.deal_status_updates to authenticated;

-- The caller's firm, only for an active rep (null otherwise).
create or replace function public.my_rep_firm_id()
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.rep_firm_id from public.profiles p
   where p.id = auth.uid() and p.role = 'rep' and p.is_active and p.rep_firm_id is not null;
$function$;

-- Same RAG rule as get_rag_scorecard, for one firm and month.
create or replace function public.firm_rag_status(p_firm_id uuid, p_month text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  with a as (select count(*) n from public.activity_entries where rep_firm_id = p_firm_id and reporting_month = p_month),
       op as (select count(*) n from public.pipeline_entries where rep_firm_id = p_firm_id and (status is null or status = 'Open') and reporting_month <= p_month),
       np as (select count(*) n from public.pipeline_entries where rep_firm_id = p_firm_id and created_date is not null and to_char(created_date, 'YYYY-MM') = p_month)
  select case
    when (select n from a) < 4 then 'Red'
    when (select n from a) between 4 and 7 then 'Amber'
    when (select n from op) = 0 then 'Amber'
    when (select n from np) = 0 then 'Amber'
    else 'Green' end;
$function$;

create or replace function public.get_my_reviews(p_limit integer default 3)
returns table(reporting_month text, rag_status text, rep_feedback text, finalized_at timestamptz, activity_count bigint)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select mr.reporting_month,
         coalesce(mr.rag_status, public.firm_rag_status(mr.rep_firm_id, mr.reporting_month)),
         nullif(trim(mr.rep_feedback), ''),
         mr.finalized_at,
         (select count(*) from public.activity_entries e where e.rep_firm_id = mr.rep_firm_id and e.reporting_month = mr.reporting_month)
    from public.monthly_reviews mr
   where mr.rep_firm_id = public.my_rep_firm_id() and mr.is_finalized
   order by mr.reporting_month desc
   limit greatest(1, least(p_limit, 12));
$function$;

create or replace function public.get_my_deals()
returns table(crm_id text, project_name text, account_name text, status text, stage text, value_usd numeric,
              created_date date, expected_close_date date, actual_close_date date,
              pending_status text, pending_close_date date, pending_at timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.crm_id, p.project_name, p.account_name, p.status, p.stage, p.value_usd,
         p.created_date, p.expected_close_date, p.actual_close_date,
         u.proposed_status, u.proposed_close_date, u.created_at
    from public.pipeline_entries p
    left join lateral (
      select d.proposed_status, d.proposed_close_date, d.created_at
        from public.deal_status_updates d
       where d.crm_id = p.crm_id and d.handled_at is null
       order by d.created_at desc limit 1
    ) u on true
   where p.rep_firm_id = public.my_rep_firm_id() and p.crm_id is not null
   order by (p.status = 'Open') desc, p.expected_close_date nulls last, p.created_date desc;
$function$;

create or replace function public.submit_deal_update(p_crm_id text, p_status text, p_close_date date, p_note text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_firm uuid := public.my_rep_firm_id();
  v_deal public.pipeline_entries;
  v_id uuid;
begin
  if v_firm is null then raise exception 'Only an active rep with a firm can update deals'; end if;
  if p_status not in ('Open', 'Won', 'Lost') then raise exception 'Status must be Open, Won or Lost'; end if;
  select * into v_deal from public.pipeline_entries where crm_id = p_crm_id and rep_firm_id = v_firm;
  if v_deal.id is null then raise exception 'This deal is not one of your firm''s deals'; end if;
  insert into public.deal_status_updates (crm_id, rep_firm_id, project_name, submitted_by, submitted_by_email, proposed_status, proposed_close_date, note)
  values (p_crm_id, v_firm, v_deal.project_name, auth.uid(), (select email from public.profiles where id = auth.uid()),
          p_status, p_close_date, nullif(trim(coalesce(p_note, '')), ''))
  returning id into v_id;
  return v_id;
end;
$function$;

-- Key accounts = classification TOP AUDAC LEAD or an AUDAC partner type
-- (same rule as the manager dashboard).
create or replace function public.get_my_key_accounts()
returns table(external_id text, name text, city text, state_code text, reason text,
              last_contact date, last_deal_date date, last_deal_name text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select a.external_id, a.name, a.city, a.state_code,
         case when a.classification = 'TOP AUDAC LEAD' then 'Top lead' else trim(a.audac_partner_type) end,
         (select max(e.entry_date) from public.activity_entries e where e.account_external_id = a.external_id),
         d.when_date, d.project_name
    from public.crm_accounts a
    left join lateral (
      select coalesce(p.actual_close_date, p.created_date) as when_date, p.project_name
        from public.pipeline_entries p
       where p.account_external_id = a.external_id and p.crm_id is not null
       order by coalesce(p.actual_close_date, p.created_date) desc nulls last limit 1
    ) d on true
   where a.rep_firm_id = public.my_rep_firm_id()
     and a.is_active
     and (a.classification = 'TOP AUDAC LEAD' or a.audac_partner_type ~* 'AUDAC\s+(Certified\s+)?(Partner|Distributor)')
   order by 6 nulls first, a.name;
$function$;

revoke all on function public.my_rep_firm_id() from public, anon;
revoke all on function public.firm_rag_status(uuid, text) from public, anon, authenticated;
revoke all on function public.get_my_reviews(integer) from public, anon;
revoke all on function public.get_my_deals() from public, anon;
revoke all on function public.submit_deal_update(text, text, date, text) from public, anon;
revoke all on function public.get_my_key_accounts() from public, anon;
grant execute on function public.my_rep_firm_id() to authenticated;
grant execute on function public.get_my_reviews(integer) to authenticated;
grant execute on function public.get_my_deals() to authenticated;
grant execute on function public.submit_deal_update(text, text, date, text) to authenticated;
grant execute on function public.get_my_key_accounts() to authenticated;
