-- Duplicate guard for companies and contacts reps add (Bart, 2026-11-07).
-- "ICB Audio Video" went to Dynamics as a second company next to "ICB": the
-- check then only compared exact names. Now:
--   * crm_name_core(): a company name without the words that differ between
--     how people write the same company (Inc, LLC, Audio, Video, AV, Systems,
--     Group, ...). "ICB Audio Video LLC" and "ICB" both become "icb".
--   * crm_lookalike_accounts(): companies that are probably the same one --
--     same core name, or same first word of the core name in the same city --
--     in the same state/province. Used by the form ("Is it one of these?") and
--     by crm-writeback before it creates a company in Dynamics.
--   * search_crm_accounts(): also finds "ICB" when a rep types
--     "ICB Audio Video"; skips inactive records.
--   * find_crm_contact_by_email(): the form checks a new contact's e-mail
--     against the CRM before adding them.

create or replace function public.crm_name_core(p text)
returns text
language sql
immutable
set search_path to 'public'
as $function$
  with base as (
    select trim(regexp_replace(regexp_replace(replace(replace(lower(coalesce(p, '')), 'a/v', ' av '), '&', ' and '), '[^a-z0-9]+', ' ', 'g'), '\s+', ' ', 'g')) as full_name
  ), core as (
    select full_name,
      trim(regexp_replace(regexp_replace(full_name,
        '\m(the|inc|incorporated|llc|llp|ltd|limited|corp|corporation|co|company|and|of|audio|video|av|audiovisual|visual|system|systems|group|solution|solutions|technology|technologies|tech|service|services|integration|integrations|integrator|integrators|communication|communications|sound|media|design|designs|pro|production|productions|enterprise|enterprises|international|usa|us|electronics|entertainment)\M',
        ' ', 'g'), '\s+', ' ', 'g')) as core_name
    from base
  )
  select case when core_name = '' then full_name else core_name end from core;
$function$;

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
      -- Reps see their own firm's accounts only; the write-back (service
      -- role) and managers look across firms.
      and (case when coalesce(auth.role(), '') = 'service_role' or public.current_role_name() = 'manager'
                then (p_firm_id is null or a.rep_firm_id = p_firm_id)
                else p_firm_id is not null and a.rep_firm_id = p_firm_id end)
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
revoke all on function public.crm_lookalike_accounts(text, text, text, uuid, text, int) from public, anon;
grant execute on function public.crm_lookalike_accounts(text, text, text, uuid, text, int) to authenticated, service_role;

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
    and p_query is not null and length(trim(p_query)) >= 2
    and (a.name ilike '%' || trim(p_query) || '%'
         or (length(split_part(public.crm_name_core(p_query), ' ', 1)) >= 2
             and split_part(public.crm_name_core(a.name), ' ', 1) = split_part(public.crm_name_core(p_query), ' ', 1)))
  order by (a.name ilike '%' || trim(p_query) || '%') desc, a.name
  limit greatest(1, least(coalesce(p_limit, 8), 25));
$function$;

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
    and nullif(trim(coalesce(p_email, '')), '') is not null
    and c.email_key = lower(trim(p_email))
  order by (c.source = 'dataverse') desc
  limit 3;
$function$;
revoke all on function public.find_crm_contact_by_email(text, uuid) from public, anon;
grant execute on function public.find_crm_contact_by_email(text, uuid) to authenticated;
