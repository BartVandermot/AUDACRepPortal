-- search_crm_accounts and search_crm_contacts are called with no login (the
-- public rep form is deliberately frictionless), but were completely
-- unscoped: any caller could search company names across ALL 582 synced
-- accounts firm-wide, and search_crm_contacts returned every contact's full
-- name AND EMAIL for a given account with no ownership check at all --
-- chaining the two let an anonymous caller harvest the entire CRM contact
-- list (names + emails, across every rep firm) directly via the public
-- REST RPC endpoint, bypassing the UI entirely.
--
-- Fix, in two parts:
--  1. Both now take the rep firm the visitor is actually submitting for
--     (the form already knows this by the time either combo box is used --
--     the firm dropdown is locked or picked before the Account/Contact
--     fields render) and only search that firm's own accounts/contacts.
--     Firm IDs aren't secret (they're in the public ?firm= links), so this
--     doesn't make scraping impossible, but it shrinks a single query's
--     yield from "every account system-wide" to "one firm's ~10-90
--     accounts," and is also just more correct: a rep has no legitimate
--     reason to see another firm's dealer contacts anyway.
--  2. search_crm_contacts no longer returns email at all. The UI only ever
--     used it as a same-name disambiguation hint (see form.html) -- the
--     value actually submitted and stored is contact_name/contact_external_id,
--     never the email -- so dropping it removes the single most sensitive
--     field from an otherwise low-sensitivity (company/person name) search
--     surface, at no real UX cost.
drop function if exists public.search_crm_accounts(text, integer);
drop function if exists public.search_crm_contacts(text);

create function public.search_crm_accounts(p_query text, p_firm_id uuid, p_limit integer default 8)
returns table (external_id text, name text, city text, state_code text)
language sql
stable
security definer
set search_path = public
as $$
  select external_id, name, city, state_code
  from public.crm_accounts
  where p_firm_id is not null
    and rep_firm_id = p_firm_id
    and p_query is not null and length(trim(p_query)) >= 2
    and name ilike '%' || trim(p_query) || '%'
  order by name
  limit greatest(1, least(coalesce(p_limit, 8), 25));
$$;

create function public.search_crm_contacts(p_account_external_id text, p_firm_id uuid)
returns table (external_id text, full_name text)
language sql
stable
security definer
set search_path = public
as $$
  select c.external_id, c.full_name
  from public.crm_contacts c
  join public.crm_accounts a on a.external_id = c.parent_account_external_id
  where p_account_external_id is not null
    and p_firm_id is not null
    and c.parent_account_external_id = p_account_external_id
    and a.rep_firm_id = p_firm_id
  order by c.full_name
  limit 25;
$$;
