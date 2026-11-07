-- Address fixes for US accounts without a State in Dynamics (Bart, 2026-11-07).
-- In many of them the state is there, just in the wrong field: "NY 10550" in
-- the ZIP field, "Birmingham, Alabama" or "Florida 32615-8544" as the city,
-- "Hodgkins, Illinois" as the state with the ZIP in the city field.
-- This table holds one proposal per account (old and new City / State / ZIP),
-- Bart approves, crm-writeback ({"applyAddressFixes": true}) writes only those
-- three fields to Dynamics after checking they still hold the old values, and
-- keeps the old values here so every change can be undone.
-- Applied via execute_sql.

create table if not exists public.crm_address_fixes (
  external_id text primary key,
  name text,
  old_city text, old_state text, old_zip text,
  new_city text, new_state text, new_zip text,
  reason text,
  status text not null default 'proposed' check (status in ('proposed', 'approved', 'applied', 'failed', 'skipped')),
  error text,
  created_at timestamptz not null default now(),
  applied_at timestamptz
);
alter table public.crm_address_fixes enable row level security;
create policy crm_address_fixes_manager on public.crm_address_fixes for select to authenticated
  using (public.current_role_name() = 'manager');
revoke all on public.crm_address_fixes from anon;
grant select on public.crm_address_fixes to authenticated;

-- US ZIP3 -> state (same table as dataverse-sync's ZIP3_STATE_RANGES).
create or replace function public.us_state_from_zip(p_zip text)
returns text
language sql
immutable
as $function$
  select r.st
  from (values
    (5,5,'NY'),(6,7,'PR'),(9,9,'PR'),(10,27,'MA'),(28,29,'RI'),(30,38,'NH'),(39,49,'ME'),(50,54,'VT'),(55,55,'MA'),(56,59,'VT'),
    (60,69,'CT'),(70,89,'NJ'),(100,149,'NY'),(150,196,'PA'),(197,199,'DE'),(200,200,'DC'),(201,201,'VA'),(202,205,'DC'),(206,219,'MD'),
    (220,246,'VA'),(247,268,'WV'),(270,289,'NC'),(290,299,'SC'),(300,319,'GA'),(320,339,'FL'),(341,349,'FL'),(350,369,'AL'),(370,385,'TN'),
    (386,397,'MS'),(398,399,'GA'),(400,427,'KY'),(430,459,'OH'),(460,479,'IN'),(480,499,'MI'),(500,528,'IA'),(530,549,'WI'),(550,567,'MN'),
    (569,569,'DC'),(570,577,'SD'),(580,588,'ND'),(590,599,'MT'),(600,629,'IL'),(630,658,'MO'),(660,679,'KS'),(680,693,'NE'),(700,714,'LA'),
    (716,729,'AR'),(730,732,'OK'),(733,733,'TX'),(734,749,'OK'),(750,799,'TX'),(800,816,'CO'),(820,831,'WY'),(832,838,'ID'),(840,847,'UT'),
    (850,865,'AZ'),(870,884,'NM'),(885,885,'TX'),(889,898,'NV'),(900,961,'CA'),(967,968,'HI'),(969,969,'GU'),(970,979,'OR'),(980,994,'WA'),(995,999,'AK')
  ) as r(a, b, st)
  where p_zip ~ '^\d{5}(-\d{4})?$' and substr(p_zip, 1, 3)::int between r.a and r.b
  limit 1;
$function$;
