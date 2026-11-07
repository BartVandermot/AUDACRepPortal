-- My territory as a search page (Bart, 2026-11-07): every active company of
-- the rep's own firm, with its contacts and open deals, in one call. Firm-
-- scoped like get_my_key_accounts (my_rep_firm_id()); the firm's own account
-- is left out. Applied via execute_sql.

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
     and not exists (select 1 from public.rep_firms f where f.crm_account_external_id = a.external_id)
   order by a.name;
$function$;
revoke all on function public.get_my_territory() from public, anon;
grant execute on function public.get_my_territory() to authenticated;
