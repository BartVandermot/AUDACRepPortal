-- Applied 2026-11-07 via execute_sql, then found unused: the nightly sync
-- fetches telephone1 but does not store it in crm_accounts.phone (2 of 604
-- active accounts have a phone), so crm-writeback checks the phone number
-- live in Dynamics instead. Dropping it was declined by the Supabase MCP;
-- it is harmless (managers / service role only). Drop it when convenient:
--   drop function if exists public.crm_accounts_same_phone(text, text);

create or replace function public.crm_accounts_same_phone(p_phone text, p_exclude text default null)
returns table(external_id text, name text, city text, state_code text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select a.external_id, a.name, a.city, a.state_code
  from public.crm_accounts a
  where (coalesce(auth.role(), '') = 'service_role' or public.current_role_name() = 'manager')
    and a.is_active
    and a.external_id is distinct from p_exclude
    and length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) >= 10
    and right(regexp_replace(coalesce(a.phone, ''), '\D', '', 'g'), 10) = right(regexp_replace(p_phone, '\D', '', 'g'), 10)
  order by a.name
  limit 5;
$function$;
revoke all on function public.crm_accounts_same_phone(text, text) from public, anon;
grant execute on function public.crm_accounts_same_phone(text, text) to authenticated, service_role;
