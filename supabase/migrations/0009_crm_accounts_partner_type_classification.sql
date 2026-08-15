-- Adds AUDAC Partner Type (pvs_audacpartnertype) and Classification
-- (accountclassificationcode) from Dataverse so the CRM admin page can show
-- them alongside each account. Stored as the formatted (human-readable)
-- picklist label, same pattern as relationship_type / business_type.

alter table public.crm_accounts add column audac_partner_type text;
alter table public.crm_accounts add column classification text;
