-- A contact's rep_firm_id is normally inherited from its parent account,
-- recomputed and overwritten on every CRM sync (see dataverse-sync's
-- contacts phase). Without a way to mark "a manager corrected this one
-- specific contact," any manual override entered on the Reps page would
-- silently get clobbered the next time someone runs a sync -- the same
-- reviewed-vs-placeholder problem rep_person_aliases.reviewed already
-- solves, just for a different table.
alter table public.crm_contacts add column rep_firm_overridden boolean not null default false;

comment on column public.crm_contacts.rep_firm_overridden is 'true once a manager has manually set this contact''s rep firm from the Reps page (including manually setting it to unassigned) -- the CRM sync''s contacts phase leaves rep_firm_id untouched for these rows instead of recomputing it from the parent account, so a manual correction survives future syncs.';
