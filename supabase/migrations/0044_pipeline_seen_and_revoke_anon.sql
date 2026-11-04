-- 1. Synced opportunities get a "last seen by a full sync" timestamp, so a
--    deal deleted in Dynamics can be removed from the portal's pipeline
--    (dataverse-sync v33 sweeps rows not seen by the run that just finished).
--    uploaded_at can't serve: it's only set on insert.
alter table public.pipeline_entries add column if not exists last_synced_at timestamptz;

-- 2. Security advisor: these SECURITY DEFINER functions were callable without
--    signing in. Every page that uses them requires sign-in (since 0033), and
--    the trigger function is never meant to be called over the API at all.
revoke execute on function public.get_finalized_periods() from public, anon;
revoke execute on function public.set_my_full_name(text) from public, anon;
revoke execute on function public.auto_link_rep_crm_contact() from public, anon, authenticated;
grant execute on function public.get_finalized_periods() to authenticated;
grant execute on function public.set_my_full_name(text) to authenticated;
