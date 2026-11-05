-- Lead routing, based on how leads actually move (checked in Dynamics, 2026-11-05):
--   * Web leads: Sales Export sends the "Forward Lead" template, which names the
--     lead's Parent Account as the partner in copy. Until now that was Intellimix
--     (AVL Media Group), so the rep firm never got those leads. From now on the
--     Parent Account is the rep firm itself (Intellimix in CC).
--   * Trade-show lists (InfoComm 2026): no Parent Account; Intellimix sent each
--     rep firm the leads of its territory.
--   * "Qualified" = converted to account + contact once the rep confirmed contact
--     (not an opportunity), so it counts as followed up.
-- Routes: rep (forwarded to a rep firm), trade_show (handed to reps per
-- territory), info (handled by Intellimix: shown to the rep for information
-- only), support (technical/support questions) and junk (tests, spam).

alter table public.crm_leads add column if not exists parent_account_external_id text;

create or replace function public.crm_lead_route(l public.crm_leads)
returns text
language sql
stable
set search_path to 'public'
as $function$
  select case
    when coalesce(l.subject, '') ~* '(technical|support|portal|touch|cage code)' then 'support'
    when coalesce(l.company, '') ~* '^test' or coalesce(l.full_name, '') ~ E'[\\r\\n]' then 'junk'
    when l.parent_account_external_id is not null
         and exists (select 1 from public.rep_firms f where f.crm_account_external_id = l.parent_account_external_id) then 'rep'
    when (l.source = 'Trade Show' or coalesce(l.subject, '') ~* 'infocomm')
         and coalesce(l.subject, '') !~* '\mISE\M' then 'trade_show'
    else 'info'
  end;
$function$;
grant execute on function public.crm_lead_route(public.crm_leads) to authenticated;

-- Outcomes fit dealer leads (most trade-show visitors are integrators), not only projects.
alter table public.lead_followups drop constraint if exists lead_followups_outcome_check;
alter table public.lead_followups add constraint lead_followups_outcome_check
  check (outcome in ('contacted', 'meeting', 'project', 'not_relevant'));

-- The return type changes. DROP is refused by the desktop MCP session, so the old
-- version is renamed and locked instead (drop it later from a terminal session).
alter function public.get_my_leads() rename to get_my_leads_superseded;
revoke all on function public.get_my_leads_superseded() from public, anon, authenticated;

create function public.get_my_leads()
returns table(external_id text, full_name text, company text, email text, phone text, city text, state_code text,
              subject text, description text, source text, created_on timestamptz, route text, crm_status_reason text,
              outcome text, outcome_note text, outcome_at timestamptz, outcome_by text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select l.external_id, l.full_name, l.company, l.email, l.phone, l.city, coalesce(l.state_code, l.state_raw),
         l.subject, l.description, coalesce(l.web_source, l.source), l.created_on,
         public.crm_lead_route(l), l.crm_status_reason,
         f.outcome, f.note, f.created_at, f.submitted_by_name
    from public.crm_leads l
    left join lateral (
      select x.outcome, x.note, x.created_at, x.submitted_by_name
        from public.lead_followups x where x.lead_external_id = l.external_id
       order by x.created_at desc limit 1
    ) f on true
   where l.rep_firm_id = public.my_rep_firm_id()
     and l.crm_status_reason in ('Forwarded', 'Qualified')
     and (public.crm_lead_route(l) in ('rep', 'trade_show')
          or (public.crm_lead_route(l) = 'info' and l.created_on >= now() - interval '12 months'))
   order by l.created_on desc;
$function$;
revoke all on function public.get_my_leads() from public, anon;
grant execute on function public.get_my_leads() to authenticated;

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
  if p_outcome not in ('contacted', 'meeting', 'project', 'not_relevant') then raise exception 'Unknown outcome'; end if;
  if not exists (select 1 from public.crm_leads l
                  where l.external_id = p_lead and l.rep_firm_id = v_firm
                    and public.crm_lead_route(l) in ('rep', 'trade_show')) then
    raise exception 'This lead was not forwarded to your firm';
  end if;
  insert into public.lead_followups (lead_external_id, rep_firm_id, submitted_by, submitted_by_name, outcome, note)
  values (p_lead, v_firm, auth.uid(),
          (select coalesce(full_name, email) from public.profiles where id = auth.uid()),
          p_outcome, nullif(trim(coalesce(p_note, '')), ''))
  returning id into v_id;
  return v_id;
end;
$function$;
