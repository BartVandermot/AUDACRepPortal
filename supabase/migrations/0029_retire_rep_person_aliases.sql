-- rep_person_aliases resolved an Opportunity's rep by NAME because that felt
-- like the only signal available -- but the Opportunity's Contact field is
-- actually a real Dataverse lookup, and that Contact is already synced into
-- crm_contacts with its own (auto-resolved-or-overridable) rep_firm_id. A
-- name-keyed table alongside that is redundant, and strictly less precise:
-- two different real people sharing a display name would get the same
-- decision under the old table, but never under a per-contact override.
--
-- This migrates every reviewed alias decision onto the matching crm_contacts
-- row(s) (by normalized full_name, the same matching the sync's old
-- name-lookup effectively did) as a manual override, then drops the table.
-- An "excluded" alias (rep_firm_id null, i.e. "not a tracked rep") becomes an
-- explicit rep_firm_id = null override -- important for e.g. the several
-- Canadian names excluded here that would otherwise silently re-resolve to
-- PAG Canada once the alias table stops shadowing that automatic match.
update public.crm_contacts cc
set rep_firm_id = a.rep_firm_id,
    rep_firm_overridden = true
from public.rep_person_aliases a
where a.reviewed
  and lower(trim(cc.full_name)) = a.person_name_key;

drop table public.rep_person_aliases;

-- Replaces the alias table's other job -- surfacing an opportunity whose rep
-- couldn't be resolved so someone can fix it -- but keyed on the actual
-- Contact record instead of a name, and folded into the CRM Contacts
-- resolution filter that already exists rather than a separate table+page
-- section. Set true by the opportunities sync when it sees this contact on a
-- deal it couldn't attribute to any firm; cleared by the sync once that
-- resolves, or immediately by a manager overriding the contact's rep firm.
alter table public.crm_contacts add column if not exists blocks_pipeline_sync boolean not null default false;

comment on column public.crm_contacts.blocks_pipeline_sync is 'true when the opportunities sync saw this contact on a deal it could not attribute to a rep firm (no Installer match, no resolved/overridden rep_firm_id here) -- cleared once resolved, by sync or manual override';
