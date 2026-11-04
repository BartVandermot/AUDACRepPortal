-- Managers/executives aren't members of a rep firm. Both AUDAC managers had
-- been tied to C. L. Pugh & Associates by opening a ?firm= signup link while
-- signed in (claim_rep_firm accepted any role), which then locked the
-- activity form to that firm for them. Untie them, and only let reps claim.

update public.profiles
set rep_firm_id = null
where role in ('manager', 'executive') and rep_firm_id is not null;

create or replace function public.claim_rep_firm(p_firm_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is null then
    raise exception 'Must be signed in';
  end if;
  if not exists (select 1 from public.rep_firms where id = p_firm_id and status = 'active') then
    raise exception 'Invalid rep firm';
  end if;
  update public.profiles set rep_firm_id = p_firm_id
  where id = auth.uid() and rep_firm_id is null and role = 'rep';
end;
$function$;
