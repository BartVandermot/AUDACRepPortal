-- "Forwarded" is a status reason of the Disqualified state in Dynamics: a
-- forwarded lead is already closed there. When the manager later gives it
-- another reason (e.g. No Longer Interested after the rep reported "not
-- interested"), the rep must keep seeing the lead and their own follow-up.
create or replace function public.get_my_leads()
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
     and (l.crm_status_reason in ('Forwarded', 'Qualified') or f.outcome is not null)
     and (public.crm_lead_route(l) in ('rep', 'trade_show')
          or (public.crm_lead_route(l) = 'info' and l.created_on >= now() - interval '12 months'))
   order by l.created_on desc;
$function$;
