-- Supports a live Dataverse Opportunity sync (mirrors the existing
-- accounts/contacts sync) rather than only CSV upload. account_external_id
-- links each pipeline entry back to the CRM account it came from, matching
-- the account_external_id/contact_external_id pattern already on
-- activity_entries. crm_id becomes a real dedup key so re-running the sync
-- updates the same row instead of duplicating it -- scoped to
-- (crm_id, reporting_month) rather than crm_id alone, since the same open
-- opportunity legitimately reappears as a new monthly snapshot if the sync
-- is run again in a later reporting month; that's not a duplicate.
alter table public.pipeline_entries
  add column account_external_id text references public.crm_accounts(external_id);

alter table public.pipeline_entries
  add constraint pipeline_entries_crm_id_month_unique unique (crm_id, reporting_month);
