-- Performance advisor flagged 9 RLS policies that call auth.uid() directly
-- in their USING/WITH CHECK clause. Postgres re-evaluates a bare auth.uid()
-- call once PER ROW scanned; wrapping it as (select auth.uid()) lets the
-- planner evaluate it once per query and treat the result as a constant,
-- which is the standard Supabase-recommended fix. Purely a query-plan
-- optimization -- the boolean logic of every policy is unchanged, only the
-- auth.uid() calls are wrapped.

alter policy profiles_select_own_or_staff on public.profiles
  using ((id = (select auth.uid())) or (current_role_name() = any (array['manager'::text, 'executive'::text])));

alter policy activity_entries_delete_own on public.activity_entries
  using (created_by = (select auth.uid()));

alter policy activity_entries_select_own on public.activity_entries
  using (created_by = (select auth.uid()));

alter policy activity_entries_update_own on public.activity_entries
  using (created_by = (select auth.uid()));

alter policy activity_entries_delete_firm_admin on public.activity_entries
  using (exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.is_rep_admin
      and p.rep_firm_id = activity_entries.rep_firm_id
  ));

alter policy activity_entries_select_firm_admin on public.activity_entries
  using (exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.is_rep_admin
      and p.rep_firm_id = activity_entries.rep_firm_id
  ));

alter policy activity_entries_update_firm_admin on public.activity_entries
  using (exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.is_rep_admin
      and p.rep_firm_id = activity_entries.rep_firm_id
  ));

alter policy activity_attachments_delete_scoped on public.activity_attachments
  using ((current_role_name() = 'manager'::text) or (uploaded_by = (select auth.uid())));

alter policy activity_attachments_select_scoped on public.activity_attachments
  using ((current_role_name() = any (array['manager'::text, 'executive'::text])) or (uploaded_by = (select auth.uid())));
