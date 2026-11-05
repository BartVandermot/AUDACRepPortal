-- Leads from Dynamics in the portal.
-- AUDAC forwards North American leads to the rep firms (status "Forwarded")
-- and then loses sight of them. The nightly sync now brings in US/Canada
-- leads created since Intellimix became distributor (2025-06-23), resolved to
-- a rep firm like accounts are; reps report the outcome on My territory.
-- Leads hold personal data of prospects: reps reach them only through the
-- firm-scoped RPCs below, never the table itself.

create table if not exists public.crm_leads (
  external_id text primary key,
  full_name text,
  company text,
  email text,
  phone text,
  city text,
  state_raw text,
  state_code text,
  zip text,
  country_code text,
  subject text,
  description text,
  source text,
  web_source text,
  crm_status text,
  crm_status_reason text,
  created_on timestamptz,
  rep_firm_id uuid references public.rep_firms(id),
  last_synced_at timestamptz
);
alter table public.crm_leads enable row level security;
create policy crm_leads_select_staff on public.crm_leads
  for select using (public.current_role_name() = any (array['manager', 'executive']));
grant select on public.crm_leads to authenticated;
create index if not exists crm_leads_firm_idx on public.crm_leads(rep_firm_id, created_on desc);

create table if not exists public.lead_followups (
  id uuid primary key default gen_random_uuid(),
  lead_external_id text not null references public.crm_leads(external_id) on delete cascade,
  rep_firm_id uuid not null references public.rep_firms(id),
  submitted_by uuid not null default auth.uid() references auth.users(id),
  submitted_by_name text,
  outcome text not null check (outcome in ('contacted', 'quoted', 'won', 'lost', 'not_relevant')),
  note text,
  created_at timestamptz not null default now()
);
alter table public.lead_followups enable row level security;
create policy lead_followups_select on public.lead_followups
  for select using (public.current_role_name() = any (array['manager', 'executive']) or submitted_by = (select auth.uid()));
grant select on public.lead_followups to authenticated;
create index if not exists lead_followups_lead_idx on public.lead_followups(lead_external_id, created_at desc);

-- Rep: the firm's leads, with the latest follow-up.
create or replace function public.get_my_leads()
returns table(external_id text, full_name text, company text, email text, phone text, city text, state_code text,
              subject text, description text, source text, created_on timestamptz,
              outcome text, outcome_note text, outcome_at timestamptz, outcome_by text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select l.external_id, l.full_name, l.company, l.email, l.phone, l.city, coalesce(l.state_code, l.state_raw),
         l.subject, l.description, coalesce(l.web_source, l.source), l.created_on,
         f.outcome, f.note, f.created_at, f.submitted_by_name
    from public.crm_leads l
    left join lateral (
      select x.outcome, x.note, x.created_at, x.submitted_by_name
        from public.lead_followups x where x.lead_external_id = l.external_id
       order by x.created_at desc limit 1
    ) f on true
   where l.rep_firm_id = public.my_rep_firm_id()
   order by l.created_on desc;
$function$;

create or replace function public.submit_lead_followup(p_lead text, p_outcome text, p_note text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_firm uuid := public.my_rep_firm_id();
  v_id uuid;
begin
  if v_firm is null then raise exception 'Only an active rep with a firm can report on leads'; end if;
  if p_outcome not in ('contacted', 'quoted', 'won', 'lost', 'not_relevant') then raise exception 'Unknown outcome'; end if;
  if not exists (select 1 from public.crm_leads where external_id = p_lead and rep_firm_id = v_firm) then
    raise exception 'This lead is not one of your firm''s leads';
  end if;
  insert into public.lead_followups (lead_external_id, rep_firm_id, submitted_by, submitted_by_name, outcome, note)
  values (p_lead, v_firm, auth.uid(),
          (select coalesce(full_name, email) from public.profiles where id = auth.uid()),
          p_outcome, nullif(trim(coalesce(p_note, '')), ''))
  returning id into v_id;
  return v_id;
end;
$function$;

revoke all on function public.get_my_leads() from public, anon;
revoke all on function public.submit_lead_followup(text, text, text) from public, anon;
grant execute on function public.get_my_leads() to authenticated;
grant execute on function public.submit_lead_followup(text, text, text) to authenticated;
