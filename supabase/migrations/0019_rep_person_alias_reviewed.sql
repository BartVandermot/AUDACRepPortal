-- Distinguishes "a manager decided this" from "nobody's looked at this yet" --
-- both currently look identical (a row with rep_firm_id = null could mean
-- either "explicitly not a tracked rep" or "not decided"). Without this,
-- auto-creating placeholder rows for unresolved names (so they're visible on
-- /reps without waiting for someone to be looking at a sync's live output)
-- would be indistinguishable from a deliberate exclusion.
alter table public.rep_person_aliases add column reviewed boolean not null default false;

comment on column public.rep_person_aliases.reviewed is 'true once a manager has made an explicit decision (assigned a firm, or explicitly excluded). false means this is an auto-created placeholder for an unresolved name awaiting review.';

-- Every pre-existing row was manually entered before this flag existed --
-- treat all of them as already decided, not as fresh placeholders.
update public.rep_person_aliases set reviewed = true;
