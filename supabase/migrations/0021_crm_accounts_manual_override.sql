-- Same latent bug as crm_contacts (fixed in 0020) exists on crm_accounts: a
-- manager's manual rep-firm correction on the CRM Data page currently gets
-- silently overwritten the next time "Sync from CRM" runs, since the
-- accounts phase unconditionally recomputes rep_firm_id from parent
-- account/state every time. This flag lets that phase skip recomputation
-- for a row a manager has explicitly corrected.
alter table public.crm_accounts add column rep_firm_overridden boolean not null default false;

comment on column public.crm_accounts.rep_firm_overridden is 'true once a manager has manually set this account''s rep firm from the CRM Data page (including manually setting it to unassigned) -- the CRM sync''s accounts phase leaves rep_firm_id untouched for these rows instead of recomputing it from the parent account/state, so a manual correction survives future syncs.';
