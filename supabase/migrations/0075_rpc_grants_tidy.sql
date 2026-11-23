-- Grants tidy-up after 0073/0074 (2026-11-23, debug pass).
-- Applied via execute_sql. New functions get EXECUTE for PUBLIC by default;
-- the app only calls them signed in. The functions check the role themselves,
-- so this closes the door rather than a hole.

revoke execute on function public.confirm_rep_project_match(uuid, boolean) from public, anon;
revoke execute on function public.get_rep_projects(uuid) from public, anon;
revoke execute on function public.get_my_territory() from public, anon;
-- Helper, only called inside get_rep_projects.
revoke execute on function public.rep_project_match_signals(text,text,text,numeric,text,text,text,numeric) from public, anon, authenticated;
-- Replaced by get_rep_projects (0074).
revoke execute on function public.get_rep_projects_superseded_0074(uuid) from public, anon, authenticated;

grant execute on function public.confirm_rep_project_match(uuid, boolean) to authenticated;
grant execute on function public.get_rep_projects(uuid) to authenticated;
grant execute on function public.get_my_territory() to authenticated;

-- Permission helper returned NULL (not false) for a rep without a firm or a
-- deactivated rep, so "if not can_import...(...) then raise" didn't fire.
create or replace function public.can_import_projects_for_firm(p_firm_id uuid)
returns boolean language sql stable security definer set search_path to 'public' as $function$
  select coalesce(public.current_role_name() = 'manager'
      or (public.current_role_name() = 'rep' and public.my_rep_firm_id() = p_firm_id), false);
$function$;

-- One deal is never suggested to two projects in the same run.
create or replace function public.match_rep_projects(p_firm_id uuid)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare n integer;
begin
  update public.rep_projects r
     set dealer_account_external_id = a.external_id
    from public.crm_accounts a
   where r.rep_firm_id = p_firm_id and r.dealer_account_external_id is null and r.dealer_name is not null
     and a.is_active and a.name_key = lower(trim(r.dealer_name));

  with cand as (
    select r.id, p.crm_id, p.created_date,
           (public.rep_project_key(p.project_name) = public.rep_project_key(r.project_name)) as exact
      from public.rep_projects r
      join public.pipeline_entries p on p.rep_firm_id = r.rep_firm_id and p.crm_id is not null
     where r.rep_firm_id = p_firm_id and r.matched_crm_id is null and r.suggested_crm_id is null
       and length(public.rep_project_key(r.project_name)) >= 4
       and (public.rep_project_key(p.project_name) = public.rep_project_key(r.project_name)
            or (length(public.rep_project_key(r.project_name)) >= 8 and public.rep_project_key(p.project_name) like '%' || public.rep_project_key(r.project_name) || '%')
            or (length(public.rep_project_key(p.project_name)) >= 8 and public.rep_project_key(r.project_name) like '%' || public.rep_project_key(p.project_name) || '%'))
       and not (p.crm_id = any (r.rejected_crm_ids))
       and not exists (select 1 from public.rep_projects o where o.matched_crm_id = p.crm_id or o.suggested_crm_id = p.crm_id)
  ),
  best as (   -- one deal per project: the exact name first, then the newest
    select distinct on (id) id, crm_id, exact from cand order by id, exact desc, created_date desc nulls last
  ),
  c as (      -- and one project per deal, so a registration is never offered twice
    select distinct on (crm_id) id, crm_id from best order by crm_id, exact desc, id
  )
  update public.rep_projects r
     set suggested_crm_id = c.crm_id, suggested_at = now()
    from c where r.id = c.id;
  get diagnostics n = row_count;
  return n;
end;
$function$;
