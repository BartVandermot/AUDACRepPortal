-- CSV imports (Education, Pipeline, Sell-out) used to silently DROP any row
-- whose company/dealer name couldn't be resolved to a rep firm -- discovered
-- when a real Education export turned out to have 6 real, active rep firms'
-- certifications vanishing this way because their own CRM account record had
-- no territory match yet. The app-side fix changes that to actually import
-- the row with rep_firm_id left blank (and, for genuinely new/unresolved
-- companies, ask the manager to assign a firm before finishing the import)
-- rather than discarding real data. That requires rep_firm_id to allow null
-- on all three CSV-import tables.
alter table public.education_records alter column rep_firm_id drop not null;
alter table public.pipeline_entries alter column rep_firm_id drop not null;
alter table public.sellout_records alter column rep_firm_id drop not null;
