-- A rep who leaves their firm gets deactivated instead of deleted: their
-- logged activity keeps its name/history, but they can no longer submit or
-- import, and they drop out of the manager's work lists.

alter table public.profiles add column if not exists is_active boolean not null default true;

-- Only active accounts may log activities.
alter policy activity_entries_insert_own on public.activity_entries
  with check (
    created_by = (select auth.uid())
    and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.is_active)
  );

-- ...or import them (managers are never deactivated through this flag).
create or replace function public.can_import_activities_for_firm(p_firm_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select auth.uid() is not null and exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.is_active
      and (p.role = 'manager' or (p.rep_firm_id = p_firm_id and p.rep_firm_id is not null))
  );
$function$;
