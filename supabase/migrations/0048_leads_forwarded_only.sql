-- Reps see only the leads AUDAC actually forwarded to them (status reason
-- "Forwarded"). New = not passed on yet; Canceled/Lost/etc. = closed by AUDAC;
-- Qualified = already turned into an opportunity (shows under deals).
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
     and l.crm_status_reason = 'Forwarded'
   order by l.created_on desc;
$function$;
