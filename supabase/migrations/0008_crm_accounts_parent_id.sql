-- crm.html shows whether an account's rep_firm_id came from the parent-account
-- chain vs. the state fallback, but dataverse-sync only ever computed the parent
-- id transiently for resolution -- it was never actually persisted. Add the
-- column so the admin page's query (and that badge) work.

alter table public.crm_accounts add column parent_account_external_id text;
comment on column public.crm_accounts.parent_account_external_id is 'Dataverse accountid of this account''s parentaccountid -- used by the CRM admin page to show whether rep_firm_id was resolved via the parent-account chain vs. the state fallback';
