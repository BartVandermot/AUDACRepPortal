-- Accounts reps don't see (Bart, 2026-11-07): competitors, other independent
-- rep firms, and distributors. They stay in the CRM, on Accounts & Contacts for
-- managers, and in the write-back's duplicate check (service role), so a rep
-- who adds one of them as a "new company" is held for Bart, not duplicated.
-- Applied via execute_sql.

create or replace function public.crm_hidden_from_reps(p_relationship_type text, p_business_type text)
returns boolean
language sql
immutable
as $function$
  select coalesce(p_relationship_type, '') in ('Competitor', 'Independent Rep Firm')
      or coalesce(p_business_type, '') ilike 'distributor';
$function$;

-- My territory
create or replace function public.get_my_territory()
returns table(external_id text, name text, street text, city text, state_code text, zip text, phone text, website text,
              relationship_type text, business_type text, key_reason text, added_by_firm boolean,
              last_logged date, logged_count int, contacts jsonb, open_deals jsonb)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select a.external_id, a.name, a.street, a.city, a.state_code, a.zip, a.phone, a.website,
         a.relationship_type, a.business_type,
         case when a.classification = 'TOP AUDAC LEAD' then 'Top lead'
              when a.audac_partner_type ~* 'AUDAC\s+(Certified\s+)?(Partner|Distributor)' then trim(a.audac_partner_type) end,
         a.source = 'manual',
         (select max(e.entry_date) from public.activity_entries e where e.account_external_id = a.external_id and e.rep_firm_id = a.rep_firm_id),
         (select count(*)::int from public.activity_entries e where e.account_external_id = a.external_id and e.rep_firm_id = a.rep_firm_id),
         coalesce((select jsonb_agg(jsonb_build_object('id', c.external_id, 'name', c.full_name, 'email', c.email, 'phone', c.phone) order by c.full_name)
                     from public.crm_contacts c where c.parent_account_external_id = a.external_id and c.is_active), '[]'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object('crm_id', p.crm_id, 'name', p.project_name, 'value', p.value_usd, 'close', p.expected_close_date) order by p.expected_close_date nulls last)
                     from public.pipeline_entries p where p.account_external_id = a.external_id and p.rep_firm_id = a.rep_firm_id and p.status = 'Open'), '[]'::jsonb)
    from public.crm_accounts a
   where a.rep_firm_id = public.my_rep_firm_id()
     and a.is_active
     and not public.crm_hidden_from_reps(a.relationship_type, a.business_type)
     and not exists (select 1 from public.rep_firms f where f.crm_account_external_id = a.external_id)
   order by a.name;
$function$;

-- Key accounts (Home / dashboard widgets)
create or replace function public.get_my_key_accounts()
returns table(external_id text, name text, city text, state_code text, reason text, last_contact date, last_deal_date date, last_deal_name text)
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
     and not public.crm_hidden_from_reps(a.relationship_type, a.business_type)
     and (a.classification = 'TOP AUDAC LEAD' or a.audac_partner_type ~* 'AUDAC\s+(Certified\s+)?(Partner|Distributor)')
   order by 6 nulls first, a.name;
$function$;

-- Company search in the activity form
create or replace function public.search_crm_accounts(p_query text, p_firm_id uuid, p_limit integer DEFAULT 8)
returns table(external_id text, name text, city text, state_code text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select a.external_id, a.name, a.city, a.state_code
  from public.crm_accounts a
  where p_firm_id is not null
    and a.rep_firm_id = p_firm_id
    and a.is_active
    and (public.current_role_name() = 'manager' or not public.crm_hidden_from_reps(a.relationship_type, a.business_type))
    and p_query is not null and length(trim(p_query)) >= 2
    and (a.name ilike '%' || trim(p_query) || '%'
         or (length(split_part(public.crm_name_core(p_query), ' ', 1)) >= 2
             and split_part(public.crm_name_core(a.name), ' ', 1) = split_part(public.crm_name_core(p_query), ' ', 1)))
  order by (a.name ilike '%' || trim(p_query) || '%') desc, a.name
  limit greatest(1, least(coalesce(p_limit, 8), 25));
$function$;

-- "Already in AUDAC's CRM?" in the form (reps); the write-back still sees all
create or replace function public.crm_lookalike_accounts(p_name text, p_city text, p_state text, p_firm_id uuid, p_exclude text default null, p_limit int default 5)
returns table(external_id text, name text, city text, state_code text, reason text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with q as (
    select public.crm_name_core(p_name) as core,
           split_part(public.crm_name_core(p_name), ' ', 1) as first_word,
           lower(trim(coalesce(p_city, ''))) as city,
           upper(trim(coalesce(p_state, ''))) as st
  ), cand as (
    select a.external_id, a.name, a.city, a.state_code,
           public.crm_name_core(a.name) as core,
           lower(trim(coalesce(a.city, ''))) as a_city
    from public.crm_accounts a, q
    where a.is_active
      and a.external_id is distinct from p_exclude
      and (q.st = '' or a.state_code = q.st)
      and (case when coalesce(auth.role(), '') = 'service_role' or public.current_role_name() = 'manager'
                then (p_firm_id is null or a.rep_firm_id = p_firm_id)
                else p_firm_id is not null and a.rep_firm_id = p_firm_id
                     and not public.crm_hidden_from_reps(a.relationship_type, a.business_type) end)
  )
  select c.external_id, c.name, c.city, c.state_code,
         case when c.core = q.core then 'same name' else 'similar name, same city' end
  from cand c, q
  where length(q.core) >= 2
    and (c.core = q.core
         or (length(q.first_word) >= 2 and split_part(c.core, ' ', 1) = q.first_word and q.city <> '' and c.a_city = q.city))
  order by (c.core = q.core) desc, c.name
  limit greatest(1, least(coalesce(p_limit, 5), 10));
$function$;

-- New-contact e-mail check in the form
create or replace function public.find_crm_contact_by_email(p_email text, p_firm_id uuid)
returns table(external_id text, full_name text, account_external_id text, account_name text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select c.external_id, c.full_name, a.external_id, a.name
  from public.crm_contacts c
  join public.crm_accounts a on a.external_id = c.parent_account_external_id
  where p_firm_id is not null
    and a.rep_firm_id = p_firm_id
    and c.is_active and a.is_active
    and (public.current_role_name() = 'manager' or not public.crm_hidden_from_reps(a.relationship_type, a.business_type))
    and nullif(trim(coalesce(p_email, '')), '') is not null
    and c.email_key = lower(trim(p_email))
  order by (c.source = 'dataverse') desc
  limit 3;
$function$;
