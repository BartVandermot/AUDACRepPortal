-- Dataverse can have two distinct accounts (different external_id) that share
-- the same normalized name -- the live sync's external_id-based upsert was
-- hitting the name_key unique constraint on the second one. name_key is now
-- only used for lookup (company -> rep firm resolution), not as an upsert
-- conflict target for the live sync, so it doesn't need to be unique.

alter table public.crm_accounts drop constraint crm_accounts_name_key_key;
create index idx_crm_accounts_name_key on public.crm_accounts (name_key);
